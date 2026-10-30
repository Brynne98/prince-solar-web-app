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
    const attempt = () => {
      const timedOut = new Promise(r => setTimeout(() => r({ data: null, error: { message: 'timed out' } }), 10000));
      return Promise.race([window.sb.rpc('api_link_status'), timedOut]).catch(e => ({ data: null, error: e }));
    };
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

// A Family plant past the 3rd (SOLAR-208): the form shows the cost card first.
class PlanError extends Error {
  constructor(body) { super(body.error); this.code = body.error; this.extraInverters = body.extraInverters || 0; this.dueNow = body.dueNow || 0; }
}

window.linkSunsynk = async function linkSunsynk(username, password, confirmCost = false) {
  const { data: { session } } = await window.sb.auth.getSession();
  if (!session) throw new Error(LINK_ERRORS['sign in first']);
  const res = await fetch(`${window.SUNSYNK_CONFIG.url}/functions/v1/link-sunsynk`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${session.access_token}`,
      apikey: window.SUNSYNK_CONFIG.key,
    },
    body: JSON.stringify({ username, password, confirmCost }),
  });
  const body = await res.json().catch(() => ({}));
  if (body.error === 'confirm_cost') throw new PlanError(body);
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
const billDay = (d) => new Date(d + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
const perUnit = (period) => (period === 'yearly' ? 'a year' : 'a month');
const quote = (plan, period, added = 0) => window.sb.rpc('api_billing_quote', { p_plan: plan, p_period: period, p_added: added })
  .then(({ data, error }) => { if (error) throw error; return data; });

window.billingFmt = { rand, billDay, perUnit };

// Paystack (SOLAR-208, the billing function). A saved card is charged at once;
// otherwise, or after the saved card is declined, Paystack's card page opens and
// comes back to the Plan section with ?reference=, which billingReturn checks.
const billingCall = async (route, body) => {
  const { data: { session } } = await window.sb.auth.getSession();
  if (!session) throw new Error('Your session ended. Sign in again.');
  const res = await fetch(`${window.SUNSYNK_CONFIG.url}/functions/v1/billing/${route}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.access_token}`, apikey: window.SUNSYNK_CONFIG.key },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out.error || 'payment failed');
  return out;
};
// The Plan section on Billing, on the plant the user was looking at.
const planUrl = (extra = '') => {
  const plant = new URLSearchParams(location.search).get('plant');
  return `${location.pathname}?tab=billing&section=plan${plant ? `&plant=${encodeURIComponent(plant)}` : ''}${extra}`;
};
const billingPaid = (plan) => {
  window.track('upgrade_done', plan ? { plan } : {});
  location.assign(planUrl('&billing=paid'));
};

window.startUpgrade = async function startUpgrade(plan, period, added = 0, newCard = false) {
  try {
    let r = await billingCall('pay', { plan, period, added, newCard });
    if (r.status === 'failed') {
      window.toast('Your saved card was declined. Enter another card.', { error: true });
      r = await billingCall('pay', { plan, period, added, newCard: true });
    }
    if (r.url) location.assign(r.url);
    else if (r.status === 'paid') billingPaid(plan);
    else window.toast('Your payment is still being checked. Look again in a minute.');
  } catch (e) {
    if (/open soon/.test(e.message)) return window.toast('Paid plans open soon. Nothing was charged.');
    window.toast(/settle the failed payment/.test(e.message) ? 'Pay the payment that didn’t go through first.' : 'Couldn’t start the payment. Try again.', { error: true });
  }
};

// Pay a failed renewal with another card.
window.settlePayment = async function settlePayment() {
  try {
    const r = await billingCall('pay', { settle: true });
    location.assign(r.url);
  } catch (e) {
    window.toast(/open soon/.test(e.message) ? 'Paid plans open soon. Nothing was charged.' : 'Couldn’t start the payment. Try again.', { error: true });
  }
};

// Change the saved card (SOLAR-238): R1 on Paystack's card page, refunded once the
// card is saved. Comes back through billingReturn like any card-page payment.
window.changeCard = async function changeCard() {
  try {
    const r = await billingCall('pay', { card: true });
    location.assign(r.url);
  } catch (e) {
    if (/open soon/.test(e.message)) return window.toast('Paid plans open soon. Nothing was charged.');
    window.toast('Couldn’t open the card page. Try again.', { error: true });
  }
};

// Once, when Account opens: back from Paystack's card page (?reference=), after a
// payment (?billing=paid), or from the "Pay with another card" email (?pay=1).
window.billingReturn = async function billingReturn(billingStatus) {
  const q = new URLSearchParams(location.search);
  const ref = q.get('reference'), done = q.get('billing'), pay = q.get('pay');
  if (!ref && !done && !pay) return;
  history.replaceState(null, '', planUrl());
  if (pay) {
    if (billingStatus?.state === 'past_due') await window.settlePayment();
    return;
  }
  if (done === 'paid') { window.toast('Payment received. Your plan is updated.'); return; }
  try {
    const { status, kind } = await billingCall('verify', { reference: ref });
    // A card change changes no plan: the caller re-reads the card ('card').
    if (status === 'paid' && kind === 'card') {
      window.track('card_change_done');
      window.toast('Card changed. The R1 check goes back to your card.');
      return 'card';
    }
    // A full reload: resumed plants join the plant list.
    if (status === 'paid') return billingPaid(null);
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
    window.startUpgrade(want.plan, want.period, 0, true);
  });
});

/**
 * Shown when the plan doesn't cover a plant.
 *   reason 'add'        Free or Home with a plant, before the form (onAddPaused: go on, paused)
 *          'paused'     Upgrade on a login row with paused plants (`paused`: their names)
 *          'upgrade'    Upgrade in the Plan section, on Home: the price before the saved card is charged
 *          'history'    a lock on Free after its week (SOLAR-242): both plans, yearly first, priced a month
 * `added` = inverters the login brings past the 3rd plant, priced into Family.
 * A paid user's period changes at renewal, so only Free gets the switch.
 */
function Paywall({ reason, added = 0, paused = [], onCancel, onAddPaused }) {
  const { useState, useEffect } = React;
  const history = reason === 'history';
  const offers = history ? ['home', 'family'] : ['family'];
  const [period, setPeriod] = useState(history ? 'yearly' : 'monthly');
  const [quotes, setQuotes] = useState(null);
  useEffect(() => { window.track('paywall_shown', { reason }); }, []);
  useEffect(() => {
    let alive = true;
    Promise.all(offers.map(p => quote(p, period, p === 'family' ? added : 0)))
      .then(qs => alive && setQuotes(Object.fromEntries(qs.map((q, i) => [offers[i], q]))))
      .catch(() => alive && setQuotes({ error: true }));
    return () => { alive = false; };
  }, [period]);
  const first = quotes && !quotes.error ? quotes[offers[0]] : null;
  const paid = first && first.plan !== 'free';
  const per = paid ? first.period : period;
  return (
    <div className="paywall" role="dialog" aria-labelledby="pw-title">
      <h2 id="pw-title" className="sset-title">{history ? 'See every day' : reason === 'upgrade' ? 'Upgrade to Family'
        : reason === 'paused' ? `Collect data for ${paused.length === 1 ? paused[0] : paused.length + ' stopped plants'}`
        : 'Add another plant'}</h2>
      <p className="sset-note">{history ? 'Free keeps the last 24 hours.' : first?.plan === 'family' ? 'Plants after your 3rd stay stopped until you add them to your plan.'
        : (paid ? 'Home' : 'Free') + ' covers one plant.'}</p>
      {!paid && (
        <div className="segmented seg-sm pw-period" role="group" aria-label="Billing">
          {(history ? ['yearly', 'monthly'] : ['monthly', 'yearly']).map(p => (
            <button type="button" key={p} className={'seg-btn' + (period === p ? ' active' : '')} aria-pressed={period === p}
                    onClick={() => setPeriod(p)}>{p === 'monthly' ? 'Monthly' : 'Yearly'}{history && p === 'yearly' && <span className="pw-save">2 months free</span>}</button>
          ))}
        </div>
      )}
      {quotes?.error ? <p className="sset-note pw-error">Couldn’t load prices. Close this and try again.</p> : (
        <div className="pw-plans">
          {offers.map(p => {
            const q = quotes?.[p];
            return (
              <div key={p} className={'pw-plan' + (p === 'family' ? ' pw-main' : '')}>
                <div className="pw-name">{p === 'family' ? 'Family' : 'Home'}</div>
                {history && per === 'yearly'
                  ? <div className="pw-price"><b>{q ? rand(Math.round(q.nextCharge / 12)) : '…'}</b> a month{q && <span className="pw-billed">{rand(q.nextCharge)} billed yearly</span>}</div>
                  : <div className="pw-price"><b>{q ? rand(q.nextCharge) : '…'}</b> {perUnit(per)}</div>}
                <ul className="pw-gives">
                  <li>{p === 'family' ? 'Up to 3 plants' : '1 plant'}</li>
                  <li>Your full history</li>
                </ul>
                {paid && q && q.dueNow !== q.nextCharge && <div className="pw-due">{rand(q.dueNow)} today, then {rand(q.nextCharge)} {perUnit(per)} from {billDay(q.nextDate)}</div>}
                <button type="button" className={p === 'family' ? 'save-btn' : 'ghost-btn'} disabled={!q}
                        onClick={() => window.startUpgrade(p, per, p === 'family' ? added : 0)}>{p === 'home' ? 'Choose Home' : q?.plan === 'family' ? 'Add to my plan' : 'Upgrade to Family'}</button>
              </div>
            );
          })}
        </div>
      )}
      {first && <p className="field-note">Plants after the 3rd: {rand(first.extraPrice)} {perUnit(per)} for each inverter.</p>}
      <div className="conn-form-actions pw-foot">
        <span className="field-note">Cancel any time.</span>
        {onAddPaused && <button type="button" className="ghost-btn" onClick={onAddPaused}>Add it stopped</button>}
        <button type="button" className="ghost-btn" onClick={onCancel}>{history ? 'Stay on Free' : 'Not now'}</button>
      </div>
    </div>
  );
}
window.Paywall = Paywall;

// The same moment on the Connect screen and inside Settings; one wording for both.
const NO_PLANT_TEXT = 'signed in, but no plant is shared with it yet. Your login is saved. Retry any time.';

/** Password input in the app's field style, with a show button. type="button": inside a
 *  form a bare button submits. */
function LinkPassword({ id = 'ss-pass', autoComplete = 'off', value, onChange, invalid }) {
  const [show, setShow] = React.useState(false);
  return (
    <div className="link-pw">
      <input id={id} className="input" type={show ? 'text' : 'password'} value={value} autoComplete={autoComplete}
             onChange={(e) => onChange(e.target.value)} {...invalid} />
      <button type="button" className="link-eye" onClick={() => setShow(v => !v)}
              aria-label={show ? 'Hide password' : 'Show password'} aria-pressed={show}>
        {show ? <window.EyeOffIcon /> : <window.EyeIcon />}
      </button>
    </div>
  );
}

// One form for a SunSynk login, built from the app's own Settings parts (SOLAR-96).
// `compact`: inside Account's SunSynk logins section (Add login, Reconnect). Otherwise the
// Connect card that opens in place on a page with no inverter yet (Setup), with its title.
// Either way: one line on which login, the two fields, a note, then Cancel and the green
// button at the right.
function LinkForm({ relink, onLinked, compact, onCancel, initialUsername, hasPlant }) {
  const { useState, useEffect, useRef } = React;
  // The plan's answer: a paywall reason, or the cost of plants past the 3rd.
  const [paywall, setPaywall] = useState(null);
  const [cost, setCost] = useState(null);
  // A login with more plants than the plan has room for: the user picks which collect
  // (SOLAR-251). { r: the link's answer, max, chosen: Set of plant ids }.
  const [pick, setPick] = useState(null);
  // Free and Home cover one plant: with one already, the paywall comes before the form.
  useEffect(() => {
    if (!hasPlant || relink) return;
    let alive = true;
    quote('family', 'monthly').then(q => alive && q.plan !== 'family' && setPaywall({ reason: 'add' })).catch(() => {});
    return () => { alive = false; };
  }, []);
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
  const [bad, setBad] = useState({});
  const edited = (id) => setBad(b => (b[id] ? { ...b, [id]: undefined } : b));

  const submit = async (e, confirmCost = false) => {
    e?.preventDefault();
    const problems = {};
    if (!username.trim()) problems['ss-user'] = 'Enter your email';
    if (!password) problems['ss-pass'] = 'Enter your password';
    if (Object.keys(problems).length) {
      setBad(problems);
      setTimeout(() => document.getElementById(Object.keys(problems)[0])?.focus());
      return;
    }
    setBusy(true); setBad({});
    findTimer.current = setTimeout(() => setFinding(true), 2500);
    try {
      const r = await window.linkSunsynk(username.trim(), password, confirmCost);
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
        setPassword(''); setCost(null);
        setPaywall({ reason: 'paused', paused: r.plants.map(p => p.name || 'Plant ' + p.id) });
        await onLinked(r);
        return;
      }
      // Some of this login's plants collect, some don't fit: ask which. The first ones
      // linked are ticked, as the server picked them.
      const stopped = new Set((r.paused || []).map(Number));
      const on = (r.plants || []).filter(p => !stopped.has(Number(p.id)));
      if (stopped.size && on.length && !relink) {
        setPassword(''); setCost(null);
        setPick({ r, max: on.length, chosen: new Set(on.map(p => Number(p.id))) });
        return;
      }
      // Busy until the caller has the new login list, or the screen sits idle before it changes.
      await onLinked(r);
      setPassword(''); setNoPlants(false); setCost(null);
    } catch (ex) {
      if (ex instanceof PlanError) {
        const q = await quote('family', 'monthly', ex.extraInverters).catch(() => null);
        setCost(q ? { n: ex.extraInverters, ...q } : null);
        if (!q) fail('Couldn’t load prices. Try again.');
        return;
      }
      fail(ex instanceof TypeError ? 'Can’t reach Prince Solar Hub. Check your connection and try again.' : ex.message);
    } finally {
      clearTimeout(findTimer.current); setFinding(false);
      setBusy(false);
    }
  };

  const label = (id, text, hint) => (
    <label htmlFor={id}>{text}{bad[id] ? <span className="link-bad" id={id + '-err'}>{bad[id]}</span> : hint && <span>{hint}</span>}</label>
  );
  const invalid = (id) => window.invalidProps(id, bad[id]);
  const green = noPlants ? (busy ? 'Checking…' : 'Retry now')
    : busy ? (finding ? 'Finding your plant…' : 'Checking your login…')
    : relink ? 'Reconnect' : compact ? 'Add login' : 'Connect';

  if (paywall) {
    const close = () => { setPaywall(null); setPassword(''); onCancel && onCancel(); };
    // Before the form, a plant past the plan can still be added, paused.
    const addPaused = paywall.reason === 'add' ? () => setPaywall(null) : undefined;
    return <div className={compact ? 'conn-form' : 'link-card'}><Paywall reason={paywall.reason} added={paywall.added} paused={paywall.paused} onCancel={close} onAddPaused={addPaused} /></div>;
  }

  if (pick) {
    const { r, max, chosen } = pick;
    const toggle = (id) => setPick(p => {
      const c = new Set(p.chosen);
      if (c.has(id)) c.delete(id); else if (max === 1) { c.clear(); c.add(id); } else if (c.size < max) c.add(id);
      return { ...p, chosen: c };
    });
    const go = async () => {
      setBusy(true);
      const was = new Set((r.paused || []).map(Number));
      const ids = (r.plants || []).map(p => Number(p.id));
      // Stops first, so the plan has room for the starts. A failure keeps the server's
      // own pick; Billing shows which plants collect.
      let failed = false;
      for (const id of ids.filter(id => !was.has(id) && !chosen.has(id))) failed = failed || !!(await window.sb.rpc('api_plant_stop', { p_plant: id })).error;
      if (!failed) for (const id of ids.filter(id => was.has(id) && chosen.has(id))) failed = failed || !!(await window.sb.rpc('api_plant_start', { p_plant: id })).error;
      if (failed) window.toast('Couldn’t save your pick. Change it on Billing.', { error: true });
      else window.track('plants_picked', { plants: ids.length, collecting: chosen.size });
      await onLinked(failed ? r : { ...r, paused: ids.filter(id => !chosen.has(id)) });
      setBusy(false); setPick(null);
    };
    return (
      <div className={(compact ? 'conn-form' : 'link-card') + ' pick-card'} role="dialog" aria-labelledby="pick-title">
        <h2 id="pick-title" className="sset-title">Pick {max === 1 ? 'the plant' : max + ' plants'} to collect</h2>
        <p className="sset-note">Your plan has room for {max === 1 ? 'one' : max}. The rest stay stopped.</p>
        <div className="pick-list" role="group" aria-labelledby="pick-title">
          {(r.plants || []).map(p => {
            const id = Number(p.id);
            return (
              <label key={id} className="pick-row">
                <input type={max === 1 ? 'radio' : 'checkbox'} name="pick" checked={chosen.has(id)} disabled={busy || (!chosen.has(id) && max > 1 && chosen.size >= max)} onChange={() => toggle(id)} />
                <span>{p.name || 'Plant ' + id}</span>
              </label>
            );
          })}
        </div>
        <div className="conn-form-actions">
          <button type="button" className="save-btn" disabled={busy || !chosen.size} aria-busy={busy} onClick={go}>{busy ? 'Saving…' : 'Collect'}</button>
        </div>
      </div>
    );
  }

  if (cost) {
    const unit = perUnit(cost.period);
    return (
      <div className={(compact ? 'conn-form' : 'link-card') + ' cost-card'} role="alertdialog" aria-labelledby="cost-title">
        <div id="cost-title" className="confirm-title">Add {cost.n === 1 ? '1 inverter' : cost.n + ' inverters'} for {rand(cost.n * cost.extraPrice)} {unit}?</div>
        <div className="confirm-text">Plants after your 3rd cost {rand(cost.extraPrice)} {unit} for each inverter. {rand(cost.dueNow)} today, then {rand(cost.nextCharge)} {unit} from {billDay(cost.nextDate)}.</div>
        <div className="conn-form-actions">
          <button type="button" className="ghost-btn" disabled={busy} onClick={() => { setCost(null); setPassword(''); onCancel && onCancel(); }}>Cancel</button>
          <button type="button" className="ghost-btn" disabled={busy} onClick={() => submit(null, 'paused')}>Add it stopped</button>
          <button type="button" className="save-btn" disabled={busy} aria-busy={busy} onClick={() => submit(null, true)}>{busy ? 'Adding…' : 'Add plant'}</button>
        </div>
      </div>
    );
  }

  return (
    <form className={compact ? 'conn-form link-form' : 'link-form link-card'} onSubmit={submit} noValidate aria-busy={busy}>
      {!compact && <h2 className="sset-title">{noPlants ? 'Connected, but no plant yet' : relink ? 'Reconnect SunSynk' : 'Connect your inverter'}</h2>}
      {noPlants ? (
        // The login worked but SunSynk lists no plant for it. Say so and offer Retry; never
        // send the owner to an installer or SunSynk.
        <p className="sset-note"><b>{username.trim()}</b> {NO_PLANT_TEXT}</p>
      ) : (<>
        <p className="sset-note">{relink
          ? 'SunSynk stopped accepting your login. Your history is safe.'
          : 'Use the login from the SunSynk Connect app.'}</p>
        {/* In Account the two fields share one line, as they did before (SOLAR-97); a phone
            stacks them. On the Connect card they stack. */}
        <div className={compact ? 'field-row' : undefined}>
          <div className="field">
            {label('ss-user', 'SunSynk email', ownEmail && username === ownEmail ? 'Your account email' : null)}
            <input id="ss-user" className="input" type="text" placeholder="you@example.com" value={username} autoComplete="off"
                   readOnly={!!relink} onChange={(e) => { setUsername(e.target.value); edited('ss-user'); }} {...invalid('ss-user')} />
          </div>
          <div className="field link-last">
            {label('ss-pass', 'SunSynk password')}
            <LinkPassword value={password} onChange={(v) => { setPassword(v); edited('ss-pass'); }} invalid={invalid('ss-pass')} />
          </div>
        </div>
        <div className="field-note link-note">{compact ? 'We never keep your password.' : 'We never keep your password. Disconnect any time in Account.'}</div>
      </>)}
      <div className="conn-form-actions link-actions">
        {noPlants
          ? <button type="button" className="ghost-btn" disabled={busy} onClick={() => { setNoPlants(false); setPassword(''); }}>Use a different login</button>
          : onCancel && <button type="button" className="ghost-btn" onClick={onCancel} disabled={busy}>Cancel</button>}
        <button type="submit" className="save-btn" disabled={busy} aria-busy={busy}>{green}</button>
      </div>
    </form>
  );
}
window.LinkForm = LinkForm;
window.LinkPassword = LinkPassword;

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
          <form className="login-card" onSubmit={retry} aria-busy={checking}>
            <window.AuthBrand />
            <div className="login-title">Couldn’t check your SunSynk logins</div>
            <button type="submit" disabled={checking} aria-busy={checking}>{checking ? 'Checking…' : 'Try again'}</button>
            {/* No server text on screen (SOLAR-163). */}
            <div className="login-links"><window.SignOutButton className="login-link quiet" /></div>
          </form>
        </div>
      );
    }
  }
  return typeof children === 'function' ? children({ accounts, error, refresh }) : children;
};
