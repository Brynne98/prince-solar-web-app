# SOLAR-644 spec v13 (final 2026-11-24: Neon 9.5, Sol 9.5, Astra 9.5, Fable 9, all deployable): what an unpaid renewal tells the owner

Example: Family, R99 a month, renewal due 23 Nov 2026 at 15:30, plan cutoff the end of 8 Dec 2026 (midnight, account time zone).
All plan names, amounts, dates and times come from account state and the open renewal bill. Never "15 days": grace counts from the renewal date, so a refusal on a later retry leaves less.

## Fixed by Brynne (not open for debate)
- F1. The email button does exactly what Billing's button does: same label, same flow, same first step.
- F2. Copy names the exact plan, amount and date. Buttons have no dates or prices. Say each fact once per screen. Alert emails inform only (what happened and the numbers, no guessed causes, no advice the owner can't act on). Everyday home owners, plain short words. Never suggest contacting an installer or the inverter maker. No VAT. No new hard-coded "SunSynk", ZAR or Johannesburg.

## Names used below
- **due plan / due amount**: the open renewal bill's `plan_name` and `amount_minor` (while ended with a renewal payment still being checked: the latest renewal bill, open or void). It differs from the running plan when a downgrade was booked (Family running, bill for Home R49).
- **running plan**: the plan readings come from now. That is what ends at the cutoff.
- **cutoff**: `plan_ends_at`, written as the date only, "8 Dec 2026" (Brynne, 2026-11-24: no time shown).
- **Cutoff moves to the end of the day** (Brynne, 2026-11-24). One SQL helper, `billing.past_due_cutoff(past_due_since, retry_days, tz)`, with `tz = coalesce(account.time_zone, market.default_time_zone)` (the same zone the copy uses, 0247:183). It returns the last millisecond of the local day today's rule lands on (`past_due_since + max(retry_days) + 1 day`): start of the next local day minus 1 ms. Example: 23 Nov 15:30 → `2026-12-08 23:59:59.999+02`.
  - Stored in `plan_ends_at`, and the job writes the same instant to `ended_at`. So `day()` prints "8 Dec 2026" for "Pay by", for "Family ended on 8 Dec 2026", for `access_ended_at` and for "Readings stopped on", with no formatter change. A booked cancel's `cancel_at` is untouched.
  - Minus 1 ms, not 1 s (a payment at 23:59:59 must still satisfy `ended_at > paid` in `revive`, 0245:934) and not 1 µs (ms-precision parsers could round it into 9 Dec).
  - Returns null when `past_due_since` is null (so `coalesce(…, p_at)` at 0246:644 still works). `run_one` and `apply_purchase` load only the market today (0245:1248, 0246:637); both must also read the account's time zone.
  - Used at all three places that work out this cutoff today: `account_status` (0241:104), the job `run_one` (0245:1256–1257, test and `ended_at`), and `apply_purchase` (0246:644, a restart ending the old unpaid plan). The `<=` test at 0241:105 stays as is.
  - Gives up to one extra day of readings; the history delete date moves with it.
  - Tests that assert the old instant change: `scripts/sql/billing-state-tests.sql` 362, 372, 374, 1593, 1615, 1679; 370–371, 373, 1590–1592, 1595 ("ended at exactly day 15"); line 1586 (payment at day 15 + 1 h refunded) becomes accepted if before the new cutoff.

## States (new `past_due_reason` in account state, from the open renewal bill's attempts)
| reason | when | card | tries left |
|---|---|---|---|
| `refused` | last saved-card attempt on the bill has `hard_decline` | removed | none |
| `no_card` | renewal found no usable card (attempt channel `none`), or the card was already off | none | none |
| `retrying` | soft decline, card active, and `next_try_on` exists (a billing run is still to come before the cutoff that will try the card) | kept | yes |
| `last_try_failed` | soft decline, card active, and no billing run remains before the cutoff — whether the final try failed or was never made (e.g. an open Paystack page blocked the last morning's run) | kept | none |
| `checking` | the open renewal bill has a `saved_card` attempt with status `created`, `pending` or `unknown` (not `card_page`; an abandoned Paystack tab never hides the Pay button). Takes priority over earlier failures on the bill. | kept | n/a |

**Retry date shown to owners** (`next_try_on`, new in account state): the next daily billing run (`billing-run`, today 04:00–05:55 UTC) at or after `greatest(now, next untried slot)` and strictly before `plan_ends_at`, shown as its day in the account's time zone. Untried = no non-void saved_card/none attempt since that slot (as `run_one` counts it, 0245:1282). Null when no such run remains, and null when there is no active card. Example: slot 26 Nov 15:30 → "27 Nov 2026"; final slot 7 Dec 15:30 → "8 Dec 2026" (before the midnight cutoff); if the 8 Dec run is skipped, next_try_on goes null and the state becomes `last_try_failed`. Date only, no time. `next_retry_at` stays as it is for the job. State also carries `retry_window_ends_at` = least(end of that run's window, `plan_ends_at`) so an open screen knows when to re-read.

Older rows without enough evidence fall back to the neutral wording "Your R99 payment for Family is overdue. Pay by 8 Dec 2026 or Family ends and readings stop."

## 1. Emails (all transactional: `outbox_kinds.reminder = false`, never stopped by the reminders setting)
Mail parts named as in `outboxMail`: title, lead, note, button.
Which attempt sends what: a failed `saved_card` attempt sends `payment_failed` (soft) or `card_update` (hard); a `none` attempt sends `payment_due`; a failed `card_page` attempt (the owner paying on Paystack and seeing the result on screen) sends no email. Today `outbox_on_attempt` doesn't check the channel (0247:1137).

### 1-soft. `payment_failed` (retrying, last_try_failed), one per failed saved-card try
(Its send-time "a later try" check, 0247:1321, counts only saved_card / none attempts, so a failed card-page payment doesn't swallow it.)
- Subject: "Your Family payment didn't go through"
- Title: "Pay R99 by 8 Dec 2026"
- Line straight under the title (as today, text.ts:525): "If it isn't paid by then, Family ends and readings stop." (so "then" can't read as the retry date)
- Lead: "We couldn't charge your card for Family. We'll try it again on 27 Nov 2026." / after the last try: "We couldn't charge your card for Family. We won't try it again."
- Button: "Pay with another card"

### 1a. `card_update` (refused), day of refusal
- Subject: "Your Family payment didn't go through"
- Title: "Pay R99 by 8 Dec 2026"
- Lead: "We couldn't charge your Visa •••• 4081 for Family, so we've removed it from your account. We won't try it again." (card from the refused attempt itself: `apply_payment` sets the outbox `ref` to the attempt id and `outbox_take` reads it; rows queued before deploy fall back to the latest hard-declined saved_card attempt on the bill; "your saved card" if unknown)
- Note: "If it isn't paid by then, Family ends and readings stop."
- Button: "Pay with another card"

### 1b. New key `payment_due` (no_card), renewal day. Replaces today's `payment_failed` "That was our last try." for this case.
`outbox_guard` gets a `payment_due` branch like `card_update`'s: bill open, past due, no active card.
- Subject: "Your Family payment is due"
- Title: "Pay R99 by 8 Dec 2026"
- Lead: "There's no card saved to pay for Family."
- Note and button as 1a.

### 1c. No reminder email (Brynne, 2026-11-24)
No new grace-period reminder. Failed saved-card retries still send the §1-soft emails. A reminder 3 days before the end is parked in SOLAR-654.

### 1d. `plan_ended` (all reasons)
- Subject: "Your Family plan has ended"
- Title: "Family ended on 8 Dec 2026" (from the subscription's `ended_at`)
- Lead when the `plan_ended` event's reason is `unpaid`: "It wasn't paid, so readings have stopped." + the existing history line. Other reasons: today's "Readings have stopped." + history line.
- Button: "See plans"
- Needs `outbox_take` to attach the end reason from the subscription's latest `plan_ended` event (a revived plan can have two).
- Held (not sent, not dropped) while `renewal_in_flight` is true, **or** while that renewal bill still has a card-page attempt in `created`, `pending` or `unknown` made before the cutoff, for at most 24 hours from the cutoff. `notify` has no Paystack key, so it never verifies; it only reads. The billing job (`billing/run`, which has the key) verifies those card pages in the same run that ends the plan, so the email waits for that answer instead of racing it (today `end_sub` queues it before `billing/run` verifies, 0247:1171, billing/index.ts:247). If 24 hours pass with no final answer (still open, or closed by the 24 h timeout), the email is sent **without** "It wasn't paid": lead "Readings have stopped." + history line. The hold is a skip in `outbox_take` (row left for a later pass, `tries` not counted), not an `outbox_guard` drop. Held rows are excluded in the query before its batch limit, so a full batch of held rows never stops later emails.
- Keyed per ending, not per subscription: dedupe key `plan_ended:<sub id>:<ended_at>` (today `plan_ended:<sub id>`, 0247:1172), so if a revived plan later ends for real its email isn't swallowed by the dropped one. The row stores its `ended_at`; `outbox_guard` drops it if the subscription's current `ended_at` differs (that ending is no longer current), and `outbox_take` reads the `plan_ended` event matching that `ended_at`, not just the latest.

### 1e. Downgrade booked
Every email above uses the due plan for what's paid and the running plan for what ends: "Pay R49 for Home by 8 Dec 2026" / "If it isn't paid by then, Family ends and readings stop."

## 2. Billing → Plan (red note under the plan name, one button)
- refused: "R99 for Family didn't go through and your card was removed. Pay by 8 Dec 2026 or Family ends and readings stop."
- no_card: "R99 for Family is due. Pay by 8 Dec 2026 or Family ends and readings stop."
- retrying: "R99 for Family didn't go through. We'll try your card again on 27 Nov 2026. Pay by 8 Dec 2026 or Family ends and readings stop."
- last_try_failed: "R99 for Family didn't go through. We won't try your card again. Pay by 8 Dec 2026 or Family ends and readings stop."
- checking: "We're still checking your R99 payment for Family with your bank." No button (avoids paying twice). No promise of an email: not every outcome sends one. While this note shows (also when an email link or a 409 lands here), the app re-reads the account every 15 s (the shell loop below): when the try settles and the bill is still due, the note changes to the matching state above and the button comes back; when it's paid, the note clears.
- **One refresh rule for every past-due note** (refused, no_card, retrying, last_try_failed, checking, and the neutral fallback): while Billing is visible and `state === 'past_due'`, it re-reads the account every 60 s (while `checking`, the 15 s shell loop below takes over), also right when `retry_window_ends_at` passes (timer set only if that time is still ahead), and whenever the tab comes back into view. A failed read is retried on the next tick. Polling skips while the tab is hidden (as link.jsx:82 does). So a run that didn't happen turns into the `last_try_failed` note, and a late morning charge that succeeds clears the note, without a manual reload.
- **Across the cutoff.** A saved-card try can be paid before the cutoff and confirmed after it; meanwhile the account reads `ended` and the app swaps Billing for the ended screen (app.jsx:1818), and the backend later brings the plan back (`revive`, 0245:931). So the 15 s re-read lives in the signed-in shell, not in Billing: it runs while account state has `renewal_in_flight` (new field; not the existing SQL helper `billing.payment_in_flight`, which only sees open bills). True when the latest subscription's latest renewal bill, open or void, has (a) a saved_card attempt in `created`, `pending` or `unknown`, or (b) a card_page attempt made before the cutoff, in `created`, `pending` or `unknown`, with new column `verified_processing = true` **or** new column `verify_unanswered_at` set, while `now < cutoff + 24 h`; whatever the plan state. Before the cutoff, (b) only starts the 15 s loop; it changes no screen and no refusal. It skips hidden tabs, re-reads on show, and stops when it settles.
- **Card-page payments at the cutoff.** An owner can pay on Paystack just before midnight and the confirmation come after.
  - New column `payment_attempts.verified_processing` (default false). `apply_payment` sets it true when Paystack gives any answer that is not final for a card page (today `pending`, `ongoing`, `processing`, `queued`; an unlisted status must not fall into the catch-all at 0245:1032 and read as an abandoned tab), and clears it on any final answer. Today a just-opened page and a payment Paystack is still processing both read `pending` (0245:738, 1033), so without it an abandoned tab and a real payment can't be told apart.
  - New column `payment_attempts.verify_unanswered_at`. When any check of a renewal card page gets no usable answer (the job, `/billing/pay` or `/billing/verify`; timeout or gateway error: `verify()` returns null, billing/index.ts:121), the billing function records it under the account lock unless the attempt has already settled. Any later answer clears it.
  - A renewal card page still unanswered or not final at cutoff + 24 h has its status set to `failed` (by `apply_payment` and by the no-answer command alike, so a saved-card restart isn't bounced by the card-page check at 0245:729), with its own `gateway_response` marking the timeout, so §1d still leaves out "It wasn't paid" whichever runs first. The cutoff here is `coalesce(s.ended_at, billing.past_due_cutoff(…))`, since `end_sub` clears `past_due_since` (0245:199). Today `apply_payment` never times out a card page (0245:926).
  - **Re-check while held.** Account state carries the oldest still-held attempt's reference. Once the cutoff has passed, while (b) holds and a tab is visible, the shell calls the existing `/billing/verify` with it once a minute, and re-reads the account at once when the answer settles it (applied, failed, void, refund); an applied answer sends `renewal_paid_done`, deduped on the reference. So the hold clears as soon as Paystack answers, not at the next morning job (whose last verify is about 07:00 SAST; there is no webhook for a failed charge, billing/index.ts:192).
  - **Before a restart checkout** (`POST /billing/pay`, before `start_checkout`): the billing function verifies with Paystack every unresolved card page (`created`, `pending`, `unknown`, ignoring `claimed_until`) on the latest renewal bill, open or void:
    - paid before the cutoff → applied (through `revive` after the morning job; directly by `apply_payment`, `action: 'applied'`, between midnight and the job, 0245:952). The reply says the renewal was applied, the app reloads into the running plan, and `plan_start_done` doesn't fire for a restart that never happened (link.jsx:327);
    - still processing → `verified_processing` set, so `renewal_in_flight` is true; `start_checkout` refuses with the 409 and the app shows the paused note;
    - no usable answer → `verify_unanswered_at` recorded, so `renewal_in_flight` is true; 409, and the reloaded screen shows the paused note (consistent with the refusal); the once-a-minute re-check above clears it when Paystack answers; at cutoff + 24 h it ends and restart goes ahead;
    - abandoned, failed or never submitted → restart goes ahead. (If such a page is paid later anyway, the existing stale-payment refund applies.)
- **Ended while that payment is still being checked** (`state === 'ended'` and `renewal_in_flight`):
  - The ended screen **and Billing → Plan** (reachable from the ended screen, and where an owner watching the checking note already is) show "Readings are paused while we check your Family payment." instead of their usual ended wording (no "Family ended on …", no history line), and no "See plans" button. With a booked downgrade, the due plan ("…your Home payment."). The Plan card's heading shows the plan's name, not "No plan". `pay_wall_shown` doesn't fire while it holds, and fires once when "See plans" appears after a failed try.
  - The server refuses to start a new plan or restart while it holds (same 409, "A payment is already in progress."): checked at the top of `start_checkout` and in `begin_attempt` for purchase bills, before its cached-page branch (0245:704), so neither a new checkout nor an older open purchase bill gets through. Not for renewal bills: before the cutoff, "Pay with another card" must still reopen an existing Paystack page mid-challenge. An owner whose card was charged can't pay twice.
  - If the renewal is applied, the plan comes back (`revive`) and the app returns to it as normal. If it fails, the usual ended screen and "See plans" come back.
  - The `plan_ended` email waits (§1d), then its guard runs again (dropped if the plan came back). So "It wasn't paid" never reaches an owner whose card was charged before the cutoff.
- Button (all but checking): "Pay with another card"
- "Change plan" hidden while past due (today it opens Plans and every button there refuses); "See plans" doesn't take its place.
- Downgrade booked: "R49 for Home …" with "or Family ends and readings stop".

## 3. Billing → Card
- refused and no_card: "No card saved." No button. (Plan, just above, already says the card was removed; say it once.)
- retrying / last_try_failed / checking: the saved card as today.
- After paying: the new card shows if Paystack lets it be saved.

## 4. Billing → Payments
Heading "Payment history". Completed payments and refunds only; the unpaid amount is shown once, in Plan.

## 5. Live card and bell (same facts on phone and desktop)
- Title: "Family payment failed" (no_card: "Family payment due"). Booked downgrade: the due plan ("Home payment failed").
- Body: "Pay R99 by 8 Dec 2026 or readings stop." (retrying adds nothing more; the retry date is in Billing.)
- Button: "Pay with another card"
- checking: no Live card, no bell notice, no header dot; the owner has nothing to do. Billing shows the checking note.
- Built directly from state, no regex strip (fixes "Payment of R1 990 failed" shown twice on yearly plans).
- At the cutoff: while the cached account is past due, the signed-in shell re-reads it when `plan_ends_at` passes (delay worked out from the state's server time `at`, 0247:182, not the device clock) and whenever a tab comes back into view. It needs a successful read **started** at or after the cutoff: if the timer joins a read already in flight (`reloadAccount` shares one, link.jsx:131), it reads again after; a failed read, or one that still says past due, is retried every 60 s while the tab is visible. So Live (or any page) swaps to the ended screen instead of keeping a pay button after readings stop.
- Header account dot shows on every page while past due (in both `App` and `Setup`). `AccountMenu` gets the reason: "Payment failed" / "Payment due" / "Reconnect a login" / "Needs attention" (both), with matching aria-labels (today it always says "Reconnect a login"). Neutral fallback rows: title "Family payment overdue", label "Payment due". checking: no payment dot here or on Settings' Billing row; a reconnect alert still shows.
- "Pay the failed payment first" (refusals elsewhere) → "Pay the overdue payment first".

## 6. Pay flow (one flow from Billing, Live, bell and every email)
- Email link carries the bill id in the existing `pay` parameter (`?pay=<bill id>`), which sign-in already keeps (`DEEP_KEYS`, auth.jsx:97). The bill id goes through to the actual pay request. Under the account lock, `begin_attempt` checks the bill belongs to the account and is still payable before handing back an existing Paystack page or making an attempt. For a renewal bill, still payable = `inv.status = 'open'` and `account_status` says `state in ('active', 'past_due')` with `sub = inv.subscription`. (Not `inv.status = 'open'` alone: between midnight and the morning job the bill is still open but the plan has ended. And `active` must stay payable: on renewal day before the morning job, `pay_now` and Change card (`start_card_check`) use the open renewal bill, 0245:640, 654; tests F9, Q4, P4-7.) `begin_attempt` gets an optional `p_account` for the ownership check. Paid: "This payment has already been made." Gone: "This payment is no longer due." (+ goes to Billing). A saved-card try in flight (checking, or ended with `renewal_in_flight`): opens Billing, which shows the checking note or the paused-while-we-check note. Otherwise straight on. Links in emails sent before this ships (`?pay=1`, no bill id) open Billing.
- The server's "a payment is already in progress" (409) re-reads the account. If the renewal is `checking`, or the plan is ended with `renewal_in_flight`, the app opens Billing (from Live or the bell too) and shows the checking note or the paused note. Otherwise: "A payment is already in progress." (today it falls through to a generic error).
- Working step: "Opening Paystack…"
- Couldn't open: "Couldn't open Paystack. Try again."
- The reference is kept until the result is known (not cleared before verifying).
- Paid, renewal: "Payment received. Family carries on." Paid, renewal that applied a downgrade: "Payment received. Home is now your plan." First plans and upgrades: "Payment received." (unchanged)
- Closed without paying (verified void, also on a repeat check): "Payment not completed."
- Declined: "The payment didn't go through."
- On `applied` (first check, polling or Check again) the account is reloaded so Billing's red note clears.
- Pending: a message that stays (a new `sticky` toast option; today only toasts with an action skip the 5 s dismiss): "We're still checking your payment." The page re-checks the same reference every 5 s for 60 s. Still pending after that: "We're still checking your payment." [Check again] (no promise of an email).
- `/verify` returns `plan`, `plan_name`, `period` and whether the renewal changed the plan, so the paid message and `renewal_paid_done` are right even when the webhook settled it first.
- Couldn't check: "Couldn't check your payment." [Check again]
- Refund case unchanged.
- Double-click guard on the button.

## 7. Analytics
- New `renewal_paid_done` (`plan`, `period`): one per verified, applied manual renewal payment, also when the webhook settled it first; deduped on the payment reference (return, refresh and Check again send it once). Line in ANALYTICS.md.
- `plan_start_done` unchanged for first plans and restarts (today renewals wrongly fall into it with no properties).

## 8. Tests to add (besides the cutoff tests in Names)
- Abandoned card page at the cutoff: the email goes after the morning run, with "It wasn't paid".
- Card page paid 23:59, confirmed after: plan revived, email dropped.
- First cutoff verify times out: reload shows the paused note; an open purchase checkout is refused; the next answer clears the hold; at cutoff + 24 h, with Paystack still unreachable for the old reference, a restart on the saved card goes through and the email says "Readings have stopped."

## Out of scope
- Letting a past-due owner cancel or delete (policy; separate ticket if wanted).
- Old `bill_*` emails (removed ~2026-11-25). SOLAR-645 messaging rebuild.
