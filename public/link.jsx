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
    const attempt = () => withTimeout(window.sb.rpc('api_logins'), 10000).catch(e => ({ data: null, error: e }));
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
  // one SunSynk login with no plan (0203)
  'one login': window.AccountText.logins.oneLogin,
  'no plan': window.AccountText.logins.noLoginEnded,
};


// ---- Account and billing (SOLAR-641) -------------------------------------------
// Every line about plans, chosen plants, prices, billing, the free week and history comes
// from the text catalog (window.AccountText, made from supabase/functions/_shared/text.ts),
// filled from the account's state (api_account_state, 0247). Nothing here works out a count,
// a price, a plan name or a date. AT is shared with the later files (one global scope).
const AT = window.AccountText;

// The account's state, read once and shared by every screen. reloadAccount() reads it again
// and tells them (ps-account). useAccount(): null until the first read lands.
let acctNow = null, acctLoad = null;
window.reloadAccount = () => acctLoad || (acctLoad = window.fetchAccountState()
  // _got: when it landed, so a timer set from the server's clock (a.at) can allow for the trip
  .then(a => { if (a) a._got = Date.now(); acctNow = a; window.dispatchEvent(new Event('ps-account')); return a; })
  .finally(() => { acctLoad = null; }));
window.accountNow = () => acctNow;
// the read on its way, if any (it may have started before a change the caller knows about)
window.accountLoading = () => acctLoad;
window.useAccount = function useAccount() {
  const [a, setA] = React.useState(acctNow);
  React.useEffect(() => {
    const on = () => setA(acctNow);
    window.addEventListener('ps-account', on);
    if (acctNow) setA(acctNow); else window.reloadAccount().catch(() => {});
    return () => window.removeEventListener('ps-account', on);
  }, []);
  return a;
};
window.sb.auth.onAuthStateChange((event) => { if (event === 'SIGNED_OUT') acctNow = null; });
// A read started now, not one already on its way (it may have started before a change).
const freshAccount = async () => { await acctLoad?.catch(() => {}); return window.reloadAccount(); };

// An unpaid renewal (SOLAR-644): the account is read again, signed in on any page, while its
// screens can change without the owner doing anything. A hidden tab asks nothing and reads
// again on coming back; a failed read is tried again on the next tick.
//   - a renewal payment may still land (renewal_in_flight, or Billing's checking note): every 15 s;
//   - after the cutoff, a card page Paystack hasn't answered (held_reference; the plan runs on
//     for up to a day meanwhile): asked once a minute, and the account read at once when it settles;
//   - past due: when the plan's end passes (from the server's clock), then every 60 s until a
//     read says it ended, so no page keeps a pay button after readings stop.
const inFlight = (a) => !!a && (a.renewal_in_flight || (a.state === 'past_due' && a.past_due_reason === 'checking'));
// Billing shows a "still checking" note instead of a pay button: the bank is answering a
// saved-card try, or a payment made before the cutoff is still being checked past it. (Before
// the cutoff a card page still being answered changes no screen: Pay reopens it.)
const heldNote = (a) => !!a && a.state === 'past_due' && a.past_due_reason === 'checking';
const readNow = () => { if (!document.hidden) freshAccount().catch(() => {}); };
window.useAccountWatch = function useAccountWatch(acct) {
  const fast = inFlight(acct), held = acct?.held_reference || null;
  const pastDue = acct?.state === 'past_due' && !!acct.plan_ends_at;
  // a plant's old history being deleted: read again each minute until it's gone (SOLAR-659)
  const deleting = !!acct?.plants?.some(p => p.deleting);
  React.useEffect(() => {
    if (!fast && !held && !pastDue) return;
    document.addEventListener('visibilitychange', readNow);
    const t = fast && setInterval(readNow, 15000);
    return () => { document.removeEventListener('visibilitychange', readNow); clearInterval(t); };
  }, [fast, !!held, pastDue]);
  // its own timer: the 15 s reads must not keep restarting it
  React.useEffect(() => {
    if (!held) return;
    const h = setInterval(() => {
      if (document.hidden) return;
      billingCall('verify', { reference: held }).then(v => {
        if (!SETTLED.includes(v.status)) return;
        if (v.status === 'applied') renewalPaid(held, v);
        freshAccount().catch(() => {});
      }).catch(() => {});
    }, 60000);
    return () => clearInterval(h);
  }, [held]);
  React.useEffect(() => {
    if (!deleting) return;
    const d = setInterval(readNow, 60000);
    return () => clearInterval(d);
  }, [deleting]);
  // set again from each read: the time left comes from the server's clock, so a new read only corrects it
  React.useEffect(() => {
    if (!pastDue) return;
    const left = Date.parse(acct.plan_ends_at) - Date.parse(acct.at || new Date().toISOString()) - (Date.now() - (acct._got || Date.now()));
    // then every minute, so a failed read (acct unchanged, no new effect) is tried again
    let i = null;
    const c = setTimeout(() => { readNow(); i = setInterval(readNow, 60000); }, left > 0 ? left + 1000 : 60000);
    return () => { clearTimeout(c); clearInterval(i); };
  }, [pastDue, acct]);
};

