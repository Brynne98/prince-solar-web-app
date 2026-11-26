CREATE OR REPLACE FUNCTION billing.is_hard_decline(p_msg text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(p_msg ~* '(stolen|lost card|pick ?up|restricted card|expired|closed|invalid card|no such card|not reusable|invalid authorization|authorization.*(invalid|not found)|card.*(blocked|deactivated))', false)
$function$;
