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

// Eye / eye-with-a-line-through-it, for the reveal toggle.
const EyeIcon = () => (
  <svg width="16" height="16" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M1.5 10S4.5 4.5 10 4.5 18.5 10 18.5 10 15.5 15.5 10 15.5 1.5 10 1.5 10Z" />
    <circle cx="10" cy="10" r="2.5" />
  </svg>
);
const EyeOffIcon = () => (
  <svg width="16" height="16" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M8.1 4.7A7.7 7.7 0 0 1 10 4.5c5.5 0 8.5 5.5 8.5 5.5a15 15 0 0 1-2.4 3.1M4.4 6A15 15 0 0 0 1.5 10S4.5 15.5 10 15.5c1.2 0 2.2-.2 3.2-.6" />
    <path d="M8.3 8.3a2.5 2.5 0 0 0 3.4 3.4" />
    <path d="M2.5 2.5l15 15" />
  </svg>
);

function LoginScreen() {
  const { useState } = React;
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPw, setShowPw] = useState(false);
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
        {/* type="button" matters: inside a form, a bare <button> defaults to submit,
            so revealing the password would try to sign in with it half-typed */}
        <div className="login-pw">
          <input type={showPw ? 'text' : 'password'} placeholder="Password" value={password}
                 autoComplete="current-password" onChange={(e) => setPassword(e.target.value)} required />
          <button type="button" className="login-eye" onClick={() => setShowPw(v => !v)}
                  title={showPw ? 'Hide password' : 'Show password'}
                  aria-label={showPw ? 'Hide password' : 'Show password'} aria-pressed={showPw}>
            {showPw ? <EyeOffIcon /> : <EyeIcon />}
          </button>
        </div>
        <button type="submit" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        {/* Always rendered, even when empty. Mounting it only on error grew the card by
            a line, and since the card is vertically centred that shunted the whole form
            up ~15px — the fields moving out from under the cursor at the exact moment
            you're retyping a password. The slot holds its space instead. */}
        <div className="login-err" role="alert" aria-live="polite">{err}</div>
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