// Paystack (the billing function). A saved card is charged at once; otherwise, or after the
// saved card is declined, Paystack's card page opens and comes back with ?reference=, which
// billingReturn checks.
const billingCall = async (route, body, ms = 30000) => {
  // a payment that hasn't started in 30 s says so (SOLAR-294)
  const [res, out] = await edgePost('billing/' + route, body, AbortSignal.timeout(ms))
    .catch(e => { throw new Error(/abort|timeout/i.test(e.name) ? 'timed out' : e.message); });
  if (!res.ok) throw new Error(out.error || 'payment failed');
  return out;
};
window.billingCall = billingCall;
// Billing's Plan section, on the plant the user was looking at.
const planUrl = (extra = '') => {
  const plant = new URLSearchParams(location.search).get('plant');
  return `${location.pathname}?tab=billing&section=plan${plant ? `&plant=${encodeURIComponent(plant)}` : ''}${extra}`;
};
const billingPaid = () => location.assign(planUrl('&billing=paid'));
// The toast for a payment or a change that failed, in the catalog's words.
const payFailed = (e, fallback = AT.pay.startFailed) => {
  const t = AT.refused(e?.message || '');
  window.toast(t === AT.refused('') ? fallback : t, /open soon/.test(e?.message || '') ? { info: true } : { error: true });
};
window.payFailed = payFailed;
// A saved card's charge: the billing function gives Paystack 30 s to charge and 30 s more to
// check, so the page waits past both (SOLAR-363).
const PAY_WAIT = 70000;
// Still no answer: the charge may land later, so read the account every 5 s for a minute. A
// plan that moved since the Pay tap is paid; otherwise it's still being checked.
const acctSig = (a) => (a ? [a.state, a.plan, a.interval, a.places, a.next_plan, a.next_interval].join('|') : null);
const payLanded = async (beforeP) => {
  const was = acctSig(await beforeP);
  for (let i = 0; was && i < 12; i++) {
    await new Promise(res => setTimeout(res, 5000));
    const a = await window.fetchAccountState().catch(() => null);
    if (a && acctSig(a) !== was) return { status: 'applied' };
  }
  return { status: 'pending' };
};
// While a payment step runs, a small pop-up says so, so a slow one never looks frozen (SOLAR-294).
// It has no close: every step ends, the slowest after about 2 minutes. Returns the function that closes it.
const working = (text) => mountNode(<Dialog busy label={text}><div className="pop-wait" role="status"><span className="spin" aria-hidden="true" />{text}</div></Dialog>);
// One payment at a time: a second click while one is open does nothing.
let paying = false;
// paidEvent: { name, props } sent once the money is taken, here or back from the card page (SOLAR-268).
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
// card are shown first (SOLAR-276). r: AccountText.quoteReview's lines; card: the saved card.
function PayReview({ r, card, onDone }) {
  return (
    <Dialog label={r.title} onClose={() => onDone(false)}>
      <h2 id="pay-review-t" className="pay-review-t">{r.title}</h2>
      {r.due != null && <div className="pay-review-due"><span>{AT.pay.dueToday}</span><b>{r.due}</b></div>}
      <div className="pay-review-box">
        {r.lines.map(l => <div key={l} className="pay-review-ln"><span>{l}</span></div>)}
        {card && <div className="pay-review-ln"><span>{AT.pay.card}</span><b className="pay-review-card">{card}</b></div>}
      </div>
      <div className="pay-review-acts">
        <button type="button" className="ghost-btn" onClick={() => onDone(false)}>{AT.pay.cancel}</button>
        <button type="button" className="save-btn" onClick={() => onDone(true)}>{r.button}</button>
      </div>
    </Dialog>
  );
}
window.PayReview = PayReview;
// Shown over the page; true: go on.
const askReview = (r, card) => new Promise(resolve => {
  let close;
  const done = (yes) => { close(); resolve(yes); };
  close = mountNode(<PayReview r={r} card={card} onDone={done} />);
});

