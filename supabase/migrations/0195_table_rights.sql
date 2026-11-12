-- ============================================================================
-- 0195 — Users hold only the table rights a policy uses (SOLAR-532, security
--        review 10).
--
-- Read from the live catalog on 2026-11-12. authenticated held, with no policy
-- or caller behind them:
--   plant_config   DELETE, INSERT, TRUNCATE          (policies: read, update)
--   profiles       TRUNCATE                          (policy: own row)
--   agg_minute, app_config, inverter_history, plant_config, plant_energy,
--   plant_users, profiles, readings, strings         TRIGGER, REFERENCES, MAINTAIN
--   client_errors_id_seq, config_changes_id_seq, email_queue_id_seq
--                                                    all rights, anon as well
-- Row rules blocked the row writes; TRUNCATE skips row rules and was kept out
-- only because the API has no truncate call.
--
-- What stays, each used by a policy:
--   SELECT            the readings tables, plant_users, plant_config
--   UPDATE            plant_config
--   SELECT, INSERT, UPDATE   profiles; email_prefs and push_prefs (by column)
--   INSERT            client_errors
-- No table needs DELETE from a user. Every id is an identity column, so an
-- insert needs no right on its sequence.
-- ============================================================================

revoke all on all tables in schema public from anon;
revoke truncate, delete, trigger, references, maintain on all tables in schema public from authenticated;
revoke insert on public.plant_config from authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- New tables, sequences and functions made by a migration (role postgres) start
-- with nothing for users; each migration grants what its policy needs. Live
-- already had this; stated here so a fresh database gets it too.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated;
