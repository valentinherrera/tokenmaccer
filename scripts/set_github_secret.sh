#!/bin/bash
# Sets the client secret of the GitHub OAuth app "TokenMaccer Leaderboard" on the hosted Supabase
# project qcjbdnwxijosfxyngbfk. Run it yourself, from anywhere:
#
#     scripts/set_github_secret.sh
#
# The secret is read hidden from the terminal, handed to `supabase config push` only through the
# environment of that one process, and never printed, logged or written to disk. The script prints
# "gesetzt" or a short error, nothing else.
#
# Re-running config push later without the secret does not clear it: the CLI skips credential
# fields whose env reference is unset ("will not be pushed").
set -u

REF="qcjbdnwxijosfxyngbfk"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://${REF}.supabase.co"
PUBLISHABLE_KEY="sb_publishable_tfwEaH4P3kOsz7O1N5EbNQ_tn2_eF-a"

if ! command -v supabase >/dev/null 2>&1; then
    echo "Fehler: supabase CLI fehlt (brew install supabase/tap/supabase)." >&2
    exit 1
fi

printf 'GitHub Client Secret (Eingabe unsichtbar): ' >&2
IFS= read -r -s secret
printf '\n' >&2
if [ -z "${secret}" ]; then
    echo "Fehler: leeres Secret, nichts geändert." >&2
    exit 1
fi

# Push with a 5-minute ceiling; all CLI output is discarded so nothing secret can reach the terminal.
cd "${ROOT}" || exit 1
SUPABASE_AUTH_EXTERNAL_GITHUB_SECRET="${secret}" \
    perl -e 'alarm shift; exec @ARGV' 300 \
    supabase config push --project-ref "${REF}" --yes </dev/null >/dev/null 2>&1
status=$?
unset secret
if [ "${status}" -ne 0 ]; then
    echo "Fehler: config push fehlgeschlagen (Exit ${status}). Angemeldet? supabase login" >&2
    exit 1
fi

# Check: with a secret in place, the authorize endpoint redirects to GitHub instead of answering 400.
# The hosted auth service applies a config push after a few seconds, so retry for up to a minute.
tries=0
while :; do
    code="$(curl -s -m 30 -o /dev/null -w '%{http_code}' \
        -H "apikey: ${PUBLISHABLE_KEY}" "${URL}/auth/v1/authorize?provider=github")"
    tries=$((tries + 1))
    if [ "${code}" = "302" ] || [ "${code}" = "303" ] || [ "${tries}" -ge 12 ]; then
        break
    fi
    sleep 5
done
if [ "${code}" = "302" ] || [ "${code}" = "303" ]; then
    echo "gesetzt"
else
    echo "Fehler: Secret übertragen, aber GitHub-Anmeldung antwortet mit HTTP ${code}." >&2
    exit 1
fi
