CREATE OR REPLACE FUNCTION public.mail_block(p_emails text[], p_reason text, p_detail text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with r as (
    insert into private.mail_blocked as b (email, reason, detail)
    select distinct lower(btrim(e)), p_reason, left(p_detail, 500)
      from unnest(p_emails) e where nullif(btrim(e), '') is not null
    on conflict (email) do update
       set reason = excluded.reason, detail = excluded.detail, last_at = now(), events = b.events + 1
    returning 1)
  select count(*)::int from r
$function$;
