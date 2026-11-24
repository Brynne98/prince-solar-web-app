#!/bin/sh
# SOLAR-656 (0257): concurrent sunsynk_tally calls must not deadlock. LOCAL database only.
#   sh scripts/sql/tally-deadlock-test.sh "postgresql://postgres:postgres@127.0.0.1:<db port>/postgres" [function]
# 8 clients x 400 calls (TALLY_TX), half sending the rows in one order and half in reverse, the same
# six keys. pgbench exits non-zero when a call fails (a deadlock aborts the client).
# Its test rows (kind tt_*) are deleted after.
set -eu
DB="$1"
FN="${2:-public.sunsynk_tally}"
TX="${TALLY_TX:-400}"
BIN="${PGBIN:-/opt/homebrew/opt/libpq/bin}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"; "$BIN/psql" "$DB" -qc "delete from private.sunsynk_calls where kind like '"'"'tt\\_%'"'"'" >/dev/null' EXIT

cat > "$DIR/a.sql" <<EOF
begin;
select $FN('[{"kind":"tt_a","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_b","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_c","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_d","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_e","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_f","result":"ok","calls":1,"ms":5,"ms_max":5}]'::jsonb, null, null, null);
select pg_sleep(0.002);
commit;
EOF
cat > "$DIR/b.sql" <<EOF
begin;
select $FN('[{"kind":"tt_f","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_e","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_d","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_c","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_b","result":"ok","calls":1,"ms":5,"ms_max":5},{"kind":"tt_a","result":"ok","calls":1,"ms":5,"ms_max":5}]'::jsonb, null, null, null);
select pg_sleep(0.002);
commit;
EOF

"$BIN/pgbench" -n -c 8 -j 8 -t "$TX" -f "$DIR/a.sql" -f "$DIR/b.sql" "$DB" > "$DIR/out.txt" 2>&1 || { tail -5 "$DIR/out.txt"; echo "FAIL: a call failed"; exit 1; }
# every call counted: 8 clients x 400 calls, one per key each
"$BIN/psql" "$DB" -v ON_ERROR_STOP=1 -qAt -c "do \$\$ begin
  if (select count(*) <> 6 or min(calls) <> 8 * $TX or max(calls) <> 8 * $TX from private.sunsynk_calls where kind like 'tt\\_%') then
    raise exception 'FAIL: calls lost';
  end if; end \$\$"
echo "tally-deadlock-test: $((8 * TX)) concurrent calls, no deadlock, every call counted"
