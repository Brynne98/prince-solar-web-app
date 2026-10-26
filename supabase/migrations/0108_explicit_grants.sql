-- ============================================================================
-- 0108 — Every public table carries its own grants; new objects start closed
--        (SOLAR-145, SOLAR-138 item 4).
--
-- From 2026-10-30 Supabase gives a new public table or sequence no grants to
-- anon, authenticated or service_role. Production keeps what it has. A fresh
-- database (local `supabase db reset`, a branch, a new project) already runs
-- that way locally (config.toml auto_expose_new_tables = false), and a few old
-- migrations relied on the old defaults. A fresh database missed these, all
-- present in production:
--   inverter_history       0045 made it as inverter_temp with no grant
--   *_id_seq               client_errors, config_changes, email_queue: no
--                          USAGE, so inserts as those roles failed
--   app_config             service_role DELETE
--   9 functions            service_role EXECUTE (they revoke public, then
--                          grant authenticated or anon only)
--
-- Then the default privileges for role postgres stop giving anything to anon
-- and authenticated (tables, sequences, functions) or to service_role
-- (tables, sequences), as the 2026-10-30 Supabase default does for tables.
-- From here every migration grants what its object needs; DEPLOY.md has the
-- rule. Existing grants are unchanged. Defaults for supabase_admin stay: our
-- migrations run as postgres, and postgres cannot alter them.
-- ============================================================================

grant select on public.inverter_history to authenticated;
grant all    on public.inverter_history to service_role;

grant delete on public.app_config to service_role;

grant usage, select on sequence public.client_errors_id_seq  to authenticated, service_role;
grant usage, select on sequence public.config_changes_id_seq to service_role;
grant usage, select on sequence public.email_queue_id_seq    to service_role;

grant execute on function public.admin_overview()                to service_role;
grant execute on function public.admin_set_tester_places(integer) to service_role;
grant execute on function public.admin_testers()                 to service_role;
grant execute on function public.admin_waitlist_delete(text)     to service_role;
grant execute on function public.api_account_delete()            to service_role;
grant execute on function public.api_join_waitlist(text)         to service_role;
grant execute on function public.api_prefs_set(jsonb)            to service_role;
grant execute on function public.api_tester_places()             to service_role;
grant execute on function public.hook_tester_places(jsonb)       to service_role;

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;
-- Postgres itself gives every new function EXECUTE to PUBLIC (so to anon and
-- authenticated) from its built-in default, which a schema-level revoke can't
-- remove. That one is revoked for all schemas. service_role keeps EXECUTE on
-- new public functions, as production already had; a fresh database now gets
-- it too.
alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated;
alter default privileges for role postgres in schema public
  grant execute on functions to service_role;
alter default privileges for role postgres
  revoke execute on functions from public;
