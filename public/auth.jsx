// ============================================================================
// auth.jsx — Supabase session + the login gate.
//
// Every read goes through an api_* RPC granted to `authenticated`, so the app needs
// a signed-in session before it can show anything. The session is persisted by
// supabase-js in localStorage and auto-refreshed, so a wall-mounted tablet signs in
// once and stays in.
// ============================================================================

window.sb = window.supabase.createClient(
  window.SUNSYNK_CONFIG.url,
  window.SUNSYNK_CONFIG.key,
  { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'synsynk.auth' } }
);

// Resolves once the initial session lookup is done, so the first render doesn't
// flash the login form at an already-signed-in user.
window.useSession = function useSession() {
  const { useState, useEffect } = React;
  const [state, setState] = useState({ loading: true, session: null });

  useEffect(() => {
    let alive = true;
    window.sb.auth.getSession().then(({ data }) => {
      if (alive) setState({ loading: false, session: data.session || null });
    });
    const { data: sub } = window.sb.auth.onAuthStateChange((_e, session) => {
      if (alive) setState({ loading: false, session: session || null });
    });
    return () => { alive = false; sub.subscription.unsubscribe(); };
  }, []);

  return state;
};

function LoginScreen() {
  const { useState } = React;
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);

  const submit = async (e) => {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    const { error } = await window.sb.auth.signInWithPassword({ email, password });
    if (error) setErr(error.message);
    setBusy(false);
  };

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <div className="login-title">SynSynk</div>
        <div className="login-sub">Solar dashboard</div>
        <input type="email" placeholder="Email" value={email} autoComplete="username"
               onChange={(e) => setEmail(e.target.value)} required />
        <input type="password" placeholder="Password" value={password} autoComplete="current-password"
               onChange={(e) => setPassword(e.target.value)} required />
        <button type="submit" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        {err && <div className="login-err">{err}</div>}
      </form>
    </div>
  );
}

/** Renders children only when signed in. */
window.AuthGate = function AuthGate({ children }) {
  const { loading, session } = window.useSession();
  if (loading) return <div className="login-wrap"><div className="login-card">Loading…</div></div>;
  if (!session) return <LoginScreen />;
  return children;
};

window.signOut = () => window.sb.auth.signOut();
