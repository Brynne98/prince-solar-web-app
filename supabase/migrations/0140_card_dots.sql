-- SOLAR-300: a card reads "Visa •••• 4081", as other apps show it, not "Visa ending 4081".
-- The billing emails (receipt, switch receipt, failed payment) take this label; the
-- Billing card row and the pay review build the same text in the app.
create or replace function private.billing_card_label(p_card jsonb)
returns text language sql immutable as $$
  select case when p_card is null then 'Your card'
    else initcap(trim(coalesce(nullif(trim(p_card->>'card_type'), ''), p_card->>'brand', 'card')))
         || ' •••• ' || coalesce(p_card->>'last4', '????') end
$$;
