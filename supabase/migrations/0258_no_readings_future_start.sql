-- ============================================================================
-- 0258 — "No readings" ignores a start time in the future (SOLAR-645, step 1 fix).
--
-- 0256's grant trigger writes plant_alert_state.started_at = the grant's start. A grant
-- that starts in two weeks, for an account that reads its plants today, wrote a time two
-- weeks ahead, and email_sweep's test (started_at < now - 30 min) kept "No readings" off
-- for plants read today until then. The start time now counts only once it has passed:
-- the sweep waits only while started_at is in the last 30 minutes. A future start still
-- gives its 30 minutes once it comes.
--
-- Body: email_sweep 0174 (0256's patch kept), both lines patched in place.
-- ============================================================================
do $$
declare
  d text := pg_get_functiondef('public.email_sweep()'::regprocedure);
  old text := $o$coalesce(s.started_at, 0) < now_s - 1800$o$;
begin
  if (length(d) - length(replace(d, old, ''))) / length(old) <> 2 then
    raise exception 'email_sweep changed since 0256: edit it by hand';
  end if;
  execute replace(d, old, $n$not coalesce(s.started_at between now_s - 1800 and now_s, false)$n$);
end $$;
