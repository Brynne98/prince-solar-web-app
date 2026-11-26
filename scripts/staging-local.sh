#!/usr/bin/env bash
# Local staging (SOLAR-679 F10): a fresh local Supabase from every migration, with cron on and
# calling its own functions (F11), the fake SunSynk, the Paystack test key, and mail only through
# Resend when you ask for it. No live user data. Used in CI and on this machine.
#
#   scripts/staging-local.sh [<folder holding supabase/>]
#
# The folder defaults to the repo. To run beside another local stack, copy supabase/ to a folder
# of its own and give it its own project_id and ports in config.toml first.
#
# Settings it reads (none are printed):
#   PAYSTACK_SECRET_KEY  a Paystack test key (sk_test_...); no live key is accepted
#   RESEND_API_KEY       optional; mail is sent only with NOTIFY_LIVE=1 as well
#   NOTIFY_LIVE          optional, "1" to send mail
# Leaves running: the stack, the fake SunSynk on :4400, `supabase functions serve`. Logs and the
# functions' settings file go to $STAGING_DIR (default: a new temp folder). Stop with
# `supabase stop --workdir <folder>` and kill the two background jobs it names.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WD="$(cd "${1:-$REPO}" && pwd)"
OUT="${STAGING_DIR:-$(mktemp -d)}"
mkdir -p "$OUT"
PSQL="${PSQL:-$( [ -x /opt/homebrew/opt/libpq/bin/psql ] && echo /opt/homebrew/opt/libpq/bin/psql || echo psql )}"

case "${PAYSTACK_SECRET_KEY:-}" in
  sk_test_*) ;;
  "") echo "PAYSTACK_SECRET_KEY is not set: payments will fail (set a Paystack test key)" >&2 ;;
  *) echo "refusing: PAYSTACK_SECRET_KEY is not a test key" >&2; exit 1 ;;
esac

supabase start --workdir "$WD" -x studio,imgproxy,vector,logflare,supavisor,realtime,postgres-meta >/dev/null
eval "$(supabase status --workdir "$WD" -o env 2>/dev/null | grep -E '^(API_URL|DB_URL|SERVICE_ROLE_KEY)=')"
case "$DB_URL" in *127.0.0.1*|*localhost*) ;; *) echo "refusing: $DB_URL is not local" >&2; exit 1 ;; esac
PROJECT_ID="$(sed -n 's/^project_id = "\(.*\)"/\1/p' "$WD/supabase/config.toml")"

# cron and pg_net on, calling this stack's own functions through its gateway container
"$PSQL" -X -q -v ON_ERROR_STOP=1 "$DB_URL" \
  -v key="$SERVICE_ROLE_KEY" -v url="http://supabase_kong_${PROJECT_ID}:8000/functions/v1" <<'SQL'
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
delete from vault.secrets where name in ('service_role_key', 'functions_url');
select vault.create_secret(:'key', 'service_role_key') \g /dev/null
select vault.create_secret(:'url', 'functions_url') \g /dev/null
select private.schedule_jobs() \g /dev/null
SQL

# the fake SunSynk
if ! curl -s -o /dev/null http://127.0.0.1:4400/; then
  nohup node "$REPO/scripts/mock-sunsynk/server.js" >"$OUT/mock-sunsynk.log" 2>&1 &
  echo "fake SunSynk: pid $!"
fi

# the functions, with the fake SunSynk and test keys
ENVF="$OUT/functions.env"
umask 077
{
  grep -v '^#' "$REPO/scripts/mock-sunsynk/mock.env"
  [ -n "${PAYSTACK_SECRET_KEY:-}" ] && echo "PAYSTACK_SECRET_KEY=$PAYSTACK_SECRET_KEY"
  [ -n "${RESEND_API_KEY:-}" ] && echo "RESEND_API_KEY=$RESEND_API_KEY"
  echo "NOTIFY_LIVE=${NOTIFY_LIVE:-0}"
} >"$ENVF"
nohup supabase functions serve --workdir "$WD" --env-file "$ENVF" >"$OUT/functions.log" 2>&1 &
echo "functions: pid $!"
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$API_URL/functions/v1/link-sunsynk" || true)
  case "$code" in 2*|4*) break ;; esac
  sleep 2
done
echo "staging up: $API_URL (logs in $OUT)"
