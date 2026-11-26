CREATE OR REPLACE FUNCTION public.api_notices_read(p_keys text[] DEFAULT NULL::text[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ select $function$;
