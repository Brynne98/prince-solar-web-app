// ============================================================================
// link.jsx — "Connect your SunSynk account".
//
// A signed-in user with no linked plants sees this instead of the dashboard. They
// enter their SunSynk Connect login once; the link-sunsynk Edge Function exchanges
// it for a token and the password never lands anywhere. When the token later dies
// (password changed, SunSynk migration) the account flips to needs_relink and the
// dashboard shows a banner pointing back here.
//
// Two backends, deliberately: api_link_status / api_link_remove are RPCs (plain
// database calls, self-scoped by auth.uid()); the credential exchange is an Edge
// Function because it has to sign requests with the app secret, which can't live
// in a browser bundle.
// ============================================================================

// A database call that takes longer than ms ends as a 'timed out' error, so nothing waits forever.
const withTimeout = (call, ms) => Promise.race([call,
  new Promise(r => setTimeout(() => r({ data: null, error: { message: 'timed out' } }), ms))]);
// A POST to one of our Edge Functions as the signed-in user: [response, its JSON or {}].
const edgePost = async (path, body, signal) => {
  const { data: { session } } = await window.sb.auth.getSession();
  if (!session) throw new Error('Your session ended. Sign in again.');
  const res = await fetch(`${window.SUNSYNK_CONFIG.url}/functions/v1/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.access_token}`, apikey: window.SUNSYNK_CONFIG.key },
    body: JSON.stringify(body),
    signal,
  });
  return [res, await res.json().catch(() => ({}))];
};
// Draws node in a root of its own on the body, outside the app; returns the function that removes it.
const mountNode = (node) => {
  const el = document.body.appendChild(document.createElement('div'));
  const root = ReactDOM.createRoot(el);
  root.render(node);
  return () => { root.unmount(); el.remove(); };
};

/**
 * Status of the signed-in user's SunSynk link(s). `refresh()` reads it again and resolves
 * once the newest read has landed, with that read's error or null, so a button can stay
 * busy until the list it changed is back on screen. `loading` is only the first read: a
 * re-read never blanks the list.
 */
window.useLinkStatus = function useLinkStatus() {
  const { useState, useEffect, useRef, useCallback } = React;
  const [state, setState] = useState({ loading: true, accounts: [], error: null });
  const latest = useRef(null);
  const refresh = useCallback(() => {
    // Ten seconds, then it counts as a failed read. Raced here rather than with an abort
    // signal: supabase-js waits on the stored session before the request even starts, and
    // a stall there never reaches the signal.
    const attempt = () => withTimeout(window.sb.rpc('api_link_status'), 10000).catch(e => ({ data: null, error: e }));
    // One quiet second try: a phone opening the app can stall or fail the first read
    // while its network and stored session wake up, and a retry then loads (SOLAR-21).
    const read = attempt().then(r => (r.error ? attempt() : r)).then(({ data, error }) => {
      // A failed re-read keeps the logins already shown; an empty list would send a
      // signed-in household from the dashboard back to the Connect screen.
      // `|| 'failed'`: a failure with no message must still read as one, not as "no logins".
      if (read === latest.current) setState(s => ({ loading: false, accounts: error ? s.accounts : (data || []), error: error ? (error.message || 'failed') : null }));
      return error || null;
    });
    latest.current = read;
    // An older caller waits for whichever read is newest, so it never settles on a list
    // that is about to be replaced, and never hangs because its own read was dropped.
    const settle = (p) => p.then(e => (p === latest.current ? e : settle(latest.current)));
    return settle(read);
  }, []);
  useEffect(() => { refresh(); }, [refresh]);
  // Read again each minute while on screen, and on coming back, so the Logins row, the red
  // dot and the cut-off banner follow a login that dies, recovers or is reconnected
  // elsewhere without a reload (SOLAR-153). A hidden page asks nothing (SOLAR-140).
  useEffect(() => {
    const tick = () => { if (!document.hidden) refresh(); };
    const t = setInterval(tick, 60000);
    document.addEventListener('visibilitychange', tick);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', tick); };
  }, [refresh]);
  return { ...state, refresh };
};

window.linkSunsynk = async function linkSunsynk(username, password) {
  const [res, body] = await edgePost('link-sunsynk', { username, password });
  if (!res.ok) throw new Error(LINK_ERRORS[body.error] || 'Couldn’t connect to SunSynk. Check the login and try again.');
  window.track('plant_linked');
  return body;
};

