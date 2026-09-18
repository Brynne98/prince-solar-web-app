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
//
// Sign-in and sign-up also offer "Continue with Google". Supabase runs the OAuth
// dance and brings the user back to SITE_URL with the session in the URL fragment
// (implicit flow, same as the emailed links), which supabase-js consumes and strips
// on load, so the same onAuthStateChange path lights the app up. A Google account
// whose email already has a password login is linked to it. A denied or failed
// round trip comes back as #error_description=…, which the sign-in card shows.
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
      // Whoever signs in next starts on the dashboard, not on the Settings tab the
      // last person signed out from.
      else if (event === 'SIGNED_OUT') { localStorage.removeItem('synsynk.tab'); setState({ loading: false, session: null, recovering: false }); }
      else setState(s => ({ ...s, loading: false, session: session || null,
                              recovering: event === 'SIGNED_OUT' ? false : s.recovering }));
    });
    return () => { alive = false; sub.subscription.unsubscribe(); };
  }, []);

  return { ...state, doneRecovering: () => setState(s => ({ ...s, recovering: false })) };
};

// Eye / eye-with-a-line-through-it, for the reveal toggle.
const EyeIcon = () => (
  <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M1.5 10S4.5 4.5 10 4.5 18.5 10 18.5 10 15.5 15.5 10 15.5 1.5 10 1.5 10Z" />
    <circle cx="10" cy="10" r="2.5" />
  </svg>
);
const EyeOffIcon = () => (
  <svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <path d="M8.1 4.7A7.7 7.7 0 0 1 10 4.5c5.5 0 8.5 5.5 8.5 5.5a15 15 0 0 1-2.4 3.1M4.4 6A15 15 0 0 0 1.5 10S4.5 15.5 10 15.5c1.2 0 2.2-.2 3.2-.6" />
    <path d="M8.3 8.3a2.5 2.5 0 0 0 3.4 3.4" />
    <path d="M2.5 2.5l15 15" />
  </svg>
);

/** Google's four-colour G, as drawn in their sign-in branding guide. */
const GoogleMark = () => (
  <svg width="20" height="20" viewBox="0 0 48 48" aria-hidden="true">
    <path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9.1 3.6l6.8-6.8C35.8 2.5 30.3 0 24 0 14.6 0 6.5 5.4 2.6 13.2l7.9 6.1C12.4 13.7 17.7 9.5 24 9.5z"/>
    <path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v8.5h12.7c-.6 2.9-2.2 5.4-4.7 7.1l7.6 5.9c4.4-4.1 6.9-10.1 6.9-17z"/>
    <path fill="#FBBC05" d="M10.5 28.7c-.5-1.5-.8-3-.8-4.7s.3-3.2.8-4.7l-7.9-6.1C1 16.5 0 20.1 0 24s1 7.5 2.6 10.8l7.9-6.1z"/>
    <path fill="#34A853" d="M24 48c6.5 0 11.9-2.1 15.9-5.8l-7.6-5.9c-2.1 1.4-4.9 2.3-8.3 2.3-6.3 0-11.6-4.2-13.5-9.9l-7.9 6.1C6.5 42.6 14.6 48 24 48z"/>
  </svg>
);

/** The product's mark, shared by every gate screen. */
function AuthBrand() {
  return (
    <div className="auth-brand">
      <span className="sun" />
      <div>
        <div className="auth-brand-name">Prince Solar</div>
        <div className="auth-brand-tag">Minute-by-minute solar history, kept forever.</div>
      </div>
    </div>
  );
}

/** Labelled password input with a reveal toggle. type="button" on the eye matters:
 *  inside a form a bare <button> submits, so revealing would sign in half-typed. */
function PasswordField({ id, label, value, onChange, placeholder, autoComplete, error, hint }) {
  const { useState } = React;
  const [show, setShow] = useState(false);
  return (
    <div className="auth-field">
      <FieldLabel id={id} label={label} error={error} hint={hint} />
      <div className="login-pw">
        <input id={id} type={show ? 'text' : 'password'} placeholder={placeholder} value={value}
               autoComplete={autoComplete} onChange={(e) => onChange(e.target.value)} required minLength={6}
               {...(error ? invalidProps(id, error) : hint ? { 'aria-describedby': `${id}-hint` } : {})} />
        <button type="button" className="login-eye" onClick={() => setShow(v => !v)}
                title={show ? 'Hide password' : 'Show password'}
                aria-label={show ? 'Hide password' : 'Show password'} aria-pressed={show}>
          {show ? <EyeOffIcon /> : <EyeIcon />}
        </button>
      </div>
    </div>
  );
}

