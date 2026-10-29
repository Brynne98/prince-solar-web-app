#!/bin/bash
# One load step: grow the fake fleet to N inverters, fill today so far for every
# fake plant (so the day's tables are full size), then run N for M minutes.
#   load-test/step.sh 200 10 /path/results
set -euo pipefail
N=$1; MIN=${2:-10}; OUT=${3:-/tmp}
DIR=$(cd "$(dirname "$0")" && pwd)
q() { docker exec solar-loadtest-client psql -h solar-loadtest-db -U postgres -Atq -v ON_ERROR_STOP=1 -c "$1"; }

q "select loadtest.add_fleet($N)" >/dev/null
# Today so far, from 00:00 SAST, 50 plants per call to keep each transaction small.
FROM=$(q "select extract(epoch from date_trunc('day', now() at time zone 'Africa/Johannesburg') at time zone 'Africa/Johannesburg')::bigint")
TO=$(( $(date +%s) / 60 * 60 - 60 ))
HI=$(( 900000 + N / 2 ))
t0=$(date +%s)
for ((lo = 900001; lo <= HI; lo += 50)); do
  hi=$(( lo + 49 < HI ? lo + 49 : HI ))
  q "select loadtest.prefill($lo, $hi, $FROM, $TO)" >/dev/null
done
q "vacuum analyze public.readings, public.strings, public.agg_minute" >/dev/null
echo "{\"prefill\":true,\"inverters\":$N,\"seconds\":$(( $(date +%s) - t0 ))}" | tee -a "$OUT/$N.jsonl"
node "$DIR/run.mjs" --inverters "$N" --minutes "$MIN" --out "$OUT/$N.jsonl"