// A first plan, a restart or an upgrade. plants: the final choice (the checkout asked for it
// first). The price comes from the server's quote; with a saved card it is shown before the
// charge. paidEvent: sent once paid.
window.startPlan = async function startPlan(acct, plan, interval, plants, { newCard = false, paidEvent = null } = {}) {
  if (paying) return;
  paying = true;
  try {
    const stop0 = working(AT.pay.checking);
    let q;
    try { q = await window.fetchPlanQuote(plan, interval); } finally { stop0(); }
    const saved = !!acct.card && !newCard;
    if (saved) {
      const ok = await askReview(AT.quoteReview(acct, q), AT.cardLine(acct));
      window.track('pay_review_done', { plan, choice: ok ? 'pay' : 'cancel' });
      if (!ok) return;
    }
    const stop = working(saved ? AT.pay.taking : AT.pay.opening);
    const before = window.fetchAccountState().catch(() => null);
    let r;
    try {
      r = await billingCall('pay', { plan, period: interval, plants, newCard: !saved }, PAY_WAIT)
        .catch(e => (e.message === 'timed out' ? payLanded(before) : Promise.reject(e)));
      if (r.status === 'failed') {
        window.toast(AT.pay.declined, { error: true });
        r = await billingCall('pay', { plan, period: interval, plants, newCard: true });
      }
    } finally { if (!r?.url && r?.status !== 'applied') stop(); }   // a new page is on its way: keep it up
    if (r.url) {
      window.track('checkout_opened', { plan, period: interval });
      try { paidEvent ? sessionStorage.setItem(PAID_EVENT, JSON.stringify(paidEvent)) : sessionStorage.removeItem(PAID_EVENT); } catch (e) {}
      openCardPage(r);
    } else if (r.status === 'applied' && r.renewal) {
      // a renewal paid before the plan ended landed: the plan is back, nothing new started
      const a = await freshAccount().catch(() => null);
      renewalPaid(r.reference, { plan: a?.plan, period: a?.interval });
      billingPaid();
    } else if (r.status === 'applied') {
      window.track(q.kind === 'upgrade' ? 'upgrade_done' : 'plan_start_done', { plan, period: interval });
      if (paidEvent) window.track(paidEvent.name, paidEvent.props);
      billingPaid();
    } else if (r.status === 'refund') window.toast(AT.pay.refund, { error: true });
    else window.toast(AT.pay.pending, { info: true });
  } catch (e) {
    if (!(await inProgress(e))) payFailed(e);
  } finally {
    paying = false;
  }
};

