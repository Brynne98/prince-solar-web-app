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
//   signup    email + password, Google first. If the project requires email
//             confirmation it moves on to `inbox`; otherwise they land straight in
//             the app (and then on the Connect screen, step 2 of 2).
//   inbox     "Check your inbox": no form. The emailed link signs them in, and a
//             sign-in in another tab of this browser reaches this one too
//             (supabase-js broadcasts it), so the screen moves on by itself.
//   forgot    email → reset link
//   recovery  reached from the reset link. Supabase signs the user in with a
//             short-lived session and fires PASSWORD_RECOVERY; we ask for the new
//             password and call updateUser. Until then the app is gated.
//
// Sign-in and sign-up also offer "Continue with Google", as Google's own button
// (SOLAR-122). It signs in through a Google popup on this page and hands back an ID
// token, which signInWithIdToken trades for a session, so the same onAuthStateChange
// path lights the app up. Google's popup names this site, not the Supabase host that
// a redirect would go through. A Google account whose email already has a password
// login is linked to it. There is no redirect fallback: it would go through
// supabase.co, which Google's brand check won't accept as ours. If Google's script
// is blocked, the card says so and email sign-in still works.
// ============================================================================

window.sb = window.supabase.createClient(
  window.SUNSYNK_CONFIG.url,
  window.SUNSYNK_CONFIG.key,
  { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'synsynk.auth' },
    global: { fetch: fetchWithRefreshCutoff } }
);

// supabase-js renews an expired sign-in before any other request goes out, holding a
// lock until the renewal answers, and sends it with no time limit. A tablet waking up
// can send it on a connection that died while asleep, so it never answers and every
// read waits behind it ("Couldn't check your SunSynk logins — timed out", SOLAR-21).
// Cut the renewal off after 5 s; supabase-js counts that as a network failure and
// sends it again, on a fresh connection. Only the renewal: sign-up and other calls
// can rightly take longer.
function fetchWithRefreshCutoff(url, opts) {
  if (!String(url).includes('grant_type=refresh_token') || (opts && opts.signal)) return fetch(url, opts);
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 5000);
  return fetch(url, { ...opts, signal: ctl.signal }).finally(() => clearTimeout(timer));
}

// Where emailed links (confirmation, password reset) bring the user back to.
const SITE_URL = location.origin + location.pathname.replace(/\/[^/]*$/, '/');
// Reset links come back tagged, so an expired one can be told from a confirmation (SOLAR-198).
const RESET_URL = SITE_URL + '?link=reset';

// "Reset password" in the password-changed email links to ?reset=1 (SOLAR-155). Signed in,
// it opens Change password on Account; signed out, "Forgot password?". Read once and taken
// out of the address, so a reload or a later sign-in doesn't open it again.
let resetPending = new URLSearchParams(location.search).get('reset') === '1';
if (resetPending) {
  const u = new URL(location.href);
  u.searchParams.delete('reset');
  history.replaceState(null, '', u.pathname + u.search + u.hash);
}
window.resetAsked = () => resetPending;
window.takeResetAsk = () => { const r = resetPending; resetPending = false; return r; };

