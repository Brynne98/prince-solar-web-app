// ============================================================================
// auth.jsx — Supabase session + the sign-in / sign-up / reset screens.
//
// Every read goes through an api_* RPC granted to `authenticated`, so the app needs
// a signed-in session before it can show anything. The session is persisted by
// supabase-js in localStorage and auto-refreshed, so a wall-mounted tablet signs in
// once and stays in.
//
// Four screens, one component, switched by `mode`:
//   signin    email + password
//   signup    email + password + confirm. If the project requires email
//             confirmation, the user is told to check their inbox; otherwise they
//             land straight in the app (and then on the Connect screen).
//   forgot    email → reset link
//   recovery  reached from the reset link. Supabase signs the user in with a
//             short-lived session and fires PASSWORD_RECOVERY; we ask for the new
//             password and call updateUser. Until then the app is gated.
// ============================================================================

window.sb = window.supabase.createClient(
  window.SUNSYNK_CONFIG.url,
  window.SUNSYNK_CONFIG.key,
  { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'synsynk.auth' } }
);

// Where emailed links (confirmation, password reset) bring the user back to.
const SITE_URL = location.origin + location.pathname.replace(/\/[^/]*$/, '/');

// Resolves once the initial session lookup is done, so the first render doesn't
// flash the login form at an already-signed-in user. `recovering` is true from the
// moment a reset link lands until the user sets a new password.
window.useSession = function useSession() {
  const { useState, useEffect } = React;
  const [state, setState] = useState({ loading: true, session: null, recovering: false });

  useEffect(() => {
    let alive = true;
    window.sb.auth.getSession().then(({ data }) => {
      if (alive) setState(s => ({ ...s, loading: false, session: data.session || null }));
    });
    const { data: sub } = window.sb.auth.onAuthStateChange((event, session) => {
      if (!alive) return;
      if (event === 'PASSWORD_RECOVERY') setState({ loading: false, session, recovering: true });
      else setState(s => ({ ...s, loading: false, session: session || null,
                              recovering: event === 'SIGNED_OUT' ? false : s.recovering }));
    });
    return () => { alive = false; sub.subscription.unsubscribe(); };
  }, []);

  return { ...state, doneRecovering: () => setState(s => ({ ...s, recovering: false })) };
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

/** The product's mark, shared by every gate screen. */
function AuthBrand() {
  return (
    <div className="auth-brand">
      <span className="sun" />
      <div>
        <div className="auth-brand-name">SynSynk</div>
        <div className="auth-brand-tag">Minute-by-minute solar history, kept for good.</div>
      </div>
    </div>
  );
}

/** Labelled password input with a reveal toggle. type="button" on the eye matters:
 *  inside a form a bare <button> submits, so revealing would sign in half-typed. */
function PasswordField({ id, label, value, onChange, placeholder, autoComplete }) {
  const { useState } = React;
  const [show, setShow] = useState(false);
  return (
    <div className="auth-field">
      <label htmlFor={id}>{label}</label>
      <div className="login-pw">
        <input id={id} type={show ? 'text' : 'password'} placeholder={placeholder} value={value}
               autoComplete={autoComplete} onChange={(e) => onChange(e.target.value)} required minLength={6} />
        <button type="button" className="login-eye" onClick={() => setShow(v => !v)}
                title={show ? 'Hide password' : 'Show password'}
                aria-label={show ? 'Hide password' : 'Show password'} aria-pressed={show}>
          {show ? <EyeOffIcon /> : <EyeIcon />}
        </button>
      </div>
    </div>
  );
}

function AuthScreen({ initialMode = 'signin', onRecovered }) {
  const { useState } = React;
  const [mode, setMode] = useState(initialMode);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [password2, setPassword2] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [note, setNote] = useState(null);

  const go = (m) => { setMode(m); setErr(null); setNote(null); setPassword(''); setPassword2(''); };

  const submit = async (e) => {
    e.preventDefault();
    setBusy(true); setErr(null); setNote(null);
    try {
      if (mode === 'signin') {
        const { error } = await window.sb.auth.signInWithPassword({ email, password });
        if (error) throw error;
      } else if (mode === 'signup') {
        if (password !== password2) throw new Error('Passwords don’t match');
        const { data, error } = await window.sb.auth.signUp({ email, password, options: { emailRedirectTo: SITE_URL } });
        if (error) throw error;
        // With email confirmation on, signUp returns a user but no session.
        if (!data.session) {
          go('signin');
          setNote(`Check ${email} for a confirmation link, then sign in.`);
        }
      } else if (mode === 'forgot') {
        const { error } = await window.sb.auth.resetPasswordForEmail(email, { redirectTo: SITE_URL });
        if (error) throw error;
        setNote(`If ${email} has an account, a reset link is on its way.`);
      } else if (mode === 'recovery') {
        if (password !== password2) throw new Error('Passwords don’t match');
        const { error } = await window.sb.auth.updateUser({ password });
        if (error) throw error;
        onRecovered && onRecovered();
      }
    } catch (ex) {
      setErr(ex.message || String(ex));
    } finally {
      setBusy(false);
    }
  };

  const copy = {
    signin:   { h: 'Welcome back',          p: 'Sign in to your dashboard.',                                                cta: 'Sign in' },
    signup:   { h: 'Create your account',   p: 'This is your dashboard login. You’ll connect your SunSynk account next.',   cta: 'Create account' },
    forgot:   { h: 'Reset your password',   p: 'Enter your email and we’ll send you a link to choose a new one.',            cta: 'Send reset link' },
    recovery: { h: 'Choose a new password', p: 'You’re signed in from the reset link. Set a new password to continue.',     cta: 'Save password' },
  }[mode];

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <AuthBrand />
        <div className="login-title">{copy.h}</div>
        <div className="login-sub">{copy.p}</div>

        {mode !== 'recovery' && (
          <div className="auth-field">
            <label htmlFor="auth-email">Email</label>
            <input id="auth-email" type="email" placeholder="you@example.com" value={email} autoComplete="username"
                   onChange={(e) => setEmail(e.target.value)} required />
          </div>
        )}
        {mode !== 'forgot' && (
          <PasswordField id="auth-password" label={mode === 'signin' ? 'Password' : 'New password'}
                         value={password} onChange={setPassword}
                         placeholder={mode === 'signin' ? '••••••••' : 'At least 6 characters'}
                         autoComplete={mode === 'signin' ? 'current-password' : 'new-password'} />
        )}
        {(mode === 'signup' || mode === 'recovery') && (
          <PasswordField id="auth-password2" label="Confirm password" value={password2} onChange={setPassword2}
                         placeholder="Same again" autoComplete="new-password" />
        )}

        <button type="submit" disabled={busy}>{busy ? '…' : copy.cta}</button>

        {/* Always rendered, even when empty: mounting it only on error grew the card by
            a line and shunted the centred form up under the cursor mid-retype. */}
        <div className={'login-err' + (note && !err ? ' login-note' : '')} role="alert" aria-live="polite">
          {err || note}
        </div>

        <div className="login-links">
          {mode === 'signin' && (<>
            <span>New here? <button type="button" className="login-link" onClick={() => go('signup')}>Create an account</button></span>
            <button type="button" className="login-link quiet" onClick={() => go('forgot')}>Forgot password?</button>
          </>)}
          {mode === 'signup' && (
            <span>Already have an account? <button type="button" className="login-link" onClick={() => go('signin')}>Sign in</button></span>
          )}
          {mode === 'forgot' && (
            <button type="button" className="login-link quiet" onClick={() => go('signin')}>← Back to sign in</button>
          )}
          {mode === 'recovery' && (
            <button type="button" className="login-link quiet" onClick={() => window.sb.auth.signOut()}>Cancel</button>
          )}
        </div>
      </form>
    </div>
  );
}

/** Renders children only when signed in and not mid-password-reset. */
window.AuthGate = function AuthGate({ children }) {
  const { loading, session, recovering, doneRecovering } = window.useSession();
  if (loading) return <div className="login-wrap"><div className="login-card"><AuthBrand /><div className="login-sub">Loading…</div></div></div>;
  if (recovering) return <AuthScreen initialMode="recovery" onRecovered={doneRecovering} />;
  if (!session) return <AuthScreen />;
  return children;
};

window.signOut = () => window.sb.auth.signOut();
// Shared with the Connect screen so it looks like the same product.
Object.assign(window, { EyeIcon, EyeOffIcon, AuthBrand, PasswordField });