// link-sunsynk answers in developer shorthand; these are the household's words for it.
const LINK_ERRORS = {
  'SunSynk rejected those credentials': 'SunSynk didn’t accept that email and password.',
  'could not reach SunSynk': 'Can’t reach SunSynk right now. Try again in a minute.',
  'sign in first': 'Your session ended. Sign in again.',
  'session invalid': 'Your session ended. Sign in again.',
  'too many attempts': 'Too many tries. Try again in an hour.',
};


// ---- Paywall (SOLAR-208) ------------------------------------------------------
const rand = (n) => 'R' + Number(n).toLocaleString('en-US');
// "30 Nov"; a date in another year carries it ("31 Oct 2027"), so a yearly date doesn't read as this year's.
const billDay = (d) => window.dayText(d, { day: 'numeric', month: 'short', year: d.slice(0, 4) === String(new Date().getFullYear()) ? undefined : 'numeric' });
const perUnit = (period) => (period === 'yearly' ? 'a year' : 'a month');
// here, not in tabs.jsx, so the billing notices in the header can name a plan before tabs loads
const PLAN_NAME = { free: 'Free', home: 'Home', family: 'Family' };
// extras: the extra plants wanted on Family in all; null keeps those held (SOLAR-264).
// A billing read or change that takes too long ends as an error, so no button or pop-up waits
// forever (SOLAR-294). The caller says "try again"; a change may still land, so it re-reads.
const billingRpc = (name, args) => withTimeout(window.sb.rpc(name, args), 15000);
window.billingRpc = billingRpc;
const quote = (plan, period, extras = null) => billingRpc('api_billing_quote', { p_plan: plan, p_period: period, p_extra: extras })
  .then(({ data, error }) => { if (error) throw error; return data; });

// Offers (SOLAR-330). offer: its terms from the server (api_billing_status.offer, quote.offerTerms),
// or null. The line under an offer price: how long it lasts and what comes after.
const offerName = (o) => (o.id === 'launch' ? 'launch price' : 'offer price');
const offerLine = (o, list, period) => !o ? null
  : o.until ? `Until ${billDay(o.until)}. Then ${rand(list)} ${perUnit(period)}.`
  : o.months && !o.held ? `For your first ${period === 'yearly' ? 'year' : o.months + ' months'}. Then ${rand(list)} ${perUnit(period)}.`
  : `${o.id === 'launch' ? 'Launch price. ' : ''}Yours while you stay.`;
// Who can still join: the cap, before joining.
const offerCap = (o) => (o && !o.held && o.cap ? `${o.id === 'launch' ? 'Launch price' : 'Offer'} for the first ${o.cap} members.` : null);
// The list price struck out before an offer price; nothing when they're the same.
const Was = ({ list, price }) => (list > price ? <s className="pw-was">{rand(list)}</s> : null);

window.billingFmt = { rand, billDay, perUnit, offerName, offerLine, offerCap, Was };

// Paystack (SOLAR-208, the billing function). A saved card is charged at once;
// otherwise, or after the saved card is declined, Paystack's card page opens and
// comes back to the Plan section with ?reference=, which billingReturn checks.
const billingCall = async (route, body) => {
  // a payment that hasn't started in 30 s says so (SOLAR-294)
  const [res, out] = await edgePost('billing/' + route, body, AbortSignal.timeout(30000))
    .catch(e => { throw new Error(/abort|timeout/i.test(e.name) ? 'timed out' : e.message); });
  if (!res.ok) throw new Error(out.error || 'payment failed');
  return out;
};
// The Plan section on Billing, on the plant the user was looking at.
const planUrl = (extra = '') => {
  const plant = new URLSearchParams(location.search).get('plant');
  return `${location.pathname}?tab=billing&section=plan${plant ? `&plant=${encodeURIComponent(plant)}` : ''}${extra}`;
};
// switched: a paid switch to yearly (SOLAR-298) is not an upgrade; its own event goes.
const billingPaid = (plan, switched = false) => {
  if (!switched) window.track('upgrade_done', plan ? { plan } : {});
  location.assign(planUrl('&billing=paid'));
};

