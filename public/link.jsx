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
  const hadLogins = useRef(false);
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
      // Every login gone at once may be the account deleted on another device: its answers
      // come back empty, not refused, so a tab left on screen would never look (SOLAR-526).
      if (!error && read === latest.current) {
        const some = (data || []).length > 0;
        if (hadLogins.current && !some) window.checkSession();
        hadLogins.current = some;
      }
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

// The SunSynk login owners share their plant to, as Visitor (SOLAR-310).
const SHARE_TO = 'admin@princesolarhub.co.za';
// A plant shared to us: plantId or an inverter serial. Resolves like linkSunsynk, so the
// screens that take a login take this too; a claimed plant throws with .taken = what was typed.
window.claimShare = async function claimShare(ref) {
  const [res, body] = await edgePost('claim-share', { ref });
  window.track('share_check_done', { result: body.result || body.error || String(res.status) });
  if (body.error === 'taken') throw Object.assign(new Error('taken'), { taken: ref });
  if (body.error === 'not_shared') throw Object.assign(new Error('Not shared with us yet'), { field: true });
  if (!res.ok) throw new Error(LINK_ERRORS[body.error] || 'Couldn’t check SunSynk. Try again.');
  window.track('plant_linked', { via: 'share' });
  return { plants: [{ id: body.plantId, name: body.plantName }], paused: body.result === 'claimed_paused' ? [body.plantId] : [] };
};

// link-sunsynk answers in developer shorthand; these are the household's words for it.
const LINK_ERRORS = {
  'SunSynk rejected those credentials': 'SunSynk didn’t accept that email and password.',
  'could not reach SunSynk': 'Can’t reach SunSynk right now. Try again in a minute.',
  'sign in first': 'Your session ended. Sign in again.',
  'session invalid': 'Your session ended. Sign in again.',
  'too many attempts': 'Too many tries. Try again in an hour.',
};


// ---- Billing (SOLAR-208) -------------------------------------------------------
// "R1 799", the app's and emails' money format (SOLAR-348); no break inside a price
// narrow: a narrow no-break space, for the large prices, where a full one reads as a gap (SOLAR-364)
const rand = (n, narrow) => 'R' + Number(n).toLocaleString('en-US').replace(/,/g, narrow ? '\u202f' : '\u00a0');
// "30 Nov"; a date in another year carries it ("31 Oct 2027"), so a yearly date doesn't read as this year's.
// No date (a comped plan has none) gives '' (SOLAR-433).
const billDay = (d) => !d ? '' : window.dayText(d, { day: 'numeric', month: 'short', year: d.slice(0, 4) === String(new Date().getFullYear()) ? undefined : 'numeric' });
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

// "Office", "Office and Shop", "Office, Shop and Barn"
const andList = (names) => (names.length > 1 ? names.slice(0, -1).join(', ') + ' and ' + names[names.length - 1] : names[0] || '');
// The plants a downgrade picks from, under their logins as Billing lists them: collecting
// and not up for deletion, except those that stop on the billing date (drop), which can
// still be picked. A plant two logins share shows under the first. Here, not in tabs.jsx,
// so the header's notices can name them before tabs loads (SOLAR-505).
const pickableLogins = (links) => {
  const seen = new Set();
  return (links?.accounts || []).filter(a => a.status !== 'disabled').map(a => ({ ...a,
    plants: (a.plants || []).filter(p => !p.paused && (!p.remove_on || p.drop) && !seen.has(p.plant_id) && seen.add(p.plant_id)) }))
    .filter(a => a.plants.length);
};
// What a booked cancel or smaller plan deletes on its date, said once in the same words on
// Billing, in the bell and in the banner (SOLAR-505): which plants stay, which go. Up to two
// are named; more are counted. A cancel takes all history too. '' when a smaller plan stops none.
const lossLine = (links, cancel) => {
  const plants = pickableLogins(links).flatMap(a => a.plants);
  const kept = plants.filter(p => !p.drop).map(window.plantLabel), gone = plants.filter(p => p.drop).map(window.plantLabel);
  if (!gone.length) return cancel ? 'All history is deleted then.' : '';
  const stays = kept.length ? `${andList(kept)} ${kept.length > 1 ? 'stay' : 'stays'}. ` : '';
  const what = gone.length > 2 ? `The other ${gone.length} plants` : andList(gone);
  return stays + what + (cancel ? ' and all history are deleted then.' : ` and ${gone.length > 1 ? 'their' : 'its'} history are deleted then.`);
};

