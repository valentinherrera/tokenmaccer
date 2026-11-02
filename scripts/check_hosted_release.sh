#!/bin/bash
# Before a public release: what the app and the privacy notice promise must already be true on the servers.
#   1. The hosted privacy notice README and website link to (and its German version) is reachable (HTTP 200).
#      The app itself opens the copy it bundles; the URL is privacyURL in app/App/OnboardingViews.swift and
#      points at the public repository's main branch.
#   2. The hosted auth server allows GitHub sign-in and has e-mail sign-up switched off
#      (supabase/config.toml [auth.email] enable_signup = false, applied with `supabase config push`).
#   3. Every migration in supabase/migrations is applied to the hosted project (`supabase db push`).
#   4. The website answers invitation links (https://tokenmaccer.app/join/<code> hands over to tokenmaccer://join/<code>,
#      docs/join.html behind the rewrite in docs/vercel.json), and the app shares them as such
#      (GroupInvite.siteLive = true in app/Shared/GroupInvite.swift).
# Read only: one GET per link, one GET of the public auth settings, `supabase migration list`.
#
#   scripts/check_hosted_release.sh
# Overrides, for testing against the local stack or another project:
#   TM_PRIVACY_URL        default: privacyURL in app/App/OnboardingViews.swift
#   TM_AUTH_URL TM_AUTH_KEY  default: url and publishable_key in supabase/app-config.json
#   TM_MIGRATION_LIST     a file with the output of `supabase migration list` instead of running it
#   TM_MIGRATION_ARGS     default: --project-ref <project_ref from app-config.json>; e.g. --local
#   TM_SITE_URL           default: https://tokenmaccer.app (e.g. http://localhost:3517 for `vercel dev` in docs/)
# `supabase migration list` against the hosted project needs `supabase login` and the database password in
# SUPABASE_DB_PASSWORD (`read -s SUPABASE_DB_PASSWORD; export SUPABASE_DB_PASSWORD`). The script passes it
# with --password: without it, CLI v2.121 tries to create a temporary login role, which the hosted project
# refuses ("permission denied to alter role cli_login_postgres"). Without the variable the check fails by
# name instead of running the CLI; any CLI error is printed, not swallowed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/supabase/app-config.json"
cfg() { /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$CONFIG" "$1"; }

fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# 1. Privacy notice links
PRIVACY="${TM_PRIVACY_URL:-$(sed -n 's/.*privacyURL = URL(string: "\([^"]*\)")!.*/\1/p' "$ROOT/app/App/OnboardingViews.swift" | head -1)}"
if [ -z "$PRIVACY" ]; then
  bad "privacy link: no privacyURL found in app/App/OnboardingViews.swift"
else
  # A .md file (GitHub) has its German twin next to it as .de.md; a page on tokenmaccer.app has it under /de.
  case "$PRIVACY" in *.md) german="${PRIVACY%.md}.de.md" ;; *) german="${PRIVACY%/}/de" ;; esac
  for link in "$PRIVACY" "$german"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 "$link" 2>/dev/null || true)"
    if [ "$code" = 200 ]; then ok "privacy link $link"; else bad "privacy link $link: HTTP ${code:-none} (push docs/ to main first)"; fi
  done
fi

# 2. Auth settings of the hosted project
AUTH_URL="${TM_AUTH_URL:-$(cfg url)}"
AUTH_KEY="${TM_AUTH_KEY:-$(cfg publishable_key)}"
settings="$(curl -fsS --max-time 20 -H "apikey: $AUTH_KEY" "$AUTH_URL/auth/v1/settings" 2>/dev/null || true)"
verdict="$(/usr/bin/python3 -I -c '
import json, sys
try:
    s = json.loads(sys.stdin.read())
except ValueError:
    print("no settings (auth server unreachable?)"); sys.exit()
ext = s.get("external", {})
problems = []
if ext.get("github") is not True: problems.append("GitHub sign-in is off")
if ext.get("email") is not False: problems.append("e-mail sign-up is on (supabase config push)")
if s.get("disable_signup") is not False: problems.append("sign-up is disabled for everyone, new GitHub users could not join")
print("; ".join(problems) or "ok")
' <<<"$settings")"
if [ "$verdict" = ok ]; then ok "auth $AUTH_URL: GitHub on, e-mail sign-up off"; else bad "auth $AUTH_URL: $verdict"; fi