// A payment step that ran out of time may still have gone through, so it doesn't say "try again".
const SLOW_NOTE = 'This is taking too long. Check Billing in a minute before you try again.';
// The toast for a payment step that failed: paid plans not open yet, too slow, or fallback.
const payFailed = (e, fallback) => (/open soon/.test(e.message) ? window.toast('Paid plans open soon. Nothing was charged.')
  : window.toast(e.message === 'timed out' ? SLOW_NOTE : fallback, { error: true }));
// While a payment step runs, a small pop-up says so, so a slow one never looks frozen (SOLAR-294).
// It has no close: every step ends, the slowest after 30 s. Returns the function that closes it.
const working = (text) => mountNode(<Dialog busy label={text}><div className="pop-wait" role="status"><span className="spin" aria-hidden="true" />{text}</div></Dialog>);
// Paid after the plan or extra plants changed: nothing applied, refunded by hand (0127).
const REFUND_NOTE = 'Your plan changed while you paid, so nothing changed. The payment will be refunded.';
// extras: the extra plants wanted on Family in all (SOLAR-264); left out, those held.
// plants: the stopped plants the room is for; once paid they start first, else the oldest.
// One payment at a time: a second click while one is open does nothing.
// paidEvent: { name, props } sent once the money is taken, here or back from the card page (SOLAR-268).
let paying = false;
const PAID_EVENT = 'ps.paidEvent';
// The card-page payment last opened. Paystack sends the user back with ?reference= only
// once paid; after a decline they close the page and come back without it, so
// billingReturn checks this one instead (SOLAR-338).
const OPEN_REF = 'ps.cardPage';
const openCardPage = (r) => { try { sessionStorage.setItem(OPEN_REF, r.reference); } catch (e) {} location.assign(r.url); };
// Back with the browser's back button the page is restored as it was, so nothing checks
// the payment: load it again.
window.addEventListener('pageshow', (e) => { try { if (e.persisted && sessionStorage.getItem(OPEN_REF)) location.reload(); } catch (x) {} });

// A question over the page (SOLAR-286): the browser's own modal dialog dims the page, keeps
// focus inside and closes on Escape. A click on the dimmed page outside it closes it too,
// unless keep (a form: a stray tap must not throw away what was typed). Closing hands focus
// back to what had it, e.g. the plant's switch. size: 'wide' for the plan cards, 'mid' for
// the lock's plans. busy: a change is on its way, so nothing closes it until it lands.
function Dialog({ label, onClose, keep = false, busy = false, size = null, children }) {
  const ref = React.useRef(null);
  // What had focus, read at first render before a child takes it, and whether it showed a ring
  // (a keyboard user): only then does it get one back on close.
  const [back] = React.useState(() => ({ el: document.activeElement, ring: !!document.activeElement?.matches?.(':focus-visible') }));
  React.useEffect(() => {
    const d = ref.current;
    d.showModal();
    return () => { if (d.open) d.close(); if (back.el && back.el.isConnected) back.el.focus({ preventScroll: true, focusVisible: back.ring }); };
  }, []);
  return (
    <dialog ref={ref} className={'pop-dlg' + (size ? ' pop-' + size : '')} aria-label={label}
            onCancel={(e) => { e.preventDefault(); if (!busy && e.target === ref.current) onClose(); }}   // only its own Escape, not one from a pop-up opened over it
            onClick={(e) => { if (!keep && !busy && e.target === ref.current) onClose(); }}>
      <div className="pop-body">{children}</div>
    </dialog>
  );
}
window.Dialog = Dialog;