// Billing's Plan section, from any page: the address, so the page that opens it reads it.
// text: a toast to show there; a page load would drop it, so it is kept for that load.
const CARRY_TOAST = 'ps.carryToast';
const toBilling = (text) => {
  if (new URLSearchParams(location.search).get('tab') === 'billing') { if (text) window.toast(text, { error: true }); return; }
  try { if (text) sessionStorage.setItem(CARRY_TOAST, text); } catch (e) {}
  location.assign(planUrl());
};
// The server's "a payment is already in progress" (409): a renewal the bank is still answering
// shows its note in Billing; anything else says so here. True when it was that refusal.
const inProgress = async (e) => {
  if (!/already in progress/i.test(e?.message || '')) return false;
  const a = await freshAccount().catch(() => null);
  if (heldNote(a)) toBilling(); else window.toast(AT.pay.inProgress, { error: true });
  return true;
};
// Pay an unpaid renewal with another card. bill: the bill an email names, else the one due now.
window.settlePayment = async function settlePayment(bill) {
  if (paying) return;
  paying = true;
  const stop = working(AT.pay.opening);
  try {
    // another card: the saved one is not charged again (it just failed)
    const r = await billingCall('pay', { settle: true, newCard: true, ...(bill ? { bill } : {}) });
    if (r.url) openCardPage(r); else { stop(); if (r.status === 'applied') billingPaid(); else window.toast(AT.pay.pending, { info: true }); }
  } catch (e) {
    stop();
    if (await inProgress(e)) return;
    // paid already or no longer due: Billing shows how things stand, with the reason
    if (/already been made|no longer due/i.test(e?.message || '')) { freshAccount().catch(() => {}); return toBilling(AT.refused(e.message)); }
    payFailed(e, AT.pay.cardFailed);
  } finally {
    paying = false;
  }
};

// Change the saved card (SOLAR-238): the market's smallest charge on Paystack's card page,
// refunded once the card is saved. Comes back through billingReturn like any card-page payment.
window.changeCard = async function changeCard() {
  const stop = working(AT.pay.opening);
  try {
    const r = await billingCall('pay', { card: true });
    openCardPage(r);
  } catch (e) {
    stop();
    payFailed(e, AT.pay.cardFailed);
  }
};

// A change booked for the billing date (downgrade, interval, cancel) or its undo, through the
// billing function. Answers the new state, or null after a toast.
window.bookChange = async function bookChange(body, event) {
  try {
    await billingCall('change', body);
    if (event) window.track(event.name, event.props);
    return await window.reloadAccount();
  } catch (e) {
    payFailed(e, AT.refused(''));
    window.reloadAccount().catch(() => {});
    return null;
  }
};

// The card-page payment to check on this page load: back from Paystack (?reference=), or a
// card page closed without paying (OPEN_REF). SignedIn waits for it before reading the
// plan, the plants and the pay screen, so a paid one shows on this load, not after a
// second (SOLAR-579). Once per page; null when there is none.
let returnCheck = null;
// A payment's end: kept until then, so a reload checks it again.
const SETTLED = ['applied', 'failed', 'void', 'refund'];
const checkRef = async (ref) => {
  // not this user's (another account signed in on this tab): forgotten, nothing said
  const v = await billingCall('verify', { reference: ref }).catch(e => ({ status: /unknown reference/.test(e.message) ? 'unknown' : 'error' }));
  try {
    // only this reference's own slot: a newer card page opened meanwhile keeps its own
    const kept = sessionStorage.getItem(OPEN_REF);
    if (SETTLED.includes(v.status) || v.status === 'unknown') { if (kept === ref) sessionStorage.removeItem(OPEN_REF); }
    else if (!kept) sessionStorage.setItem(OPEN_REF, ref);
  } catch (e) {}
  return { ...v, reference: ref };
};
window.checkReturn = () => returnCheck || (returnCheck = (async () => {
  const q = new URLSearchParams(location.search);
  let open = null;
  try { open = sessionStorage.getItem(OPEN_REF); } catch (e) {}
  const ref = q.get('reference') || (!q.get('billing') && !q.get('pay') ? open : null);
  return ref ? checkRef(ref) : null;
})());
// renewal_paid_done (SOLAR-644): once per payment, whichever check saw it applied first.
const PAID_REFS = 'ps.renewalPaid';
const renewalPaid = (ref, v) => {
  let seen = [];
  try { seen = JSON.parse(localStorage.getItem(PAID_REFS)) || []; } catch (e) {}
  if (!ref || seen.includes(ref)) return;
  try { localStorage.setItem(PAID_REFS, JSON.stringify([...seen, ref].slice(-200))); } catch (e) {}
  window.track('renewal_paid_done', { plan: v?.plan ?? null, period: v?.period ?? null });
};
const paidNow = (text = AT.pay.received) => {
  window.toast(text);
  // a bigger plan may have places open for locked plants: PickAfterPay asks which are read
  window.pickAsked = true; window.dispatchEvent(new Event('ps-pick'));
};

