CREATE OR REPLACE FUNCTION history.take(p_shard integer DEFAULT 0, p_shards integer DEFAULT 1, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cap int := history.setting('HISTORY_CALLS_PER_MINUTE', 600);
  used int;
  out jsonb := '[]';
  ln uuid;
  k text; sid bigint; pl bigint; kd text; go boolean; fs boolean;
  imp bigint;
  c int;
  v bigint;
  cl uuid;
begin
  if p_shards < 1 or p_shard < 0 or p_shard >= p_shards then
    raise exception 'history.take: shard % of %', p_shard, p_shards;
  end if;
  if p_shard = 0 then perform history.tidy(p_at); end if;
  insert into history.calls as hc (minute, calls) values (date_trunc('minute', p_at), 0)
  on conflict (minute) do update set calls = hc.calls returning hc.calls into used;

  create temp table if not exists _ht_route (plant bigint primary key, account uuid, lane uuid) on commit drop;
  truncate _ht_route;
  insert into _ht_route
  select distinct on (rr.plant) rr.plant, rr.account, rr.lane
    from billing.reading_routes(p_at) rr
    join plants.login_info l on l.id = rr.lane and l.status = 'ok'
   where abs(hashtext(rr.lane::text)) % p_shards = p_shard
     and not plants.throttled(rr.lane, p_at - interval '2 minutes')
     and not exists (select 1 from history.lanes hl where hl.lane = rr.lane and hl.backoff_until > p_at)
     and not private.history_deleting(rr.plant)
   order by rr.plant,
            exists (select 1 from history.import_accounts ia join history.imports i on i.id = ia.import
                     where i.plant = rr.plant and i.status = 'open' and ia.left_at is null and ia.account = rr.account) desc,
            rr.account;

  for ln in select distinct r.lane from _ht_route r order by 1 loop
    continue when exists (select 1 from history.days d where d.lane = ln and d.status = 'queued' and d.claimed_until > p_at)
               or exists (select 1 from history.totals t where t.lane = ln and t.claimed_until > p_at);
    k := null; sid := null; imp := null;
    -- 1. a hole or a check day
    select 'day', d.id, d.plant, d.kind, d.grid_only, false into k, sid, pl, kd, go, fs
      from history.days d join _ht_route r on r.plant = d.plant and r.lane = ln
     where d.status = 'queued' and d.import is null and d.due_at <= p_at
       and (d.claimed_until is null or d.claimed_until <= p_at)
     order by (d.why = 'gap') desc, d.day desc, (d.kind = 'minutes') desc, d.id limit 1;
    -- 2. the import this login is walking, when its next day is due; else a new one
    if sid is null then
      select i.id into imp from history.imports i join _ht_route r on r.plant = i.plant and r.lane = ln
       where i.status = 'open' and i.started_at is not null and i.next_at <= p_at
         and exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null and a.account = r.account)
       order by i.started_at, i.id limit 1;
      if imp is null then
        select i.id into imp from history.imports i join _ht_route r on r.plant = i.plant and r.lane = ln
         where i.status = 'open' and i.started_at is null
           and exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null and a.account = r.account)
         order by (select max(o.started_at) from history.imports o join history.import_accounts oa on oa.import = o.id
                    where o.lane = ln and o.id <> i.id
                      and oa.account in (select a.account from history.import_accounts a where a.import = i.id)) nulls first,
                  i.requested_at, i.id
         limit 1;
      end if;
      if imp is not null then
        select 'day', d.id, d.plant, d.kind, d.grid_only, false into k, sid, pl, kd, go, fs
          from history.days d
         where d.import = imp and d.status = 'queued' and d.due_at <= p_at
           and (d.claimed_until is null or d.claimed_until <= p_at)
         order by d.day desc, (d.kind = 'minutes') desc, d.id limit 1;
      end if;
    end if;
    -- 3. kWh totals
    if sid is null then
      select 'totals', t.plant, t.plant, 'totals', false, t.full_sweep into k, sid, pl, kd, go, fs
        from history.totals t join _ht_route r on r.plant = t.plant and r.lane = ln
       where t.due_at <= p_at and (t.claimed_until is null or t.claimed_until <= p_at)
       order by t.due_at, t.plant limit 1;
    end if;
    continue when sid is null;

    c := history.cost(kd, pl, go, fs);
    exit when used > 0 and used + c > cap;
    used := used + c;
    v := (select p.version from plants.plant_info p where p.id = pl);
    cl := gen_random_uuid();
    if k = 'day' then
      update history.days set claim = cl, claimed_until = p_at + interval '90 seconds', lane = ln, version = v where id = sid;
      update history.imports set started_at = p_at, next_at = p_at, lane = ln
       where id = (select d.import from history.days d where d.id = sid) and started_at is null;
    else
      update history.totals set claim = cl, claimed_until = p_at + interval '90 seconds', lane = ln, version = v where plant = sid;
    end if;
    out := out || jsonb_build_array((
      select jsonb_build_object(
        'step', k, 'id', sid, 'claim', cl, 'plant', pl, 'version', v, 'kind', kd,
        'day', d.day, 'why', d.why, 'grid_only', go, 'full', fs, 'calls', c,
        -- the plant feed fills what inverter history cannot, for the days it still holds (H11)
        'feed', coalesce(d.why <> 'import' or d.day >= (p_at at time zone plants.tz(pl))::date - 13, false),
        'timezone', plants.tz(pl), 'brand', p.brand, 'vendor_plant_id', p.vendor_id,
        'login', jsonb_build_object('id', l.id, 'user_id', l.user_id, 'username', l.username, 'brand', l.brand,
                                    'access_token', tk.access_token, 'access_expires_at', tk.access_expires_at))
        from plants.plant_info p
        join plants.login_info l on l.id = ln
        join plants.login_tokens tk on tk.id = l.id
        left join history.days d on k = 'day' and d.id = sid
       where p.id = pl));
  end loop;
  update history.calls set calls = used where minute = date_trunc('minute', p_at);
  if p_shard = 0 then
    perform billing.heartbeat('history', p_at, jsonb_build_object('handed_out', jsonb_array_length(out)));
  end if;
  return out;
end $function$;