/** Marks a field invalid and ties it to its message (`describedBy` defaults to the label-line one). */
const invalidProps = (id, error, describedBy = `${id}-err`) =>
  error ? { 'aria-invalid': true, 'aria-describedby': describedBy } : {};

/** The label, with the field's error (or, when there is none, a standing hint) on the same
 *  line, so neither ever grows the card. */
const FieldLabel = ({ id, label, error, hint }) => (
  <div className="auth-label-row">
    <label htmlFor={id}>{label}</label>
    {error ? <span id={`${id}-err`} className="field-err">{error}</span>
           : hint && <span id={`${id}-hint`} className="field-hint">{hint}</span>}
  </div>
);

/** Supabase's own error text is written for developers; say it in the household's words.
 *  Returns the message, and the field it belongs to or a follow-up action when there is one. */
function explain(ex) {
  const code = ex?.code;
  if (code === 'invalid_credentials') return { text: 'Email or password is wrong.' };
  if (code === 'email_not_confirmed') return { text: 'Confirm your email first. The link is in your inbox.' };
  if (code === 'user_already_exists' || code === 'email_exists') return { text: 'That email already has an account.', action: 'signin' };
  if (code === 'weak_password') {
    const reasons = ex.reasons || [];
    if (reasons.includes('pwned')) return { text: 'That password has appeared in a data leak. Choose another.' };
    return { field: 'auth-password', text: reasons.includes('characters') ? 'Mix letters, numbers and symbols' : 'Choose a longer password' };
  }
  if (code === 'same_password') return { field: 'auth-password', text: 'That’s your current password' };
  if (code === 'email_address_invalid') return { field: 'auth-email', text: 'Use a different email' };
  if (code === 'signup_disabled') return { text: 'New accounts are closed right now.' };
  if (code === 'over_email_send_rate_limit') return { text: 'Too many emails sent. Wait a few minutes, then try again.' };
  if (code === 'over_request_rate_limit' || ex?.status === 429) return { text: 'Too many tries. Wait a minute, then try again.' };
  if (ex?.name === 'AuthRetryableFetchError' || ex instanceof TypeError) return { text: 'Can’t reach Prince Solar. Check your connection and try again.' };
  return { text: ex?.message || 'Something went wrong. Try again.' };
}

