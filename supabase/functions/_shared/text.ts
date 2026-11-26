// Every line about accounts, logins, chosen plants, plans, prices, billing, the free week
// and history kept or deleted (SOLAR-641). Screens (public/build/text.js, made from this
// file by scripts/build-jsx.js) and emails (notify) both read it. Slots come only from
// billing.screen_state (0247), as the app gets it from api_account_state: no count,
// price, plan name or date is worked out anywhere else. Money from amount_minor +
// currency + locale; dates in the account's time zone.
//
// Copy rules (design section 6, CLAUDE.md memory): name the exact plan, plant and date;
// no billing-system words; buttons say the action only; a fact appears once per screen;
// a "kept until" line only when that plant has a delete date.

export type Iso = string;
export type PlantState = {
  plant: number; name: string | null; chosen: boolean; locked: boolean; read_now: boolean;
  needs_reconnect: boolean; trial_used_elsewhere: boolean; delete_at: Iso | null; purged: boolean;
  kept_elsewhere: boolean; payment_hold: boolean; drop_at_period_end: boolean; logins: string[]; gone_logins: string[]; claimed: boolean; shared: boolean;
};
export type PriceRow = {
  plan: string; name: string; places: number; interval: "month" | "year";
  amount_minor: number; list_minor: number | null; offer: string | null; currency: string;
};
export type Bill = {
  id: string; kind: string; plan: string; plan_name: string; interval: "month" | "year"; amount_minor: number;
  currency: string; paid_at: Iso; period_start: Iso | null; period_end: Iso | null; refunded: boolean;
};
export type Login = { id: string; brand: string; username: string; status: "ok" | "needs_reconnect" };
export type AccountState = {
  state: "none" | "trialing" | "active" | "past_due" | "ended";
  plan: string | null; plan_name: string | null; interval: "month" | "year" | null; amount_minor: number | null;
  currency: string; places: number; chosen: number; linked: number; open: number; must_choose: boolean;
  trial_ends_at: Iso | null; period_end: Iso | null; cancel_at: Iso | null; next_charge_at: Iso | null;
  next_retry_at: Iso | null; past_due_since: Iso | null; plan_ends_at: Iso | null; access_ended_at: Iso | null;
  may_add_login: boolean; may_choose: boolean; may_switch: boolean; may_delete: boolean;
  fit_all_plan: string | null; fit_all_name: string | null;
  card: { last4: string | null; exp_month: number | null; exp_year: number | null; card_type: string | null } | null;
  card_expires_first: boolean; next_plan: string | null; next_plan_name: string | null; next_interval: string | null;
  next_amount_minor: number | null; next_places: number | null; amount_due_minor: number | null; pay_url: string | null;
  owed_minor: number; dispute_open: boolean;
  time_zone: string; locale: string; last_plan: string | null; last_plan_name: string | null; had_plan: boolean;
  /** Ended on a plan from us (a grant ended last). */
  grant_ended?: boolean;
  retention_days: number; trial_places: number; trial_ends_soon: boolean; cancel_soon: boolean;
  if_cancelled_delete_at: Iso | null; history_kept_until: Iso | null; history_purged: boolean;
  /** When the state was read. */
  at?: Iso;
  /** An unpaid renewal (0248): why it is unpaid, the next try's day (a plain date), when an open
   *  screen reads again, the bill to pay, whether a renewal payment may still land, and the last
   *  saved card when it was refused for good (shown, never charged). */
  past_due_reason?: "refused" | "no_card" | "retrying" | "last_try_failed" | "checking" | null;
  next_try_on?: string | null; retry_window_ends_at?: Iso | null;
  due_bill?: { id: string; plan: string; plan_name: string; interval: string; amount_minor: number; currency: string } | null;
  renewal_in_flight?: boolean; held_reference?: string | null;
  refused_card?: AccountState["card"];
  plants: PlantState[]; prices: PriceRow[]; logins: Login[]; bills: Bill[];
};
export type Quote = {
  kind: "purchase" | "upgrade" | "downgrade" | "interval"; plan: string; plan_name: string; places: number;
  interval: "month" | "year"; due_minor: number; next_amount_minor: number; next_at: Iso; currency: string;
  offer: string | null; drop?: number;
  /** upgrade: the new period starts at the payment (monthly to yearly, SOLAR-675) */
  starts_now?: boolean;
};
/** Forms for zero, one and many. zero falls back to many. */
export type Forms = { zero?: string; one: string; many: string };

// ------------------------------------------------------------------ formatting

/** "R49", "R1 799", "R40.50": the currency's own symbol, a thin space between thousands. */
export function money(minor: number | null | undefined, currency: string, locale = "en-ZA"): string {
  if (minor == null) return "";
  const n = minor / 100;
  const sym = new Intl.NumberFormat(locale, { style: "currency", currency, currencyDisplay: "narrowSymbol" })
    .formatToParts(0).find((p) => p.type === "currency")?.value ?? currency;
  const digits = new Intl.NumberFormat("en-US", { minimumFractionDigits: minor % 100 ? 2 : 0, maximumFractionDigits: 2 })
    .format(n).replace(/,/g, " ");
  return sym + digits;
}
const dtf = (s: AccountState | { time_zone: string; locale?: string }, o: Intl.DateTimeFormatOptions) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: s.time_zone, ...o });
/** "3 Dec 2026" in the account's time zone. */
export const day = (s: { time_zone: string }, iso: Iso | null | undefined): string =>
  iso ? dtf(s, { day: "numeric", month: "short", year: "numeric" }).format(new Date(iso)).replace(/\bSept\b/, "Sep") : "";
/** "27 Nov 2026" for a plain date ("2026-11-27"), with no time zone to shift it. */
const dateOnly = (d: string | null | undefined): string => day({ time_zone: "UTC" }, d);
/** "Friday 4 Dec" for a date this week or next. */
export const weekday = (s: { time_zone: string }, iso: Iso | null | undefined): string =>
  iso ? dtf(s, { weekday: "long", day: "numeric", month: "short" }).format(new Date(iso)).replace(/\bSept\b/, "Sep") : "";
export const forms = (n: number, f: Forms) => (n === 0 ? f.zero ?? f.many : n === 1 ? f.one : f.many).replace(/\{n\}/g, String(n));
/** "A", "A and B", "A, B and C" */
export const names = (list: string[]) => list.length < 2 ? list.join("") : `${list.slice(0, -1).join(", ")} and ${list[list.length - 1]}`;
export const plantName = (p: { name: string | null; plant: number }) => p.name || `Plant ${p.plant}`;
const per = (i: string | null) => (i === "year" ? "a year" : "a month");
const plantsWord = (n: number) => forms(n, { one: "1 plant", many: "{n} plants" });

// ------------------------------------------------------------------ the plan, everywhere

/** The plan's name, or what the account has instead. */
export function planTitle(s: AccountState): string {
  if (s.plan_name) return s.plan_name;
  if (s.state === "trialing") return "Free week";
  if (s.state === "active") return "Plan from us";          // a grant: places with no billing
  return "No plan";
}
/** "R49 a month" for a running plan; null when nothing is charged. */
export const planPrice = (s: AccountState) => s.amount_minor != null ? `${money(s.amount_minor, s.currency, s.locale)} ${per(s.interval)}` : null;

/** The one line under the plan's name: what happens next and when. */
export function planStatus(s: AccountState): string | null {
  switch (s.state) {
    case "trialing": return `Free until ${weekday(s, s.trial_ends_at)}`;
    case "active":
      if (s.cancel_at) return `Ends on ${day(s, s.cancel_at)}`;
      return s.next_charge_at ? `Renews on ${day(s, s.next_charge_at)}` : null;
    case "past_due":
      return pastDueNote(s).text;
    case "ended":
      return s.access_ended_at ? `${s.grant_ended ? "Plan from us ended" : s.had_plan ? `${s.last_plan_name} ended` : "Free week ended"} on ${day(s, s.access_ended_at)}` : null;
    default: return null;
  }
}

/** An unpaid renewal: what is paid (the open renewal bill: a booked downgrade bills the smaller
 *  plan) and what ends at the cutoff (the plan running now). */
