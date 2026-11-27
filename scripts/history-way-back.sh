#!/usr/bin/env bash
# SOLAR-686 H23: the way back from 0284, written from main's function files.
#
#   scripts/history-way-back.sh <git ref before 0284, e.g. main> > way-back.sql
#   psql "$DB" -v ON_ERROR_STOP=1 -f way-back.sql
#
# One transaction: open imports and holes go back into the old bookmarks and queues, the old
# functions and trigger come back as they were at <ref>, the new jobs go and the old ones come
# back, schema history and the throttle column are dropped. The old edge functions (recover,
# sync-plant-energy) are deployed again from <ref> after it.
set -euo pipefail
REF="${1:?git ref before 0284}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
F=supabase/schemas/functions
old() { git -C "$REPO" show "$REF:$F/$1.sql"; echo; }

cat <<'SQL'
begin;
set local lock_timeout = '5s';
-- the work History holds now, back into the old bookmarks and queues
update public.plant_config c
   set backfill_next = x.floor_day, backfill_until = x.top, backfill_tries = 0
  from (select i.plant, i.floor_day, max(d.day) filter (where d.kind = 'minutes') as top
          from history.imports i join history.days d on d.import = i.id and d.status = 'queued'
         where i.status = 'open' group by i.plant, i.floor_day) x
 where c.plant_id = x.plant and x.top is not null;
update public.plant_config c set temp_next = x.d, temp_tries = 0
  from (select plant, min(day) d from history.days where status = 'queued' and kind = 'extras' group by plant) x
 where c.plant_id = x.plant;
insert into private.refill_queue (plant_id)
select distinct plant from history.days where status = 'queued' and why = 'gap'
on conflict do nothing;
insert into billing.history_lanes (lane, backoff_s, backoff_until)
select lane, backoff_s, backoff_until from history.lanes
on conflict (lane) do update set backoff_s = excluded.backoff_s, backoff_until = excluded.backoff_until;

-- the new jobs off (schedule_jobs below puts the old ones back)
select cron.unschedule(jobname) from cron.job where jobname in ('history', 'history-check', 'history-totals', 'history-trim');

drop function billing.request_history(uuid, bigint[], timestamp with time zone, boolean, text);
SQL
for f in billing/request_history billing/apply_purchase billing/write_seats billing/purge_now public/billing_jobs \
         public/plant_config_seed private/plant_start_fill public/plant_bootstrap_kick public/poll_commit_batch \
         public/poll_commit public/q_missing_minutes_day plants/plant_listed public/api_overview public/api_plant_states \
         private/history_done private/email_on_history public/plant_history_loading public/plant_bookmarks_clear \
         private/first_load_continue public/q_missing_minutes billing/history_take billing/history_step billing/history_renew \
         private/schedule_jobs; do
  old "$f"
done
cat <<'SQL'
create trigger email_on_history after update of backfill_next, temp_next on public.plant_config
  for each row execute function private.email_on_history();
drop function public.history_jobs(text, jsonb);
drop function public.login_throttled(uuid);
drop function plants.throttled(uuid, timestamptz);
drop schema history cascade;
alter table plants.logins drop column throttled_at;
delete from public.app_config where key in ('HISTORY_DAYS', 'HISTORY_CALLS_PER_MINUTE');
select private.schedule_jobs();
delete from supabase_migrations.schema_migrations where version = '0284';
commit;
SQL
