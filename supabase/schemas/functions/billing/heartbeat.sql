CREATE OR REPLACE FUNCTION billing.heartbeat(p_job text, p_at timestamp with time zone, p_result jsonb, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  insert into billing.job_heartbeats (job, last_run_at, last_result, last_error, last_error_at)
  values (p_job, p_at, p_result, p_error, case when p_error is not null then p_at end)
  on conflict (job) do update set last_run_at = excluded.last_run_at, last_result = excluded.last_result,
    last_error = coalesce(excluded.last_error, job_heartbeats.last_error),
    last_error_at = coalesce(excluded.last_error_at, job_heartbeats.last_error_at)
$function$;