function due(s: AccountState) {
  const b = s.due_bill;
  return { amount: money(b?.amount_minor ?? s.amount_due_minor, b?.currency ?? s.currency, s.locale),
    plan: b?.plan_name ?? s.plan_name ?? s.last_plan_name ?? "", ends: s.plan_name ?? s.last_plan_name ?? "",
    by: day(s, s.plan_ends_at) };
}
/** Billing's red note on an unpaid renewal, by why it is unpaid. button: null while the bank
 *  is still answering (paying again could pay twice). */
/** "R99 payment", or "R49 payment for Home" when a booked downgrade bills another plan. The
 *  plan that ends is named once, where it ends. */
const duePayment = (d: ReturnType<typeof due>) => `${d.amount} payment${d.plan !== d.ends ? ` for ${d.plan}` : ""}`;
const nothingToDo = "You don't need to do anything.";
export function pastDueNote(s: AccountState): { text: string; button: string | null } {
  // what is lost, framed as what is kept; only the plan being paid is named (a booked downgrade: Home)
  const d = due(s), yours = `Your ${duePayment(d)}`, end = `Pay by ${d.by} to keep your readings.`;
  const text = (t: string) => ({ text: t, button: billing.payOther });
  switch (s.past_due_reason) {
    case "checking": return { text: `We're still checking your ${duePayment(d)}. ${nothingToDo}`, button: null };
    case "refused": return text(`${yours} didn't go through. We won't try your saved card again. ${end}`);
    case "no_card": return text(`${yours} is due. ${end}`);
    case "retrying": return text(`${yours} didn't go through. We'll try your card again on ${dateOnly(s.next_try_on)}. ${end}`);
    case "last_try_failed": return text(`${yours} didn't go through. We won't try your card again. ${end}`);
    default: return text(`${yours} is overdue. ${end}`);
  }
}
/** The account menu's word under the name, and its dot's label: a payment to make, a login to
 *  reconnect, or both. A payment the bank is still answering needs nothing. */
export function accountAlert(s: AccountState | null, reconnect: boolean): string | null {
  const pay = s?.state === "past_due" && s.past_due_reason !== "checking";
  if (pay && reconnect) return "Needs attention";
  if (pay) return s!.past_due_reason === "no_card" || !s!.past_due_reason ? "Payment due" : "Payment failed";
  return reconnect ? "Reconnect a login" : null;
}

/** Chosen plants out of the places: counts are chosen plants, zero included. */
export function placesLine(s: AccountState): string {
  return forms(s.chosen, {
    zero: `No plants chosen. ${forms(s.places, { one: "1 place", many: "{n} places" })} open.`,
    one: `1 of ${plantsWord(s.places)} chosen`,
    many: `{n} of ${plantsWord(s.places)} chosen`,
  });
}

/** Over the places (a plan shrank): nothing is read until the owner picks. */
export const mustChoose = (s: AccountState) => s.must_choose
  ? { title: `Choose ${plantsWord(s.places)}`, body: `${planTitle(s)} reads ${plantsWord(s.places)}. Nothing is read until you choose.`, button: "Choose plants" }
  : null;

/** A change booked for the billing date, with its undo button. */
export function bookedChange(s: AccountState): { text: string; button: string } | null {
  if (s.state !== "active" || !s.period_end) return null;
  if (s.cancel_at) return { text: `${s.plan_name} ends on ${day(s, s.cancel_at)}. ${keptAfterCancel(s)}`, button: `Keep ${s.plan_name}` };
  if (s.next_plan && s.next_plan !== s.plan) {
    const going = s.plants.filter((p) => p.drop_at_period_end);
    return {
      // a move booked with the other interval says so (SOLAR-675)
      text: [`Moves to ${s.next_plan_name}${s.next_interval && s.next_interval !== s.interval ? (s.next_interval === "year" ? " yearly" : " monthly") : ""} on ${day(s, s.period_end)}.`,
        going.length ? dropLine(s, going) : null].filter(Boolean).join(" "),
      button: `Keep ${s.plan_name}`,
    };
  }
  if (s.next_interval && s.next_interval !== s.interval) {
    return { text: `Paid ${s.next_interval === "year" ? "yearly" : "monthly"} from ${day(s, s.period_end)}.`,
      button: s.interval === "year" ? "Stay yearly" : "Stay monthly" };
  }
  return null;
}
const keptAfterCancel = (s: AccountState) =>
  s.if_cancelled_delete_at && s.cancel_at
    ? `Readings stop then; history is kept ${forms(s.retention_days, { one: "1 day", many: "{n} days" })}.` : "Readings stop then.";
/** The plants a booked downgrade lets go, and what happens to each one's history. */
function dropLine(s: AccountState, going: PlantState[]): string {
  const gone = going.filter((p) => !p.kept_elsewhere).map(plantName), kept = going.filter((p) => p.kept_elsewhere).map(plantName);
  return [gone.length ? `${names(gone)} ${forms(gone.length, { one: "stops", many: "stop" })} and ${forms(gone.length, { one: "its", many: "their" })} history is deleted then.` : null,
    kept.length ? `${names(kept)} ${forms(kept.length, { one: "stops", many: "stop" })}; another account keeps the history.` : null].filter(Boolean).join(" ");
}

/** The saved card (or c: Billing passes the refused card, shown but never charged). */
export const cardLine = (s: AccountState, c = s.card) => c
  ? `${(c.card_type || "Card").replace(/^\w/, (x) => x.toUpperCase())} •••• ${c.last4 ?? ""}`.trim()
  : null;
export const cardSub = (s: AccountState) => !s.card && s.refused_card ? "Can't be charged"
  : s.card && s.card.exp_month
  ? (s.card_expires_first ? "Expires before your next payment" : `Expires ${String(s.card.exp_month).padStart(2, "0")}/${String(s.card.exp_year).slice(-2)}`)
  : null;

/** One paid bill in Billing's list. */
export const billRow = (s: AccountState, b: Bill) => ({
  when: day(s, b.paid_at),
  what: `${b.plan_name}, ${b.kind === "upgrade" ? "upgrade" : b.interval === "year" ? "yearly" : "monthly"}`,
  amount: money(b.amount_minor, b.currency, s.locale),
  note: b.refunded ? "Refunded" : null,
});

// ------------------------------------------------------------------ Billing page

export const billing = {
  title: "Billing",
  planHead: "Plan",
  cardHead: "Card",
  billsHead: "Payment history",
  cancelHead: "Cancellation",
  cancelButton: "Cancel",
  noBills: "No payments yet.",
  noCard: "No card saved.",
  changePlan: "Change plan",
  seePlans: "See plans",
  cancelPlan: "Cancel plan",
  pay: "Pay",
  payOther: "Pay with another card",
  changeCard: "Change card",
  addCard: "Add card",
  choosePlants: "Choose plants",
};

/** Cancel plan pop-up. */
export const cancelDialog = (s: AccountState) => ({
  title: `Cancel ${s.plan_name}?`,
  steps: [
    [`Until ${day(s, s.period_end)}`, "Nothing changes. Nothing more is charged."],
    [`On ${day(s, s.period_end)}`, s.if_cancelled_delete_at
      ? `Readings stop. History is kept until ${day(s, s.if_cancelled_delete_at)}, then deleted.`
      : "Readings stop."],
  ] as [string, string][],
  button: "Cancel plan",
  keep: `Keep ${s.plan_name}`,
});

/** Delete account refused (may_delete false): why, and where to go. to: where the button
 *  leads, never a section the page does not show; null: Close only. */