// The saved card is charged without Paystack's page, so the amount, the next bill and the
// card are shown first (SOLAR-276). Centred on a desktop, from the bottom on a phone.
function PayReview({ title, note, due, then, card, onDone }) {
  const cancel = React.useRef(null);
  React.useEffect(() => { cancel.current?.focus(); }, []);
  return (
    <Dialog label={title} onClose={() => onDone(false)}>
      <h2 id="pay-review-t" className="pay-review-t">{title}</h2>
      {note && <p className="field-note">{note}</p>}
      <div className="pay-review-ln due"><span>Due today</span><b>{rand(due)}</b></div>
      <div className="pay-review-ln"><span>{then[0]}</span><b>{then[1]}</b></div>
      <div className="pay-review-ln"><span>Card</span><b>{card}</b></div>
      <div className="pay-review-acts">
        <button type="button" className="ghost-btn" ref={cancel} onClick={() => onDone(false)}>Cancel</button>
        <button type="button" className="save-btn" onClick={() => onDone(true)}>Pay</button>
      </div>
    </Dialog>
  );
}
// true: pay. Nothing to review (no saved card: Paystack's page shows the price; nothing due;
// a refused change, which the pay call explains) also answers true.
const reviewPay = async (plan, period, extras) => {
  const stop = working('Checking the price…');
  // Nothing is charged yet, so a failed or slow read just says try again, never pays without the review.
  const [{ data: b, error }, q] = await Promise.all([billingRpc('api_billing_status'), quote(plan, period, extras)])
    .catch(() => { throw new Error('price check'); }).finally(stop);
  if (error) throw new Error('price check');
  if (!b?.card || !q?.dueNow) return true;
  const name = plan === 'family' ? 'Family' : 'Home';
  const more = (extras ?? q.extraPlants) - q.extraPlants;
  // A switch to yearly (SOLAR-298) is paid now and starts on the billing date.
  const title = q.switch ? 'Switch to yearly'
    : q.plan === plan && more > 0 ? `Add ${more} ${more === 1 ? 'plant' : 'plants'} to ${name}` : `Upgrade to ${name}`;
  const ok = await new Promise(resolve => {
    let close;
    const done = (yes) => { close(); resolve(yes); };
    close = mountNode(<PayReview title={title} note={q.switch ? `Your year starts ${billDay(q.startsOn)}.` : null} due={q.dueNow} card={`${b.card.name} •••• ${b.card.last4}`}
      then={[`Then from ${billDay(q.nextDate)}`, `${rand(q.nextCharge)} ${perUnit(q.switch ? 'yearly' : q.period || period)}`]} onDone={done} />);
  });
  window.track('pay_review_done', { plan, choice: ok ? 'pay' : 'cancel' });
  return ok;
};

window.startUpgrade = async function startUpgrade(plan, period, newCard = false, extras = null, plants = null, paidEvent = null) {
  if (paying) return;
  paying = true;
  try {
    if (!newCard && !await reviewPay(plan, period, extras)) return;
    const stop = working(newCard ? 'Opening the card page…' : 'Taking payment…');
    let r;
    try {
      r = await billingCall('pay', { plan, period, newCard, extras, plants });
      if (r.status === 'failed') {
        window.toast('Your saved card was declined. Enter another card.', { error: true });
        r = await billingCall('pay', { plan, period, newCard: true, extras, plants });
      }
    } finally { if (!r?.url && r?.status !== 'paid') stop(); }   // a new page is on its way: keep it up
    if (r.url) {
      window.track('checkout_opened', { plan, period });
      try { paidEvent ? sessionStorage.setItem(PAID_EVENT, JSON.stringify(paidEvent)) : sessionStorage.removeItem(PAID_EVENT); } catch (e) {}
      openCardPage(r);
    } else if (r.status === 'paid') {
      if (paidEvent) window.track(paidEvent.name, paidEvent.props);
      billingPaid(plan, paidEvent?.name === 'yearly_switch_done');
    }
    else if (r.status === 'refund') window.toast(REFUND_NOTE, { error: true });
    else window.toast('Your payment is still being checked. Look again in a minute.');
  } catch (e) {
    payFailed(e, /settle the failed payment/.test(e.message) ? 'Pay the payment that didn’t go through first.'
      : /year is paid/.test(e.message) ? 'Your year is paid. Your plan stays as it is until it starts.'
      : 'Couldn’t start the payment. Try again.');
  } finally {
    paying = false;
  }
};

// Pay a failed renewal with another card.
window.settlePayment = async function settlePayment() {
  const stop = working('Opening the card page…');
  try {
    const r = await billingCall('pay', { settle: true });
    openCardPage(r);
  } catch (e) {
    stop();
    payFailed(e, 'Couldn’t start the payment. Try again.');
  }
};

// Change the saved card (SOLAR-238): R1 on Paystack's card page, refunded once the
// card is saved. Comes back through billingReturn like any card-page payment.
window.changeCard = async function changeCard() {
  const stop = working('Opening the card page…');
  try {
    const r = await billingCall('pay', { card: true });
    openCardPage(r);
  } catch (e) {
    stop();
    payFailed(e, 'Couldn’t open the card page. Try again.');
  }
};