function AuthScreen({ initialMode = 'signin', onRecovered }) {
  const { useState } = React;
  const [mode, setMode] = useState(initialMode);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [password2, setPassword2] = useState('');
  // false, or the button that is waiting ('form' or 'google'); only that one says so.
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [note, setNote] = useState(null);
  const [agree, setAgree] = useState(false);

  // A failed Google round trip lands here signed out with the reason in the URL.
  // The back button restores the page from cache with `busy` still set, so clear it.
  React.useEffect(() => {
    // Email links (confirm, reset) come back the same way when they are stale.
    const params = new URLSearchParams(location.hash.slice(1) || location.search);
    if (params.get('error_description')) {
      setErr(params.get('error_code') === 'otp_expired'
        ? 'That link has expired. Ask for a new one.'
        : 'Sign-in didn’t finish. Try again.');
      history.replaceState(null, '', location.pathname);
    }
    const onShow = (e) => { if (e.persisted) setBusy(false); };
    window.addEventListener('pageshow', onShow);
    return () => window.removeEventListener('pageshow', onShow);
  }, []);

  // Field id → its message. Every problem at once, each shown under its own field.
  const [bad, setBad] = useState({});

  const go = (m) => { setMode(m); setErr(null); setNote(null); setBad({}); setPassword(''); setPassword2(''); };

  // Replaces the browser's own bubbles (noValidate), which named one field in a popup.
  const check = () => {
    const newPw = mode === 'signup' || mode === 'recovery';
    const out = {};
    if (mode !== 'recovery') {
      if (!email.trim()) out['auth-email'] = 'Enter your email';
      else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) out['auth-email'] = 'Enter a valid email';
    }
    if (mode !== 'forgot') {
      if (!password) out['auth-password'] = mode === 'signin' ? 'Enter your password' : 'Choose a password';
      // Matches the minimum set in Supabase (Auth → Email) and supabase/config.toml.
      else if (newPw && password.length < 8) out['auth-password'] = 'Use at least 8 characters';
    }
    if (newPw) {
      if (!password2) out['auth-password2'] = 'Confirm your password';
      else if (password !== password2) out['auth-password2'] = 'Passwords don’t match';
    }
    if (mode === 'signup' && !agree) out['auth-agree'] = 'Accept the Terms and Privacy Policy';
    return out;
  };

  // Focus the first bad field after React commits, so it already reads as invalid.
  const flag = (problems) => {
    setBad(problems); setErr(null); setNote(null);
    // Blur first: re-focusing a field that already has focus is silent to a screen reader.
    setTimeout(() => { const el = document.getElementById(Object.keys(problems)[0]); el?.blur(); el?.focus(); });
  };
  // Editing a field clears only its own message.
  const edited = (...ids) => setBad(b => {
    if (!ids.some(id => b[id])) return b;
    const next = { ...b };
    ids.forEach(id => delete next[id]);
    return next;
  });

  const submit = async (e) => {
    e.preventDefault();
    const problems = check();
    if (Object.keys(problems).length) return flag(problems);
    const addr = email.trim();
    setBusy('form'); setErr(null); setNote(null); setBad({});
    try {
      if (mode === 'signin') {
        const { error } = await window.sb.auth.signInWithPassword({ email: addr, password });
        if (error) throw error;
      } else if (mode === 'signup') {
        const { data, error } = await window.sb.auth.signUp({ email: addr, password, options: { emailRedirectTo: SITE_URL } });
        if (error) throw error;
        // With email confirmation on, signUp returns a user but no session.
        if (!data.session) {
          go('signin');
          setNote(`Check ${addr} for a confirmation link, then sign in.`);
        }
      } else if (mode === 'forgot') {
        const { error } = await window.sb.auth.resetPasswordForEmail(addr, { redirectTo: SITE_URL });
        if (error) throw error;
        setNote(`If ${addr} has an account, a reset link is on its way.`);
      } else if (mode === 'recovery') {
        const { error } = await window.sb.auth.updateUser({ password });
        if (error) throw error;
        onRecovered && onRecovered();
      }
    } catch (ex) {
      const e = explain(ex);
      if (e.field) flag({ [e.field]: e.text }); else setErr(e);
    } finally {
      setBusy(false);
    }
  };

  // Leaves the page on success, so `busy` stays set until the redirect lands.
  const google = async () => {
    if (mode === 'signup' && !agree) return flag({ 'auth-agree': 'Accept the Terms and Privacy Policy' });
    setBusy('google'); setErr(null); setNote(null); setBad({});
    // select_account: a household shares a tablet, so always offer the account list.
    const { error } = await window.sb.auth.signInWithOAuth({
      provider: 'google', options: { redirectTo: SITE_URL, queryParams: { prompt: 'select_account' } },
    });
    if (error) { setErr(explain(error)); setBusy(false); }
  };

  const copy = {
    signin:   { h: 'Welcome back',          p: null,                                                   cta: 'Sign in',         busy: 'Signing in…' },
    signup:   { h: 'Create your account',   p: 'Your Prince Solar login. You’ll connect SunSynk next.', cta: 'Create account',  busy: 'Creating account…' },
    forgot:   { h: 'Reset your password',   p: 'We’ll email you a link to choose a new one.',          cta: 'Send reset link', busy: 'Sending…' },
    recovery: { h: 'Choose a new password', p: 'Set a new password to continue.',                      cta: 'Save password',   busy: 'Saving…' },
  }[mode];

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit} noValidate aria-busy={!!busy}>
        <AuthBrand />
        <div className="login-title">{copy.h}</div>
        {copy.p && <div className="login-sub">{copy.p}</div>}

        {mode !== 'recovery' && (
          <div className="auth-field">
            <FieldLabel id="auth-email" label="Email" error={bad['auth-email']} />
            <input id="auth-email" type="email" placeholder="you@example.com" value={email} autoComplete="username"
                   onChange={(e) => { setEmail(e.target.value); edited('auth-email'); }}
                   {...invalidProps('auth-email', bad['auth-email'])} />
          </div>
        )}
        {mode !== 'forgot' && (
          <PasswordField id="auth-password" label={mode === 'recovery' ? 'New password' : 'Password'}
                         value={password} error={bad['auth-password']}
                         onChange={(v) => { setPassword(v); edited('auth-password', 'auth-password2'); }}
                         hint={mode === 'signin' ? null : '8+ characters'}
                         placeholder={mode === 'signin' ? 'Your password' : 'Choose a password'}
                         autoComplete={mode === 'signin' ? 'current-password' : 'new-password'} />
        )}
        {(mode === 'signup' || mode === 'recovery') && (
          <PasswordField id="auth-password2" label="Confirm password" value={password2}
                         error={bad['auth-password2']}
                         onChange={(v) => { setPassword2(v); edited('auth-password2'); }}
                         placeholder="Type it again" autoComplete="new-password" />
        )}

        {mode === 'signup' && (
          <label className={'auth-consent' + (bad['auth-agree'] ? ' invalid' : '')}>
            <input id="auth-agree" type="checkbox" checked={agree}
                   onChange={(e) => { setAgree(e.target.checked); edited('auth-agree'); }}
                   {...invalidProps('auth-agree', bad['auth-agree'])} />
            <span>I agree to the <a href="?page=terms" target="_blank" rel="noopener">Terms of Service</a> and <a href="?page=privacy" target="_blank" rel="noopener">Privacy Policy</a>.</span>
            {/* The sentence turns red instead of adding a line; this names the problem for screen readers. */}
            {bad['auth-agree'] && <span id="auth-agree-err" className="sr-only">{bad['auth-agree']}</span>}
          </label>
        )}
        <button type="submit" disabled={!!busy} aria-busy={busy === 'form'}>{busy === 'form' ? copy.busy : copy.cta}</button>

        {/* Always mounted so it works as a live region; empty, it takes no space. */}
        <div id="auth-msg" className={'login-err' + (note && !err ? ' login-note' : '')} role="alert" aria-live="polite">
          {err?.text ?? err ?? note}
          {err?.action === 'signin' && <> <button type="button" className="login-link" onClick={() => go('signin')}>Sign in</button></>}
        </div>

        {(mode === 'signin' || mode === 'signup') && (<>
          <div className="login-or"><span>or</span></div>
          <button type="button" className="login-google" onClick={google} disabled={!!busy} aria-busy={busy === 'google'}>
            <GoogleMark /> {busy === 'google' ? 'Opening Google…' : 'Continue with Google'}
          </button>
          {mode === 'signin' && (
            <div className="login-fine">Continuing with Google creates an account and accepts
              the <a href="?page=terms" target="_blank" rel="noopener">Terms</a> and <a href="?page=privacy" target="_blank" rel="noopener">Privacy Policy</a>.</div>
          )}
        </>)}

        <div className="login-links">
          {mode === 'signin' && (<>
            <button type="button" className="login-link" onClick={() => go('signup')}>Create an account</button>
            <button type="button" className="login-link quiet" onClick={() => go('forgot')}>Forgot password?</button>
          </>)}
          {mode === 'signup' && (
            <span>Already have an account? <button type="button" className="login-link" onClick={() => go('signin')}>Sign in</button></span>
          )}
          {mode === 'forgot' && (
            <button type="button" className="login-link quiet" onClick={() => go('signin')}>Back to sign in</button>
          )}
          {mode === 'recovery' && (
            <SignOutButton className="login-link quiet" busyText="Cancelling…">Cancel</SignOutButton>
          )}
        </div>
      </form>
    </div>
  );
}

