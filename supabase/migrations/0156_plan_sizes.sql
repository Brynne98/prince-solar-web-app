-- ============================================================================
-- 0156 — New plan sizes, no extra plants sold (SOLAR-371).
--
-- Decided 2026-11-06: Free 1 plant. Home 2 plants, R99 a month or R990 a year. Family
-- 5 plants, R199 a month or R1,990 a year. A year is 10 months. Over 5 plants: email us.
--
-- Extra plants are no longer sold: a charge buys none (billing_extra_added is always 0),
-- so a quote or pay that asks for more gets none. An account already holding extras keeps
-- them, at the price in billing_amount, on top of Family's 5, and can still drop them
-- (api_billing_extras only books fewer).
--
-- Existing Family and Home yearly accounts pay the new price from their next charge.
-- The launch offer's prices (private.offers) are unchanged.
-- ============================================================================

-- 0145's prices, with Home yearly R990 and Family R199 / R1,990.
create or replace function public.billing_amount(p_plan text, p_period text, p_extra int default 0, p_offer text default null)
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select case p_plan
    when 'free'   then 0
    when 'home'   then case p_period when 'monthly' then coalesce(o.home_monthly, 99) when 'yearly' then coalesce(o.home_yearly, 990) end
    when 'family' then case p_period when 'monthly' then coalesce(o.family_monthly, 199) when 'yearly' then coalesce(o.family_yearly, 1990) end
                       + greatest(p_extra, 0) * case p_period when 'monthly' then coalesce(o.extra_monthly, 49)
                                                              when 'yearly' then coalesce(o.extra_yearly, 588) end
  end
  from (select 1) x left join private.offers o on o.id = p_offer
$$;

-- 0129's room: Home 2, Family 5 plus any extras still held.
create or replace function public.billing_room(p_plan text, p_extra int default 0)
returns int language sql immutable as $$
  select case coalesce(p_plan, 'free')
    when 'family' then 5 + greatest(coalesce(p_extra, 0), 0)
    when 'home' then 2
    else 1 end
$$;

-- 0129's extras a charge buys: none now.
create or replace function private.billing_extra_added(b private.billing, p_plan text, p_extra int)
returns int language sql immutable as $$
  select 0
$$;
