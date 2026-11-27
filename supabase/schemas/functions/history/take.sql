CREATE OR REPLACE FUNCTION history.take(p_shard integer DEFAULT 0, p_shards integer DEFAULT 1, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cap int := ceil(history.setting('HISTORY_CALLS_PER_MINUTE', 600)::numeric / greatest(p_shards, 1));
  used int;
  out jsonb := '[]';
  ln uuid;
  r record;
  imp bigint;
  c int;
  cl uuid;
  got boolean;
begin
  if p_shards < 1 or p_shard < 0 or p_shard >= p_shards then
    raise exception 'history.take: shard % of %', p_shard, p_shards;
  end if;
  if p_shard = 0 then perform history.tidy(p_at); end if;
  used := coalesce((select hc.calls from history.calls hc where hc.minute = date_trunc('minute', p_at) and hc.shard = p_shard), 0);

  -- the routes and the plants' versions in one statement (one snapshot): a step carries the version
  -- its route was read at, so a route that changes before the write is refused (H8)
  create temp table if not exists _ht_route (plant bigint primary key, account uuid, lane uuid, version bigint) on commit drop;
  truncate _ht_route;
  -- one route per plant first, then this group's logins: a plant two accounts read is in one group
  insert into _ht_route
  select x.plant, x.account, x.lane, x.version from (
    select distinct on (rr.plant) rr.plant, rr.account, rr.lane, p.version
      from billing.reading_routes(p_at) rr
      join plants.login_info l on l.id = rr.lane and l.status = 'ok'
      join plants.plant_info p on p.id = rr.plant
     where not private.history_deleting(rr.plant)
     order by rr.plant,
              exists (select 1 from history.import_accounts ia join history.imports i on i.id = ia.import
                       where i.plant = rr.plant and i.status = 'open' and ia.left_at is null and ia.account = rr.account) desc,
              rr.via_share, rr.since, rr.account, rr.lane) x
   where abs(hashtext(x.lane::text)) % p_shards = p_shard
     and not plants.throttled(x.lane, p_at - interval '2 minutes')
     and not exists (select 1 from history.lanes hl where hl.lane = x.lane and hl.backoff_until > p_at);

  -- the logins in a new order each call, so the share of the cap is not always spent on the same ones
  for ln in select y.lane from (select distinct x.lane from _ht_route x) y order by random() loop
    exit when used >= cap;
    continue when exists (select 1 from history.days d where d.lane = ln and d.status = 'queued' and d.claimed_until > p_at)
               or exists (select 1 from history.totals t where t.lane = ln and t.claimed_until > p_at);
    -- the import this login is walking, when its next step is due; else a new one
    imp := null;
    select i.id into imp from history.imports i join _ht_route x on x.plant = i.plant and x.lane = ln
     where i.status = 'open' and i.started_at is not null and i.next_at <= p_at
       and exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null and a.account = x.account)
     order by i.started_at, i.id limit 1;
    if imp is null and not exists (select 1 from history.imports i join _ht_route x on x.plant = i.plant and x.lane = ln
                                    where i.status = 'open' and i.started_at is not null and i.next_at <= p_at + interval '5 seconds') then
      select i.id into imp from history.imports i join _ht_route x on x.plant = i.plant and x.lane = ln
       where i.status = 'open' and i.started_at is null
         and exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null and a.account = x.account)
       order by (select max(o.started_at) from history.imports o join history.import_accounts oa on oa.import = o.id
                  where o.lane = ln and o.id <> i.id
                    and oa.account in (select a.account from history.import_accounts a where a.import = i.id)) nulls first,
                i.requested_at, i.id
       limit 1;
    end if;

    -- the candidates, the one due longest ago first; a hole before totals before an import on a tie
    got := false;
    for r in
      select * from (
        (select 'day' as k, d.id, d.plant, d.kind, d.grid_only, false as full_sweep, d.due_at as due, 0 as pri, d.import
           from history.days d join _ht_route x on x.plant = d.plant and x.lane = ln
          where d.status = 'queued' and d.import is null and d.due_at <= p_at
            and (d.claimed_until is null or d.claimed_until <= p_at)
          order by (d.why = 'gap') desc, d.day desc, (d.kind = 'minutes') desc, d.id limit 1)
        union all
        (select 'totals', t.plant, t.plant, 'totals', false, t.full_sweep, t.due_at, 1, null::bigint
           from history.totals t join _ht_route x on x.plant = t.plant and x.lane = ln
          where t.due_at <= p_at and (t.claimed_until is null or t.claimed_until <= p_at)
          order by t.due_at, t.plant limit 1)
        union all
        (select 'day', d.id, d.plant, d.kind, d.grid_only, false, coalesce((select i.next_at from history.imports i where i.id = d.import), d.due_at), 2, d.import
           from history.days d
          where imp is not null and d.import = imp and d.status = 'queued' and d.due_at <= p_at
            and (d.claimed_until is null or d.claimed_until <= p_at)
          order by d.day desc, (d.kind = 'minutes') desc, d.id limit 1)) cand
      order by due, pri
    loop
      c := history.cost(r.kind, r.plant, r.grid_only, r.full_sweep);
      -- within the group's share: a step that does not fit gives way to this login's next one; the
      -- first step of a minute always goes, so a dear one (kWh totals, many inverters) is never
      -- shut out (the logins come in a new order each call)
      continue when used > 0 and used + c > cap;
      cl := gen_random_uuid();
      if r.k = 'day' then
        -- the import first, then the day (one lock order with step_done and stop: import, then day)
        if r.import is not null then
          update history.imports set started_at = coalesce(started_at, p_at), next_at = coalesce(next_at, p_at), lane = ln
           where id = r.import and status = 'open';
        end if;
        update history.days d set claim = cl, claimed_until = p_at + interval '90 seconds', lane = ln, calls = c, shard = p_shard,
                                  version = (select x.version from _ht_route x where x.plant = d.plant)
         where d.id = r.id and d.status = 'queued' and (d.claimed_until is null or d.claimed_until <= p_at);
      else
        update history.totals t set claim = cl, claimed_until = p_at + interval '90 seconds', lane = ln, calls = c, shard = p_shard,
                                    version = (select x.version from _ht_route x where x.plant = t.plant)
         where t.plant = r.id and (t.claimed_until is null or t.claimed_until <= p_at);
      end if;
      continue when not found;   -- another run took or closed it in the meantime
      used := used + c;
      got := true;
      out := out || jsonb_build_array((
        select jsonb_build_object(
          'step', r.k, 'id', r.id, 'claim', cl, 'plant', r.plant, 'version', x.version, 'kind', r.kind,
          'day', d.day, 'why', d.why, 'tries', coalesce(d.tries, 0), 'grid_only', r.grid_only, 'full', r.full_sweep, 'calls', c,
          -- the plant feed fills what inverter history cannot, for the days it still holds (H11)
          'feed', coalesce(d.why <> 'import' or d.day >= (p_at at time zone plants.tz(r.plant))::date - 13, false),
          'timezone', plants.tz(r.plant), 'brand', p.brand, 'vendor_plant_id', p.vendor_id,
          'login', jsonb_build_object('id', l.id, 'user_id', l.user_id, 'username', l.username, 'brand', l.brand,
                                      'access_token', tk.access_token, 'access_expires_at', tk.access_expires_at))
          from _ht_route x
          join plants.plant_info p on p.id = x.plant
          join plants.login_info l on l.id = ln
          join plants.login_tokens tk on tk.id = l.id
          left join history.days d on r.k = 'day' and d.id = r.id
         where x.plant = r.plant));
      exit;   -- one step per login
    end loop;
  end loop;
  insert into history.calls as hc (minute, shard, calls) values (date_trunc('minute', p_at), p_shard, used)
  on conflict (minute, shard) do update set calls = excluded.calls;
  if p_shard = 0 then
    perform billing.heartbeat('history', p_at, jsonb_build_object('handed_out', jsonb_array_length(out)));
  end if;
  return out;
end $function$;
