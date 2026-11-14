-- ============================================================================
-- 0201 — Two stores a signed-in user could fill with no cap (SOLAR-549).
--
--   api_notices_read(keys)   stored any text it was given (0173): 20,000 rows in one
--                            call. Now it stores only the key of a notice the account
--                            has now, so a call adds at most one row per notice. The
--                            app sends only keys api_notifications gave it.
--   profiles.prefs           had no size limit: 5 MB in one write, sent back by api_me
--                            on every load. Now 20,000 bytes as text; the largest the
--                            app writes is about 100 bytes per plant.
-- ============================================================================

create or replace function public.api_notices_read(p_keys text[] default null)
returns void language sql security definer set search_path = '' as $$
  insert into private.notice_reads (user_id, key)
  select auth.uid(), private.notice_key(p)
    from jsonb_array_elements(private.billing_notices()) p
   where auth.uid() is not null
     and (p_keys is null or private.notice_key(p) = any (p_keys))
  on conflict do nothing;
$$;

-- rows no notice_key could have made
delete from private.notice_reads where key !~ '^[a-z_]+:[0-9a-f]{32}$';

-- not valid: a row already over the limit stays readable and takes only a smaller value
alter table public.profiles drop constraint if exists profiles_prefs_size;
alter table public.profiles add constraint profiles_prefs_size
  check (octet_length(prefs::text) <= 20000) not valid;