// Resolves once the initial session lookup is done, so the first render doesn't
// flash the login form at an already-signed-in user. `recovering` is true from the
// moment a reset link lands until the user sets a new password.
window.useSession = function useSession() {
  const { useState, useEffect } = React;
  const [state, setState] = useState({ loading: true, session: null, recovering: false });

  useEffect(() => {
    let alive = true;
    window.sb.auth.getSession().then(({ data }) => {
      if (data.session) window.identifyUser(data.session.user.id);
      if (alive) setState(s => ({ ...s, loading: false, session: data.session || null }));
    });
    const { data: sub } = window.sb.auth.onAuthStateChange((event, session) => {
      // A first sign-in is a sign-up: email confirmed (or Google account made) and signed in
      // in the same minute, and that minute is now (SOLAR-85).
      if (event === 'SIGNED_IN' && session) {
        const u = session.user, last = Date.parse(u.last_sign_in_at);
        window.identifyUser(u.id);
        if (Math.abs(last - Date.parse(u.email_confirmed_at || u.created_at)) < 60000 && Date.now() - last < 60000)
          window.track('sign_up_done', { method: u.app_metadata?.provider });
      }
      if (event === 'SIGNED_OUT') window.identifyUser(null);
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

/** "Continue with Google" (SOLAR-122), in our own look over Google's real button. Signs in through a Google
 *  popup and passes the ID token to Supabase. Google hashes the nonce we give it into
 *  the token; Supabase checks the token against the plain one. Google's button only
 *  comes in its own look (and turns into "Continue as <name>"), so it sits invisible
 *  on top of ours, stretched to cover it, and takes the click. `blocked` lays a
 *  click-catcher over both (sign-up before the Terms are ticked), since clicks inside
 *  Google's frame can't be stopped. */
function GoogleSignIn({ blocked, onBlocked, onStart, onDone }) {
  const { useState, useEffect, useRef } = React;
  const box = useRef(null);
  const [state, setState] = useState('loading'); // loading | ready | failed
  // Kept current for Google's callback, which is registered once.
  const cbs = useRef({});
  cbs.current = { onStart, onDone };

  useEffect(() => {
    let alive = true, tries = 0;
    const raw = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
    // Google's script (276 KB) loads only for the sign-in screen, not on every open
    // (SOLAR-143). No integrity hash: Google updates it in place (SOLAR-122).
    if (!document.getElementById('gsi-client')) {
      const s = document.createElement('script');
      s.id = 'gsi-client'; s.src = 'https://accounts.google.com/gsi/client'; s.async = true;
      document.head.appendChild(s);
    }
    const setup = async () => {
      if (!alive) return;
      if (!window.google?.accounts?.id) {
        // async script: wait up to 10 s, then give up on it.
        if (++tries > 50) return setState('failed');
        return setTimeout(setup, 200);
      }
      const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw));
      if (!alive) return;
      window.google.accounts.id.initialize({
        client_id: window.GOOGLE_CLIENT_ID,
        nonce: Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, '0')).join(''),
        auto_select: false,
        callback: async ({ credential }) => {
          cbs.current.onStart();
          const { error } = await window.sb.auth.signInWithIdToken({ provider: 'google', token: credential, nonce: raw });
          cbs.current.onDone(error);
        },
      });
      window.google.accounts.id.renderButton(box.current, {
        type: 'standard', theme: 'filled_black', size: 'large', shape: 'rectangular',
        text: 'continue_with', logo_alignment: 'center', width: Math.min(400, box.current.offsetWidth || 320),
      });
      // Stretch Google's button over ours so every part of ours opens Google.
      const g = box.current.firstElementChild;
      if (g && g.offsetWidth && g.offsetHeight) {
        g.style.transform = `scale(${box.current.offsetWidth / g.offsetWidth}, ${box.current.offsetHeight / g.offsetHeight})`;
      }
      setState('ready');
    };
    setup();
    return () => { alive = false; };
  }, []);

  // Blocked by a privacy setting or extension, or Google is down: the button goes, a toast says why.
  useEffect(() => { if (state === 'failed') sayError('Google sign-in didn’t load. Use your email instead.'); }, [state]);
  if (state === 'failed') return null;
  return (
    <div className="gsi-wrap">
      <div className="login-google" aria-hidden="true"><GoogleMark /> Continue with Google</div>
      <div ref={box} className="gsi-box" />
      {blocked && <button type="button" className="gsi-block" onClick={onBlocked} aria-label="Continue with Google" />}
    </div>
  );
}

/** The product's mark, shared by every gate screen. */
function AuthBrand() {
  return (
    <div className="auth-brand">
      <span className="sun" />
      <div>
        <div className="auth-brand-name">Prince Solar Hub</div>
        <div className="auth-brand-tag">Your solar history, kept for good.</div>
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
  if (code === 'email_not_confirmed') return { text: 'Confirm your email first.', action: 'resend' };
  if (code === 'user_already_exists' || code === 'email_exists') return { text: 'That email already has an account.', action: 'signin' };
  if (code === 'weak_password') {
    const reasons = ex.reasons || [];
    if (reasons.includes('pwned')) return { text: 'That password was in a data leak. Choose another.' };
    return { field: 'auth-password', text: reasons.includes('characters') ? 'Mix letters, numbers and symbols' : 'Choose a longer password' };
  }
  if (code === 'same_password') return { field: 'auth-password', text: 'That’s your current password' };
  if (code === 'email_address_invalid') return { field: 'auth-email', text: 'Use a different email' };
  if (code === 'signup_disabled') return { text: 'New accounts are closed right now.' };
  if (code === 'over_email_send_rate_limit') return { text: 'Too many emails sent. Try again in a few minutes.' };
  if (code === 'over_request_rate_limit' || ex?.status === 429) return { text: 'Too many tries. Try again in a minute.' };
  if (ex?.name === 'AuthRetryableFetchError' || ex instanceof TypeError) return { text: 'Can’t reach Prince Solar Hub. Check your connection.' };
  // hook_tester_places (0085) refuses new accounts with this message.
  if (/Tester places are full/i.test(ex?.message || '')) return { text: 'Tester places are full.', action: 'full' };
  // Never the server's own words (SOLAR-163).
  return { text: 'Something went wrong. Try again.' };
}

/** A problem that isn't about one field: a red toast at the foot of the screen (SOLAR-163).
 *  `action` is a follow-up link in the toast, e.g. { label: 'Sign in', onClick }. */
const sayError = (text, action) => window.toast?.(text, { error: true, action });

/** Sign-up once every tester place is taken: an email box for the launch. */
function PlacesFullCard({ places, onSignIn }) {
  const { useState } = React;
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [msg, setMsg] = useState(null);
  const submit = async (e) => {
    e.preventDefault();
    const addr = email.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(addr)) { setMsg('Enter a valid email'); return; }
    setBusy(true); setMsg(null);
    // supabase-js query builders are thenables without .catch.
    const { error } = await Promise.resolve(window.sb.rpc('api_join_waitlist', { p_email: addr })).catch(e => ({ error: e }));
    setBusy(false);
    if (error) sayError(explain(error).text);
    else setDone(true);
  };
  return (
    <form className="login-card" onSubmit={submit} noValidate aria-busy={busy}>
      <AuthBrand />
      <div className="login-title">Tester places are full</div>
      {done ? (
        <div className="login-sub">You’re on the list. We’ll email you when Prince Solar Hub opens to everyone.</div>
      ) : (<>
        <div className="login-sub">{places ? `All ${places} places are taken. ` : ''}More open when we launch. Leave your email and we’ll let you know.</div>
        <div className="auth-field">
          <FieldLabel id="wait-email" label="Email" error={msg} />
          <input id="wait-email" type="email" placeholder="you@example.com" value={email} autoComplete="email"
                 onChange={(e) => { setEmail(e.target.value); setMsg(null); }}
                 {...invalidProps('wait-email', msg)} />
        </div>
        <button type="submit" disabled={busy} aria-busy={busy}>{busy ? 'Saving…' : 'Notify me'}</button>
      </>)}
      <div className="login-links">
        <span>Already have an account? <button type="button" className="login-link" onClick={onSignIn}>Sign in</button></span>
      </div>
    </form>
  );
}

// Supabase refuses a second email to one address within 60 s.
const RESEND_WAIT = 60;

/** After sign-up (kind 'signup') or a reset request (kind 'reset'), until the emailed link
 *  is tapped. One screen for both (SOLAR-163). Resend waits out the 60 s, so one tap sends
 *  one email; it is green once it can be used. */
function InboxCard({ kind, email, onBack, onSignIn }) {
  const { useState, useEffect } = React;
  const [wait, setWait] = useState(RESEND_WAIT);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (wait <= 0) return;
    const t = setTimeout(() => setWait(w => w - 1), 1000);
    return () => clearTimeout(t);
  }, [wait]);
  const resend = async (e) => {
    e.preventDefault();
    if (busy || wait > 0) return;
    setBusy(true);
    const { error } = await (kind === 'reset'
      ? window.sb.auth.resetPasswordForEmail(email, { redirectTo: RESET_URL })
      : window.sb.auth.resend({ type: 'signup', email, options: { emailRedirectTo: SITE_URL } })
    ).catch(e => ({ error: e }));
    setBusy(false);
    if (error) sayError(explain(error).text);
    else { window.toast?.('Email sent again.'); setWait(RESEND_WAIT); }
  };
  return (
    <form className="login-card" onSubmit={resend} aria-busy={busy}>
      <AuthBrand />
      <div className="login-title">Check your inbox</div>
      <div className="login-sub">We sent a link to <b>{email}</b>. Tap it to carry on.</div>
      <button type="submit" className="auth-resend" disabled={busy || wait > 0} aria-busy={busy}>
        {busy ? 'Sending…' : wait > 0 ? `Resend in ${wait}s` : 'Resend email'}
      </button>
      <div className="login-links">
        <button type="button" className="login-link quiet" onClick={onBack}>Wrong email?</button>
        {kind === 'reset'
          ? <button type="button" className="login-link quiet" onClick={onSignIn}>Back to sign in</button>
          : <span>Already confirmed? <button type="button" className="login-link" onClick={onSignIn}>Sign in</button></span>}
      </div>
    </form>
  );
}

