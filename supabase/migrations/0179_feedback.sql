-- SOLAR-428: "Send feedback" from the account menu.
-- api_send_feedback keeps the message in private.feedback (a list we read with SQL) and queues
-- one email to hello@, reply-to the sender, so a reply goes straight to them.
-- A screenshot goes only in the email: the app shrinks it to a JPEG under 1 MB and sends it
-- here as base64. It rides in the queue row until notify sends it, then the row's data is
-- cleared, so neither the screenshot nor the message stays in the queue. No file storage.

create table private.feedback (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users on delete cascade,
  message     text not null check (char_length(message) between 1 and 4000),
  page        text check (char_length(page) <= 200),
  app_version text check (char_length(app_version) <= 40),
  has_image   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index feedback_user_at on private.feedback (user_id, created_at);
alter table private.feedback enable row level security;

-- 22023: refused on purpose; the app says why (must() doesn't report it as an error).
create or replace function public.api_send_feedback(p_message text, p_page text, p_version text, p_image text default null)
returns bigint language plpgsql security definer set search_path = '' as $$
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
  -- Ten a day is plenty for a person and stops a stuck button filling hello@.
  if (select count(*) from private.feedback where user_id = uid and created_at > now() - interval '1 day') >= 10 then
    raise exception 'feedback limit' using errcode = '22023';
  end if;

  select email into em from auth.users where id = uid;
  insert into private.feedback (user_id, message, page, app_version, has_image)
  values (uid, msg, left(p_page, 200), left(p_version, 40), p_image is not null)
  returning id into fid;

  -- No user_id on the row: the mail is to hello@, not to the user (like bill_mail_failed).
  insert into public.email_queue (to_email, kind, key, data, priority)
  values ('hello@princesolarhub.co.za', 'feedback', 'feedback:' || fid,
          jsonb_build_object('id', fid, 'user', uid, 'email', em, 'message', msg, 'page', left(p_page, 200),
                             'version', left(p_version, 40), 'image', p_image), 1);
  return fid;
end $$;
revoke all on function public.api_send_feedback(text, text, text, text) from public, anon;
grant execute on function public.api_send_feedback(text, text, text, text) to authenticated;

-- Once notify is done with a feedback email, its copy of the message and screenshot goes.
-- The message stays in private.feedback; a deleted account takes that with it.
create or replace function private.feedback_mail_done() returns trigger language plpgsql set search_path = '' as $$
begin
  new.data := jsonb_build_object('id', new.data->'id');
  return new;
end $$;
create trigger feedback_mail_done before update of status on public.email_queue
  for each row when (new.kind = 'feedback' and new.status in ('sent', 'failed', 'skipped'))
  execute function private.feedback_mail_done();
