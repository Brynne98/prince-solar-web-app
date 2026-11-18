-- 0225 — test accounts do not take offer places (SOLAR-585, decided by Brynne 2026-11-19).
--
-- An offer counts its places as rows in private.offer_members (0145, 0221). A test account
-- that paid took a launch place for good. Now private.test_users lists the test accounts;
-- a membership row for one of them is never kept, so it pays the offer price like anyone
-- new but its place is not counted. Its price is held by billing.offer_id as before.
-- Test accounts are added here by user id (no email in the repo).

create table private.test_users (
  user_id uuid primary key,
  added_on date not null default (now() at time zone 'Africa/Johannesburg')::date
);

insert into private.test_users (user_id) values
  ('bc8f0e78-2f43-4637-a3cc-4a73ee18cf8b'), ('34bf96fe-d923-4c4f-975d-feb34c7802ff'),
  ('2a891804-8838-4fb3-acf2-f88bf0672626'), ('3270101a-15be-4c25-8aa4-aeac7422cc91'),
  ('01f69b07-1b11-4210-af74-484ffed23bfc'), ('a4a683fd-6ba1-4b1c-a0ad-ef4c51756d5c'),
  ('2636dc2c-545c-450c-89c7-523665a09f9f')
on conflict do nothing;

create or replace function private.offer_member_skip_tests()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if exists (select 1 from private.test_users t where t.user_id = new.user_id) then
    return null;
  end if;
  return new;
end $$;

create trigger offer_member_skip_tests before insert on private.offer_members
  for each row execute function private.offer_member_skip_tests();

delete from private.offer_members m using private.test_users t where m.user_id = t.user_id;
