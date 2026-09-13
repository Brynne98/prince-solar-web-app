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

/** Status of the signed-in user's SunSynk link(s). Null while loading. */
window.useLinkStatus = function useLinkStatus(refreshKey) {
  const { useState, useEffect } = React;
  const [state, setState] = useState({ loading: true, accounts: [], error: null });
  useEffect(() => {
    let alive = true;
    window.sb.rpc('api_link_status').then(({ data, error }) => {
      if (!alive) return;
      setState({ loading: false, accounts: error ? [] : (data || []), error: error ? error.message : null });
    });
    return () => { alive = false; };
  }, [refreshKey]);
  return state;
};

window.linkSunsynk = async function linkSunsynk(username, password) {
  const { data: { session } } = await window.sb.auth.getSession();
  if (!session) throw new Error('Not signed in');
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
  if (!res.ok) throw new Error(body.error || "Couldn't connect to SunSynk. Check the login and try again.");
  return body;
};

window.disconnectSunsynk = async function disconnectSunsynk(accountId) {
  const { error } = await window.sb.rpc('api_link_disconnect', { p_account: accountId });
  if (error) throw new Error(error.message);
};

// The same moment on the Connect screen and inside Settings; one wording for both.
const NO_PLANT_TEXT = 'signed in, but SunSynk lists no plant for it. Usually the installer still owns the plant: ask them to share it with this login in SunSynk Connect (Plant → Share). Your login is saved here, so retry once the plant shows in SunSynk Connect.';

function LinkForm({ relink, onLinked, compact, onCancel, initialUsername }) {
  const { useState } = React;
  const [username, setUsername] = useState(initialUsername || '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [noPlants, setNoPlants] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    setBusy(true); setErr(null); setNoPlants(false);
    try {
      const r = await window.linkSunsynk(username.trim(), password);
      setPassword('');
      if (r.warning) { setNoPlants(true); return; }
      onLinked(r);
    } catch (ex) {
      setErr(ex.message);
    } finally {
      setBusy(false);
    }
  };

  // Inside Settings the form sits in the Connection section and borrows its field
  // styling rather than the sign-in card's. Same submit, same messages.
  if (compact) {
    return (
      <form className="conn-form" onSubmit={submit}>
        {noPlants ? (
          <div className="field-note" style={{ marginTop: 0 }}>
            <b style={{ color: 'var(--text)' }}>{username.trim()}</b> {NO_PLANT_TEXT}
          </div>
        ) : (
          <div className="field-row">
            <div className="field">
              <label htmlFor="ss-user">SunSynk Connect email</label>
              <input id="ss-user" className="input" type="text" placeholder="you@example.com" value={username}
                     autoComplete="off" onChange={(e) => setUsername(e.target.value)} required readOnly={!!relink} autoFocus={!relink} />
            </div>
            <div className="field">
              <label htmlFor="ss-pass">SunSynk Connect password</label>
              <input id="ss-pass" className="input" type="password" placeholder="••••••••" value={password} autoComplete="off"
                     onChange={(e) => setPassword(e.target.value)} required />
            </div>
          </div>
        )}
        <div className="conn-form-actions">
          {noPlants
            ? <button type="button" className="save-btn" onClick={() => onLinked({ retry: true })}>Retry now</button>
            : <button type="submit" className="save-btn" disabled={busy}>{busy ? 'Connecting…' : (relink ? 'Reconnect' : 'Connect')}</button>}
          {onCancel && <button type="button" className="ghost-btn" onClick={onCancel}>Cancel</button>}
          {err ? <span className="field-note" style={{ margin: 0, color: 'var(--load)' }}>{err}</span>
               : <span className="field-note" style={{ margin: 0 }}>The password is swapped for a token and never stored.</span>}
        </div>
      </form>
    );
  }

  // The login worked but SunSynk lists no plant for it. Almost always the
  // installer still owns the plant; nothing here can fix that, so say what will.
  if (noPlants) {
    return (
      <div className={compact ? '' : 'login-card'}>
        {!compact && <window.AuthBrand />}
        <div className="login-title">Connected, but no plant yet</div>
        <div className="login-sub">
          <b>{username.trim()}</b> {NO_PLANT_TEXT}
        </div>
        <button type="button" onClick={() => onLinked({ retry: true })}>Retry now</button>
        <div className="login-links">
          <button type="button" className="login-link quiet" onClick={() => setNoPlants(false)}>Use a different SunSynk login</button>
        </div>
      </div>
    );
  }

  return (
    <form className={compact ? '' : 'login-card'} onSubmit={submit}>
      {!compact && <window.AuthBrand />}
      <div className="login-title">{relink ? 'Reconnect SunSynk' : compact ? 'Connect another SunSynk login' : 'Connect your SunSynk'}</div>
      <div className="login-sub">
        {relink
          ? 'Your SunSynk connection stopped working — usually a changed password. Sign in again to resume logging. Your history is intact.'
          : compact
            ? 'For a plant on a different SunSynk account. Its plants are added to your selector.'
            : 'Sign in with your SunSynk Connect login. We exchange it for an access token and never keep the password.'}
      </div>
      <div className="auth-field">
        <label htmlFor="ss-user">SunSynk Connect email</label>
        <input id="ss-user" type="text" placeholder="you@example.com" value={username} autoComplete="off"
               onChange={(e) => setUsername(e.target.value)} required />
      </div>
      <window.PasswordField id="ss-pass" label="SunSynk Connect password" value={password} onChange={setPassword}
                            placeholder="••••••••" autoComplete="off" />
      <button type="submit" disabled={busy}>{busy ? 'Connecting…' : (relink ? 'Reconnect' : 'Connect')}</button>
      <div className="login-err" role="alert" aria-live="polite">{err}</div>
      <div className="login-links">
        <span className="login-fine">Signing in here does not sign you out of the SunSynk app. Disconnect any time from Settings.</span>
        {onCancel && <button type="button" className="login-link quiet" onClick={onCancel}>Cancel</button>}
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
window.LinkGate = function LinkGate({ children }) {
  const { useState } = React;
  const [refreshKey, setRefreshKey] = useState(0);
  const { loading, accounts, error } = window.useLinkStatus(refreshKey);

  if (loading) return <div className="login-wrap"><div className="login-card">Loading…</div></div>;

  const plants = accounts.flatMap(a => a.plants || []);
  const active = accounts.some(a => a.status === 'active');
  const needsRelink = accounts.some(a => a.status === 'needs_relink');

  if (!plants.length || (!active && needsRelink)) {
    return (
      <div className="login-wrap">
        <LinkForm relink={needsRelink && !active} onLinked={() => setRefreshKey(k => k + 1)} />
        {error && <div className="login-err">{error}</div>}
      </div>
    );
  }
  return typeof children === 'function' ? children({ accounts, refresh: () => setRefreshKey(k => k + 1) }) : children;
};
