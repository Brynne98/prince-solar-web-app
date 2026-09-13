-- 0047 — drop the api_inverter_temps alias. It bridged the minutes between the
-- 0046 backend push and the v0.15.0 site push (the old page called it); the new
-- page calls api_inverter_history and nothing else references the old name.
drop function if exists public.api_inverter_temps(date, bigint);