// Once, when Settings opens: back from Paystack's card page (?reference=), after a
// payment (?billing=paid), or from the "Pay with another card" email (?pay=1). Also once
// on any other page, for a card page closed without paying (OPEN_REF).
window.billingReturn = async function billingReturn(acct) {
  const q = new URLSearchParams(location.search);
  const done = q.get('billing'), pay = q.get('pay');
  try { const t = sessionStorage.getItem(CARRY_TOAST); sessionStorage.removeItem(CARRY_TOAST); if (t) window.toast(t, { error: true }); } catch (e) {}
  const check = await window.checkReturn();
  returnCheck = Promise.resolve(null);
  if (!check && !done && !pay) return;
  if (q.get('reference') || done || pay) history.replaceState(null, '', planUrl());
  if (pay) {
    // an email's bill (?pay=<bill id>); an older email's ?pay=1 just opens Billing. A renewal the
    // bank is still answering shows its note here instead.
    const bill = /^[0-9a-f-]{36}$/i.test(pay) ? pay : null;
    // the server says if it is paid or no longer due
    if (bill && !heldNote(acct)) await window.settlePayment(bill);
    return;
  }
  if (done === 'paid') return paidNow();
  // The event a card-page payment was opened with: sent only if it was paid.
  let paidEvent = null;
  // kept while the result is unknown, so a reload during the check still sends it
  try { paidEvent = JSON.parse(sessionStorage.getItem(PAID_EVENT)); if (SETTLED.includes(check.status)) sessionStorage.removeItem(PAID_EVENT); } catch (e) {}
  return payResult(check, paidEvent);
};
// What a checked card-page payment says. Still being checked: asked again every 5 s for a
// minute, then a Check again button; no answer from Paystack: Check again too.
async function payResult(v, paidEvent = null, polled = false) {
  const { status, kind } = v;
  if (SETTLED.includes(status)) try { sessionStorage.removeItem(PAID_EVENT); } catch (e) {}
  const again = () => { window.toast(AT.pay.pending, { info: true, sticky: true }); checkRef(v.reference).then(r => payResult(r, paidEvent, true)); };
  // A card change changes no plan: the caller re-reads the card ('card').
  if (status === 'unknown') return;
  if (status === 'applied' && kind === 'card_check') {
    window.track('card_change_done');
    window.toast(AT.pay.cardChanged);
    if (polled) freshAccount().catch(() => {});   // the first check's caller reads the card itself
    return 'card';
  }
  if (status === 'applied') {
    if (paidEvent) window.track(paidEvent.name, paidEvent.props);
    if (kind === 'renewal') renewalPaid(v.reference, v);
    else window.track(kind === 'upgrade' ? 'upgrade_done' : 'plan_start_done', {});
    freshAccount().catch(() => {});   // Billing's red note goes
    return paidNow(AT.paidText(v));
  }
  if (status === 'refund') return window.toast(AT.pay.refund, { error: true });
  if (status === 'failed') return window.toast(AT.pay.failed, { error: true });
  if (status === 'void') return window.toast(AT.pay.void, { info: true });
  if (status === 'error') return window.toast(AT.pay.checkFailed, { error: true, action: { label: AT.pay.checkAgain, onClick: again } });
  if (polled) return window.toast(AT.pay.pending, { info: true, action: { label: AT.pay.checkAgain, onClick: again } });
  window.toast(AT.pay.pending, { info: true, sticky: true });
  // one loop per payment, a minute long; a hidden tab waits
  if (polling.has(v.reference)) return;
  polling.add(v.reference);
  try {
    const end = Date.now() + 60000;
    while (Date.now() < end) {
      await new Promise(res => setTimeout(res, 5000));
      if (document.hidden) continue;
      const r = await checkRef(v.reference);
      if (r.status !== 'pending') return payResult(r, paidEvent, true);
    }
    return payResult({ ...v, status: 'pending' }, paidEvent, true);
  } finally { polling.delete(v.reference); }
}
const polling = new Set();

