#!/usr/bin/env bash
# verify.sh <verify.sql>  -- after the window: run the SQL. Exit code decides.
# The SQL file is a `do $$` block that raises on any failed criterion, followed by a
# `select report from _verify_report`. The before/after alerts hash went with
# api_alerts_due (0266, SOLAR-660).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQL="${1:?usage: $0 <verify.sql>}"
set +e; out="$(supabase --workdir "$ROOT" db query --linked -f "$SQL" 2>&1)"; rc=$?; set -e
echo "$out" | grep -v "new version\|recommend\|untrusted\|boundary\|Initialising" || true
[ $rc -eq 0 ] || exit $rc
echo "$out" | grep -q 'PASS' || { echo "no PASS line"; exit 1; }
