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
  if (!res.ok) throw new Error(body.error || `Link failed (${res.status})`);
  return body;
};

window.disconnectSunsynk = async function disconnectSunsynk(accountId) {
  const { error } = await window.sb.rpc('api_link_disconnect', { p_account: accountId });
  if (error) throw new Error(error.message);
};

function LinkForm({ relink, onLinked }) {
  const { useState } = React;
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPw, setShowPw] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [warn, setWarn] = useState(null);

  const submit = async (e) => {
    e.preventDefault();
    setBusy(true); setErr(null); setWarn(null);
    try {
      const r = await window.linkSunsynk(username.trim(), password);
      setPassword('');
      if (r.warning) setWarn(r.warning);
      onLinked(r);
    } catch (ex) {
      setErr(ex.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="login-card" onSubmit={submit}>
      <window.AuthBrand />
      <div className="login-title">{relink ? 'Reconnect SunSynk' : 'Connect your SunSynk'}</div>
      <div className="login-sub">
        {relink
          ? 'Your SunSynk connection stopped working — usually a changed password. Sign in again to resume logging. Your history is intact.'
          : 'Sign in with your SunSynk Connect login. We exchange it for an access token and never keep the password.'}
      </div>
      <div className="auth-field">
        <label htmlFor="ss-user">SunSynk Connect email</label>
        <input id="ss-user" type="text" placeholder="The login you use in the SunSynk app" value={username} autoComplete="off"
               onChange={(e) => setUsername(e.target.value)} required />
      </div>
      <window.PasswordField id="ss-pass" label="SunSynk Connect password" value={password} onChange={setPassword}
                            placeholder="••••••••" autoComplete="off" />
      <button type="submit" disabled={busy}>{busy ? 'Connecting…' : (relink ? 'Reconnect' : 'Connect')}</button>
      <div className={'login-err' + (warn && !err ? ' login-note' : '')} role="alert" aria-live="polite">{err || warn}</div>
      <div className="login-links">
        <span className="login-fine">Signing in here does not sign you out of the SunSynk app. Disconnect any time from Settings.</span>
      </div>
    </form>
  );
}

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
