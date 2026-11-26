CREATE OR REPLACE FUNCTION billing.kept_by_others_until(p_account uuid, p_plant bigint, p_at timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare se record; st billing.status; latest timestamptz; ends timestamptz;
begin
  for se in select s.account, s.drop_at_period_end from billing.seats s
             where s.plant = p_plant and s.account <> p_account and s.closed_at is null loop
    st := billing.account_status(se.account, p_at);
    ends := case when st.state = 'active' and st.sub is null then
                   -- grants only: the latest end (none: no end)
                   (select case when bool_or(g.ends_at is null) then 'infinity'::timestamptz else max(g.ends_at) end
                      from billing.grants g where g.account = se.account and g.starts_at <= p_at
                       and (g.ends_at is null or g.ends_at > p_at))
                 when st.state = 'past_due' or (st.state = 'active' and st.cancel_at is null) then 'infinity'
                 when st.state = 'active' then st.cancel_at
                 when st.state = 'trialing' then st.trial_ends_at
                 when st.state = 'ended' then st.access_ended_at end;
    if se.drop_at_period_end and st.state in ('active', 'past_due') and st.sub is not null then
      ends := st.period_end;                     -- dropped then, no retention
    elsif ends is not null and ends <> 'infinity' then
      ends := ends + make_interval(days => st.retention_days);
    end if;
    latest := greatest(latest, ends);
  end loop;
  return latest;
end $function$;
