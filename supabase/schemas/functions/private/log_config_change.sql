CREATE OR REPLACE FUNCTION private.log_config_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  f text;
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  n jsonb := to_jsonb(new);
begin
  if new.plant_id is null then return new; end if;
  foreach f in array tg_argv loop
    if (o -> f) is distinct from (n -> f) and not (tg_op = 'INSERT' and n -> f = 'null'::jsonb) then
      insert into public.config_changes (plant_id, sn, field, old_value, new_value, changed_by)
      values (new.plant_id,
              case when tg_table_name = 'meta' then n ->> 'sn' end,
              f,
              nullif(o -> f, 'null'::jsonb),
              nullif(n -> f, 'null'::jsonb),
              auth.uid());
    end if;
  end loop;
  return new;
end $function$;
