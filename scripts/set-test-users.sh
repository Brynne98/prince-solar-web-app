#!/bin/sh
# Lets these accounts link fake SunSynk logins (name@mock) in production (SOLAR-270,
# SOLAR-477): looks up their user ids by email and sets the TESTER_USERS secret. Replaces
# the list. Billing is not touched: testers pay on the live key like everyone else.
#   scripts/set-test-users.sh                    # brynneprince98+test@gmail.com
#   scripts/set-test-users.sh a@x.com b@y.com
# No redeploy needed: link-sunsynk reads the secret on its next start.
set -eu
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- brynneprince98+test@gmail.com
case "$*" in *"'"*) echo "no quotes in emails" >&2; exit 1 ;; esac
emails=$(printf "'%s'," "$@")
got=$(supabase db query --linked -o csv \
  "select count(*) || ' ' || coalesce(string_agg(id::text, ','), '') from auth.users where email in (${emails%,})" 2>/dev/null | tail -1 | tr -d '"')
n=${got%% *} ids=${got#* }
if [ "$n" != "$#" ]; then echo "found $n of $# accounts; check the emails" >&2; exit 1; fi
supabase secrets set TESTER_USERS="$ids"
echo "TESTER_USERS set for $n account(s): $*"