# 3. Migrations applied
listing=""
cli_error=""
if [ -n "${TM_MIGRATION_LIST:-}" ]; then
  listing="$(cat "$TM_MIGRATION_LIST")"
elif [ -z "${TM_MIGRATION_ARGS:-}" ] && [ -z "${SUPABASE_DB_PASSWORD:-}" ]; then
  cli_error="SUPABASE_DB_PASSWORD is not set (read -s SUPABASE_DB_PASSWORD; export SUPABASE_DB_PASSWORD)"
else
  if [ -n "${TM_MIGRATION_ARGS:-}" ]; then
    read -r -a margs <<<"$TM_MIGRATION_ARGS"
  else
    margs=(--project-ref "$(cfg project_ref)" --password "$SUPABASE_DB_PASSWORD")
  fi
  errfile="$(mktemp)"
  if listing="$(cd "$ROOT" && supabase migration list "${margs[@]}" </dev/null 2>"$errfile")"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    # Outside a terminal the CLI reports errors as JSON on stdout ({"_tag": "Error", "error": {"message"}}),
    # otherwise as text on stderr. Show whichever there is, without the update notice.
    cli_error="$(/usr/bin/python3 -I -c '
import json, sys
out, err = sys.argv[1], open(sys.argv[2]).read()
try:
    msg = json.loads(out)["error"]["message"]
except (ValueError, KeyError, TypeError):
    lines = [l for l in (err + "\n" + out).splitlines()
             if l.strip() and "new version of Supabase CLI" not in l and "recommend updating" not in l]
    msg = " / ".join(lines[-4:]) or "no output"
print(" ".join(str(msg).split())[:400])
' "$listing" "$errfile")"
    cli_error="supabase migration list exited $rc: $cli_error"
    listing=""
  fi
  rm -f "$errfile"
fi
# Outside a terminal the CLI prints JSON ({"migrations": [{"local", "remote", "time"}]}), in a terminal a
# table "local | remote | time". Take the remote versions from either.
remote="$(/usr/bin/python3 -I -c '
import json, re, sys
text = sys.stdin.read()
try:
    rows = [str(m.get("remote") or "") for m in json.loads(text)["migrations"]]
except (ValueError, KeyError, TypeError, AttributeError):
    rows = [line.split("|")[1].strip() for line in text.splitlines() if line.count("|") >= 2]
print("\n".join(v for v in rows if re.fullmatch(r"[0-9]+", v)))
' <<<"$listing")"
if [ -n "$cli_error" ]; then
  bad "migrations: $cli_error"
elif [ -z "$remote" ]; then
  bad "migrations: no remote versions listed"
else
  for file in "$ROOT"/supabase/migrations/*.sql; do
    version="$(basename "$file" | cut -d_ -f1)"
    if grep -qx "$version" <<<"$remote"; then ok "migration $version applied"; else bad "migration $version not applied (supabase db push)"; fi
  done
fi

# 4. Invitation links on the website
SITE="${TM_SITE_URL:-https://tokenmaccer.app}"
SITE="${SITE%/}"
join="$SITE/join/k7m2p9qrst"
page="$(curl -sS --max-time 20 -w '\n%{http_code}' "$join" 2>/dev/null || true)"
status="${page##*$'\n'}"
if [ "$status" != 200 ]; then
  bad "invitation page $join: HTTP ${status:-none} (deploy docs/ to Vercel)"
elif ! grep -q "tokenmaccer://join/" <<<"$page"; then
  bad "invitation page $join: answers, but without the hand-over to tokenmaccer://join/ (docs/join.html?)"
else
  ok "invitation page $join"
fi
if grep -q 'static let siteLive = true' "$ROOT/app/Shared/GroupInvite.swift"; then
  ok "app shares invitation links as $SITE/join/… (siteLive)"
else
  bad "app still shares the tokenmaccer:// fallback: set GroupInvite.siteLive = true in app/Shared/GroupInvite.swift"
fi
exit "$fail"
