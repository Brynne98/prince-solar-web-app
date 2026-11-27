#!/usr/bin/env bash
# SOLAR-686 H23: rehearse 0285 on a full local copy of production, history rows included.
#
#   scripts/rehearse-history.sh <folder holding supabase/ of a LOCAL stack> <scratch folder>
#
# 1. the local stack is reset to 0284 (production's newest migration today)
# 2. production's data, read only (supabase db dump --remote, data only), without tokens, Vault,
#    sign-ins, payment cards, mail bodies or push keys; logins copied without their tokens;
#    auth users as ids with masked emails
# 3. 0285 runs while a stand-in reader saves a minute every 2 s on copied plants; the log has the
#    release time, the copy's compare, the saves' longest wait
# 4. the way back: the old jobs and callers switched back, bookmarks copied back (H23)
# The dump stays in the scratch folder only; delete it after the proof (it holds production rows).
set -euo pipefail
WD="$(cd "$1" && pwd)"; OUT="$2"; mkdir -p "$OUT"; umask 077
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PSQL="${PSQL:-/opt/homebrew/opt/libpq/bin/psql}"
DB="$(supabase status --workdir "$WD" -o env 2>/dev/null | sed -n 's/^DB_URL="\(.*\)"$/\1/p')"
case "$DB" in *127.0.0.1*|*localhost*) ;; *) echo "refusing: $DB is not local" >&2; exit 1 ;; esac
REF=pmakzojwhouamawgszrc
log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$OUT/rehearsal.log"; }

log "reset the local stack to 0284"
supabase db reset --local --workdir "$WD" --version 0284 --no-seed >/dev/null
# production's jobs, as 0283 left them, but paused: the copy calls nothing
"$PSQL" -Xq -v ON_ERROR_STOP=1 "$DB" -c "create extension if not exists pg_cron" -c "select private.schedule_jobs()" \
  -c "select cron.alter_job(jobid, active := false) from cron.job" >/dev/null

if [ ! -s "$OUT/data.sql" ]; then
log "dump production data (read only)"
supabase db dump --remote="$REF" --data-only --use-copy -s public,private,billing,plants,msg \
  -x plants.logins -x billing.payment_methods -x billing.payment_events -x msg.outbox -x msg.push_sends \
  -x public.push_subs -x public.email_queue -x private.feedback -x private.fn_calls \
  -f "$OUT/data.sql" >/dev/null
log "dump: $(du -h "$OUT/data.sql" | cut -f1)"
supabase db query --remote="$REF" --read-only -o csv \
  "select id, account, user_id, brand, kind, username, status, linked_at, last_ok_at, last_error, last_try_at, last_try from plants.logins" \
  2>/dev/null | sed 1d > "$OUT/logins.csv"
supabase db query --remote="$REF" --read-only -o csv "select id from auth.users" 2>/dev/null | sed 1d > "$OUT/users.csv"
fi
sed -i '' '1{/^id/d;}' "$OUT/logins.csv" "$OUT/users.csv"

log "load the copy"
# production's partitions of readings and strings (split into days over time; the migrations make
# months): the local ones go, production's are made with their own bounds
[ -s "$OUT/parts.csv" ] || supabase db query --remote="$REF" --read-only -o csv \
  "select n.nspname as schema, p.relname as parent, c.relname as child, pg_get_expr(c.relpartbound, c.oid) as bound from pg_inherits i join pg_class c on c.oid = i.inhrelid
     join pg_class p on p.oid = i.inhparent join pg_namespace n on n.oid = p.relnamespace
    where c.relkind in ('r', 'p') and n.nspname in ('public', 'private', 'billing', 'plants', 'msg')" 2>/dev/null > "$OUT/parts.csv"
python3 - "$OUT/parts.csv" > "$OUT/partitions.sql" <<'PY'
import csv, sys
rows = [r for r in csv.reader(open(sys.argv[1])) if r and r[0] != 'schema' and len(r) == 4]
for parent in sorted({(r[0], r[1]) for r in rows}):
    print(f"do $$ declare c text; begin for c in select format('%I.%I', n.nspname, k.relname) from pg_inherits i join pg_class k on k.oid = i.inhrelid join pg_namespace n on n.oid = k.relnamespace where i.inhparent = '{parent[0]}.{parent[1]}'::regclass loop execute 'drop table ' || c; end loop; end $$;")
for r in rows:
    print(f"create table {r[0]}.{r[2]} partition of {r[0]}.{r[1]} {r[3]};")
PY
"$PSQL" -Xq -v ON_ERROR_STOP=1 "$DB" -f "$OUT/partitions.sql"
"$PSQL" -Xq -v ON_ERROR_STOP=1 "$DB" <<SQL
set session_replication_role = replica;
-- the migrations' own rows (markets, plans, kinds...) give way to production's
do \$\$ declare t text; begin
  for t in select format('%I.%I', schemaname, tablename) from pg_tables
            where schemaname in ('public', 'private', 'billing', 'plants', 'msg') loop
    execute 'truncate ' || t || ' cascade';
  end loop;
end \$\$;
create temp table u (id uuid);
\\copy u from '$OUT/users.csv' with (format csv)
insert into auth.users (id, aud, role, email) select id, 'authenticated', 'authenticated', 'u' || left(md5(id::text), 10) || '@copy.invalid'
  from u on conflict (id) do nothing;