function AuthScreen({ initialMode = 'signin', onRecovered }) {
  const { useState, useEffect } = React;
  const [mode, setMode] = useState(initialMode);
  useEffect(() => { window.track('screen_viewed', { stage: 'sign_in', screen: mode }); }, [mode]);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [password2, setPassword2] = useState('');
  // false, or the button that is waiting ('form' or 'google'); only that one says so.
  const [busy, setBusy] = useState(false);
  const [agree, setAgree] = useState(false);
  // Where the link went and why ('signup' or 'reset'), for Check your inbox.
  const [sent, setSent] = useState(null);
  // { places, left } from api_tester_places; null until it answers or if it fails.
  const [places, setPlaces] = useState(null);
  React.useEffect(() => {
    window.sb.rpc('api_tester_places').then(({ data }) => data && setPlaces(data), () => {});
  }, []);
  // Signed out, the app frame (and its toast) isn't mounted, so each screen mounts it (SOLAR-163).
  const toastHost = window.SaveToast ? <window.SaveToast /> : null;
  // The hook said no: the count was stale, or this was a new Google account on the sign-in card.
  const showError = (error) => {
    const e = explain(error);
    if (e.action === 'full') { setPlaces(p => ({ places: p?.places ?? 0, left: 0 })); go('signup'); }
    else if (e.field) flag({ [e.field]: e.text });
    else if (e.action === 'resend') sayError(e.text, { label: 'Send a new link', onClick: () => resend(email.trim()).catch(showError) });
    else sayError(e.text, e.action === 'signin' ? { label: 'Sign in', onClick: () => go('signin') } : undefined);
  };
  // A new confirmation link, from the expired-link card or the not-confirmed toast (SOLAR-196).
  // Supabase answers the same for unknown and already-confirmed emails, so this always moves on.
  const resend = async (addr) => {
    const { error } = await window.sb.auth.resend({ type: 'signup', email: addr, options: { emailRedirectTo: SITE_URL } });
    if (error) throw error;
    setSent({ to: addr, kind: 'signup', from: mode }); go('inbox');
  };

  // A stale email link (confirm, reset) lands here signed out with the reason in the URL.
  // The back button restores the page from cache with `busy` still set, so clear it.
  React.useEffect(() => {
    const params = new URLSearchParams(location.hash.slice(1) || location.search);
    if (params.get('error_description')) {
      // The link carries no email, so the expired card asks for it (SOLAR-196). An expired
      // reset link goes to Forgot password, which already asks for one (SOLAR-198).
      if (params.get('error_code') !== 'otp_expired') sayError('Sign-in didn’t finish. Try again.');
      else if (new URLSearchParams(location.search).get('link') === 'reset') { go('forgot'); sayError('That link has expired.'); }
      else go('expired');
      history.replaceState(null, '', location.pathname);
    }
    const onShow = (e) => { if (e.persisted) setBusy(false); };
    window.addEventListener('pageshow', onShow);
    return () => window.removeEventListener('pageshow', onShow);
  }, []);

  // Field id → its message. Every problem at once, each shown under its own field.
  const [bad, setBad] = useState({});

  const go = (m) => { setMode(m); setBad({}); setPassword(''); setPassword2(''); };

  // Replaces the browser's own bubbles (noValidate), which named one field in a popup.
  const check = () => {
    const newPw = mode === 'signup' || mode === 'recovery';
    const out = {};
    if (mode !== 'recovery') {
      if (!email.trim()) out['auth-email'] = 'Enter your email';
      else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) out['auth-email'] = 'Enter a valid email';
    }
    if (mode !== 'forgot' && mode !== 'expired') {
      if (!password) out['auth-password'] = mode === 'signin' ? 'Enter your password' : 'Choose a password';
      // Matches the minimum set in Supabase (Auth → Email) and supabase/config.toml.
      else if (newPw && password.length < 8) out['auth-password'] = 'Use at least 8 characters';
    }
    if (mode === 'recovery') {
      if (!password2) out['auth-password2'] = 'Confirm your password';
      else if (password !== password2) out['auth-password2'] = 'Passwords don’t match';
    }
    if (mode === 'signup' && !agree) out['auth-agree'] = 'Accept the Terms and Privacy Policy';
    return out;
  };

  // Focus the first bad field after React commits, so it already reads as invalid.
  const flag = (problems) => {
    setBad(problems);
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
    setBusy('form'); setBad({});
    try {
      if (mode === 'signin') {
        const { error } = await window.sb.auth.signInWithPassword({ email: addr, password });
        if (error) throw error;
      } else if (mode === 'signup') {
        const { data, error } = await window.sb.auth.signUp({ email: addr, password, options: { emailRedirectTo: SITE_URL } });
        if (error) throw error;
        // With email confirmation on, signUp returns a user but no session.
        if (!data.session) { setSent({ to: addr, kind: 'signup', from: mode }); go('inbox'); }
      } else if (mode === 'forgot') {
        const { error } = await window.sb.auth.resetPasswordForEmail(addr, { redirectTo: RESET_URL });
        if (error) throw error;
        setSent({ to: addr, kind: 'reset', from: mode }); go('inbox');
      } else if (mode === 'expired') {
        await resend(addr);
      } else if (mode === 'recovery') {
        const { error } = await window.sb.auth.updateUser({ password });
        if (error) throw error;
        onRecovered && onRecovered();
      }
    } catch (ex) {
      showError(ex);
    } finally {
      setBusy(false);
    }
  };

  const copy = {
    signin:   { h: 'Welcome back',          p: null,                                                   cta: 'Sign in',         busy: 'Signing in…' },
    signup:   { h: 'Create your account',   p: null,                                                   cta: 'Create account',  busy: 'Creating account…' },
    forgot:   { h: 'Reset your password',   p: 'We’ll email you a link to choose a new one.',          cta: 'Send reset link', busy: 'Sending…' },
    recovery: { h: 'Choose a new password', p: 'Set a new password to continue.',                      cta: 'Save password',   busy: 'Saving…' },
    expired:  { h: 'That link has expired', p: 'Links last 24 hours. Enter your email and we’ll send a new one.', cta: 'Send a new link', busy: 'Sending…' },
  }[mode];

  if (mode === 'signup' && places?.left === 0) {
    return (
      <div className="login-wrap">
        <PlacesFullCard places={places.places} onSignIn={() => go('signin')} />
        {toastHost}
      </div>
    );
  }

  if (mode === 'inbox') {
    return (
      <div className="login-wrap">
        <InboxCard kind={sent.kind} email={sent.to} onBack={() => go(sent.from)} onSignIn={() => go('signin')} />
        {toastHost}
      </div>
    );
  }

  // Stays mounted while signing in (only hidden), so Google's button isn't drawn twice.
  const googleButton = (<>
    {busy === 'google' && <div className="auth-wait"><span className="auth-spin" aria-hidden="true" />Signing in with Google…</div>}
    <div hidden={busy === 'google'}>
      <GoogleSignIn
        blocked={mode === 'signup' && !agree}
        onBlocked={() => flag({ 'auth-agree': 'Accept the Terms and Privacy Policy' })}
        onStart={() => { setBusy('google'); setBad({}); }}
        onDone={(error) => { if (error) { showError(error); setBusy(false); } }} />
    </div>
  </>);

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit} noValidate aria-busy={!!busy}>
        <AuthBrand />
        <div className="login-title">{copy.h}</div>
        {copy.p && <div className="login-sub">{copy.p}</div>}
        {mode === 'signup' && places?.left > 0 && <div className="login-sub">{places.left} of {places.places} tester places left</div>}
        {/* Google first on sign-in and sign-up (SOLAR-118): one tap, and no confirmation
            email to wait for. On sign-in its terms line sits right under it. */}
        {(mode === 'signin' || mode === 'signup') && (<>
          {googleButton}
          {mode === 'signin' && <div className="login-fine">Continuing with Google creates an account and accepts
            the <a href="terms.html" target="_blank" rel="noopener">Terms</a> and <a href="privacy.html" target="_blank" rel="noopener">Privacy Policy</a>.</div>}
          <div className="login-or"><span>or with email</span></div>
        </>)}

        {mode !== 'recovery' && (
          <div className="auth-field">
            <FieldLabel id="auth-email" label="Email" error={bad['auth-email']} />
            <input id="auth-email" type="email" placeholder="you@example.com" value={email} autoComplete="username"
                   onChange={(e) => { setEmail(e.target.value); edited('auth-email'); }}
                   {...invalidProps('auth-email', bad['auth-email'])} />
          </div>
        )}
        {mode !== 'forgot' && mode !== 'expired' && (
          <PasswordField id="auth-password" label={mode === 'recovery' ? 'New password' : 'Password'}
                         value={password} error={bad['auth-password']}
                         onChange={(v) => { setPassword(v); edited('auth-password', 'auth-password2'); }}
                         hint={mode === 'signin' ? null : '8+ characters'}
                         placeholder={mode === 'signin' ? 'Your password' : 'Choose a password'}
                         autoComplete={mode === 'signin' ? 'current-password' : 'new-password'} />
        )}
        {mode === 'recovery' && (
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
            <span>I agree to the <a href="terms.html" target="_blank" rel="noopener">Terms of Service</a> and <a href="privacy.html" target="_blank" rel="noopener">Privacy Policy</a>.</span>
            {/* The sentence turns red instead of adding a line; this names the problem for screen readers. */}
            {bad['auth-agree'] && <span id="auth-agree-err" className="sr-only">{bad['auth-agree']}</span>}
          </label>
        )}
        <button type="submit" disabled={!!busy} aria-busy={busy === 'form'}>{busy === 'form' ? copy.busy : copy.cta}</button>

        {/* Grey links that go back on the left, the way forward in green on the right. */}
        <div className="login-links">
          {mode === 'signin' && (<>
            <button type="button" className="login-link quiet" onClick={() => go('forgot')}>Forgot password?</button>
            <button type="button" className="login-link" onClick={() => go('signup')}>Create an account</button>
          </>)}
          {mode === 'signup' && (
            <span>Already have an account? <button type="button" className="login-link" onClick={() => go('signin')}>Sign in</button></span>
          )}
          {mode === 'forgot' && (
            <button type="button" className="login-link quiet" onClick={() => go('signin')}>Back to sign in</button>
          )}
          {mode === 'expired' && (
            <span>Already confirmed? <button type="button" className="login-link" onClick={() => go('signin')}>Sign in</button></span>
          )}
          {mode === 'recovery' && (
            <SignOutButton className="login-link quiet" busyText="Cancelling…">Cancel</SignOutButton>
          )}
        </div>
      </form>
      {toastHost}
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
  if (!session) return <AuthScreen key="signin" initialMode={window.takeResetAsk() ? 'forgot' : 'signin'} />;
  return children;
};