export function deleteBlocked(s: AccountState): { title: string; text: string; action: string | null; to: "billing" | "cancel" | "mail" | null } | null {
  if (s.may_delete) return null;
  if (s.dispute_open) return { title: "A payment is in dispute", text: "You can delete your account once it's settled.", action: null, to: null };
  // the bank is still answering a renewal: nothing to pay, and a paid one may leave a running plan
  if (s.state === "past_due" && s.past_due_reason === "checking") return { title: "We're checking a payment", text: "Try again once the check is done.", action: null, to: null };
  if (s.state === "past_due") return { title: "Pay the overdue payment first", text: "Pay it in Billing, then you can delete your account.", action: "Go to Billing", to: "billing" };
  if (s.owed_minor > 0) return { title: `${money(s.owed_minor, s.currency, s.locale)} is owed`, text: "Email us to settle it, then you can delete your account.", action: "Email us", to: "mail" };
  if (s.cancel_at) return { title: `${s.plan_name} ends on ${day(s, s.cancel_at)}`, text: "You can delete your account after that.", action: null, to: null };
  if (s.plan_name) return { title: "Cancel your plan first", text: `Your ${s.plan_name} plan is still running. Cancel it in Billing, then you can delete your account.`, action: "Go to cancel plan", to: "cancel" };
  return { title: "Your plan from us is still running", text: "Email us to end it, then you can delete your account.", action: "Email us", to: "mail" };
}

// ------------------------------------------------------------------ Plans pop-up

export const plans = {
  title: "Plans",
  monthly: "Monthly",
  yearly: "Yearly",
  fits: "Fits your plants",
  current: "Your plan",
  feats: ["Live, every minute", "Power-cut and battery emails", "History, for good", "Monthly report"],
};
/** One plan card: price for this account (launch price kept on a running plan), list price struck. */
export function planCard(s: AccountState, p: PriceRow) {
  const current = s.plan === p.plan && (s.state === "active" || s.state === "past_due");
  const offer = p.list_minor != null && p.list_minor > p.amount_minor;
  return {
    name: p.name,
    places: forms(p.places, { one: "1 plant", many: "{n} plants" }),
    price: money(p.amount_minor, p.currency, s.locale),
    per: per(p.interval),
    was: offer ? money(p.list_minor, p.currency, s.locale) : null,
    offer: offer ? "Launch price" : null,
    fits: s.fit_all_plan === p.plan && s.linked > 0,
    current: current && s.interval === p.interval,
    button: current ? (s.interval === p.interval ? null : p.interval === "year" ? "Pay yearly" : "Pay monthly")
      : s.state === "active" || s.state === "past_due" ? `Move to ${p.name}` : `Start ${p.name}`,
  };
}

/** The review step before a payment or a booked change. */
export function quoteReview(s: AccountState, q: Quote) {
  const m = (n: number) => money(n, q.currency, s.locale);
  switch (q.kind) {
    case "purchase": return {
      title: `Start ${q.plan_name}`, due: m(q.due_minor),
      lines: [`Then ${m(q.next_amount_minor)} ${per(q.interval)} from ${day(s, q.next_at)}.`],
      button: "Pay",
    };
    case "upgrade": return {
      title: `Move to ${q.plan_name}`, due: m(q.due_minor),
      lines: [q.starts_now ? "A year from today, less the unused days of your plan."
        : q.due_minor ? "For the days left until your next payment." : "Nothing to pay for the days left.",
        `Then ${m(q.next_amount_minor)} ${per(q.interval)} from ${day(s, q.next_at)}.`],
      button: q.due_minor ? "Pay" : `Move to ${q.plan_name}`,
    };
    case "downgrade": return {
      title: `Move to ${q.plan_name}`, due: null,
      lines: [`From ${day(s, q.next_at)}: ${m(q.next_amount_minor)} ${per(q.interval)}, ${forms(q.places, { one: "1 plant", many: "{n} plants" })}.`],
      button: `Move to ${q.plan_name}`,
    };
    default: return {
      title: q.interval === "year" ? "Pay yearly" : "Pay monthly", due: null,
      lines: [`From ${day(s, q.next_at)}: ${m(q.next_amount_minor)} ${per(q.interval)}.`],
      button: q.interval === "year" ? "Pay yearly" : "Pay monthly",
    };
  }
}

// ------------------------------------------------------------------ choosing plants

/** Checkout and start: the final plant choice, before paying. */
export const checkoutPick = (s: AccountState, planName: string, places: number) => ({
  title: `Choose plants for ${planName}`,
  note: `${planName} reads ${forms(places, { one: "1 plant", many: "{n} plants" })}.`,
  tooMany: `${planName} reads ${forms(places, { one: "1 plant", many: "{n} plants" })}. Untick one.`,
  none: "Choose at least one plant.",
  button: "Next",
});

/** A downgrade: the plants the smaller plan keeps; the others stop on the billing date. */
export const keepPick = (s: AccountState, planName: string, places: number) => ({
  title: `Plants to keep on ${planName}`,
  note: `${planName} reads ${forms(places, { one: "1 plant", many: "{n} plants" })}. The others stop on ${day(s, s.period_end)}.`,
  tooMany: `${planName} reads ${forms(places, { one: "1 plant", many: "{n} plants" })}. Untick one.`,
  button: `Move to ${planName}`,
});

/** The free week, before it starts: up to its places. */
export const weekPick = (s: AccountState) => ({
  title: "Choose plants",
  note: `The free week reads up to ${forms(s.trial_places, { one: "1 plant", many: "{n} plants" })}.`,
  button: "Start free week",
});

/** The Choose plants pop-up on the Plants page. */
export const choosePlants = (s: AccountState) => ({
  title: "Choose plants",
  note: s.state === "trialing" || s.state === "none"
    ? `The free week reads up to ${forms(s.trial_places, { one: "1 plant", many: "{n} plants" })}.`
    : `${planTitle(s)} reads ${forms(s.places, { one: "1 plant", many: "{n} plants" })}.`,
  tooMany: `That is more than ${forms(s.state === "trialing" || s.state === "none" ? s.trial_places : s.places, { one: "1 plant", many: "{n} plants" })}. Untick one.`,
  usedElsewhere: "Free week used",
  button: "Save",
  more: "Need more plants? See plans.",
});

/** Every change of chosen plants is confirmed here (design: no one-tap toggle). atPayment:
 *  the checkout pick, where nothing changes until the payment goes through (said once, first). */
export function switchConfirm(s: AccountState, goingIds: number[], comingIds: number[], atPayment = false) {
  const byId = (id: number) => s.plants.find((p) => p.plant === id);
  const going = goingIds.map(byId).filter(Boolean) as PlantState[];
  const coming = comingIds.map(byId).filter(Boolean) as PlantState[];
  const inNames = names(coming.map(plantName));
  const title = going.length && coming.length ? `Switch to ${inNames}?`
    : coming.length ? `Read ${inNames}?` : `Stop reading ${names(going.map(plantName))}?`;
  const now = atPayment ? "" : " now";
  const lines = atPayment ? ["When the payment goes through:"] : [];
  lines.push(...going.map((p) => p.kept_elsewhere
    ? `${plantName(p)} stops. Another account keeps its history; you lose access to it.`
    : `${plantName(p)} stops and its history is deleted${now}.`));
  if (coming.length) lines.push(`${inNames} ${forms(coming.length, { one: "starts", many: "start" })}${now}.`);
  if (going.length && coming.length) lines.push("Switching often slows history loading.");
  return { title, lines, button: going.length && coming.length ? "Switch" : coming.length ? "Read" : "Stop reading", danger: going.some((p) => !p.kept_elsewhere) };
}

/** A plant's word on the Plants page. */
export const plantTag = (s: AccountState, p: PlantState): string | null =>
  p.needs_reconnect ? "Reconnect" : p.chosen && p.read_now ? null : p.chosen ? (s.state === "ended" ? "Not read" : null)
    : p.trial_used_elsewhere && (s.state === "trialing" || s.state === "none") ? "Free week used" : "Locked";
/** A plant's "kept until", only when it has a delete date. */
export const plantKept = (s: AccountState, p: PlantState) =>
  p.delete_at && !p.purged && p.chosen && new Date(p.delete_at) > new Date(s.at ?? Date.now()) ? `History kept until ${day(s, p.delete_at)}`
    : p.purged && p.chosen ? "History deleted" : null;

