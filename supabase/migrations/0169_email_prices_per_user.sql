-- ============================================================================
-- 0169: billing emails quote the price this user would pay (SOLAR-443).
--
-- notify priced winback and plants-removal-soon with api_offer(), the offer a
-- new account would join. An account joins an offer once (0145), so a user who
-- had the launch price and left was quoted R49 and charged R99.
--
-- email_prices(user): monthly prices with the user's own offer, as
-- api_billing_status quotes them: a Free account gets the offer it could still
-- join, a paid one the offer it holds. listPrices are the usual prices.
-- Read by notify with the service role only, like the other email_* readers.
-- ============================================================================

create or replace function public.email_prices(p_user uuid)
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('prices', private.billing_price_list(o.id), 'listPrices', private.billing_price_list(null))
    from (select private.billing_offer_now(p_user) as id) o
$$;

revoke all on function public.email_prices(uuid) from public, anon, authenticated;
grant execute on function public.email_prices(uuid) to service_role;
