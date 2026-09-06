#!/usr/bin/env bash
# verify.sh <verify.sql> snapshot <file>  -- before deploy: store the alerts hash
# verify.sh <verify.sql> check    <file>  -- after the window: run the SQL, compare the hash
# The SQL file is a `do $$` block that raises on any failed criterion, followed by a
# `select report from _verify_report`. Exit code decides.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQL="$1"; MODE="${2:-}"; FILE="${3:-}"
HASH_SQL="select md5(coalesce(jsonb_agg(to_jsonb(a) order by a.key)::text, '[]')) as h from public.plant_users pu, public.api_alerts_due(pu.plant_id) a"
hash() { supabase --workdir "$ROOT" db query --linked "$HASH_SQL" | grep -o '"h": *"[0-9a-f]*"' | grep -o '[0-9a-f]\{32\}'; }
case "$MODE" in
  snapshot) h="$(hash)"; [ -n "$h" ] || { echo "no hash"; exit 1; }; echo "$h" > "$FILE"; echo "alerts snapshot $h";;
  check)
    set +e; out="$(supabase --workdir "$ROOT" db query --linked -f "$SQL" 2>&1)"; rc=$?; set -e
    echo "$out" | grep -v "new version\|recommend\|untrusted\|boundary\|Initialising" || true
    [ $rc -eq 0 ] || exit $rc
    echo "$out" | grep -q 'PASS' || { echo "no PASS line"; exit 1; }
    before="$(cat "$FILE")"; after="$(hash)"
    [ "$before" = "$after" ] || { echo "FAIL alerts changed: $before -> $after"; exit 1; }
    echo "alerts unchanged ($after)";;
  *) echo "usage: $0 <verify.sql> snapshot|check <file>"; exit 2;;
esac
