CREATE OR REPLACE FUNCTION private.call_fn(p_path text, p_body jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 55000)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare rid bigint;
begin
  rid := net.http_post(
    url := private.functions_url() || '/' || p_path,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Content-Type', 'application/json'),
    body := p_body,
    timeout_milliseconds := p_timeout_ms);
  insert into private.fn_calls (id, fn, shard, timeout_ms)
  values (rid, split_part(split_part(p_path, '?', 1), '/', 1) || coalesce(':' || (p_body ->> 'task'), ''), (p_body ->> 'shard')::int, p_timeout_ms)
  on conflict (id) do nothing;
  return rid;
end $function$;