// Once, when Account opens: back from Paystack's card page (?reference=), after a
// payment (?billing=paid), or from the "Pay with another card" email (?pay=1). Also once
// on any other page, for a card page closed without paying (OPEN_REF).
window.billingReturn = async function billingReturn(billingStatus) {
  const q = new URLSearchParams(location.search);
  const done = q.get('billing'), pay = q.get('pay');
  let ref = q.get('reference'), open = null;
  try { open = sessionStorage.getItem(OPEN_REF); sessionStorage.removeItem(OPEN_REF); } catch (e) {}
  const fromUrl = !!(ref || done || pay);
  ref = ref || (!done && !pay ? open : null);
  if (!ref && !done && !pay) return;
  if (fromUrl) history.replaceState(null, '', planUrl());
  if (pay) {
    if (billingStatus?.state === 'past_due') await window.settlePayment();
    return;
  }
  if (done === 'paid') { window.toast('Payment received. Your plan is updated.'); return; }
  // The event a card-page payment was opened with: sent only if it was paid.
  let paidEvent = null;
  try { paidEvent = JSON.parse(sessionStorage.getItem(PAID_EVENT)); sessionStorage.removeItem(PAID_EVENT); } catch (e) {}
  try {
    const { status, kind } = await billingCall('verify', { reference: ref });
    // A card change changes no plan: the caller re-reads the card ('card').
    if (status === 'paid' && kind === 'card') {
      window.track('card_change_done');
      window.toast('Card changed. The R1 we took to check it goes back to your card.');
      return 'card';
    }
    // A full reload: resumed plants join the plant list.
    if (status === 'paid') { if (paidEvent) window.track(paidEvent.name, paidEvent.props); return billingPaid(null, kind === 'switch'); }
    if (status === 'refund') return window.toast(REFUND_NOTE, { error: true });
    window.toast(status === 'failed' ? 'The payment didn’t go through. Nothing was charged.' : 'Your payment is still being checked. Look again in a minute.', { error: status === 'failed' });
  } catch {
    window.toast('Couldn’t check the payment. Look again in a minute.', { error: true });
  }
};

// From the website's pricing: ?plan=home&period=yearly. Sign-in drops the query, so it
// is kept for a day, then the card page opens once the user is signed in. Always the
// card page, never a silent charge to a saved card: it shows the price to confirm.
(() => {
  const q = new URLSearchParams(location.search), plan = q.get('plan');
  if (plan !== 'home' && plan !== 'family') return;
  localStorage.setItem('ps.wantPlan', JSON.stringify({ plan, period: q.get('period') === 'yearly' ? 'yearly' : 'monthly', at: Date.now() }));
  q.delete('plan'); q.delete('period');
  history.replaceState(null, '', location.pathname + (q.toString() ? `?${q}` : '') + location.hash);
})();
window.sb.auth.onAuthStateChange((event, session) => {
  if (!session || (event !== 'INITIAL_SESSION' && event !== 'SIGNED_IN')) return;
  let want = null;
  try { want = JSON.parse(localStorage.getItem('ps.wantPlan')); } catch {}
  if (!want) return;
  localStorage.removeItem('ps.wantPlan');
  if (Date.now() - want.at > 86400000) return;
  // Outside the callback: an awaited Supabase call inside it waits on the auth lock.
  setTimeout(async () => {
    const { data: b } = await window.sb.rpc('api_billing_status');
    if (b?.plan !== 'free' || b.comped || b.state === 'past_due') return;
    window.track('website_plan_done', { plan: want.plan, period: want.period });
    window.startUpgrade(want.plan, want.period, true);
  });
});

/**
 * Shown when the plan doesn't cover a plant.
 *   reason 'paused'     Upgrade on a login row with paused plants (`paused`: their names)
 *          'upgrade'    Upgrade in the Plan section, on Home: the price before the saved card is charged
 * A paid user's period changes at renewal, so only Free gets the switch.
 */