/** After a save: what changed, by name. */
export function chosenToast(s: AccountState, coming: number[], going: number[]): string {
  const n = (ids: number[]) => names(ids.map((id) => plantName(s.plants.find((p) => p.plant === id) ?? { name: null, plant: id })));
  return [coming.length ? `${n(coming)} ${forms(coming.length, { one: "is", many: "are" })} read now.` : null,
    going.length ? `${n(going)} ${forms(going.length, { one: "stopped", many: "stopped" })}.` : null].filter(Boolean).join(" ") || "Saved.";
}
/** A refused save or change, from the database's refusal. */
export function refused(msg: string): string {
  if (/already in progress/i.test(msg)) return pay.inProgress;
  if (/already been made/i.test(msg)) return "This payment has already been made.";
  if (/no longer due/i.test(msg)) return "This payment is no longer due.";
  if (/past_due|failed payment|pay it first|pay the failed/i.test(msg)) return "Pay the overdue payment first.";
  if (/already had its free week/.test(msg)) return "A plant you ticked has had its free week. Untick it.";
  if (/free week reads up to|plan has \d+ places|that plan has/.test(msg)) return "That is more plants than your plan reads.";
  if (/pick the plants to drop|more plants to drop/.test(msg)) return "Choose the plants to keep first.";
  if (/while the account is ended|without a plan/.test(msg)) return "Pay first, then choose plants.";
  if (/open soon/.test(msg)) return "Paid plans open soon. Nothing was charged.";
  if (/plan is cancelled/.test(msg)) return "Keep your plan first.";
  return "Couldn't save. Try again.";
}

/** Payment steps: what the small working pop-up and the toasts say. */
export const pay = {
  checking: "Checking the price…",
  opening: "Opening Paystack…",
  taking: "Taking payment…",
  dueToday: "Due today",
  card: "Card",
  cancel: "Cancel",
  received: "Payment received.",
  declined: "Your saved card was declined. Enter another card.",
  refund: "Your plan changed while you paid. The payment will be refunded.",
  pending: "We're still checking your payment. Don't pay again yet.",
  failed: "The payment didn't go through.",
  void: "Payment not completed.",
  checkFailed: "Couldn't check your payment.",
  checkAgain: "Check again",
  inProgress: "A payment is already in progress.",
  startFailed: "Couldn't start the payment. Try again.",
  cardFailed: "Couldn't open Paystack. Try again.",
  cardChanged: "Card changed.",
  undone: "Your plan carries on as before.",
  booked: "Booked.",
};
/** Paid: a renewal names the plan that carries on (or the smaller one it moved to). */
export const paidText = (v: { kind?: string | null; plan_name?: string | null; changed?: boolean } | null) =>
  v?.kind === "renewal" && v.plan_name
    ? `${pay.received} ${v.changed ? `${v.plan_name} is now your plan.` : `${v.plan_name} carries on.`}` : pay.received;

export const logins = {
  addLogin: "Add login",
  oneLogin: "One login during the free week.",
  noLoginEnded: "Pay first to add a login.",
  remove: "Remove login",
  reconnect: "Reconnect",
  removeTitle: (username: string) => `Remove ${username}?`,
};
/** Removing a login: which plants go and what happens to each one's history. A plant goes
 *  when nothing reaches it after the removal, as billing.remove_login and billing.unclaim
 *  decide: a login: the plants it lists or went from, with no other login listing them now
 *  and no claim. shared: the "Shared plants" group: the plants that came through the share
 *  that no login lists now (claimed, or a share removed that keeps its place). */
export function removeLogin(s: AccountState, loginId: string, shared = false) {
  const only = shared ? s.plants.filter((p) => p.shared && !p.logins.length)
    : s.plants.filter((p) => (p.logins.includes(loginId) || (p.gone_logins || []).includes(loginId))
      && !p.claimed && p.logins.every((l) => l === loginId));
  const chosen = only.filter((p) => p.chosen);
  const gone = chosen.filter((p) => !p.kept_elsewhere && !p.payment_hold).map(plantName);
  const kept = chosen.filter((p) => p.kept_elsewhere).map(plantName);
  // a payment on its way may bring the plant back: its history waits (billing.payment_hold)
  const held = chosen.filter((p) => !p.kept_elsewhere && p.payment_hold).map(plantName);
  return [gone.length ? `${names(gone)}: history deleted now.` : null,
    kept.length ? `${names(kept)}: another account keeps the history.` : null,
    held.length ? `${names(held)}: history kept while a payment is pending.` : null,
    !chosen.length ? "No chosen plant goes with it." : null].filter(Boolean) as string[];
}

// ------------------------------------------------------------------ pay screen (no plan)

export function payScreen(s: AccountState) {
  const ended = s.state === "ended";
  const title = !ended ? null
    : s.grant_ended ? "Your plan from us has ended"
    : s.had_plan ? `Your ${s.last_plan_name} plan has ended`
    : s.access_ended_at ? "Your free week has ended" : "Your plants had their free week";
  if (!title) return null;
  return {
    title,
    body: [s.access_ended_at ? "Readings have stopped." : "Choose a plan to start reading.", keptLine(s)]
      .filter(Boolean).join(" "),
    button: "See plans",
  };
}

// ------------------------------------------------------------------ cards on Live and the bell

export type Notice = { kind: string; tone: "bad" | "warn" | "info"; title: string; short: string; body: string | null;
  bodyShort: string | null; button: string; action: "pay" | "plans" | "choose" | "billing"; closable?: string };

/** The plan that fits every linked plant, at this account's price: "Home, R49 a month". */
export function fitLine(s: AccountState): string | null {
  const p = s.prices.find((x) => x.plan === s.fit_all_plan && x.interval === "month");
  return p ? `${p.name}, ${money(p.amount_minor, p.currency, s.locale)} a month` : null;
}

export function notices(s: AccountState): Notice[] {
  const out: Notice[] = [];
  const fit = fitLine(s);
  if (s.state === "past_due" && s.past_due_reason !== "checking") {
    const d = due(s), word = !s.past_due_reason ? "overdue" : s.past_due_reason === "no_card" ? "due" : "failed";
    const body = `Pay ${d.amount} by ${d.by} to keep your readings.`;
    const title = `${d.plan} payment ${word}`;
    out.push({ kind: "past_due", tone: "bad", title, short: title,
      body, bodyShort: body, button: billing.payOther, action: "pay" });
  }
  const mc = mustChoose(s);
  if (mc) out.push({ kind: "must_choose", tone: "warn", title: mc.title, short: mc.title, body: mc.body, bodyShort: null, button: mc.button, action: "choose" });
  if (s.state === "trialing") {
    out.push(s.trial_ends_soon
      ? { kind: "trial_ends_soon", tone: "warn", title: `Your free week ends ${weekday(s, s.trial_ends_at)}`,
          short: `Free week ends ${weekday(s, s.trial_ends_at)}`, body: `Readings stop then.${fit ? ` For your plants: ${fit}.` : ""}`,
          bodyShort: fit, button: billing.seePlans, action: "plans" }
      : { kind: "trial", tone: "info", title: `Free until ${weekday(s, s.trial_ends_at)}`, short: `Free until ${weekday(s, s.trial_ends_at)}`,
          body: fit ? `For your plants: ${fit}.` : null, bodyShort: fit, button: billing.seePlans, action: "plans",
          closable: `trial:${s.trial_ends_at}` });
  }
  if (s.state === "active" && s.cancel_at && s.cancel_soon) {
    out.push({ kind: "cancel_soon", tone: "warn", title: `${s.plan_name} ends on ${day(s, s.cancel_at)}`, short: `${s.plan_name} ends ${day(s, s.cancel_at)}`,
      body: keptAfterCancel(s), bodyShort: null, button: `Keep ${s.plan_name}`, action: "billing", closable: `cancel:${s.cancel_at}` });
  }
  return out;
}

// ------------------------------------------------------------------ emails

export type MailPart =
  | { lead: string }
  | { rows: [string, string][]; hero?: { label: string; value: string; sub?: string } }
  | { steps: [string, string][] }
  | { pair: [string, string] }
  | { note: string }
  | { button: { label: string; page: "billing" | "plans" | "pay" | "card" | "cancel"; bill?: string } };
