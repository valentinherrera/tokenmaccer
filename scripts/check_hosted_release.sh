#!/bin/bash
# Before a public release: what the app and the privacy notice promise must already be true on the servers.
#   1. The privacy notice the join sheet links to (and its German version) is reachable (HTTP 200), so nobody
#      lands on a 404 before consenting. The link points at the public repository's main branch.
#   2. The hosted auth server allows GitHub sign-in and has e-mail sign-up switched off
#      (supabase/config.toml [auth.email] enable_signup = false, applied with `supabase config push`).
#   3. Every migration in supabase/migrations is applied to the hosted project (`supabase db push`).
# Read only: one GET per link, one GET of the public auth settings, `supabase migration list`.
#
#   scripts/check_hosted_release.sh
# Overrides, for testing against the local stack or another project:
#   TM_PRIVACY_URL        default: privacyURL in app/App/OnboardingViews.swift
#   TM_AUTH_URL TM_AUTH_KEY  default: url and publishable_key in supabase/app-config.json
#   TM_MIGRATION_LIST     a file with the output of `supabase migration list` instead of running it
#   TM_MIGRATION_ARGS     default: --project-ref <project_ref from app-config.json>; e.g. --local
# `supabase migration list` against the hosted project needs `supabase login` and the database password
# (SUPABASE_DB_PASSWORD or the prompt).
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
  for link in "$PRIVACY" "${PRIVACY%.md}.de.md"; do
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
if [ -n "${TM_MIGRATION_LIST:-}" ]; then
  listing="$(cat "$TM_MIGRATION_LIST")"
else
  read -r -a margs <<<"${TM_MIGRATION_ARGS:---project-ref $(cfg project_ref)}"
  listing="$(cd "$ROOT" && supabase migration list "${margs[@]}" 2>/dev/null || true)"
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
if [ -z "$remote" ]; then
  bad "migrations: no remote versions listed (supabase login, database password?)"
else
  for file in "$ROOT"/supabase/migrations/*.sql; do
    version="$(basename "$file" | cut -d_ -f1)"
    if grep -qx "$version" <<<"$remote"; then ok "migration $version applied"; else bad "migration $version not applied (supabase db push)"; fi
  done
fi
exit "$fail"
