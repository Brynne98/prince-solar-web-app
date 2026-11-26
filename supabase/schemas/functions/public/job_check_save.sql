CREATE OR REPLACE FUNCTION public.job_check_save(p_changes jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  insert into private.job_checks as t (name, failing, since, detail)
  select x.name, x.failing, now(), x.detail
    from jsonb_to_recordset(coalesce(p_changes, '[]')) as x(name text, failing boolean, detail jsonb)
   where x.name is not null and x.failing is not null
  on conflict (name) do update set failing = excluded.failing, since = excluded.since, detail = excluded.detail;
$function$;
