-- ============================================================================
-- 0183 — the payment reference in the bank-reversal email (SOLAR-484).
--
-- The psh_ reference is what Paystack's receipt shows (subject and Transaction Details),
-- so a customer can match a charge with it.
--
-- email_reversed_reference: a lost dispute queues bill_failed under a new failed
-- charge; the payment the bank took back is only in that charge's error
-- ('dispute lost: <ref>', 0130 and 0132). notify reads it here for the email.
-- ============================================================================

create or replace function public.email_reversed_reference(p_reference text)
returns text language sql stable security definer set search_path = '' as $$
  select substr(c.error, length('dispute lost: ') + 1)
    from private.billing_charges c
   where c.reference = p_reference and c.error like 'dispute lost: %'
$$;
revoke all on function public.email_reversed_reference(text) from public, anon, authenticated;
grant execute on function public.email_reversed_reference(text) to service_role;