/** sub: the line straight under the title. */
export type Mail = { subject: string; title: string; sub?: string; parts: MailPart[]; reminder?: boolean };
export type MailInput = {
  key: string; state: AccountState;
  bill?: { kind: string; plan: string; plan_name: string; interval: "month" | "year"; amount_minor: number; currency: string;
    next_amount_minor: number; period_start: Iso | null; period_end: Iso | null; paid_at: Iso | null; reference: string | null;
    card_type: string | null; last4: string | null;
    /** an upgrade that bought a new period at the payment (monthly to yearly, SOLAR-675) */
    starts_now?: boolean } | null;
  refund?: { amount_minor: number; currency: string; reference: string; reason: string; paid_at: Iso | null; paid_minor: number;
    card_type: string | null; last4: string | null } | null;
  event?: { kind: string; before: Record<string, unknown> | null; after: Record<string, unknown> | null } | null;
  plant?: { id: number; name: string | null } | null;
  /** plan_ended: that ending's date, why, and whether a renewal card page never got a final answer. */
  ended?: { ended_at: Iso | null; reason: string | null; paid_unknown: boolean } | null;
};

/** The chosen plants waiting to be deleted, grouped by their delete date, earliest first. A date
 *  already passed is left out: that history is going now. */
function keptGroups(s: AccountState): { day: string; names: string[] }[] {
  const by = new Map<string, string[]>();
  const now = s.at ? Date.parse(s.at) : Date.now();
  for (const p of s.plants.filter((p) => p.chosen && p.delete_at && !p.purged && Date.parse(p.delete_at) > now)
    .sort((a, b) => Date.parse(a.delete_at!) - Date.parse(b.delete_at!))) {
    const d = day(s, p.delete_at);
    by.set(d, [...(by.get(d) ?? []), plantName(p)]);
  }
  return [...by].map(([d, n]) => ({ day: d, names: n }));
}
/** Plants with different delete dates: each date with its plants, never one date for all. */
const keptEach = (g: { day: string; names: string[] }[]) => g.map((x) => `${names(x.names)}: history kept until ${x.day}.`).join(" ");
/** One date that covers fewer than all the chosen plants (another account keeps the rest, or
 *  their history is already deleted): name them too. */
const someOnly = (s: AccountState, g: { names: string[] }[]) =>
  g.length === 1 && g[0].names.length < s.plants.filter((p) => p.chosen).length;
/** The pay screen's history line: each date with its plants, as in the emails. */
function keptLine(s: AccountState): string | null {
  const g = keptGroups(s);
  return g.length > 1 || someOnly(s, g) ? keptEach(g) : g.length ? `History is kept until ${g[0].day}.` : s.history_purged ? "History has been deleted." : null;
}

