-- ============================================================================
-- Controlled access to the `private` schema.
--
-- `private` is deliberately NOT in the PostgREST exposed-schema list, so even
-- service_role cannot reach those tables with a plain .from() call. Rather than
-- expose the schema holding SunSynk tokens, the Edge Functions get this narrow set
-- of SECURITY DEFINER accessors: each one does exactly one job, and EXECUTE is
-- granted to service_role alone.
--
-- Net effect: the anon key that ships in the public GitHub Pages bundle has no
-- route to a token — not the table, not a function, not the schema.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Token store (was the monolith's in-memory tokenCache)
-- ---------------------------------------------------------------------------
create or replace function public.auth_token_get()
returns table (access_token text, expires_at bigint)
language sql
security definer
set search_path = private, pg_temp
as $$ select access_token, expires_at from private.auth where id = 1 $$;

create or replace function public.auth_token_set(
  p_access text, p_refresh text, p_expires bigint)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  update private.auth
     set access_token = p_access, refresh_token = p_refresh, expires_at = p_expires
   where id = 1
$$;

-- Force the next apiGet() to re-login (used on a 401 from SunSynk).
create or replace function public.auth_token_expire()
returns void
language sql
security definer
set search_path = private, pg_temp
as $$ update private.auth set expires_at = 0 where id = 1 $$;

-- ---------------------------------------------------------------------------
-- Inverters / metadata / gaps
-- ---------------------------------------------------------------------------
create or replace function public.inverters_list()
returns table (sn text, plant_id bigint)
language sql
security definer
set search_path = private, pg_temp
as $$ select sn, plant_id from private.inverters order by sn $$;

create or replace function public.inverters_seed(p_rows jsonb)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  insert into private.inverters (sn, plant_id)
  select r->>'sn', nullif(r->>'plant_id', '')::bigint
    from jsonb_array_elements(p_rows) r
  on conflict (sn) do update set plant_id = excluded.plant_id
$$;

-- Mirrors the SQLite `INSERT OR REPLACE INTO meta ...` in db.js recordPoll().
create or replace function public.meta_upsert(p_rows jsonb)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  insert into private.meta (
    sn, updated_ts, alias, model, soft_ver, hmi_ver, gsn, comm_type,
    capacity_ah, number_of_batteries, plant_id, plant_name)
  select
    r->>'sn',
    (r->>'updated_ts')::bigint,
    r->>'alias', r->>'model', r->>'soft_ver', r->>'hmi_ver', r->>'gsn', r->>'comm_type',
    nullif(r->>'capacity_ah', '')::double precision,
    nullif(r->>'number_of_batteries', '')::integer,
    nullif(r->>'plant_id', '')::bigint,
    r->>'plant_name'
  from jsonb_array_elements(p_rows) r
  on conflict (sn) do update set
    updated_ts = excluded.updated_ts, alias = excluded.alias, model = excluded.model,
    soft_ver = excluded.soft_ver, hmi_ver = excluded.hmi_ver, gsn = excluded.gsn,
    comm_type = excluded.comm_type, capacity_ah = excluded.capacity_ah,
    number_of_batteries = excluded.number_of_batteries,
    plant_id = excluded.plant_id, plant_name = excluded.plant_name
$$;

-- Logger-offline window. db.js records one when a poll lands >90 s after the last
-- row; INSERT OR IGNORE there, so do-nothing on conflict here.
create or replace function public.gap_record(p_from bigint, p_to bigint)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  insert into private.gaps (from_ts, to_ts) values (p_from, p_to)
  on conflict (from_ts) do nothing
$$;

create or replace function public.gaps_list()
returns table (from_ts bigint, to_ts bigint)
language sql
security definer
set search_path = private, pg_temp
as $$ select from_ts, to_ts from private.gaps order by from_ts $$;

-- ---------------------------------------------------------------------------
-- Grants: service_role only. Postgres grants EXECUTE to PUBLIC by default on new
-- functions, so every one of these must be revoked explicitly first.
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'auth_token_get()',
    'auth_token_set(text,text,bigint)',
    'auth_token_expire()',
    'inverters_list()',
    'inverters_seed(jsonb)',
    'meta_upsert(jsonb)',
    'gap_record(bigint,bigint)',
    'gaps_list()'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
