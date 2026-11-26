CREATE OR REPLACE FUNCTION public.api_send_feedback(p_message text, p_page text, p_version text, p_image text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  uid uuid := auth.uid();
  msg text := btrim(coalesce(p_message, ''));
  em  text;
  fid bigint;
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if msg = '' then raise exception 'empty message' using errcode = '22023'; end if;
  if char_length(msg) > 4000 then raise exception 'message too long' using errcode = '22023'; end if;
  -- 1 MB of JPEG is ~1.4M base64 characters.
  if p_image is not null and (char_length(p_image) > 1400000 or p_image !~ '^[A-Za-z0-9+/=]+$') then
    raise exception 'bad image' using errcode = '22023';
  end if;
  -- Ten a day is plenty for a person and stops a stuck button filling hello@. The lock makes
  -- parallel sends from one user wait their turn, so they can't all pass the count.
  perform pg_advisory_xact_lock(hashtextextended('feedback:' || uid::text, 0));
  if (select count(*) from private.feedback where user_id = uid and created_at > now() - interval '1 day') >= 10 then
    raise exception 'feedback limit' using errcode = '22023';
  end if;

  select email into em from auth.users where id = uid;
  insert into private.feedback (user_id, message, page, app_version, has_image)
  values (uid, msg, left(p_page, 200), left(p_version, 40), p_image is not null)
  returning id into fid;

  -- To hello@ (to_email wins over the user's address in email_claim). user_id is set only so
  -- deleting the account deletes a feedback email not sent yet; 'feedback' has no switch.
  insert into public.email_queue (user_id, to_email, kind, key, data, priority)
  values (uid, 'hello@princesolarhub.co.za', 'feedback', 'feedback:' || fid,
          jsonb_build_object('id', fid, 'user', uid, 'email', em, 'message', msg, 'page', left(p_page, 200),
                             'version', left(p_version, 40), 'image', p_image), 1);
  return fid;
end $function$;
