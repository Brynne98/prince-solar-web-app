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
  kept_elsewhere: boolean; drop_at_period_end: boolean; logins: string[]; claimed: boolean;
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
  retention_days: number; trial_places: number; trial_ends_soon: boolean; cancel_soon: boolean;
  if_cancelled_delete_at: Iso | null; history_kept_until: Iso | null; history_purged: boolean;
  plants: PlantState[]; prices: PriceRow[]; logins: Login[]; bills: Bill[];
};
export type Quote = {
  kind: "purchase" | "upgrade" | "downgrade" | "interval"; plan: string; plan_name: string; places: number;
  interval: "month" | "year"; due_minor: number; next_amount_minor: number; next_at: Iso; currency: string;
  offer: string | null; drop?: number;
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
      return [`Payment of ${money(s.amount_due_minor, s.currency, s.locale)} failed.`,
        s.next_retry_at ? `Next try ${day(s, s.next_retry_at)}.` : null,
        `Ends on ${day(s, s.plan_ends_at)} if unpaid.`].filter(Boolean).join(" ");
    case "ended":
      return s.access_ended_at ? `${s.had_plan ? `${s.last_plan_name} ended` : "Free week ended"} on ${day(s, s.access_ended_at)}` : null;
    default: return null;
  }
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
      text: [`Moves to ${s.next_plan_name} on ${day(s, s.period_end)}.`, going.length ? dropLine(s, going) : null].filter(Boolean).join(" "),
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
  s.plants.some((p) => p.chosen && !p.kept_elsewhere) && s.cancel_at
    ? `Readings stop then; history is kept ${forms(s.retention_days, { one: "1 day", many: "{n} days" })}.` : "Readings stop then.";
/** The plants a booked downgrade lets go, and what happens to each one's history. */
function dropLine(s: AccountState, going: PlantState[]): string {
  const gone = going.filter((p) => !p.kept_elsewhere).map(plantName), kept = going.filter((p) => p.kept_elsewhere).map(plantName);
  return [gone.length ? `${names(gone)} ${forms(gone.length, { one: "stops", many: "stop" })} and ${forms(gone.length, { one: "its", many: "their" })} history is deleted then.` : null,
    kept.length ? `${names(kept)} ${forms(kept.length, { one: "stops", many: "stop" })}; another account keeps the history.` : null].filter(Boolean).join(" ");
}

/** The saved card. */
export const cardLine = (s: AccountState) => s.card
  ? `${(s.card.card_type || "Card").replace(/^\w/, (c) => c.toUpperCase())} •••• ${s.card.last4 ?? ""}`.trim()
  : null;
