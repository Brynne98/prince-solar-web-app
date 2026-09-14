with m as (
  select a.plant_id, a.pv_w, a.soc,
         a.pv_w + coalesce(a.grid_w,0) - coalesce(a.load_w,0) as charge_w,
         public.local_ts_tz(a.ts, public.plant_tz(a.plant_id)) as lt
    from public.agg_minute a
   where a.pv_w is not null and a.load_w is not null
     and coalesce(a.source,'poller') <> 'plantfeed'
     and a.ts >= extract(epoch from now() - interval '200 days')
),
ceil as (select plant_id, percentile_cont(0.99) within group (order by charge_w) w from m where charge_w > 0 group by 1)
select m.plant_id, m.lt::date as day,
       floor((extract(hour from m.lt)*60 + extract(minute from m.lt))/5)::int as slot,
       round(avg(m.pv_w)) as w, count(*) n
  from m join ceil c using (plant_id)
 where (m.soc is null or m.soc < 95) and m.charge_w < 0.9*c.w
 group by 1,2,3 order by 1,2,3
