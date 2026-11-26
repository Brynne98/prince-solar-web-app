CREATE OR REPLACE FUNCTION private.notice_key(p jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select (p->>'kind') || ':' || md5((p - 'days')::text);
$function$;