export const cardSub = (s: AccountState) => s.card && s.card.exp_month
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
  billsHead: "Payments",
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
      lines: [q.due_minor ? "For the days left until your next payment." : "Nothing to pay for the days left.",
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

/** Every change of chosen plants is confirmed here (design: no one-tap toggle). */
export function switchConfirm(s: AccountState, goingIds: number[], comingIds: number[]) {
  const byId = (id: number) => s.plants.find((p) => p.plant === id);
  const going = goingIds.map(byId).filter(Boolean) as PlantState[];
  const coming = comingIds.map(byId).filter(Boolean) as PlantState[];
  const inNames = names(coming.map(plantName));
  const title = going.length && coming.length ? `Switch to ${inNames}?`
    : coming.length ? `Read ${inNames}?` : `Stop reading ${names(going.map(plantName))}?`;
  const lines = going.map((p) => p.kept_elsewhere
    ? `${plantName(p)} stops. Another account keeps its history; you lose access to it.`
    : `${plantName(p)} stops and its history is deleted now.`);
  if (coming.length) lines.push(`${inNames} ${forms(coming.length, { one: "starts", many: "start" })} now.`);
  if (going.length && coming.length) lines.push("Switching often slows history loading.");
  return { title, lines, button: going.length && coming.length ? "Switch" : coming.length ? "Read" : "Stop reading", danger: going.some((p) => !p.kept_elsewhere) };
}

/** A plant's word on the Plants page. */
export const plantTag = (s: AccountState, p: PlantState): string | null =>
  p.needs_reconnect ? "Reconnect" : p.chosen && p.read_now ? null : p.chosen ? (s.state === "ended" ? "Not read" : null)
    : p.trial_used_elsewhere && (s.state === "trialing" || s.state === "none") ? "Free week used" : "Locked";
/** A plant's "kept until", only when it has a delete date. */
export const plantKept = (s: AccountState, p: PlantState) =>
  p.delete_at && !p.purged && p.chosen ? `History kept until ${day(s, p.delete_at)}` : p.purged && p.chosen ? "History deleted" : null;

/** After a save: what changed, by name. */
export function chosenToast(s: AccountState, coming: number[], going: number[]): string {
  const n = (ids: number[]) => names(ids.map((id) => plantName(s.plants.find((p) => p.plant === id) ?? { name: null, plant: id })));
  return [coming.length ? `${n(coming)} ${forms(coming.length, { one: "is", many: "are" })} read now.` : null,
    going.length ? `${n(going)} ${forms(going.length, { one: "stopped", many: "stopped" })}.` : null].filter(Boolean).join(" ") || "Saved.";
}
/** A refused save or change, from the database's refusal. */
export function refused(msg: string): string {
  if (/past_due|failed payment|pay it first|pay the failed/i.test(msg)) return "Pay the failed payment first.";
  if (/already had its free week/.test(msg)) return "A plant you ticked has had its free week. Untick it.";
  if (/free week reads up to|plan has \d+ places|that plan has/.test(msg)) return "That is more plants than your plan reads.";
  if (/pick the plants to drop|more plants to drop/.test(msg)) return "Choose the plants to keep first.";
  if (/while the account is ended|without a plan/.test(msg)) return "Pay first, then choose plants.";
  if (/open soon/.test(msg)) return "Paid plans open soon. Nothing was charged.";
  return "Couldn't save. Try again.";
}

/** Payment steps: what the small working pop-up and the toasts say. */
export const pay = {
  checking: "Checking the price…",
  opening: "Opening the card page…",
  taking: "Taking payment…",
  dueToday: "Due today",
  card: "Card",
  cancel: "Cancel",
  received: "Payment received.",
  declined: "Your saved card was declined. Enter another card.",
  refund: "Your plan changed while you paid. The payment will be refunded.",
  pending: "Your payment is still being checked. Look again in a minute.",
  failed: "The payment didn't go through. Nothing was charged.",
  checkFailed: "Couldn't check the payment. Look again in a minute.",
  startFailed: "Couldn't start the payment. Try again.",
  cardFailed: "Couldn't open the card page. Try again.",
  cardChanged: "Card changed.",
  undone: "Your plan carries on as before.",
  booked: "Booked.",
};

export const logins = {
  addLogin: "Add login",
  oneLogin: "One login during the free week.",
  noLoginEnded: "Pay first to add a login.",
  remove: "Remove login",
  reconnect: "Reconnect",
  removeTitle: (username: string) => `Remove ${username}?`,
};
/** Removing a login: which plants go and what happens to each one's history. shared: the
 *  "Shared plants" group, whose plants go unless a login of the account also reaches them. */
export function removeLogin(s: AccountState, loginId: string, shared = false) {
  const only = shared ? s.plants.filter((p) => p.claimed && !p.logins.length)
    : s.plants.filter((p) => p.logins.length === 1 && p.logins[0] === loginId && !p.claimed);
  const chosen = only.filter((p) => p.chosen);
  const gone = chosen.filter((p) => !p.kept_elsewhere).map(plantName);
  const kept = chosen.filter((p) => p.kept_elsewhere).map(plantName);
  return [gone.length ? `${names(gone)}: history deleted now.` : null,
    kept.length ? `${names(kept)}: another account keeps the history.` : null,
    !chosen.length ? "No chosen plant goes with it." : null].filter(Boolean) as string[];
}

// ------------------------------------------------------------------ pay screen (no plan)

export function payScreen(s: AccountState) {
  const ended = s.state === "ended";
  const title = !ended ? null
    : s.had_plan ? `Your ${s.last_plan_name} plan has ended`
    : s.access_ended_at ? "Your free week has ended" : "Your plants had their free week";
  if (!title) return null;
  return {
    title,
    body: [s.access_ended_at ? "Readings have stopped." : "Choose a plan to start reading.",
      s.history_kept_until ? `History is kept until ${day(s, s.history_kept_until)}.` : s.history_purged ? "History has been deleted." : null]
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
  if (s.state === "past_due") {
    out.push({ kind: "past_due", tone: "bad", title: `Payment of ${money(s.amount_due_minor, s.currency, s.locale)} failed`,
      short: "Payment failed", body: planStatus(s)?.replace(/^Payment of \S+ failed\. /, "") ?? null,
      bodyShort: `Ends on ${day(s, s.plan_ends_at)} if unpaid.`, button: billing.pay, action: "pay" });
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
  | { button: { label: string; page: "billing" | "plans" | "pay" | "card" | "cancel" } };
export type Mail = { subject: string; title: string; parts: MailPart[]; reminder?: boolean };
export type MailInput = {
  key: string; state: AccountState;
  bill?: { kind: string; plan: string; plan_name: string; interval: "month" | "year"; amount_minor: number; currency: string;
    next_amount_minor: number; period_start: Iso | null; period_end: Iso | null; paid_at: Iso | null; reference: string | null;
    card_type: string | null; last4: string | null } | null;
  refund?: { amount_minor: number; currency: string; reference: string; reason: string; paid_at: Iso | null; paid_minor: number;
    card_type: string | null; last4: string | null } | null;
  event?: { kind: string; before: Record<string, unknown> | null; after: Record<string, unknown> | null } | null;
  plant?: { id: number; name: string | null } | null;
};

/** The email for one outbox row, from the state read at send time (and the frozen bill for a receipt). */
export function mail(m: MailInput): Mail | null {
  const s = m.state;
  const $ = (n: number | null | undefined, cur = s.currency) => money(n, cur, s.locale);
  const card = (t: string | null | undefined, l: string | null | undefined) => l ? `${(t || "Card").replace(/^\w/, (c) => c.toUpperCase())} •••• ${l}` : null;
  const kept = s.history_kept_until ? `History is kept until ${day(s, s.history_kept_until)}, then deleted.` : null;
  const fit = fitLine(s);
  switch (m.key) {
    case "receipt": {
      const b = m.bill; if (!b) return null;
      const rows: [string, string][] = [
        ["For", `${b.plan_name}, ${b.kind === "upgrade" ? "the days left" : b.interval === "year" ? "yearly" : "monthly"}${b.period_start && b.period_end ? `, ${day(s, b.period_start)} to ${day(s, b.period_end)}` : ""}`]];
      const c = card(b.card_type, b.last4); if (c) rows.push(["Card", c]);
      if (b.reference) rows.push(["Reference", b.reference]);
      if (b.period_end) rows.push(["Next payment", `${$(b.next_amount_minor, b.currency)} on ${day(s, b.period_end)}`]);
      return { subject: `Payment received: ${$(b.amount_minor, b.currency)}`, title: "Payment received",
        parts: [{ hero: { label: "Paid", value: $(b.amount_minor, b.currency), sub: day(s, b.paid_at) }, rows }, { button: { label: "See your plan", page: "billing" } }] };
    }
    case "payment_failed":
      return { subject: `Your payment of ${$(s.amount_due_minor)} didn't go through`, title: "Your payment didn't go through",
        parts: [{ pair: [`We couldn't take ${$(s.amount_due_minor)} for ${s.plan_name}`, s.next_retry_at ? `We'll try your card again on ${day(s, s.next_retry_at)}.` : "That was our last try."] },
          { pair: [`Pay by ${day(s, s.plan_ends_at)}`, `If it isn't paid by then, ${s.plan_name} ends and readings stop.`] },
          { button: { label: billing.payOther, page: "pay" } }] };
    case "card_update":
      return { subject: "Your card can't be charged", title: "Your card can't be charged",
        parts: [{ lead: `Your bank declined the card for ${s.plan_name} and it won't be tried again.` },
          { pair: [`Add a card by ${day(s, s.plan_ends_at)}`, `If it isn't paid by then, ${s.plan_name} ends and readings stop.`] },
          { button: { label: billing.payOther, page: "pay" } }] };
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
    case "plan_ended":
      return { subject: `Your ${s.last_plan_name} plan has ended`, title: `Your ${s.last_plan_name} plan has ended`,
        parts: [{ lead: ["Readings have stopped.", kept].filter(Boolean).join(" ") }, { button: { label: billing.seePlans, page: "plans" } }] };
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
      return { subject: `${s.plan_name} is paid ${s.next_interval === "year" ? "yearly" : "monthly"} from ${day(s, s.period_end)}`,
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
    case "history_delete_soon":
      return { reminder: true, subject: `Your history is deleted on ${day(s, s.history_kept_until)}`, title: `Your history is deleted on ${day(s, s.history_kept_until)}`,
        parts: [{ lead: `Readings stopped on ${day(s, s.access_ended_at)}. A plan before ${day(s, s.history_kept_until)} keeps it.` },
          { button: { label: billing.seePlans, page: "plans" } }] };
    case "history_deleted":
      return { reminder: true, subject: `History deleted: ${m.plant?.name || "your plant"}`, title: "Your history has been deleted",
        parts: [{ lead: `${m.plant?.name || "Your plant"}'s readings and history are deleted. A plan brings readings back from today.` },
          { button: { label: billing.seePlans, page: "plans" } }] };
  }
  return null;
}

export const AccountText = {
  money, day, weekday, forms, names, plantName, planTitle, planPrice, planStatus, placesLine, mustChoose, bookedChange,
  cardLine, cardSub, billRow, billing, cancelDialog, plans, planCard, quoteReview, checkoutPick, keepPick, weekPick, chosenToast, refused, pay,
  choosePlants, switchConfirm, plantTag, plantKept, logins, removeLogin, payScreen, fitLine, notices, mail,
};