/** Renders children only when signed in and not mid-password-reset. */
window.AuthGate = function AuthGate({ children, fallback = null }) {
  const { loading, session, recovering, doneRecovering } = window.useSession();
  // A stored session will almost always come back signed in, so show the dashboard's
  // shape; with none, the sign-in screen is a moment away and a skeleton would mislead.
  if (loading) return localStorage.getItem('synsynk.auth') ? fallback : null;
  // Keyed apart: the two sit in one spot, so React would otherwise keep the recovery
  // card's mode (and its busy Cancel) after Cancel signs out.
  if (recovering) return <AuthScreen key="recovery" initialMode="recovery" onRecovered={doneRecovering} />;
  if (!session) return <AuthScreen key="signin" />;
  return children;
};

// Signs out this device only: the wall tablet stays signed in when a phone signs out.
// That still waits on a server round trip before the screen changes, so the button says
// it is working. It is never reset: the session ends either way, and that unmounts it.
// supabase-js 2.58 keeps the session when that call fails (offline, a 5xx), which left
// the button doing nothing. Newer releases clear it locally then; _removeSession is that
// same step (storage, then SIGNED_OUT to every tab), safe to call on the pinned build.
function SignOutButton({ className, children = 'Sign out', busyText = 'Signing out…' }) {
  const [busy, setBusy] = React.useState(false);
  const click = async () => {
    setBusy(true);
    const { error } = await window.sb.auth.signOut({ scope: 'local' }).catch(e => ({ error: e }));
    if (error) await window.sb.auth._removeSession();
  };
  return <button type="button" className={className} onClick={click} disabled={busy} aria-busy={busy}>{busy ? busyText : children}</button>;
}
// Shared with the Connect screen so it looks like the same product.
Object.assign(window, { EyeIcon, EyeOffIcon, AuthBrand, PasswordField, FieldLabel, invalidProps, SignOutButton });
