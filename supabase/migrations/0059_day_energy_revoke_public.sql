-- 0058 added public._plant_day_energy but only granted it; Postgres gives PUBLIC (and so
-- `anon`) EXECUTE on a new function by default, which 0002 notes must be revoked explicitly.
-- RLS on plant_energy and agg_minute meant an anon caller got no rows, so nothing leaked, but
-- every other internal helper here is revoked from public and anon (0041, 0042, 0051) and this
-- one should match rather than stand out as the exception.
revoke all on function public._plant_day_energy(bigint, date, date) from public, anon;
grant execute on function public._plant_day_energy(bigint, date, date) to authenticated, service_role;
