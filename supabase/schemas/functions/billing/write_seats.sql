CREATE OR REPLACE FUNCTION billing.write_seats(p_account uuid, p_want bigint[], p_at timestamp with time zone, p_reason text DEFAULT 'switched'::text, p_counts boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare had bigint[]; held boolean;
begin
  held := billing.reading_held(p_account, p_at);                                  -- 0256
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  update billing.seats set closed_at = p_at, close_reason = p_reason
   where account = p_account and closed_at is null and plant <> all (p_want);
  insert into billing.seats (account, plant, chosen_at)
  select p_account, x, p_at from unnest(p_want) x where x <> all (had);
  update billing.plants set trial_used_at = coalesce(trial_used_at, p_at),
                            trial_used_by = coalesce(trial_used_by, p_account)
   where id = any (p_want) and id <> all (had) and (trial_used_at is null or trial_used_by is null);
  update billing.plants set version = version + 1
   where id = any (p_want || had) and not (id = any (p_want) and id = any (had));
  update billing.history_fetches set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null
   where account = p_account and status in ('queued', 'running') and plant = any (had) and plant <> all (p_want);
  -- a seat opening (or a plan restarting) on a deleted plant: it gathers history again. The
  -- caller holds the plant locks, so no write path has to touch the row.
  update billing.plants set history_purged_at = null
   where id = any (p_want) and history_purged_at is not null;
  -- a plant switched out that no account keeps is deleted now, under its lock, so the
  -- pop-up's "deleted now" holds even if the owner switches straight back
  perform billing.purge_now(x, p_at) from unnest(had) x where x <> all (p_want);
  perform billing.request_history(p_account, array(select x from unnest(p_want) x where x <> all (had)), p_at, p_counts);
  perform billing.readings_start(p_account, case when held then p_want                       -- 0256
                                      else array(select x from unnest(p_want) x where x <> all (had)) end, p_at);
end $function$;
