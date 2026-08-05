-- Local development seed. Runs on `supabase db reset`, which recreates the auth
-- schema and therefore wipes any user you made by hand.
--
-- LOCAL ONLY — this never runs against a linked project (`supabase db push` does not
-- apply seeds). The credentials below are deliberately throwaway.
--
--   dev@local.test / devpassword123
--
-- Every api_* function is granted to `authenticated`, so without a user the whole
-- dashboard 401s and it looks like the port is broken.

-- NB: confirmation_token / recovery_token / email_change* have no defaults and
-- GoTrue scans them into non-nullable Go strings. Leaving them NULL makes sign-in
-- fail with "Database error querying schema", which reads like a config problem
-- rather than a seed problem. They must be empty strings.
insert into auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  created_at, updated_at
)
select
  '00000000-0000-0000-0000-000000000000',
  gen_random_uuid(),
  'authenticated', 'authenticated', 'dev@local.test',
  crypt('devpassword123', gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}',
  '', '', '', '',
  now(), now()
where not exists (select 1 from auth.users where email = 'dev@local.test');

-- GoTrue needs a matching identity row or password sign-in fails.
insert into auth.identities (
  provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select
  u.id::text, u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email', now(), now(), now()
from auth.users u
where u.email = 'dev@local.test'
  and not exists (select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email');
