-- ============================================================================
-- 0109 — cap new waitlist emails per hour (SOLAR-138 item 6).
--
-- anon could call api_join_waitlist with any number of addresses. Nothing is
-- mailed, so it was junk rows only, but without end.
--
-- Now at most 100 new addresses in any hour, counted over everyone. A per-IP
-- cap was the other choice; the client IP reaches PostgREST only as headers the
-- caller can add to, so it would be easy to get round. An address already on
-- the list does not add a row, so it does not count. Past the cap every call
-- fails with 'try again later'; both forms already show their "try again" error.
-- ============================================================================

create index if not exists waitlist_created_idx on private.waitlist (created_at);

create or replace function public.api_join_waitlist(p_email text)
returns void
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare e text := lower(btrim(p_email));
begin
  if e is null or length(e) > 254 or e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email' using errcode = '22023';
  end if;
  -- The cap is checked before the address, so past it every caller gets the same
  -- error and the answer never tells whether an address is on the list.
  if (select count(*) from private.waitlist where created_at > now() - interval '1 hour') >= 100 then
    raise exception 'try again later' using errcode = '54000';
  end if;
  insert into private.waitlist (email) values (e) on conflict (email) do nothing;
end;
$$;
-- create or replace keeps the grants from 0085 and 0108: anon, authenticated, service_role.