// From the website's pricing: ?plan=home&period=yearly. Sign-in drops the query, so it is kept
// for a day; once signed in with no running plan, the plans pop-up opens on that plan, which
// asks for the plants first (the checkout needs the final choice).
(() => {
  const q = new URLSearchParams(location.search), plan = q.get('plan');
  if (plan !== 'home' && plan !== 'family') return;
  try { localStorage.setItem('ps.wantPlan', JSON.stringify({ plan, period: q.get('period') === 'yearly' ? 'year' : 'month', at: Date.now() })); } catch (e) {}
  q.delete('plan'); q.delete('period');
  history.replaceState(null, '', location.pathname + (q.toString() ? `?${q}` : '') + location.hash);
})();
// The website's plan, once: { plan, period } or null.
window.takeWantPlan = () => {
  let want = null;
  try { want = JSON.parse(localStorage.getItem('ps.wantPlan')); localStorage.removeItem('ps.wantPlan'); } catch (e) {}
  return want && Date.now() - want.at < 86400000 ? want : null;
};

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
function KeepPicker({ room, value, onChange, logins, ask, full, min = 1, verb = 'Keep', tag, count, lock }) {
  const [say, setSay] = React.useState(null); // 'last' | 'full'
  const one = room === 1 && min > 0;
  const tick = (id) => {
    setSay(null);
    if (one) return onChange([id]);
    if (value.includes(id)) return value.length <= min ? setSay('last') : onChange(value.filter(x => x !== id));
    if (value.length >= room) return setSay('full');
    onChange([...value, id]);
  };
  return (
    <div className="keep-pick">
      {ask && <div className="confirm-text keep-ask">{ask}</div>}
      {logins.map(acc => (
        <div key={acc.account_id} className="login-grp plant-logins">
          <div className="login-line"><div className="login-who"><span className="login-email">{acc.kind === 'share' ? 'Shared plants' : acc.sunsynk_username}</span></div></div>
          {acc.plants.map(p => {
            const name = window.plantLabel(p), on = value.includes(p.plant_id), shut = !!(lock && lock(p));
            return (
              <label key={p.plant_id} className={'login-plant keep-row' + (on ? '' : ' off')}>
                <span className="conn-user plant-nm">{name}</span>
                {tag && tag(p) && <span className="keep-tag">{tag(p)}</span>}
                <input type={one ? 'radio' : 'checkbox'} name="keep-pick" checked={on} disabled={shut} aria-label={verb + ' ' + name} onChange={() => tick(p.plant_id)} />{/* reuse-check: allow: tick boxes, not switches, for the keep pick (SOLAR-486) */}
              </label>
            );
          })}
        </div>
      ))}
      {say === 'last' ? <div className="field-note keep-count warn">{AT.checkoutPick(null, '', 0).none}</div>
        : say === 'full' ? <div className="field-note keep-count warn">{full}</div>
        : !one && count && <div className="field-note keep-count">{count(value.length)}</div>}
    </div>
  );
}

// The account's plants under their logins, in KeepPicker's shape. A plant two logins reach
// goes under the first; a claimed one under "Shared plants". keep(p): which plants to list.
const acctLogins = (a, keep = () => true) => {
  const seen = new Set(), groups = [];
  const put = (id, kind, name, p) => {
    let g = groups.find(x => x.account_id === id);
    if (!g) groups.push(g = { account_id: id, kind, sunsynk_username: name, plants: [] });
    g.plants.push({ plant_id: p.plant, plant_name: AT.plantName(p) });
  };
  for (const p of a.plants) {
    if (!keep(p) || seen.has(p.plant)) continue;
    seen.add(p.plant);
    // a login that lists it; else, unless the share reaches it, the login it went from
    const l = a.logins.find(x => p.logins.includes(x.id)) || (!p.claimed && a.logins.find(x => (p.gone_logins || []).includes(x.id)));
    if (l) put(l.id, 'login', l.username, p); else put('share', 'share', null, p);
  }
  return groups;
};
window.acctLogins = acctLogins;
// The plants a pick lists: every plant the account reaches, a deleted one too (it starts again
// with no history); a keep pick, only the chosen ones.
const pickLogins = (a, mode) => acctLogins(a, p => mode !== 'keep' || p.chosen);
window.pickLogins = pickLogins;
// The pick's button: 'close' (nothing changed), 'confirm' (SwitchConfirm first: any change of
// the plants read now, or a chosen plant going in the checkout pick), else 'done'.
const pickNext = (mode, going, coming) => mode === 'choose' ? (going.length || coming.length ? 'confirm' : 'close')
  : mode === 'checkout' && going.length ? 'confirm' : 'done';
