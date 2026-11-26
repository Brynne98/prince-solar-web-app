CREATE OR REPLACE FUNCTION public.api_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_platform text DEFAULT 'web'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;
