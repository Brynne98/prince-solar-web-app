#!/usr/bin/env bash
# SOLAR-686 H23: rehearse 0284 on a full local copy of production, history rows included.
#
#   scripts/rehearse-history.sh <folder holding supabase/ of a LOCAL stack> <scratch folder>
#
# 1. the local stack is reset to 0283 (production's migration today)
# 2. production's data, read only (supabase db dump --remote, data only), without tokens, Vault,
#    sign-ins, payment cards, mail bodies or push keys; logins copied without their tokens;
#    auth users as ids with masked emails
# 3. 0284 runs while a stand-in reader saves a minute every 2 s on copied plants; the log has the
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

log "reset the local stack to 0283"
supabase db reset --local --workdir "$WD" --version 0283 --no-seed >/dev/null
"$PSQL" -Xq "$DB" -c "select cron.unschedule(jobid) from cron.job" >/dev/null 2>&1 || true

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

log "load the copy"
"$PSQL" -Xq -v ON_ERROR_STOP=1 "$DB" <<SQL
set session_replication_role = replica;
create temp table u (id uuid);
\\copy u from '$OUT/users.csv' with (format csv)
insert into auth.users (id, aud, role, email) select id, 'authenticated', 'authenticated', 'u' || left(md5(id::text), 10) || '@copy.invalid'
  from u on conflict (id) do nothing;
\\copy plants.logins (id, account, user_id, brand, kind, username, status, linked_at, last_ok_at, last_error, last_try_at, last_try) from '$OUT/logins.csv' with (format csv)
\\i $OUT/data.sql
update plants.logins set username = 'login-' || left(md5(username), 8) where kind = 'login';
SQL
"$PSQL" -XAt "$DB" -c "select 'copy: ' || pg_size_pretty(pg_database_size(current_database())) || ', agg_minute ' ||
  (select count(*) from public.agg_minute) || ', inverter_history ' || (select count(*) from public.inverter_history) ||
  ', plant_config with temp_next ' || (select count(*) from public.plant_config where temp_next is not null)" | tee -a "$OUT/rehearsal.log"
"$PSQL" -XAt "$DB" -c "select 'before: open fetches ' || (select count(*) from billing.history_fetches where status in ('queued','running'))
  || ', refills ' || (select count(*) from private.refill_queue) || ', backfills ' || (select count(*) from public.plant_config where backfill_next is not null)" | tee -a "$OUT/rehearsal.log"

log "release 0284 with a stand-in reader saving every 2 s"
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
"$PSQL" -X -v ON_ERROR_STOP=1 "$DB" -f "$REPO/supabase/migrations/0284_history_engine.sql" > "$OUT/release.out" 2>&1 \
  && "$PSQL" -Xq "$DB" -c "insert into supabase_migrations.schema_migrations (version, name) values ('0284', 'history_engine')"
log "release took $(python3 -c "import time; print(round(time.time() - $T0, 1))") s; $(grep -o 'SOLAR-686 copy:.*' "$OUT/release.out")"
wait $SAVER
log "stand-in reader: $(grep -c . "$OUT/saves.log") saves, $(grep -c failed "$OUT/saves.log" || true) failed, longest $(grep -v failed "$OUT/saves.log" | sort -n | tail -1) ms"
"$PSQL" -XAt "$DB" -c "select 'after: open imports ' || (select count(*) from history.imports where status = 'open') || ', queued days ' ||
  (select count(*) from history.days where status = 'queued') || ', lanes ' || (select count(*) from history.lanes) ||
  ', old jobs left ' || (select count(*) from cron.job where jobname in ('recover', 'billing-history', 'first-load-continue', 'plant-energy'))" | tee -a "$OUT/rehearsal.log"