function Paywall({ reason, paused = [], plantIds = null, onCancel }) {
  const { useState, useEffect } = React;
  const offers = ['family'];
  const [period, setPeriod] = useState('monthly');
  const [quotes, setQuotes] = useState(null);
  // Closed any way (Not now, the sheet's close, leaving the screen). Paying leaves the
  // page instead, so it never counts as closed.
  useEffect(() => { window.track('paywall_shown', { reason }); return () => window.track('paywall_closed', { reason }); }, []);
  useEffect(() => {
    let alive = true;
    Promise.all(offers.map(p => quote(p, period)))
      .then(qs => alive && setQuotes(Object.fromEntries(qs.map((q, i) => [offers[i], q]))))
      .catch(() => alive && setQuotes({ error: true }));
    return () => { alive = false; };
  }, [period]);
  const first = quotes && !quotes.error ? quotes[offers[0]] : null;
  const paid = first && first.plan !== 'free';
  const per = paid ? first.period : period;
  return (
    <div className="paywall" role="dialog" aria-labelledby="pw-title">
      <h2 id="pw-title" className="sset-title">{reason === 'upgrade' ? 'Upgrade to Family'
        : reason === 'paused' ? `Collect data for ${paused.length === 1 ? paused[0] : paused.length + ' stopped plants'}`
        : 'Add another plant'}</h2>
      <p className="sset-note">{first?.plan === 'family' ? 'Plants after your 3rd stay stopped until you add them to your plan.'
        : (paid ? 'Home' : 'Free') + ' covers one plant.'}</p>
      {!paid && (
        <window.Segmented size="sm" className="pw-period" label="Billing" value={period} onChange={setPeriod}
          options={['monthly', 'yearly'].map(p => ({ value: p, label: p === 'monthly' ? 'Monthly' : 'Yearly' }))} />
      )}
      {quotes?.error ? <p className="sset-note pw-error">Couldn’t load prices. Close this and try again.</p> : (
        <div className="pw-plans">
          {offers.map(p => {
            const q = quotes?.[p];
            return (
              <div key={p} className={'pw-plan' + (p === 'family' ? ' pw-main' : '')}>
                <div className="pw-name">{p === 'family' ? 'Family' : 'Home'}</div>
                <div className="pw-price">{q && <Was list={q.listCharge} price={q.nextCharge} />}<b>{q ? rand(q.nextCharge) : '…'}</b> {perUnit(per)}</div>
                {q?.offerTerms && q.listCharge > q.nextCharge && <div className="pw-offer">{offerLine(q.offerTerms, q.listCharge, per)}</div>}
                <ul className="pw-gives">
                  <li>{p === 'family' ? 'Up to 3 plants' : '1 plant'}</li>
                  <li>Your full history</li>
                </ul>
                {paid && q && q.dueNow != null && q.dueNow !== q.nextCharge && <div className="pw-due">{rand(q.dueNow)} today, then {rand(q.nextCharge)} {perUnit(per)} from {billDay(q.nextDate)}</div>}
                <button type="button" className={p === 'family' ? 'save-btn' : 'ghost-btn'} disabled={!q || (paid && q.dueNow == null)}
                        onClick={() => (q?.offer && window.track('offer_pick_done', { offer: q.offer, plan: p, period: per }), window.startUpgrade(p, per, false, q?.plan === 'family' ? (q.extraPlants || 0) + Math.max(paused.length, 1) : null, plantIds))}>{p === 'home' ? 'Choose Home' : q?.plan === 'family' ? 'Add to my plan' : 'Upgrade to Family'}</button>
              </div>
            );
          })}
        </div>
      )}
      {first && <p className="field-note"><Was list={first.listExtraPrice} price={first.extraPrice} />{rand(first.extraPrice)} {perUnit(per)} for each plant after your 3rd.{offerCap(first.offerTerms) && ' ' + offerCap(first.offerTerms)}</p>}
      <div className="conn-form-actions pw-foot">
        <span className="field-note">Cancel any time.</span>
        <button type="button" className="ghost-btn" onClick={onCancel}>Not now</button>
      </div>
    </div>
  );
}
window.Paywall = Paywall;

// The same moment on the Connect screen and inside Settings; one wording for both.
const NO_PLANT_TEXT = 'signed in, but no plant is shared with it yet. Your login is saved. Retry any time.';