window.pickNext = pickNext;
// After a payment: a place open and a plant not read yet.
const pickWaiting = (a) => !!a && a.may_choose && a.open > 0 && a.plants.some(p => !p.chosen);
window.pickWaiting = pickWaiting;

// Every change of chosen plants is confirmed here (pickNext): it names the plants that go and
// says whether each one's history is deleted now or kept by another account, the plants that
// start, and the one line on history loading (design, "History fetch speed").
function SwitchConfirm({ acct, going, coming, atPayment = false, busy, onConfirm, onCancel }) {
  const t = AT.switchConfirm(acct, going, coming, atPayment);
  return (
    <Dialog keep label={t.title} busy={busy} onClose={onCancel}>
      <div className="confirm-title">{t.title}</div>
      {t.lines.map(l => <div key={l} className="confirm-text">{l}</div>)}
      <div className="conn-form-actions">
        <button type="button" className="ghost-btn" onClick={onCancel} disabled={busy}>{AT.pay.cancel}</button>
        <window.BusyButton className={t.danger ? 'danger-btn' : 'save-btn'} onClick={onConfirm} busy={busy}>{t.button}</window.BusyButton>
      </div>
    </Dialog>
  );
}

// Choosing plants: one pop-up for every pick (SOLAR-641).
//   mode 'choose'    the plants read now (Plants page, after a link, after a payment), up to
//                    the plan's places or the free week's. Saved through api_choose_plants; any
//                    change is confirmed first (SwitchConfirm). prefill: ids to tick.
//   mode 'checkout'  the final choice for plan (a first plan, a restart, an upgrade), before
//                    paying: onDone(ids); a chosen plant going is confirmed first.
//   mode 'keep'      the plants a smaller plan keeps: onDone(ids).
// onDone(ids | null): null when closed with nothing done.
function ChooseDialog({ acct, mode = 'choose', plan = null, from = 'plants', prefill = [], onDone }) {
  const { useState } = React;
  const trial = acct.state === 'trialing' || acct.state === 'none';
  const chosen = acct.plants.filter(p => p.chosen).map(p => p.plant);
  const t = mode === 'checkout' ? AT.checkoutPick(acct, plan.name, plan.places)
    : mode === 'keep' ? AT.keepPick(acct, plan.name, plan.places)
    : acct.state === 'none' ? { ...AT.choosePlants(acct), ...AT.weekPick(acct) } : AT.choosePlants(acct);
  const room = mode === 'choose' ? (trial ? acct.trial_places : acct.places) : plan.places;
  const logins = pickLogins(acct, mode);
  // a plant whose old history is still being deleted can't be picked until it's gone (SOLAR-659)
  const deleting = (id) => !chosen.includes(id) && !!acct.plants.find(x => x.plant === id)?.deleting;
  const all = logins.flatMap(g => g.plants.map(x => x.plant_id)).filter(id => !deleting(id));
  // choose: as chosen now, plus a new login's plants; checkout: every plant that fits, chosen
  // ones first; keep: the chosen ones that fit
  const start = mode === 'choose' ? [...new Set([...chosen, ...prefill.filter(id => !deleting(id))])].slice(0, room)
    : mode === 'checkout' ? [...new Set([...chosen, ...all])].slice(0, room) : chosen.slice(0, room);
  const [picked, setPicked] = useState(start);
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const going = chosen.filter(id => !picked.includes(id)), coming = picked.filter(id => !chosen.includes(id));
  const tag = (p) => {
    const s = acct.plants.find(x => x.plant === p.plant_id);
    if (deleting(p.plant_id)) return AT.deletingWord;
    return s && trial && mode === 'choose' && s.trial_used_elsewhere ? t.usedElsewhere : null;
  };
  const save = async () => {
    setBusy(true);
    try {
      const a = await window.saveChosenPlants(picked);
      window.track('plant_switch_done', { from, going: going.length, coming: coming.length, state: acct.state });
      window.toast(AT.chosenToast(acct, coming, going));
      onDone(picked);
      return a;
    } catch (e) {
      window.toast(AT.refused(e?.message || ''), { error: true });
      setBusy(false); setConfirm(false);
    }
  };
  const next = () => {
    if (mode !== 'choose' && !picked.length) return;
    const n = pickNext(mode, going, coming);
    if (n === 'close') return onDone(null);
    if (n === 'confirm') return setConfirm(true);
    onDone(picked);
  };
  if (confirm) return <SwitchConfirm acct={acct} going={going} coming={coming} atPayment={mode === 'checkout'} busy={busy} onCancel={() => setConfirm(false)}
    onConfirm={mode === 'choose' ? save : () => onDone(picked)} />;
  return (
    <Dialog keep label={t.title} busy={busy} onClose={() => onDone(null)}>
      <div className="confirm-title">{t.title}</div>
      {/* pick-steady: the line under the rows keeps two lines' height, so the pop-up does not jump (SOLAR-572) */}
      <div className="pick-steady">
        <KeepPicker logins={logins} room={room} value={picked} onChange={setPicked} min={mode === 'choose' ? 0 : 1}
          verb={mode === 'keep' ? 'Keep' : 'Read'} tag={tag} lock={p => deleting(p.plant_id)} ask={t.note} full={t.tooMany} />
      </div>
      <div className="conn-form-actions">
        <button type="button" className="ghost-btn" onClick={() => onDone(null)} disabled={busy}>{AT.pay.cancel}</button>
        <window.BusyButton className="save-btn" onClick={next} busy={busy} disabled={mode !== 'choose' && !picked.length}>{t.button}</window.BusyButton>
      </div>
    </Dialog>
  );
}
window.ChooseDialog = ChooseDialog;