window.billingFmt = { rand, billDay, perUnit, offerName, offerLine, offerCap, Was, andList, lossLine };

// Paystack (SOLAR-208, the billing function). A saved card is charged at once;
// otherwise, or after the saved card is declined, Paystack's card page opens and
// comes back to the Plan section with ?reference=, which billingReturn checks.
const billingCall = async (route, body, ms = 30000) => {
  // a payment that hasn't started in 30 s says so (SOLAR-294)
  const [res, out] = await edgePost('billing/' + route, body, AbortSignal.timeout(ms))
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

// The toast for a payment step that failed: paid plans not open yet, or fallback. A card
// page that didn't open in time charged nothing, so its fallback's "try again" holds.
const payFailed = (e, fallback) => (/open soon/.test(e.message) ? window.toast('Paid plans open soon. Nothing was charged.', { info: true })
  : window.toast(fallback, { error: true }));
// What to say when a failed payment refused a plan or plant change (0189, 0198); else false.
const payFirst = (e) => /failed payment/.test(e.message) && 'Pay the failed payment first.';
// A saved card's charge: the billing function gives Paystack 30 s to charge and 30 s more to
// check, so the page waits past both (SOLAR-363).
const PAY_WAIT = 70000;
// Still no answer: the charge may land later, so read Billing every 5 s for a minute. A plan
// that moved since the Pay tap is paid; otherwise it's still being checked.
const billingSig = (b) => (b ? [b.plan, b.period, b.extraPlants, b.nextPlan, b.nextPeriod, b.prepaidOn].join('|') : null);
const payLanded = async (beforeP) => {
  const was = billingSig(await beforeP);
  for (let i = 0; was && i < 12; i++) {
    await new Promise(res => setTimeout(res, 5000));
    const { data } = await billingRpc('api_billing_status').catch(() => ({}));
    if (data && billingSig(data) !== was) return { status: 'paid' };
  }
  return { status: 'pending' };
};
// While a payment step runs, a small pop-up says so, so a slow one never looks frozen (SOLAR-294).
// It has no close: every step ends, the slowest after about 2 minutes. Returns the function that closes it.
const working = (text) => mountNode(<Dialog busy label={text}><div className="pop-wait" role="status"><span className="spin" aria-hidden="true" />{text}</div></Dialog>);
// Paid after the plan or extra plants changed: nothing applied, refunded by hand (0127).
const REFUND_NOTE = 'Your plan changed while you paid. The payment will be refunded.';
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
// With onClose it has an X top right (SOLAR-516).
function Dialog({ label, onClose, keep = false, busy = false, size = null, children }) {
  const ref = React.useRef(null);
  // What had focus, read at first render before a child takes it, and whether it showed a ring
  // (a keyboard user): only then does it get one back on close.
  const [back] = React.useState(() => ({ el: document.activeElement, ring: !!document.activeElement?.matches?.(':focus-visible') }));
  React.useEffect(() => {
    const d = ref.current;
    d.showModal();
    // Opened by mouse or touch: Chrome still rings the button showModal or the content focuses
    // (ConfirmCard focuses Cancel), so the pop-up holds focus itself; Tab goes to that button
    // next. Keyboard users keep the ring. After the content's own effects (SOLAR-368).
    const t = setTimeout(() => {
      const a = document.activeElement;
      if (!back.ring && d.open && d.contains(a) && a !== d && a.matches(':focus-visible')) d.focus({ preventScroll: true });
    });
    return () => { clearTimeout(t); if (d.open) d.close(); if (back.el && back.el.isConnected) back.el.focus({ preventScroll: true, focusVisible: back.ring }); };
  }, []);
  // A phone's keyboard covers the page without shrinking it, so the page scrolls again under
  // an open pop-up whatever CSS says (SOLAR-521). A swipe moves only what scrolls inside a
  // pop-up; a pinch and a drag of selected text in a field are left alone.
  React.useEffect(() => {
    const block = (e) => {
      const at = e.target, sel = at.selectionStart != null && at.selectionStart !== at.selectionEnd;
      if (e.touches.length > 1 || sel) return;
      for (let el = at; el && el !== document.documentElement; el = el.parentElement) {
        if (el.scrollHeight > el.clientHeight + 1 && /auto|scroll/.test(getComputedStyle(el).overflowY) && el.closest('dialog[open]')) return;
      }
      e.preventDefault();
    };
    document.addEventListener('touchmove', block, { passive: false });
    return () => document.removeEventListener('touchmove', block);
  }, []);
  // Closing (SOLAR-351): the dialog goes with whatever held it, so its content moves to a
  // copy that fades out on top for --dur-fast. Runs before React removes the dialog.
  React.useLayoutEffect(() => () => {
    const d = ref.current, ms = window.motionMs('--dur-fast');
    if (!ms || !d?.open || !d.showPopover) return;
    const g = document.createElement('div');
    g.className = d.className + ' leaving';
    g.popover = 'manual'; g.inert = true;
    g.append(...d.childNodes);
    document.body.append(g);
    g.showPopover();
    setTimeout(() => g.remove(), ms);
  }, []);
  return (
    <dialog ref={ref} tabIndex={-1} className={'pop-dlg' + (size ? ' pop-' + size : '')} aria-label={label}
            onCancel={(e) => { e.preventDefault(); if (!busy && e.target === ref.current) onClose(); }}   // only its own Escape, not one from a pop-up opened over it
            onClick={(e) => { if (!keep && !busy && e.target === ref.current) onClose(); }}>
      <div className="pop-body">{children}</div>
      {/* Only a pop-up that can close has the X (SOLAR-516). After the body, so first focus
          stays where each pop-up puts it; CSS draws it on top. */}
      {onClose && <button type="button" className="pop-x" aria-label="Close" disabled={busy} onClick={onClose}><Icon id="close" /></button>}
    </dialog>
  );
}
window.Dialog = Dialog;

// The saved card is charged without Paystack's page, so the amount, the next bill and the
// card are shown first (SOLAR-276). Centred on a desktop, from the bottom on a phone.
// parts: the lines the bill is made of, before it, as [label, amount] (SOLAR-369).
function PayReview({ title, note, due, parts = [], then, card, onDone }) {
  return (
    <Dialog label={title} onClose={() => onDone(false)}>
      <h2 id="pay-review-t" className="pay-review-t">{title}</h2>
      {note && <p className="field-note">{note}</p>}
      <div className="pay-review-due"><span>Due today</span><b>{rand(due)}</b></div>
      <div className="pay-review-box">
        {parts.map(([k, v]) => <div key={k} className="pay-review-ln"><span>{k}</span><b>{v}</b></div>)}
        <div className={'pay-review-ln' + (parts.length ? ' pay-review-sum' : '')}><span>{then[0]}</span><b>{then[1]}</b></div>
        <div className="pay-review-ln"><span>Card</span><b className="pay-review-card">{card}</b></div>
      </div>
      <div className="pay-review-acts">
        <button type="button" className="ghost-btn" onClick={() => onDone(false)}>Cancel</button>
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
  // Extra plants are no longer sold (SOLAR-371); those already held stay on the bill.
  const extra = plan === 'family' ? q.extraPlants || 0 : 0;
  // A switch to yearly (SOLAR-298) is paid now and starts on the billing date.
  const title = q.switch ? 'Switch to yearly' : `Upgrade to ${name}`;
  // The bill's parts (SOLAR-369): Family alone, then the extra plants held. Not on a switch,
  // whose bill is yearly while extraPrice is the plan's monthly one.
  // extraPrice is today's offer; a next bill at list prices (the offer over by then) takes the list one.
  const each = q.listCharge != null && q.nextCharge === q.listCharge ? q.listExtraPrice ?? q.extraPrice : q.extraPrice;
  const parts = extra > 0 && !q.switch && each != null
    ? [['Family, 5 plants', rand(q.nextCharge - extra * each)], [`Extra plants, ${extra} × ${rand(each)}`, rand(extra * each)]] : [];
  const when = q.switch ? `Your year starts ${billDay(q.startsOn)}.` : q.credit != null ? `Your year starts today, with ${rand(q.credit)} off for the rest of this month.` : null;
  const ok = await new Promise(resolve => {
    let close;
    const done = (yes) => { close(); resolve(yes); };
    close = mountNode(<PayReview title={title} note={when} due={q.dueNow} parts={parts} card={`${b.card.name} •••• ${b.card.last4}`}
      then={[`Your bill from ${billDay(q.nextDate)}`, `${rand(q.nextCharge)} ${perUnit(q.switch ? 'yearly' : q.period || period)}`]} onDone={done} />);
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
    // Billing as it was before Pay, for payLanded; read while the charge starts.
    const before = billingRpc('api_billing_status').then(x => x.data).catch(() => null);
    try {
      r = await billingCall('pay', { plan, period, newCard, extras, plants }, PAY_WAIT)
        .catch(e => (e.message === 'timed out' ? payLanded(before) : Promise.reject(e)));
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
    else window.toast('Your payment is still being checked. Look again in a minute.', { info: true });
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
  if (done === 'paid') {
    window.toast('Payment received. Your plan is updated.');
    // a bigger plan may have places open for locked plants: PickAfterPay asks which run (SOLAR-537)
    window.pickAsked = true; window.dispatchEvent(new Event('ps-pick'));
    return;
  }
  // The event a card-page payment was opened with: sent only if it was paid.
  let paidEvent = null;
  try { paidEvent = JSON.parse(sessionStorage.getItem(PAID_EVENT)); sessionStorage.removeItem(PAID_EVENT); } catch (e) {}
  try {
    const { status, kind } = await billingCall('verify', { reference: ref });
    // A card change changes no plan: the caller re-reads the card ('card').
    if (status === 'paid' && kind === 'card') {
      window.track('card_change_done');
      window.toast('Card changed. The R1 check goes back to your card.');
      return 'card';
    }
    // A full reload: resumed plants join the plant list.
    if (status === 'paid') { if (paidEvent) window.track(paidEvent.name, paidEvent.props); return billingPaid(null, kind === 'switch'); }
    if (status === 'refund') return window.toast(REFUND_NOTE, { error: true });
    window.toast(status === 'failed' ? 'The payment didn’t go through. Nothing was charged.' : 'Your payment is still being checked. Look again in a minute.', status === 'failed' ? { error: true } : { info: true });
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

// "Add your plant" in the emails: ?add=plant (SOLAR-473), kept through sign-in with the
// rest of an email's link (auth.jsx). Setup opens its Add plant form, App its Billing Plants
// section with Add plant open; whichever opens it takes it out of the address, so it opens once.
window.addAsked = () => new URLSearchParams(location.search).get('add') === 'plant';
window.takeAddAsk = () => { const r = window.addAsked(); if (r) dropFromAddress(['add']); return r; };

// The same moment on the Connect screen and inside Settings; one wording for both.
const NO_PLANT_TEXT = 'has no plant shared with it yet. Your login is saved.';

// One form for a SunSynk login, built from the app's own Settings parts (SOLAR-96).
// `compact`: inside Account's SunSynk logins section (Add plant, Reconnect). Otherwise the
// The pick itself: plants under their login's email, as Plants lays them out; a circle each
// when exactly 1 must be picked, else a tick box. Past the room it says so; the last tick
// stays unless min is 0. Both lines in amber: they need reading, but nothing failed.
// Two uses. The plants a cancel or smaller plan keeps (SOLAR-496): links, plan, keep (the
// label and undo of "keep the plan as it is"). The plants a login adds (SOLAR-537): logins
// (the plants to choose from), ask and full (its two lines), min 0, verb 'Add'.
function KeepPicker({ links, plan, room, value, onChange, keep, logins, ask, full, min = 1, verb = 'Keep' }) {
  const [say, setSay] = React.useState(null); // 'last' | 'full'
  const one = room === 1 && min > 0;
  const tick = (id) => {
    setSay(null);
    if (one) return onChange([id]);
    if (value.includes(id)) return value.length <= min ? setSay('last') : onChange(value.filter(x => x !== id));
    if (value.length >= room) return setSay('full');
    onChange([...value, id]);
  };
  const left = room - value.length;
  return (
    <div className="keep-pick">
      <div className="confirm-text keep-ask">{ask || `${PLAN_NAME[plan]} keeps ${one ? '1 plant. Which one?' : `${room} plants. Which ones?`}`}</div>
      {(logins || pickableLogins(links)).map(acc => (
        <div key={acc.account_id} className="login-grp plant-logins">
          <div className="login-line"><div className="login-who"><span className="login-email">{acc.kind === 'share' ? 'Shared plants' : acc.sunsynk_username}</span></div></div>
          {acc.plants.map(p => {
            const name = window.plantLabel(p), on = value.includes(p.plant_id);
            return (
              <label key={p.plant_id} className={'login-plant keep-row' + (on ? '' : ' off')}>
                <span className="conn-user plant-nm">{name}</span>
                <input type={one ? 'radio' : 'checkbox'} name="keep-pick" checked={on} aria-label={verb + ' ' + name} onChange={() => tick(p.plant_id)} />{/* reuse-check: allow: tick boxes, not switches, for the keep pick (SOLAR-486) */}
              </label>
            );
          })}
        </div>
      ))}
      {say === 'last' ? <div className="field-note keep-count warn">At least one plant needs to be selected.</div>
        : say === 'full' ? <div className="field-note keep-count warn">{full || <>{PLAN_NAME[plan]} keeps {room} plants. Untick one first{keep ? <>, or <button type="button" className="mini-link" onClick={keep.run}>{keep.label}</button></> : ''}.</>}</div>
        : !one && <div className="field-note keep-count">{value.length} of {room} ticked.{min > 0 && left > 0 && ` Tick ${left} more.`}</div>}
    </div>
  );
}

// The plants of the logins given that are locked and have a place open (api_link_status
// can_start), under their logins. only: keep just these plant ids.
const startableLogins = (accounts, only) => {
  const seen = new Set();
  return (accounts || []).filter(a => a.status !== 'disabled').map(a => ({ ...a,
    plants: (a.plants || []).filter(p => p.can_start && (!only || only.has(Number(p.plant_id))) && !seen.has(p.plant_id) && seen.add(p.plant_id)) }))
    .filter(a => a.plants.length);
};
// The owner ticks which locked plants run (SOLAR-537, 0197), up to the places the plan has
// open, after a login links. Fewer ticks is fine: the rest
// stay locked and an open place can be filled later. A tick stays, so the pop-up says what
// changing it costs. Asks the server for the places (api_plant_picks) before it shows. With
// one plant to choose and a place for it, it shows nothing and starts that plant.
// onDone(ids): the plants now running; [] when closed with none.
function PlantPickDialog({ logins, from, onDone }) {
  const { useState, useEffect } = React;
  const all = logins.flatMap(a => a.plants);
  const [places, setPlaces] = useState(null); // { plan, open }
  const [picked, setPicked] = useState([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let alive = true;
    window.sb.rpc('api_plant_picks').then(({ data, error }) => {
      if (!alive) return;
      if (error || !data) { window.toast('Couldn’t load your plan. Try again.', { error: true }); return onDone([]); }
      // a place for each: one not held, and for a plant never ticked, one more tick the plan allows
      const open = Math.min(all.length, data.room - data.picks.filter(k => k.held).length,
        data.room - data.picks.length + all.filter(p => p.picked).length);
      if (open < 1) return onDone([]);
      // one plant and a place for it: nothing to choose, so it starts with no pop-up
      if (all.length === 1) {
        return window.sb.rpc('api_plant_pick', { p_plants: [all[0].plant_id] }).then(({ error }) => {
          if (!error) window.track('plant_pick_done', { from, count: 1, of: 1, plan: data.plan, asked: false });
          if (alive) onDone(error ? [] : [all[0].plant_id]);
        });
      }
      setPlaces({ plan: data.plan, open });
      // they all fit: ticked already, one tap to add
      if (all.length <= open) setPicked(all.map(p => p.plant_id));
    });
    return () => { alive = false; };
  }, []);
  if (!places) return null;
  const { plan, open } = places;
  const add = async () => {
    if (!picked.length) return onDone([]);
    setBusy(true);
    const { error } = await window.sb.rpc('api_plant_pick', { p_plants: picked });
    setBusy(false);
    if (error) return window.toast(payFirst(error) || (/no room/.test(error.message) ? 'Your plan has no place open for that.' : 'Couldn’t add your plants. Try again.'), { error: true });
    window.track('plant_pick_done', { from, count: picked.length, of: all.length, plan });
    onDone(picked);
  };
  const more = open === 1 ? '1 more plant' : open + ' more plants';
  return (
    <Dialog keep label="Choose plants" busy={busy} onClose={() => onDone([])}>
      <div className="confirm-title">Choose plants</div>
      <KeepPicker logins={logins} room={open} value={picked} onChange={setPicked} min={0} verb="Add"
        ask={`${PLAN_NAME[plan]} has room for ${more}.${all.length > open ? (open === 1 ? ' Which one?' : ' Which ones?') : ''}`}
        full={`${PLAN_NAME[plan]} has room for ${more}. Untick one first.`} />
      <div className="confirm-text keep-note">After this you can change one plant every 90 days.</div>
      <div className="conn-form-actions">
        <button type="button" className="ghost-btn" onClick={() => onDone([])} disabled={busy}>Not now</button>
        <window.BusyButton className="save-btn" onClick={add} busy={busy} disabled={!picked.length}>{picked.length > 1 ? 'Add plants' : 'Add plant'}</window.BusyButton>
      </div>
    </Dialog>
  );
}
window.PlantPickDialog = PlantPickDialog;
// After a payment (billingReturn): the pick pop-up, when a locked plant has a place open.
// With no place open there is nothing to choose, so nothing shows. onDone(r): the plants now
// running, in link-sunsynk's shape. In Settings, where a payment comes back to.
function PickAfterPay({ links, onDone }) {
  const [ask, setAsk] = React.useState(() => !!window.pickAsked);
  React.useEffect(() => {
    const on = () => setAsk(true);
    window.addEventListener('ps-pick', on);
    return () => window.removeEventListener('ps-pick', on);
  }, []);
  const logins = ask && !links.loading ? startableLogins(links.accounts) : [];
  const close = () => { window.pickAsked = false; setAsk(false); };
  React.useEffect(() => { if (ask && !links.loading && !logins.length) close(); });
  if (!logins.length) return null;
  return <PlantPickDialog logins={logins} from="upgrade" onDone={(ids) => { close(); if (ids.length) onDone({ plants: ids.map(id => ({ id })), paused: [] }); }} />;
}
window.PickAfterPay = PickAfterPay;

// Connect card that opens in place on a page with no inverter yet (Setup), with its title.
// Either way: one line on which login, the two fields, a note, then Cancel and the green
// button at the right.
function LinkForm({ relink, changing, onLinked, compact, onCancel, initialUsername }) {
  const { useState, useEffect, useRef } = React;
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
  // 'share': no password, the owner shares the plant to us in SunSynk (SOLAR-310).
  const [mode, setMode] = useState('login');
  const [ref, setRef] = useState('');
  // A plant someone else has: its id, for the line on how to get it back.
  const [taken, setTaken] = useState(null);
  const share = mode === 'share' && !relink;
  // The plants a link brought that are locked with a place open: the owner ticks which run
  // (SOLAR-537). { logins, done }: the pop-up is up; done(ids) carries on with the plants ticked.
  const [pick, setPick] = useState(null);
  const linked = async (r) => {
    // not after Reconnect or a new password: no login was added
    const locked = new Set((relink ? [] : r.paused || []).map(Number));
    const { data } = locked.size ? await window.sb.rpc('api_link_status') : {};
    const logins = startableLogins(data, locked);
    if (!logins.length) return onLinked(r);
    const on = await new Promise(done => setPick({ logins, done }));
    setPick(null);
    return onLinked({ ...r, paused: (r.paused || []).filter(id => !on.includes(Number(id))) });
  };

  const check = async () => {
    if (!ref.trim()) return flag({ 'ss-ref': 'Enter a plant ID or serial' });
    setBusy(true); setBad({}); setTaken(null);
    try {
      await linked(await window.claimShare(ref.trim()));
    } catch (ex) {
      if (ex.taken) setTaken(ex.taken);
      else if (ex.field) flag({ 'ss-ref': ex.message });
      else fail(ex instanceof TypeError ? 'Can’t reach Prince Solar Hub. Check your connection and try again.' : ex.message);
    } finally {
      setBusy(false);
    }
  };

  const submit = async (e) => {
    e?.preventDefault();
    if (share) return check();
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
      // Busy until the caller has the new login list, or the screen sits idle before it changes.
      await linked(r);
      setPassword(''); setNoPlants(false);
    } catch (ex) {
      fail(ex instanceof TypeError ? 'Can’t reach Prince Solar Hub. Check your connection and try again.' : ex.message);
    } finally {
      clearTimeout(findTimer.current); setFinding(false);
      setBusy(false);
    }
  };

  const invalid = (id) => window.invalidProps(id, bad[id]);
  const green = share ? (busy ? 'Checking…' : 'Check') : noPlants ? (busy ? 'Checking…' : 'Retry now')
    : busy ? (finding ? 'Finding your plant…' : 'Checking your login…')
    : relink ? (changing ? 'Save password' : 'Reconnect') : compact ? 'Add plant' : 'Connect';

  return (
    <form className={compact ? 'conn-form link-form' : 'link-form link-card'} onSubmit={submit} noValidate aria-busy={busy}>
      {pick && <PlantPickDialog logins={pick.logins} from="link" onDone={pick.done} />}
      {!compact && <h2 className="sset-title">{noPlants ? 'Connected, but no plant yet' : relink ? 'Reconnect SunSynk' : 'Add your plant'}</h2>}
      {!relink && !noPlants && (
        <window.Segmented block label="How to add it" className="link-mode" value={mode}
          onChange={(m) => { setMode(m); setBad({}); setTaken(null); window.track('link_mode_picked', { mode: m }); }}
          options={[{ value: 'login', label: 'SunSynk login' }, { value: 'share', label: 'Share plant' }]} />
      )}
      {share ? (<>
        <p className="sset-note">No password needed. In the SunSynk Connect app, share your plant with <b>{SHARE_TO}</b> as Visitor.</p>
        <div className="field link-last">
          <window.FieldLabel id="ss-ref" label="Plant ID or inverter serial" error={bad['ss-ref']} />
          <input id="ss-ref" className="input" type="text" inputMode="text" autoComplete="off" placeholder="123456" value={ref}
                 onChange={(e) => { setRef(e.target.value); edited('ss-ref'); setTaken(null); }} {...invalid('ss-ref')} />
        </div>
        {taken ? (
          <div className="field-note link-note" role="alert">
            {taken} is linked to another account. If it’s yours, remove the share in SunSynk, wait 2 hours, share it again and press Check.
            {' '}Or <a className="mini-link" href={`mailto:hello@princesolarhub.co.za?subject=${encodeURIComponent(`${taken} is linked to another account`)}`}
                     onClick={() => window.track('share_taken_email_done')}>email us</a>.
          </div>
        ) : (
          <div className="field-note link-note">Only the person who created the plant in SunSynk can share it. Installer set it up? Ask them or SunSynk support to share it.</div>
        )}
      </>) : noPlants ? (
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
        {!compact && <div className="field-note link-note">Disconnect any time in Plants.</div>}
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

// The link form over the page, as Add plant and Reconnect open it. Closing it is
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