// Signs out this device only: the wall tablet stays signed in when a phone signs out.
// supabase-js 2.58 keeps the session when that call fails (offline, a 5xx). Newer
// releases clear it locally then; _removeSession is that same step (storage, then
// SIGNED_OUT to every tab), safe to call on the pinned build. SIGNED_OUT is what turns
// AuthGate to the sign-in screen, so nothing after this should reload the page: a reload
// blanks it and draws sign-in a second time (SOLAR-98).
async function signOutHere() {
  const { error } = await window.sb.auth.signOut({ scope: 'local' }).catch(e => ({ error: e }));
  if (error) await window.sb.auth._removeSession();
}

// That still waits on a server round trip before the screen changes, so the button says
// it is working. It is never reset: the session ends either way, and that unmounts it.
function SignOutButton({ className, children = 'Sign out', busyText = 'Signing out…' }) {
  const [busy, setBusy] = React.useState(false);
  const click = async () => { setBusy(true); await signOutHere(); };
  return <button type="button" className={className} onClick={click} disabled={busy} aria-busy={busy}>{busy ? busyText : children}</button>;
}
// Shared with the Connect screen so it looks like the same product.
Object.assign(window, { EyeIcon, EyeOffIcon, AuthBrand, PasswordField, FieldLabel, invalidProps, SignOutButton, signOutHere, explainAuthError: explain });