/** The email for one outbox row, from the state read at send time (and the frozen bill for a receipt). */
export function mail(m: MailInput): Mail | null {
  const s = m.state;
  const $ = (n: number | null | undefined, cur = s.currency) => money(n, cur, s.locale);
  const card = (t: string | null | undefined, l: string | null | undefined) => l ? `${(t || "Card").replace(/^\w/, (c) => c.toUpperCase())} •••• ${l}` : null;
  const groups = keptGroups(s);
  const kept = groups.length > 1 || someOnly(s, groups) ? keptEach(groups)
    : s.history_kept_until ? `History is kept until ${day(s, s.history_kept_until)}, then deleted.` : null;
  const fit = fitLine(s);
  switch (m.key) {
    case "receipt": {
      const b = m.bill; if (!b) return null;
      const rows: [string, string][] = [
        ["For", `${b.plan_name}, ${b.kind === "upgrade" && !b.starts_now ? "the days left" : b.interval === "year" ? "yearly" : "monthly"}${b.period_start && b.period_end ? `, ${day(s, b.kind === "upgrade" && !b.starts_now && b.paid_at ? b.paid_at : b.period_start)} to ${day(s, b.period_end)}` : ""}`]];
      const c = card(b.card_type, b.last4); if (c) rows.push(["Card", c]);
      if (b.reference) rows.push(["Reference", b.reference]);
      if (b.period_end) rows.push(["Next payment", `${$(b.next_amount_minor, b.currency)} on ${day(s, b.period_end)}`]);
      return { subject: `Payment received: ${$(b.amount_minor, b.currency)}`, title: "Payment received",
        parts: [{ hero: { label: "Paid", value: $(b.amount_minor, b.currency), sub: day(s, b.paid_at) }, rows }, { button: { label: "See your plan", page: "billing" } }] };
    }
    case "payment_failed":
    case "card_update":
    case "payment_due":
    case "payment_reminder": {
      // what is paid: the bill the row is about (a booked downgrade bills the smaller plan); what ends: the running plan
      const b = m.bill, plan = b?.plan_name ?? due(s).plan, ends = due(s).ends;
      const amount = b ? $(b.amount_minor, b.currency) : due(s).amount;
      const title = `Pay ${amount}${plan !== ends ? ` for ${plan}` : ""} by ${day(s, s.plan_ends_at)} to keep your readings`;
      const saved = card(b?.card_type, b?.last4) ?? "saved card";
      // the button, and a way to pay without trusting an email link
      const pay: MailPart[] = [{ button: { label: billing.payOther, page: "pay", bill: s.due_bill?.id } }, { note: "Or open Billing in the app." }];
      if (m.key === "payment_failed") return { subject: `Your ${plan} payment didn't go through`, title,
        parts: [{ lead: `We couldn't charge your ${saved}. ${s.next_try_on ? `We'll try again on ${dateOnly(s.next_try_on)}.` : "We won't try again."}` }, ...pay] };
      if (m.key === "card_update") return { subject: `Your ${plan} payment didn't go through`, title,
        parts: [{ lead: `We couldn't charge your ${saved}. We won't try this card again.` }, ...pay] };
      // 3 days before the plan ends, when no try is left (SOLAR-654): the title says it all
      if (m.key === "payment_reminder") return { subject: `Your ${plan} payment is still due`, title, parts: pay };
      return { subject: `Your ${plan} payment is due`, title,
        parts: [{ lead: "There's no card saved, so nothing was charged." }, ...pay] };
    }
    case "refund": {
      const r = m.refund; if (!r) return null;
      const rows: [string, string][] = [["Paid on", day(s, r.paid_at)], ["Arrives in", "3 to 10 working days"], ["Reference", r.reference]];
      if (r.reason === "manual" && r.amount_minor < r.paid_minor) rows.unshift(["Payment", $(r.paid_minor, r.currency)]);
      return { subject: `${$(r.amount_minor, r.currency)} is on its way back to your card`, title: "Your refund is on its way",
        parts: [{ lead: r.reason === "manual" ? `We refunded ${r.amount_minor < r.paid_minor ? "part of " : ""}your payment. Your plan stays as it is.`
            : r.reason === "wrong_amount" ? "The amount didn't match your bill, so we sent it back."
            : "Your plan changed while you paid, so we sent it back." },
          { hero: { label: "Refund", value: $(r.amount_minor, r.currency), sub: r.last4 ? `back to ${card(r.card_type, r.last4)}` : "back to your card" }, rows },
          { note: "Paystack, who handles our payments, emails you about it too." }] };
    }
    case "plan_ended": {
      const e = m.ended, at = e?.ended_at ?? s.access_ended_at;
      // "It wasn't paid" only when no renewal payment made before the end is still unanswered
      const unpaid = e?.reason === "unpaid" && !e.paid_unknown;
      return { subject: `Your ${s.last_plan_name} plan has ended`,
        title: at ? `${s.last_plan_name} ended on ${day(s, at)}` : `Your ${s.last_plan_name} plan has ended`,
        parts: [{ lead: [unpaid ? "We didn't receive the renewal payment, so readings have stopped." : "Readings have stopped.", kept].filter(Boolean).join(" ") },
          { button: { label: billing.seePlans, page: "plans" } }] };
    }
    case "change_booked": {
      const e = m.event; if (!e) return null;
      if (e.kind === "cancel") return { subject: `${s.plan_name} ends on ${day(s, s.cancel_at)}`, title: `${s.plan_name} ends on ${day(s, s.cancel_at)}`,
        parts: [{ steps: cancelDialog({ ...s, if_cancelled_delete_at: s.if_cancelled_delete_at ?? null, period_end: s.cancel_at }).steps },
          { button: { label: "See your plan", page: "billing" } }] };
      if (e.kind === "downgrade") {
        const going = s.plants.filter((p) => p.drop_at_period_end);
        return { subject: `You move to ${s.next_plan_name} on ${day(s, s.period_end)}`, title: `You move to ${s.next_plan_name} on ${day(s, s.period_end)}`,
          parts: [...(going.length ? [{ lead: dropLine(s, going) }] : []),
            { rows: [["Next payment", `${$(s.next_amount_minor)} on ${day(s, s.period_end)}`]] as [string, string][] },
            { button: { label: "See your plan", page: "billing" } }] };
      }
      return { subject: `${s.next_plan_name ?? s.plan_name} is paid ${s.next_interval === "year" ? "yearly" : "monthly"} from ${day(s, s.period_end)}`,
        title: `Paid ${s.next_interval === "year" ? "yearly" : "monthly"} from ${day(s, s.period_end)}`,
        parts: [{ rows: [["Next payment", `${$(s.next_amount_minor)} on ${day(s, s.period_end)}`]] }, { button: { label: "See your plan", page: "billing" } }] };
    }
    case "change_undone":
      return { subject: `${s.plan_name} carries on`, title: `${s.plan_name} carries on`,
        parts: [{ lead: "Your plants, history and reports carry on as before." },
          { rows: [["Next payment", `${$(s.next_amount_minor)} on ${day(s, s.next_charge_at)}`]] }, { button: { label: "See your plan", page: "billing" } }] };
    case "card_changed":
      return { subject: `Card changed to ${cardLine(s)}`, title: "Card changed",
        parts: [{ rows: [["Card", cardLine(s) ?? ""], ...(s.next_charge_at ? [["Next payment", `${$(s.next_amount_minor)} on ${day(s, s.next_charge_at)}`]] as [string, string][] : [])] },
          { note: "If you didn't change it, reply to this email." }] };
    case "renewal_soon":
      return { subject: `Your yearly ${s.plan_name} plan renews on ${day(s, s.next_charge_at)}`, title: `${s.plan_name} renews on ${day(s, s.next_charge_at)}`,
        parts: [{ hero: { label: "We charge", value: $(s.next_amount_minor), sub: `on ${day(s, s.next_charge_at)}` }, rows: s.card ? [["Card", cardLine(s) ?? ""]] : [] },
          { note: `To stop it, cancel before ${day(s, s.next_charge_at)}.` }, { button: { label: billing.cancelPlan, page: "cancel" } }] };
    case "card_expiring":
      return { subject: "Your card expires before your next payment", title: "Your card expires before your next payment",
        parts: [{ rows: [["Card", cardLine(s) ?? ""], ["Next payment", `${$(s.next_amount_minor)} on ${day(s, s.next_charge_at)}`]] },
          { button: { label: billing.changeCard, page: "card" } }] };
    case "trial_ends_soon":
      return { reminder: true, subject: `Your free week ends ${weekday(s, s.trial_ends_at)}`, title: `Your free week ends ${weekday(s, s.trial_ends_at)}`,
        parts: [{ lead: `Readings, alerts and reports stop then.${fit ? ` For your plants: ${fit}.` : ""}` }, { button: { label: billing.seePlans, page: "plans" } }] };
    case "trial_ended":
      return { reminder: true, subject: "Your free week has ended", title: "Your free week has ended",
        parts: [{ lead: ["Readings have stopped.", kept, fit ? `For your plants: ${fit}.` : null].filter(Boolean).join(" ") },
          { button: { label: billing.seePlans, page: "plans" } }] };
    case "history_delete_soon": {
      const first = day(s, s.history_kept_until);
      if (groups.length > 1 || someOnly(s, groups)) {
        // only the plants due on the first date are named in the subject; the rest keep their own dates
        const head = `History of ${names(groups[0].names)} is deleted on ${first}`;
        return { reminder: true, subject: head, title: head,
          parts: [{ lead: [`Readings stopped on ${day(s, s.access_ended_at)}.`, keptEach(groups.slice(1)) || null,
            `A plan before ${first} keeps it${groups.length > 1 ? " all" : ""}.`].filter(Boolean).join(" ") },
            { button: { label: billing.seePlans, page: "plans" } }] };
      }
      return { reminder: true, subject: `Your history is deleted on ${first}`, title: `Your history is deleted on ${first}`,
        parts: [{ lead: `Readings stopped on ${day(s, s.access_ended_at)}. A plan before ${first} keeps it.` },
          { button: { label: billing.seePlans, page: "plans" } }] };
    }
    case "history_deleted":
      return { reminder: true, subject: `History deleted: ${m.plant?.name || "your plant"}`, title: "Your history has been deleted",
        parts: [{ lead: `${m.plant?.name || "Your plant"}'s readings and history are deleted. A plan brings readings back from today.` },
          { button: { label: billing.seePlans, page: "plans" } }] };
  }
  return null;
}

// ------------------------------------------------------------------ alerts (SOLAR-645)

// The words of every alert: the app's alert list, the pop-up and the email all come from
// here (SOLAR-645 decision A). The database sends the facts (email_queue.data) since 0264. The
// list and pop-up lines are private.alert_text (0233) and private.push_text (0229) word for
// word (a number reads as JSON writes it: the alerts store whole degrees and percents); the
// emails are email.ts's plantEvent and loginEvent as they were.
// Where the list and the email say a thing differently, they still do.

/** An alert as the database keeps it. data's since, at and from are epoch seconds.
 *  created: the row's created_at in epoch seconds; tz: the plant's time zone. */
export type AlertRow = { kind: string; data: Record<string, any> | null; created: number; tz: string };
/** One alert in the list. at: when it happened (epoch s); day ("2026-11-24") and time
 *  ("08:15") are local; tab: the page it opens. */
export type AlertLine = { title: string | null; body: string | null; at: number; tab: string; day: string; time: string };

/** "08:15" in a time zone. */
export const clock = (epoch: number, tz: string) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(epoch * 1000));
const isoDay = (epoch: number, tz: string) => {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-GB", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(new Date(epoch * 1000)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}`;
};
/** How long something lasted, as the app writes it: 45 min, 1h 33m, 2h. */
export function lasted(from: number, to: number): string {
  const m = Math.max(1, Math.round((to - from) / 60));
  return m < 60 ? `${m} min` : m % 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${Math.floor(m / 60)}h`;
}
/** A data value as text, as SQL's ->> read it. */
const jtext = (v: unknown): string | null => v == null ? null : typeof v === "string" ? v : typeof v === "object" ? JSON.stringify(v) : String(v);
/** Joins as SQL's || did: a missing part leaves the whole line missing. */
const cat = (...p: (string | null | undefined)[]): string | null => p.some((x) => x == null) ? null : p.join("");

/** The alert list's title, body, time and page for one alert. Null for a kind with no words. */
export function alertLine(r: AlertRow): AlertLine | null {
  const d = r.data ?? {}, tz = r.tz;
  const num = (k: string) => d[k] == null ? null : Number(d[k]);
  const made = Math.round(r.created);
  // a time more than 12 hours before the row is not trusted: the row's own time instead
  let ev = num("at") ?? num("since") ?? made;
  if (ev < r.created - 43200) ev = made;
  const hm = clock(num("since") ?? ev, tz);
  const took = "at" in d && "since" in d
    ? (num("at") == null || num("since") == null ? "1 min" : lasted(num("since")!, num("at")!)) : null;
  const inv = jtext(d.inverter) || null;
  const invName = inv && /^[0-9]+$/.test(inv) ? `Inverter ${inv}` : inv;
  const banks = Array.isArray(d.banks)
    ? d.banks.map((b: any) => cat(jtext(b?.name), " ", jtext(b?.chargePct), "%")).filter((x: string | null) => x != null) : [];
  const bankList = banks.length ? banks.join(", ") : null;
  const plants: string[] = Array.isArray(d.plants) ? d.plants.map((x: unknown) => jtext(x) ?? "") : [];
  let title: string | null, body: string | null;
  switch (r.kind) {
    case "grid_down":
      title = "Grid down";
      body = cat("from" in d ? cat("Between ", num("from") == null ? null : clock(num("from")!, tz), " and ", hm, ".") : cat("Since ", hm, "."),
        d.chargePct == null ? "" : ` Battery ${jtext(d.chargePct)}%.`);
      break;
    case "grid_back": title = "Grid back"; body = cat("Down for ", took, "."); break;
    case "batt_hot": title = "Battery hot"; body = cat(jtext(d.tempC), " °C since ", hm, "."); break;
    case "batt_hot_back": title = "Battery cooled"; body = cat(jtext(d.tempC), " °C. Hot for ", took, "."); break;
    case "bank_drift": title = "Battery charge uneven"; body = cat(bankList, "."); break;
    case "bank_drift_back": title = "Battery charge even again"; body = cat(bankList, ". Uneven for ", took, "."); break;
    case "string_dead":
      title = "Some panels stopped producing";
      body = cat(jtext(d.inverter), ", ", jtext(d.string)?.toLowerCase(), ", since ", hm, ".");
      break;
    case "string_back":
      title = "Panels producing again";
      body = cat(jtext(d.inverter), ", ", jtext(d.string)?.toLowerCase(), ". Stopped for ", took, ".");
      break;
    case "logger_stale": title = inv == null ? "No readings" : `No readings from ${invName}`; body = `Since ${hm}.`; break;
    case "logger_back": title = inv == null ? "Readings back" : `Readings back from ${invName}`; body = cat("No readings for ", took, "."); break;
    case "sunsynk_down": title = "SunSynk is down"; body = `No new readings since ${hm}.`; break;
    case "sunsynk_back": title = "SunSynk is back"; body = cat("Down for ", took, "."); break;
    case "needs_relink":
      title = "Sign in to SunSynk again";
      body = plants.length >= 2 ? cat("Login for ", names(plants), " stopped working at ", hm, ".") : `Login stopped working at ${hm}.`;
      break;
    case "relinked":
      title = "SunSynk reconnected";
      body = plants.length >= 2 ? cat(names(plants), " were signed out for ", took, ".") : cat("Signed out for ", took, ".");
      break;
    default: return null;
  }
  const tab = r.kind.startsWith("grid_") ? "grid"
    : /^(string|batt|bank)_/.test(r.kind) ? "inverters"
    : r.kind === "needs_relink" || r.kind === "relinked" ? "account" : "live";
  return { title, body, at: ev, tab, day: isoDay(ev, tz), time: clock(ev, tz) };
}

/** A pop-up's title and body. One plant: the list's words. More: the plant's name on top
 *  ("SunSynk" for login and SunSynk alerts), the list's title and body under it. */
export function alertPush(kind: string, t: AlertLine, plantName: string | null, plants: number): { title: string | null; body: string | null } {
  if (plants < 2) return { title: t.title, body: t.body };
  const title = kind.startsWith("sunsynk") || kind === "needs_relink" || kind === "relinked" ? "SunSynk" : plantName ?? "Your plant";
  // "Grid down" + "Since 01:28." reads as one sentence
  const body = t.body != null && /^(Since|Between) /.test(t.body)
    ? cat(t.title, " ", t.body.slice(0, 1).toLowerCase(), t.body.slice(1))
    : cat(t.title, ". ", t.body);
  return { title, body };
}

// An alert's email. Times come formatted ("08:15"); on: "today", or the day it happened
// ("Tue 21 Oct") when the email reaches the owner on a later day.
//  grid_down     from: set when the grid went off inside a gap in readings and the refill can't
//                say when (SOLAR-416): it went off between from and at
//  batt_hot      hotDays: days over 45 C in the last 30, today included, counted at send time
//  bank_drift    name: the inverter's name in SunSynk
//  logger_stale  inverters: every inverter with its last reading time, or null while it
//                still sends, so the owner sees which one stopped (SOLAR-415)
//  batt_hot_back and bank_drift_back stay in the list but send no email (SOLAR-415).
export type PlantEvent =
  | { kind: "grid_down"; at: string; from?: string; chargePct?: number }
  | { kind: "grid_back"; since: string; at: string; lasted?: string; chargePct?: number }
  | { kind: "batt_hot"; at: string; tempC: number; hotDays?: number }
  | { kind: "bank_drift"; banks: { name: string; chargePct: number }[] }
  | { kind: "string_dead"; string: string; inverter: string; since: string }
  | { kind: "string_back"; string: string; inverter: string; since: string; at: string; lasted: string }
  | { kind: "logger_stale"; since: string; inverter?: string; inverters?: { name: string; last: string | null }[] }
  | { kind: "logger_back"; since: string; at: string; lasted: string; inverter?: string };
// A SunSynk login stopped working (needs_relink) or works again (relinked), SOLAR-380: one
// email per login, naming every plant on it (0158). at: when it stopped / came back; since:
// when it stopped (relinked).
export type LoginEvent =
  | { kind: "needs_relink"; plants: string[]; at?: string }
  | { kind: "relinked"; plants: string[]; since?: string; at: string; lasted: string }
  // the owner removed the plant's share to our login (SOLAR-310, 0172)
  | { kind: "share_removed"; plants: string[] }
  // SunSynk no longer lists the plant on its password login (SOLAR-537, 0197): shown, not read
  | { kind: "plant_off_login"; plants: string[]; login?: string }
  // the share login stopped / works again (SOLAR-451, 0177): owners can't act, so no sign-in
  | { kind: "share_down"; plants: string[]; at?: string }
  | { kind: "share_back"; plants: string[]; since?: string; at: string; lasted: string };
// SunSynk's own service is down: every plant is affected, not one inverter.
export type SunsynkEvent =
  | { kind: "sunsynk_down"; since: string }
  | { kind: "sunsynk_back"; since: string; at: string; lasted: string };
export type AlertEvent = PlantEvent | LoginEvent | SunsynkEvent;

/** The app's page names, as buttons say them: "Open Grid". */
export const pageNames = { live: "Live", solar: "Solar", grid: "Grid", inverters: "Equipment" } as const;
/** An alert email's parts, in plain text: email.ts lays them out. A row's third field "batt"
 *  paints its value in the battery colour. A button opens a page for the alert's plant, or
 *  the SunSynk logins. footer: the line about the alert's switch; null: none. */
export type AlertPart =
  | { lead: string } | { note: string } | { heading: string }
  | { box: { hero?: { label: string; value: string; tone?: "bad" | "warn"; sub?: string };
      rows?: [label: string, value: string, tone?: "batt"][]; steps?: [when: string, what: string][] } }
  | { button: { label: string; page: keyof typeof pageNames | "logins" } };
export type AlertMail = { subject: string; title: string; parts: AlertPart[]; footer: string | null };

const openPage = (page: "live" | "grid" | "inverters"): AlertPart => ({ button: { label: `Open ${pageNames[page]}`, page } });
const GAP = "We're getting what we can of the missed readings.";
// up to 3 names, then a count, as the app's billing banner
const andList = (a: string[]) => names(a.length > 3 ? [...a.slice(0, 3), `${a.length - 3} more`] : a);

// Each alert shows its facts in the one box (SOLAR-415): the big number is what's wrong now
// (red or amber), or how long it lasted (white) once it's back. Rows only for other numbers.
// A sentence only where the box can't say it. Never a guessed cause, and never a promise to
// fill missed readings: we get what we can.
/** The email for one alert or login event. plant: the plant's name. */
export function alertMail(e: AlertEvent, plant: string, on = "today"): AlertMail {
  const span = (from: string, to: string) => `${from} to ${to} ${on}`;
  const footer = (what: string) => `You get ${what} alerts for ${plant}. Turn them off in notification settings.`;
  const alert = (title: string, page: "live" | "grid" | "inverters", what: string, parts: AlertPart[]): AlertMail =>
    ({ subject: title, title, parts: [...parts, openPage(page)], footer: footer(what) });
  switch (e.kind) {
    case "grid_down":
      return alert(`Grid down at ${plant}`, "grid", "grid", [{ box: {
        hero: { label: "Grid", value: "Off", tone: "bad", sub: e.from ? `went off between ${e.from} and ${e.at} ${on}` : `since ${e.at} ${on}` },
        rows: e.chargePct != null ? [["Battery", `${e.chargePct}%`, "batt"]] : [] } }]);
    case "grid_back":
      return alert(`Grid back at ${plant}`, "grid", "grid", [{ box: {
        hero: { label: "Grid was off for", value: e.lasted ?? "a while", sub: span(e.since, e.at) },
        rows: e.chargePct != null ? [["Battery", `${e.chargePct}%`, "batt"]] : [] } }]);
    case "batt_hot":
      return alert(`Battery hot at ${plant}`, "inverters", "battery", [{ box: {
        hero: { label: "Battery", value: `${e.tempC}°C`, tone: "bad", sub: `at ${e.at} ${on}` },
        rows: (e.hotDays ?? 1) > 1 ? [["Over 45°C", `${e.hotDays} of the last 30 days`]] : [] } }]);
    case "bank_drift": {
      const pcts = e.banks.map((b) => b.chargePct);
      return alert(`Batteries charging unevenly at ${plant}`, "inverters", "battery", [{ box: {
        hero: { label: "Gap", value: `${Math.max(...pcts) - Math.min(...pcts)}%`, tone: "warn", sub: "for over an hour" },
        rows: e.banks.map((b) => [b.name, `${b.chargePct}%`, "batt"] as [string, string, "batt"]) } }]);
    }
    // "Inverter 2508290475, string 2", as the app names it (SOLAR-348)
    case "string_dead":
      return alert(`Panels stopped producing at ${plant}`, "inverters", "panel", [{ box: {
        hero: { label: e.string, value: "No power", tone: "bad", sub: `since ${e.since} ${on}` },
        rows: [["Inverter", e.inverter.replace(/^Inverter /, "")], ["Other strings", "Producing"]] } }]);
    case "string_back":
      return alert(`Panels producing again at ${plant}`, "inverters", "panel", [{ box: {
        hero: { label: `${e.string} off for`, value: e.lasted, sub: span(e.since, e.at) },
        rows: [["Inverter", e.inverter.replace(/^Inverter /, "")]] } }]);
    case "logger_stale": {
      // The title names the inverter, so its row would say it twice (SOLAR-560). The whole
      // plant lists each inverter's last time only when there's more than one.
      const one = !!e.inverter;
      const list = e.inverters ?? [];
      return alert(one ? `No readings from ${e.inverter}` : `No readings from ${plant}`, "live", "reading", [
        { lead: one ? "This inverter stopped sending readings to SunSynk. We can't see if it's still running. The rest of your plant still updates."
                    : "Your plant stopped sending readings to SunSynk, so Prince Solar Hub isn't updating. We can't see if it's still running." },
        { box: { hero: { label: "Last reading", value: e.since, tone: "warn", sub: on },
          rows: one ? (list.length > 1 ? [["Other inverters", "Sending"]] : [])
                    : list.length > 1 ? list.map((i) => [i.name, i.last ?? e.since] as [string, string]) : [] } },
        { note: "We'll email you when readings come back." },
      ]);
    }
    case "logger_back":
      return alert(e.inverter ? `Readings back from ${e.inverter}` : `Readings back at ${plant}`, "live", "reading", [
        { box: { hero: { label: "No readings for", value: e.lasted, sub: span(e.since, e.at) } } },
        { note: "Gaps in your charts fill in where SunSynk has the readings." }]);
    case "sunsynk_down":
      return { subject: "SunSynk is down", title: "SunSynk is down", footer: footer("SunSynk"), parts: [
        { lead: "SunSynk isn't answering for anyone, so no readings come in." },
        { box: { hero: { label: "Down since", value: e.since, tone: "bad", sub: on } } },
        openPage("live")] };
    case "sunsynk_back":
      return { subject: "SunSynk is back", title: "SunSynk is back", footer: footer("SunSynk"), parts: [
        { box: { hero: { label: "SunSynk was down for", value: e.lasted, sub: `${e.since} to ${e.at} ${on}` } } },
        openPage("live")] };
  }
  // Login emails: a calm note, no red (SOLAR-383). No switch for these, so no "turn them off" line.
  const plants = andList(e.plants.length ? e.plants : ["your plant"]);
  const note = (subject: string, title: string, parts: AlertPart[]): AlertMail => ({ subject, title, parts, footer: null });
  switch (e.kind) {
    case "needs_relink":
      return note(`Sign in to SunSynk again for ${plants}`, "Sign in to SunSynk again", [
        { lead: "SunSynk asked for your login again." },
        { box: { hero: e.at ? { label: "No readings since", value: e.at, sub: on } : undefined, rows: [["Plants", plants]] } },
        { lead: "After you sign in, we get what we can of the missed readings." },
        { button: { label: "Sign in to SunSynk", page: "logins" } }]);
    case "share_removed":
      return note(`Sharing stopped for ${plants}`, "Sharing stopped", [
        { lead: "Your plant is no longer shared with admin@princesolarhub.co.za in SunSynk, so we stopped reading it. Your history is safe." },
        { box: { rows: [["Plants", plants]] } },
        { lead: "To start again, share it as Visitor, then add it in the app with Share plant." },
        { button: { label: "Open Prince Solar Hub", page: "logins" } }]);
    // The error, what it means, then what the owner can do (Brynne 2026-11-13). We can't
    // tell why SunSynk's list dropped the plant, so each fix names the case it is for.
    case "plant_off_login":
      return note(`We can't find ${plants} on your SunSynk login`, "Plant not found on your login", [
        { lead: `We can't find ${plants} on your SunSynk login.` },
        { box: { rows: [["Plant", plants], ...(e.login ? [["Login", e.login] as [string, string]] : [])] } },
        { heading: "What it means" },
        { lead: "We can't read this plant. You still see its history, with no new readings." },
        { heading: "How to fix it" },
        { box: { steps: [
          ["If someone shared it with you", "Ask them to share it with this login again in SunSynk."],
          ["If it is on another SunSynk login", "Add that login in Plants with Add plant."],
          ["If you deleted it in SunSynk", "There is nothing to do."],
        ] } },
        { note: "Once it is back on this login, readings start again on their own." },
        { button: { label: "Open Plants", page: "logins" } }]);
    case "share_down":
      return note(`No readings from ${plants}`, "No readings", [
        { lead: "We can't read your plants from SunSynk right now. Your power isn't affected. Readings start again on their own." },
        { box: { hero: e.at ? { label: "Last reading", value: e.at, tone: "warn", sub: on } : undefined, rows: [["Plants", plants]] } },
        { note: "We'll email you when readings come back, and get what we can of the gap." },
        openPage("live")]);
  }
  const back = e.kind === "share_back" ? ["Readings back at", "Readings back"] : ["SunSynk reconnected for", "SunSynk reconnected"];
  return note(`${back[0]} ${plants}`, back[1], [
    { box: { hero: { label: "No readings for", value: e.lasted, sub: e.since ? `${e.since} to ${e.at} ${on}` : `until ${e.at} ${on}` },
      rows: [["Plants", plants]] } },
    { note: GAP },
    openPage("live")]);
}

export const AccountText = {
  money, day, weekday, forms, names, plantName, planTitle, planPrice, planStatus, placesLine, mustChoose, bookedChange,
  cardLine, cardSub, billRow, billing, pastDueNote, accountAlert, paidText, cancelDialog, deleteBlocked, plans, planCard, quoteReview, checkoutPick, keepPick, weekPick, chosenToast, refused, pay,
  choosePlants, switchConfirm, plantTag, plantKept, logins, removeLogin, payScreen, fitLine, notices, mail,
  alertLine, alertPush,
};
