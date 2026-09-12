-- ============================================================================
-- 0043 — a place for the browser to report an error (READINESS O5).
--
-- Until now a crash in someone's browser was invisible: no analytics, no error
-- reporter, no support path. The frontend's window.onerror / unhandledrejection
-- handlers insert one row here. Insert-only for the signed-in user; nobody but
-- service_role reads it (the SQL editor, or a later admin view).
-- ============================================================================
create table if not exists public.client_errors (
  id          bigint generated always as identity primary key,
  user_id     uuid references auth.users (id) on delete set null,
  plant_id    bigint,
  at          timestamptz not null default now(),
  app_version text,
  page        text,
  message     text not null,
  stack       text,
  user_agent  text
);
create index if not exists client_errors_at_idx on public.client_errors (at desc);

alter table public.client_errors enable row level security;
drop policy if exists client_errors_insert on public.client_errors;
create policy client_errors_insert on public.client_errors
  for insert to authenticated with check (user_id = auth.uid());
revoke all on public.client_errors from anon, authenticated;
grant insert on public.client_errors to authenticated;
grant select, insert, update, delete on public.client_errors to service_role;

-- Keep it small: a browser stuck in a loop must not fill the database.
create or replace function public.client_errors_cap()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select count(*) from public.client_errors where user_id = new.user_id and at > now() - interval '1 hour') >= 50 then
    return null; -- silently dropped
  end if;
  new.message := left(new.message, 2000);
  new.stack := left(new.stack, 8000);
  return new;
end $$;
drop trigger if exists client_errors_cap on public.client_errors;
create trigger client_errors_cap before insert on public.client_errors
  for each row execute function public.client_errors_cap();