\\copy plants.logins (id, account, user_id, brand, kind, username, status, linked_at, last_ok_at, last_error, last_try_at, last_try) from '$OUT/logins.csv' with (format csv, null 'NULL')
\\i $OUT/data.sql
update plants.logins set username = 'login-' || left(md5(username), 8) where kind = 'login';
SQL
"$PSQL" -XAt "$DB" -c "select 'copy: ' || pg_size_pretty(pg_database_size(current_database())) || ', agg_minute ' ||
  (select count(*) from public.agg_minute) || ', inverter_history ' || (select count(*) from public.inverter_history) ||
  ', plant_config with temp_next ' || (select count(*) from public.plant_config where temp_next is not null)" | tee -a "$OUT/rehearsal.log"
"$PSQL" -XAt "$DB" -c "select 'before: open fetches ' || (select count(*) from billing.history_fetches where status in ('queued','running'))
  || ', refills ' || (select count(*) from private.refill_queue) || ', backfills ' || (select count(*) from public.plant_config where backfill_next is not null)" | tee -a "$OUT/rehearsal.log"

log "release 0285 with a stand-in reader saving every 2 s"
( for i in $(seq 1 60); do
    t0=$(python3 -c 'import time; print(time.time())')
    "$PSQL" -Xq "$DB" -c "begin; select set_config('billing.guarded', 'on', true);
      insert into public.agg_minute (plant_id, ts, pv_w, source)
      select p.id, (extract(epoch from now())::bigint / 60) * 60 + $i, 1, 'poller' from plants.plants p order by p.id limit 5
      on conflict do nothing;
      update plants.logins set last_try_at = now() where id = (select id from plants.logins order by id limit 1);
      commit;" >/dev/null 2>&1 || echo "save failed" >> "$OUT/saves.log"
    python3 -c "import time; print(round((time.time() - $t0) * 1000))" >> "$OUT/saves.log"
    sleep 2
  done ) &
SAVER=$!
sleep 4
T0=$(python3 -c 'import time; print(time.time())')
"$PSQL" -X -v ON_ERROR_STOP=1 "$DB" -f "$REPO/supabase/migrations/0285_history_engine.sql" > "$OUT/release.out" 2>&1 \
  && "$PSQL" -Xq "$DB" -c "insert into supabase_migrations.schema_migrations (version, name) values ('0285', 'history_engine')"
"$PSQL" -Xq "$DB" -c "select cron.alter_job(jobid, active := false) from cron.job" >/dev/null
log "release took $(python3 -c "import time; print(round(time.time() - $T0, 1))") s; $(grep -o 'SOLAR-686 copy:.*' "$OUT/release.out")"
wait $SAVER
log "stand-in reader: $(grep -c . "$OUT/saves.log") saves, $(grep -c failed "$OUT/saves.log" || true) failed, longest $(grep -v failed "$OUT/saves.log" | sort -n | tail -1) ms"
"$PSQL" -XAt "$DB" -c "select 'after: open imports ' || (select count(*) from history.imports where status = 'open') || ', queued days ' ||
  (select count(*) from history.days where status = 'queued') || ', lanes ' || (select count(*) from history.lanes) ||
  ', old jobs left ' || coalesce((select count(*) from cron.job where jobname in ('recover', 'billing-history', 'first-load-continue', 'plant-energy')), 0)" | tee -a "$OUT/rehearsal.log"

"$PSQL" -XAt "$DB" -c "select 'open work for the way back: ' || count(history.start(r.plant, null, 'restart')) || ' restarts'
  from (select distinct plant from billing.reading_routes(now()) order by plant limit 2) r" | tee -a "$OUT/rehearsal.log"
"$PSQL" -XAt "$DB" -c "select 'and ' || count(history.start(r.plant, r.account, 'switch', 1200, 4)) || ' paced switch'
  from (select plant, account from billing.reading_routes(now()) order by plant offset 2 limit 1) r" | tee -a "$OUT/rehearsal.log"
log "the way back, with the copy's open work in it"
# the code before 0285: the parent of the commit that first added it (as 0284, before it was renumbered)
BEFORE="$(git -C "$REPO" log --follow --diff-filter=A --format=%H -- supabase/migrations/0285_history_engine.sql | tail -1)^"
bash "$REPO/scripts/history-way-back.sh" "$BEFORE" > "$OUT/way-back.sql"
B0=$(python3 -c 'import time; print(time.time())')
"$PSQL" -X -v ON_ERROR_STOP=1 "$DB" -f "$OUT/way-back.sql" > "$OUT/way-back.out" 2>&1 && ok=yes || ok=no
log "way back: ran=$ok in $(python3 -c "import time; print(round(time.time() - $B0, 1))") s"
"$PSQL" -XAt "$DB" -c "select 'after the way back: history schema gone ' || (to_regnamespace('history') is null)
  || ', first loads ' || (select count(*) from public.plant_config where backfill_next is not null)
  || ', temperature walks behind ' || (select count(*) from public.plant_config where temp_next < (now() at time zone 'UTC')::date - 1)
  || ', fetches ' || (select count(*) from billing.history_fetches where status in ('queued', 'running'))
  || ', old jobs ' || (select count(*) from cron.job where jobname in ('recover', 'billing-history', 'first-load-continue', 'plant-energy'))
  || ', new jobs ' || (select count(*) from cron.job where jobname like 'history%' and jobname not like 'history-delete%')" | tee -a "$OUT/rehearsal.log"
