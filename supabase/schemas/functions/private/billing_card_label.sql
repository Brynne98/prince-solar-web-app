CREATE OR REPLACE FUNCTION private.billing_card_label(p_card jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when p_card is null then 'Your card'
    else initcap(trim(coalesce(nullif(trim(p_card->>'card_type'), ''), p_card->>'brand', 'card')))
         || ' •••• ' || coalesce(p_card->>'last4', '????') end
$function$;