// After a payment (billingReturn): the pick pop-up when the plan has places open and a plant
// waits. Nothing to choose: nothing shows. onDone(ids): the plants read now.
function PickAfterPay({ onDone }) {
  const acct = window.useAccount();
  const [ask, setAsk] = React.useState(() => !!window.pickAsked);
  React.useEffect(() => {
    const on = () => { setAsk(true); window.reloadAccount().catch(() => {}); };
    window.addEventListener('ps-pick', on);
    return () => window.removeEventListener('ps-pick', on);
  }, []);
  const close = () => { window.pickAsked = false; setAsk(false); };
  const waiting = pickWaiting(acct);
  React.useEffect(() => { if (ask && acct && !waiting) close(); });
  if (!ask || !waiting) return null;
  return <ChooseDialog acct={acct} from="upgrade" onDone={(ids) => { close(); if (ids) onDone({ plants: ids.map(id => ({ id })), paused: [] }); }} />;
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
  // The first choice after a login or a shared plant is linked: the new plants ticked, up to the
  // places open. Not after Reconnect or a new password: no login was added.
  const linked = async (r) => {
    const fresh = relink ? [] : (r.plants || []).map(p => Number(p.id ?? p.plantId)).filter(Boolean);
    const acct = await window.reloadAccount().catch(() => null);
    const waiting = acct && acct.may_choose && acct.plants.filter(p => fresh.includes(p.plant) && !p.chosen).map(p => p.plant);
    if (!waiting || !waiting.length || !(acct.state === 'none' || acct.state === 'trialing' ? acct.trial_places > acct.chosen : acct.open > 0)) return onLinked(r);
    const on = await new Promise(done => setPick({ acct, prefill: waiting, done }));
    setPick(null);
    return onLinked({ ...r, paused: fresh.filter(id => !(on || []).includes(id)) });
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
      {pick && <ChooseDialog acct={pick.acct} prefill={pick.prefill} from="link" onDone={pick.done} />}
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
          {/* the device's own connection first, else it is us: not the SunSynk logins (SOLAR-604) */}
          <window.AuthCard title={navigator.onLine === false ? 'You’re offline' : 'Can’t reach Prince Solar Hub'}
            sub={navigator.onLine === false ? 'Check your internet, then try again.' : 'Try again in a minute.'} onSubmit={retry} busy={checking}>
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