// One form for a SunSynk login, built from the app's own Settings parts (SOLAR-96).
// `compact`: inside Account's SunSynk logins section (Add login, Reconnect). Otherwise the
// Connect card that opens in place on a page with no inverter yet (Setup), with its title.
// Either way: one line on which login, the two fields, a note, then Cancel and the green
// button at the right.
function LinkForm({ relink, changing, onLinked, compact, onCancel, initialUsername, hasPlant }) {
  const { useState, useEffect, useRef } = React;
  // The plan's answer: a paywall reason.
  const [paywall, setPaywall] = useState(null);
  const [username, setUsername] = useState(initialUsername || '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  // The request checks the login, then lists its plants; the button names each half.
  const [finding, setFinding] = useState(false);
  const findTimer = useRef(null);
  // Most households use one email for both, so start from the account's own.
  const [ownEmail, setOwnEmail] = useState(null);
  useEffect(() => {
    if (initialUsername) return;
    let alive = true;
    window.sb.auth.getSession().then(({ data }) => {
      const email = data.session?.user?.email;
      if (!alive || !email) return;
      setOwnEmail(email);
      setUsername(u => u || email);
    });
    return () => { alive = false; };
  }, []);
  // A failure that isn't one box's is the red toast (SOLAR-166); a box's stays on its label.
  const fail = (text) => window.toast(text, { error: true });
  const [noPlants, setNoPlants] = useState(false);
  // Field id → message, shown on the label line.
  const { bad, setBad, flag, edited } = window.useFieldErrors();

  const submit = async (e) => {
    e?.preventDefault();
    const problems = {};
    if (!username.trim()) problems['ss-user'] = 'Enter your email';
    if (!password) problems['ss-pass'] = 'Enter your password';
    if (Object.keys(problems).length) return flag(problems);
    setBusy(true); setBad({});
    findTimer.current = setTimeout(() => setFinding(true), 2500);
    try {
      const r = await window.linkSunsynk(username.trim(), password);
      // No plant yet. Nothing on the server looks at this login again, so Retry has to
      // ask SunSynk afresh: the password stays in memory while the form is up, no longer.
      if (r.warning) {
        if (noPlants) fail('Still no plant on this login.');
        setNoPlants(true);
        return;
      }
      // Linked, but nothing to show: every plant is paused. The paywall says why, in
      // place of the form.
      const pausedAll = (r.paused || []).length > 0 && (r.paused || []).length === (r.plants || []).length && !hasPlant;
      if (pausedAll) {
        setPassword('');
        setPaywall({ reason: 'paused', paused: r.plants.map(p => window.plantLabel(p)), ids: r.paused });
        await onLinked(r);
        return;
      }
      // Busy until the caller has the new login list, or the screen sits idle before it changes.
      await onLinked(r);
      setPassword(''); setNoPlants(false);
    } catch (ex) {
      fail(ex instanceof TypeError ? 'Can’t reach Prince Solar Hub. Check your connection and try again.' : ex.message);
    } finally {
      clearTimeout(findTimer.current); setFinding(false);
      setBusy(false);
    }
  };

  const invalid = (id) => window.invalidProps(id, bad[id]);
  const green = noPlants ? (busy ? 'Checking…' : 'Retry now')
    : busy ? (finding ? 'Finding your plant…' : 'Checking your login…')
    : relink ? (changing ? 'Save password' : 'Reconnect') : compact ? 'Add login' : 'Connect';

  if (paywall) {
    const close = () => { setPaywall(null); setPassword(''); onCancel && onCancel(); };
    return <div className={compact ? 'conn-form' : 'link-card'}><Paywall reason={paywall.reason} paused={paywall.paused} plantIds={paywall.ids} onCancel={close} /></div>;
  }

  return (
    <form className={compact ? 'conn-form link-form' : 'link-form link-card'} onSubmit={submit} noValidate aria-busy={busy}>
      {!compact && <h2 className="sset-title">{noPlants ? 'Connected, but no plant yet' : relink ? 'Reconnect SunSynk' : 'Add your plant'}</h2>}
      {noPlants ? (
        // The login worked but SunSynk lists no plant for it. Say so and offer Retry; never
        // send the owner to an installer or SunSynk.
        <p className="sset-note"><b>{username.trim()}</b> {NO_PLANT_TEXT}</p>
      ) : (<>
        {/* changing: a new SunSynk password for a login that still works, so nothing stopped */}
        {!changing && <p className="sset-note">{relink
          ? 'SunSynk stopped accepting your login. Your history is safe.'
          : 'Use the login from the SunSynk Connect app.'}</p>}
        {/* In Account the two fields share one line, as they did before (SOLAR-97); a phone
            stacks them. On the Connect card they stack. */}
        <div className={compact ? 'field-row' : undefined}>
          <div className="field">
            <window.FieldLabel id="ss-user" label="SunSynk email" error={bad['ss-user']} hint={ownEmail && username === ownEmail ? 'Your account email' : null} />
            <input id="ss-user" className="input" type="text" placeholder="you@example.com" value={username} autoComplete="off"
                   readOnly={!!relink} onChange={(e) => { setUsername(e.target.value); edited('ss-user'); }} {...invalid('ss-user')} />
          </div>
          <div className="field link-last">
            <window.FieldLabel id="ss-pass" label="SunSynk password" error={bad['ss-pass']} />
            <window.PasswordInput id="ss-pass" className="input" value={password} onChange={(v) => { setPassword(v); edited('ss-pass'); }} aria={invalid('ss-pass')} />
          </div>
        </div>
        <div className="field-note link-note">{compact ? 'We never keep your password.' : 'We never keep your password. Disconnect any time in Account.'}</div>
      </>)}
      <div className="conn-form-actions link-actions">
        {noPlants
          ? <button type="button" className="ghost-btn" disabled={busy} onClick={() => { setNoPlants(false); setPassword(''); }}>Use a different login</button>
          : onCancel && <button type="button" className="ghost-btn" onClick={onCancel} disabled={busy}>Cancel</button>}
        <window.BusyButton type="submit" className="save-btn" busy={busy}>{green}</window.BusyButton>
      </div>
    </form>
  );
}
window.LinkForm = LinkForm;

// The link form over the page, as Add plant, Add login and Reconnect open it. Closing it is
// its Cancel. note: a line above the form.
function LinkDialog({ title, note, onCancel, ...form }) {
  return (
    <window.Dialog keep label={title} onClose={onCancel}>
      <div className="confirm-title">{title}</div>
      {note && <div className="confirm-text">{note}</div>}
      <LinkForm compact onCancel={onCancel} {...form} />
    </window.Dialog>
  );
}
window.LinkDialog = LinkDialog;
/**
 * Sits inside AuthGate. Hands the login list to its child, which shows the dashboard
 * when a login lists a plant and the Setup frame (Connect on Live) when none does.
 * A read that failed shows its own card, since it says nothing about the logins. A login that needs reconnecting never
 * hides the dashboard, even when every login has died: the stored readings are
 * still worth seeing, and the app shell shows a banner leading to Settings, where
 * each login reconnects on its own.
 */
// A plant to show: on some login, and not paused (SOLAR-208). Paused plants are listed
// in Account only, so an account with nothing else stays on the Connect screen.
window.hasActivePlant = (accounts) => accounts.some(a => (a.plants || []).some(p => !p.paused));

window.LinkGate = function LinkGate({ children, fallback = null }) {
  const [checking, setChecking] = React.useState(false);
  const { loading, accounts, error, refresh } = window.useLinkStatus();
  // The wall tablet's connection drops for minutes at a time, and Chrome on iPad reloads
  // the page now and then; a reload inside a drop fails both tries and used to sit on
  // "Couldn't check" until someone tapped it (SOLAR-21). Keep checking while stuck there:
  // every 15 s, and the moment the tablet is back online or on screen.
  const stuck = !loading && !!error && !window.hasActivePlant(accounts);
  React.useEffect(() => {
    if (!stuck) return;
    // One read at a time: a read inside a drop can take its full 20 s.
    let busy = false;
    const again = () => {
      if (busy || document.visibilityState !== 'visible') return;
      busy = true; refresh().finally(() => { busy = false; });
    };
    const timer = setInterval(again, 15000);
    window.addEventListener('online', again);
    document.addEventListener('visibilitychange', again);
    return () => { clearInterval(timer); window.removeEventListener('online', again); document.removeEventListener('visibilitychange', again); };
  }, [stuck, refresh]);

  if (loading) return fallback;

  // A read that failed says nothing about the logins, so it must not ask for one: a
  // household with plants would land on Connect, and a login that just connected would
  // be asked for again.
  if (!window.hasActivePlant(accounts)) {
    if (error) {
      const retry = async (e) => { e.preventDefault(); setChecking(true); await refresh(); setChecking(false); };
      return (
        <div className="login-wrap">
          <window.AuthCard title="Couldn’t check your SunSynk logins" onSubmit={retry} busy={checking}>
            <window.BusyButton type="submit" busy={checking} busyText="Checking…">Try again</window.BusyButton>
            {/* No server text on screen (SOLAR-163). */}
            <div className="login-links"><window.SignOutButton className="login-link quiet" /></div>
          </window.AuthCard>
        </div>
      );
    }
  }
  return typeof children === 'function' ? children({ accounts, error, refresh }) : children;
};
