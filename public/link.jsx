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
    const timedOut = new Promise(r => setTimeout(() => r({ data: null, error: { message: 'timed out' } }), 10000));
    const read = Promise.race([window.sb.rpc('api_link_status'), timedOut]).catch(e => ({ data: null, error: e })).then(({ data, error }) => {
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

function LinkForm({ relink, onLinked, compact, onCancel, initialUsername }) {
  const { useState } = React;
  const [username, setUsername] = useState(initialUsername || '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [noPlants, setNoPlants] = useState(false);
  // Field id → message, shown on the label line like the sign-in card.
  const [bad, setBad] = useState({});
  const edited = (id) => setBad(b => (b[id] ? { ...b, [id]: undefined } : b));

  const submit = async (e) => {
    e.preventDefault();
    const problems = {};
    if (!username.trim()) problems['ss-user'] = 'Enter your email';
    if (!password) problems['ss-pass'] = 'Enter your password';
    if (Object.keys(problems).length) {
      setBad(problems); setErr(compact ? 'Enter your SunSynk email and password.' : null);
      setTimeout(() => document.getElementById(Object.keys(problems)[0])?.focus());
      return;
    }
    setBusy(true); setErr(null); setBad({});
    try {
      const r = await window.linkSunsynk(username.trim(), password);
      // No plant yet. Nothing on the server looks at this login again, so Retry has to
      // ask SunSynk afresh: the password stays in memory while the card is up, no longer.
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
      setBusy(false);
    }
  };

  // Inside Settings the form sits in the Connection section and borrows its field
  // styling rather than the sign-in card's. Same submit, same messages.
  if (compact) {
    return (
      <form className="conn-form" onSubmit={submit} noValidate aria-busy={busy}>
        {noPlants ? (
          <div className="field-note" style={{ marginTop: 0 }}>
            <b style={{ color: 'var(--text)' }}>{username.trim()}</b> {NO_PLANT_TEXT}
          </div>
        ) : (
          <div className="field-row">
            <div className="field">
              <label htmlFor="ss-user">SunSynk Connect email</label>
              <input id="ss-user" className="input" type="text" placeholder="you@example.com" value={username}
                     autoComplete="off" onChange={(e) => { setUsername(e.target.value); edited('ss-user'); }}
                     readOnly={!!relink} autoFocus={!relink} {...window.invalidProps('ss-user', bad['ss-user'], null)} />
            </div>
            <div className="field">
              <label htmlFor="ss-pass">SunSynk Connect password</label>
              <input id="ss-pass" className="input" type="password" placeholder="Your SunSynk password" value={password} autoComplete="off"
                     onChange={(e) => { setPassword(e.target.value); edited('ss-pass'); }} {...window.invalidProps('ss-pass', bad['ss-pass'], null)} />
            </div>
          </div>
        )}
        <div className="conn-form-actions">
          <button type="submit" className="save-btn" disabled={busy} aria-busy={busy}>
            {noPlants ? (busy ? 'Checking…' : 'Retry now') : busy ? 'Connecting…' : relink ? 'Reconnect' : 'Connect'}
          </button>
          {/* not mid-request: its answer would land after the form had gone */}
          {onCancel && <button type="button" className="ghost-btn" onClick={onCancel} disabled={busy}>Cancel</button>}
          {err ? <span className="field-note" style={{ margin: 0, color: 'var(--load)' }}>{err}</span>
               : <span className="field-note" style={{ margin: 0 }}>Password is exchanged for a token, never stored.</span>}
        </div>
      </form>
    );
  }

  // The login worked but SunSynk lists no plant for it. Almost always the
  // installer still owns the plant; nothing here can fix that, so say what will.
  // A form so Retry is the card's submit button and gets the primary look.
  if (noPlants) {
    return (
      <form className="login-card" onSubmit={submit} noValidate aria-busy={busy}>
        <window.AuthBrand />
        <div className="login-title">Connected, but no plant yet</div>
        <div className="login-sub">
          <b>{username.trim()}</b> {NO_PLANT_TEXT}
        </div>
        <button type="submit" disabled={busy} aria-busy={busy}>{busy ? 'Checking…' : 'Retry now'}</button>
        <div className="login-err" role="alert" aria-live="polite">{err}</div>
        <div className="login-links">
          <button type="button" className="login-link quiet" disabled={busy}
                  onClick={() => { setNoPlants(false); setPassword(''); setErr(null); }}>Use a different SunSynk login</button>
        </div>
      </form>
    );
  }

  return (
    <form className="login-card" onSubmit={submit} noValidate aria-busy={busy}>
      <window.AuthBrand />
      <div className="login-title">{relink ? 'Reconnect SunSynk' : 'Connect SunSynk'}</div>
      <div className="login-sub">
        {relink
          ? 'SunSynk stopped accepting the saved login, usually after a password change. Sign in again to keep logging. Your history is safe.'
          : 'Use your SunSynk Connect login. We never keep the password.'}
      </div>
      <div className="auth-field">
        <window.FieldLabel id="ss-user" label="SunSynk email" error={bad['ss-user']} />
        <input id="ss-user" type="text" placeholder="you@example.com" value={username} autoComplete="off"
               onChange={(e) => { setUsername(e.target.value); edited('ss-user'); }}
               {...window.invalidProps('ss-user', bad['ss-user'])} />
      </div>
      <window.PasswordField id="ss-pass" label="SunSynk password" value={password} error={bad['ss-pass']}
                            onChange={(v) => { setPassword(v); edited('ss-pass'); }}
                            placeholder="Your SunSynk password" autoComplete="off" />
      <button type="submit" disabled={busy} aria-busy={busy}>{busy ? 'Connecting…' : (relink ? 'Reconnect' : 'Connect')}</button>
      <div className="login-err" role="alert" aria-live="polite">{err}</div>
      <div className="login-fine">Signing in here doesn’t sign you out of the SunSynk app. Disconnect any time in Settings.</div>
      <div className="login-links">
        {/* Without a way out, someone signed in to the wrong account is stuck on this screen. */}
        {onCancel
          ? <button type="button" className="login-link quiet" onClick={onCancel}>Cancel</button>
          : <window.SignOutButton className="login-link quiet" />}
      </div>
    </form>
  );
}
window.LinkForm = LinkForm;

/**
 * Sits inside AuthGate. Shows the dashboard when the user has at least one plant
 * they can see; otherwise the connect form. A needs_relink account with plants
 * still shows the dashboard, with a banner (rendered by the app shell).
 */
window.LinkGate = function LinkGate({ children, fallback = null }) {
  const [checking, setChecking] = React.useState(false);
  const { loading, accounts, error, refresh } = window.useLinkStatus();

  if (loading) return fallback;

  const plants = accounts.flatMap(a => a.plants || []);
  const active = accounts.some(a => a.status === 'active');
  const needsRelink = accounts.some(a => a.status === 'needs_relink');

  if (!plants.length || (!active && needsRelink)) {
    // A read that failed says nothing about the logins, so it must not ask for one: a
    // household with plants would land on Connect, and a login that just connected would
    // be asked for again.
    if (error) {
      const retry = async (e) => { e.preventDefault(); setChecking(true); await refresh(); setChecking(false); };
      return (
        <div className="login-wrap">
          <form className="login-card" onSubmit={retry} aria-busy={checking}>
            <window.AuthBrand />
            <div className="login-title">Couldn’t check your SunSynk logins</div>
            <button type="submit" disabled={checking} aria-busy={checking}>{checking ? 'Checking…' : 'Try again'}</button>
            <div className="login-links"><window.SignOutButton className="login-link quiet" /></div>
          </form>
        </div>
      );
    }
    return (
      <div className="login-wrap">
        <LinkForm relink={needsRelink && !active} onLinked={refresh}
                  initialUsername={needsRelink && !active ? accounts.find(a => a.status === 'needs_relink')?.sunsynk_username : undefined} />
      </div>
    );
  }
  return typeof children === 'function' ? children({ accounts, refresh }) : children;
};
