// ============================================================================
// link.jsx — "Connect your SunSynk account".
//
// A signed-in user with no linked plants sees this instead of the dashboard. They
// enter their SunSynk Connect login once; the link-sunsynk Edge Function exchanges
// it for a token and the password never lands anywhere. When the token later dies
// (password changed, SunSynk migration) the account flips to needs_relink and the
// dashboard shows a banner pointing back here.
//
// Two backends, deliberately: api_link_status / api_link_disconnect are RPCs (plain
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
  return { ...state, refresh };
};

window.linkSunsynk = async function linkSunsynk(username, password) {
  const { data: { session } } = await window.sb.auth.getSession();
  if (!session) throw new Error(LINK_ERRORS['sign in first']);
  const res = await fetch(`${window.SUNSYNK_CONFIG.url}/functions/v1/link-sunsynk`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${session.access_token}`,
      apikey: window.SUNSYNK_CONFIG.key,
    },
    body: JSON.stringify({ username, password }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(LINK_ERRORS[body.error] || 'Couldn’t connect to SunSynk. Check the login and try again.');
  return body;
};

// link-sunsynk answers in developer shorthand; these are the household's words for it.
const LINK_ERRORS = {
  'SunSynk rejected those credentials': 'SunSynk didn’t accept that email and password.',
  'could not reach SunSynk': 'Can’t reach SunSynk right now. Try again in a minute.',
  'sign in first': 'Your session ended. Sign in again.',
  'session invalid': 'Your session ended. Sign in again.',
};

window.disconnectSunsynk = async function disconnectSunsynk(accountId) {
  const { error } = await window.sb.rpc('api_link_disconnect', { p_account: accountId });
  if (error) throw new Error(error.message);
};

// The same moment on the Connect screen and inside Settings; one wording for both.
const NO_PLANT_TEXT = 'signed in, but SunSynk lists no plant for it. The installer usually still owns the plant: ask them to share it with this login in SunSynk Connect (Plant → Share). Your login is saved, so retry once it appears.';

/** Password input in the app's field style, with a show button. type="button": inside a
 *  form a bare button submits. */
function LinkPassword({ value, onChange, invalid }) {
  const [show, setShow] = React.useState(false);
  return (
    <div className="link-pw">
      <input id="ss-pass" className="input" type={show ? 'text' : 'password'} value={value} autoComplete="off"
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
function LinkForm({ relink, onLinked, compact, onCancel, initialUsername }) {
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
  const [err, setErr] = useState(null);
  const [noPlants, setNoPlants] = useState(false);
  // Field id → message, shown on the label line.
  const [bad, setBad] = useState({});
  const edited = (id) => setBad(b => (b[id] ? { ...b, [id]: undefined } : b));

  const submit = async (e) => {
    e.preventDefault();
    const problems = {};
    if (!username.trim()) problems['ss-user'] = 'Enter your email';
    if (!password) problems['ss-pass'] = 'Enter your password';
    if (Object.keys(problems).length) {
      setBad(problems); setErr(null);
      setTimeout(() => document.getElementById(Object.keys(problems)[0])?.focus());
      return;
    }
    setBusy(true); setErr(null); setBad({});
    findTimer.current = setTimeout(() => setFinding(true), 2500);
    try {
      const r = await window.linkSunsynk(username.trim(), password);
      // No plant yet. Nothing on the server looks at this login again, so Retry has to
      // ask SunSynk afresh: the password stays in memory while the form is up, no longer.
      if (r.warning) {
        if (noPlants) setErr('Still no plant on this login.');
        setNoPlants(true);
        return;
      }
      // Busy until the caller has the new login list, or the screen sits idle before it changes.
      await onLinked(r);
      setPassword(''); setNoPlants(false);
    } catch (ex) {
      setErr(ex instanceof TypeError ? 'Can’t reach Prince Solar. Check your connection and try again.' : ex.message);
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

  return (
    <form className={compact ? 'conn-form link-form' : 'link-form link-card'} onSubmit={submit} noValidate aria-busy={busy}>
      {!compact && <h2 className="sset-title">{noPlants ? 'Connected, but no plant yet' : relink ? 'Reconnect SunSynk' : 'Connect your inverter'}</h2>}
      {noPlants ? (
        // The login worked but SunSynk lists no plant for it. Almost always the installer
        // still owns the plant; nothing here can fix that, so say what will.
        <p className="sset-note"><b>{username.trim()}</b> {NO_PLANT_TEXT}</p>
      ) : (<>
        <p className="sset-note">{relink
          ? 'SunSynk stopped accepting the saved login, usually after a password change. Your history is safe.'
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
      <div className="field-note link-err" role="alert" aria-live="polite">{err}</div>
      <div className="conn-form-actions link-actions">
        {noPlants
          ? <button type="button" className="ghost-btn" disabled={busy} onClick={() => { setNoPlants(false); setPassword(''); setErr(null); }}>Use a different login</button>
          : onCancel && <button type="button" className="ghost-btn" onClick={onCancel} disabled={busy}>Cancel</button>}
        <button type="submit" className="save-btn" disabled={busy} aria-busy={busy}>{green}</button>
      </div>
    </form>
  );
}
window.LinkForm = LinkForm;

/**
 * Sits inside AuthGate. Hands the login list to its child, which shows the dashboard
 * when a login lists a plant and the Setup frame (Connect on Live) when none does.
 * A read that failed shows its own card, since it says nothing about the logins. A login that needs reconnecting never
 * hides the dashboard, even when every login has died: the stored readings are
 * still worth seeing, and the app shell shows a banner leading to Settings, where
 * each login reconnects on its own.
 */
window.LinkGate = function LinkGate({ children, fallback = null }) {
  const [checking, setChecking] = React.useState(false);
  const { loading, accounts, error, refresh } = window.useLinkStatus();
  // The wall tablet's connection drops for minutes at a time, and Chrome on iPad reloads
  // the page now and then; a reload inside a drop fails both tries and used to sit on
  // "Couldn't check" until someone tapped it (SOLAR-21). Keep checking while stuck there:
  // every 15 s, and the moment the tablet is back online or on screen.
  const stuck = !loading && !!error && !accounts.some(a => (a.plants || []).length);
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
  if (!accounts.some(a => (a.plants || []).length)) {
    if (error) {
      const retry = async (e) => { e.preventDefault(); setChecking(true); await refresh(); setChecking(false); };
      return (
        <div className="login-wrap">
          <form className="login-card" onSubmit={retry} aria-busy={checking}>
            <window.AuthBrand />
            <div className="login-title">Couldn’t check your SunSynk logins</div>
            <button type="submit" disabled={checking} aria-busy={checking}>{checking ? 'Checking…' : 'Try again'}</button>
            {/* The real reason, so a report from a phone says which failure it was. */}
            <div className="login-fine">Error: {error}</div>
            <div className="login-links"><window.SignOutButton className="login-link quiet" /></div>
          </form>
        </div>
      );
    }
  }
  return typeof children === 'function' ? children({ accounts, error, refresh }) : children;
};
