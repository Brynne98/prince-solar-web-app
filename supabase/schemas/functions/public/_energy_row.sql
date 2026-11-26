CREATE OR REPLACE FUNCTION public._energy_row(p_bucket text, p_period date, p_pv double precision, p_load double precision, p_imp double precision, p_exp double precision, p_chg double precision, p_dischg double precision)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  select jsonb_build_object(
    'pv', p_pv, 'load', p_load, 'imp', p_imp, 'exp', p_exp,
    'chg', p_chg, 'dischg', p_dischg,
    -- self-sufficiency: share of load not met by imported grid energy
    'selfSuff', round(public.independence_pct(p_load, p_imp)))   -- R23: the one independence
  || case when p_bucket = 'day' then
       jsonb_build_object(
         'time', to_char(p_period, 'YYYY-MM-DD'),
         'date', to_char(p_period, 'YYYY-MM-DD'),
         'day', extract(day from p_period)::int,
         'dow', extract(dow from p_period)::int,
         'label', to_char(p_period, 'Dy'),
         'monthLabel', to_char(p_period, 'Mon'))
     else
       -- SunSynk's year endpoint returns zero-padded month numbers ("05"), and the
       -- charts key off this string, so pad rather than emitting "5"
       jsonb_build_object(
         'time', to_char(p_period, 'MM'),
         'date', to_char(p_period, 'MM'),
         'day', to_char(p_period, 'Mon'),
         'label', to_char(p_period, 'Mon'),
         'monthLabel', to_char(p_period, 'Mon'))
     end
$function$;
