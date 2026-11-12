-- ============================================================================
-- 0194 — Pop-up addresses: known push services only, 10 per user, no takeover
--        (SOLAR-532, security review 7).
--
-- api_push_sub saved any text as a pop-up address, with no cap, and gave the
-- row to whoever sent the address last. notify then sent a request to every
-- saved address: a user could point our server at any site, hundreds of times
-- per alert, or take another user's row by knowing its address.
--
-- 1. The table takes only what a browser really issues: https on Google FCM
--    (Chrome, Brave, Opera, Samsung, Android), Mozilla (Firefox), Apple (Safari,
--    iOS) or Windows (Edge). No port, no user part, nothing before the host. A
--    phone app row is an Expo token. NOT VALID: rows saved before this stay;
--    notify skips and removes a web row that fails the same test.
-- 2. 10 rows per user. One row is one browser on one device; 10 covers a home's
--    phones, tablets and computers, and caps what one alert can send. Past 10
--    the row that got a pop-up longest ago goes, so a new device always works.
-- 3. A row moves to another user only when the caller sends the same keys as
--    the saved row. The keys never leave the browser, so that is the same
--    browser with a new account signed in (pushResync, 0124). The address
--    alone moves nothing.
-- ============================================================================

alter table public.push_subs drop constraint if exists push_subs_endpoint_ok;
alter table public.push_subs add constraint push_subs_endpoint_ok check (
  length(endpoint) <= 1024 and length(p256dh) <= 200 and length(auth) <= 200 and
  case platform
    when 'web' then endpoint ~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/[^[:space:]]+$'
    else endpoint ~ '^ExponentPushToken\[[A-Za-z0-9_-]{1,64}\]$'
  end) not valid;

create or replace function public.api_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_platform text default 'web')
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  -- one user's saves run one at a time, so two at once cannot both pass the cap
  perform pg_advisory_xact_lock(hashtextextended('push_subs:' || v_uid::text, 0));

  begin
    insert into public.push_subs as s (user_id, platform, endpoint, p256dh, auth)
    values (v_uid, p_platform, p_endpoint, p_p256dh, p_auth)
    on conflict (endpoint) do update
      set user_id = excluded.user_id, platform = excluded.platform, p256dh = excluded.p256dh,
          auth = excluded.auth
      where s.user_id = excluded.user_id
         or (s.p256dh = excluded.p256dh and s.auth = excluded.auth);
  exception when check_violation then
    raise exception 'Pop-ups are not supported in this browser' using errcode = '22023';
  end;
  if not found then
    raise exception 'Pop-ups on this browser belong to another account' using errcode = '42501';
  end if;

  delete from public.push_subs d
   where d.user_id = v_uid and d.endpoint <> p_endpoint
     and d.id in (select o.id from public.push_subs o
                   where o.user_id = v_uid and o.endpoint <> p_endpoint
                   order by coalesce(o.last_ok_at, o.created_at) desc, o.id desc
                  offset 9);
end $$;

revoke all on function public.api_push_sub(text, text, text, text) from public, anon;
grant execute on function public.api_push_sub(text, text, text, text) to authenticated;
