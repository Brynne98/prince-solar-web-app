#!/bin/sh
# Lets these accounts pay on the Paystack test key in production (SOLAR-267): looks up
# their user ids by email and sets the PAYSTACK_TEST_USERS secret. Replaces the list.
#   scripts/set-test-users.sh                    # brynneprince98+test@gmail.com
#   scripts/set-test-users.sh a@x.com b@y.com
# No redeploy needed: the billing function reads the secret on its next start.
set -eu
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- brynneprince98+test@gmail.com
case "$*" in *"'"*) echo "no quotes in emails" >&2; exit 1 ;; esac
emails=$(printf "'%s'," "$@")
got=$(supabase db query --linked -o csv \
  "select count(*) || ' ' || coalesce(string_agg(id::text, ','), '') from auth.users where email in (${emails%,})" 2>/dev/null | tail -1)
n=${got%% *} ids=${got#* }
if [ "$n" != "$#" ]; then echo "found $n of $# accounts; check the emails" >&2; exit 1; fi
supabase secrets set PAYSTACK_TEST_USERS="$ids"
echo "PAYSTACK_TEST_USERS set for $n account(s): $*"
