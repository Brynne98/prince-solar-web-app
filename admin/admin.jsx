// ============================================================================
// admin.jsx — read-only overview for admin.princesolarhub.com (SOLAR-115).
// Sign in with Supabase, then one call to admin_overview(). The function refuses
// anyone not in private.admins, so this page holds no access rules of its own.
// ============================================================================
const { useState, useEffect, useCallback } = React;

window.sb = window.supabase.createClient(window.SUNSYNK_CONFIG.url, window.SUNSYNK_CONFIG.key, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'prince-solar-admin.auth' }
});

const TZ = 'Africa/Johannesburg';
function fmtWhen(v) {
  if (!v) return '—';
  const d = typeof v === 'number' ? new Date(v * 1000) : new Date(v);
  return d.toLocaleString('en-GB', { timeZone: TZ, day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}
function ago(v) {
  if (!v) return null;
  const ms = typeof v === 'number' ? v * 1000 : Date.parse(v);
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 90) return Math.round(s) + ' s ago';
  if (s < 5400) return Math.round(s / 60) + ' min ago';
  if (s < 172800) return Math.round(s / 3600) + ' h ago';
  return Math.round(s / 86400) + ' days ago';
}
function When({ v }) {
  if (!v) return <span className="empty">—</span>;
  return <span title={fmtWhen(v)}>{ago(v)}<div className="sub">{fmtWhen(v)}</div></span>;
}

function SignIn() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(() => {
    const m = /error_description=([^&]+)/.exec(location.hash);
    return m ? decodeURIComponent(m[1].replace(/\+/g, ' ')) : '';
  });
  async function submit(e) {
    e.preventDefault();
    setBusy(true); setErr('');
    const { error } = await window.sb.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) setErr(error.message);
  }
  async function google() {
    setErr('');
    const { error } = await window.sb.auth.signInWithOAuth({
      provider: 'google', options: { redirectTo: location.origin + '/', queryParams: { prompt: 'select_account' } }
    });
    if (error) setErr(error.message);
  }
  return (
    <form className="card signin" onSubmit={submit}>
      <h1>Prince Solar admin</h1>
      <label htmlFor="em">Email</label>
      <input id="em" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required />
      <label htmlFor="pw">Password</label>
      <input id="pw" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
      <div className="row">
        <button className="primary" type="submit" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        <button type="button" onClick={google}>Google</button>
      </div>
      {err && <p className="err">{err}</p>}
    </form>
  );
}

function Section({ title, count, children }) {
  return (
    <section className="card">
      <h2>{title}<span className="n">{count}</span></h2>
      <div className="scroll">{children}</div>
    </section>
  );
}

function Freshness({ ts }) {
  if (!ts) return <span className="bad">No readings</span>;
  const age = Date.now() / 1000 - ts;
  const cls = age > 3600 ? 'bad' : age > 900 ? 'warn' : 'ok';
  return <span className={cls} title={fmtWhen(ts)}>{ago(ts)}<div className="sub">{fmtWhen(ts)}</div></span>;
}

const STATUS = { active: ['Active', 'ok'], needs_relink: ['Needs relink', 'bad'], disabled: ['Disconnected', 'empty'] };

function Overview({ data }) {
  const { users, plants, logins, errors } = data;
  return (
    <>
      <Section title="Users" count={users.length}>
        <table>
          <thead><tr><th>Email</th><th>Sign-in</th><th>Signed up</th><th>Last sign-in</th><th>Plants</th></tr></thead>
          <tbody>{users.map((u) => (
            <tr key={u.email}>
              <td>{u.email}{u.admin && <span className="sub"> admin</span>}</td>
              <td>{u.provider || '—'}</td>
              <td className="nowrap"><When v={u.createdAt} /></td>
              <td className="nowrap"><When v={u.lastSignInAt} /></td>
              <td className="num">{u.plants}</td>
            </tr>))}
          </tbody>
        </table>
      </Section>

      <Section title="Plants" count={plants.length}>
        {plants.length === 0 ? <p className="empty">No plants linked.</p> : (
        <table>
          <thead><tr><th>Plant</th><th>Owner</th><th>Inverters</th><th>Last reading</th><th>Linked</th></tr></thead>
          <tbody>{plants.map((p) => (
            <tr key={p.plantId + p.email}>
              <td>{p.name || '—'}<div className="sub mono">{p.plantId}</div></td>
              <td>{p.email}</td>
              <td className="num">{p.inverters}</td>
              <td className="nowrap"><Freshness ts={p.lastTs} /></td>
              <td className="nowrap"><When v={p.linkedAt} /></td>
            </tr>))}
          </tbody>
        </table>)}
      </Section>

      <Section title="SunSynk logins" count={logins.length}>
        {logins.length === 0 ? <p className="empty">No SunSynk logins.</p> : (
        <table>
          <thead><tr><th>Owner</th><th>SunSynk login</th><th>Status</th><th>Last good read</th><th>Last error</th></tr></thead>
          <tbody>{logins.map((l) => {
            const [label, cls] = STATUS[l.status] || [l.status, ''];
            return (
              <tr key={l.email + l.sunsynkUser}>
                <td>{l.email}</td>
                <td>{l.sunsynkUser}</td>
                <td className={cls + ' nowrap'}>{label}</td>
                <td className="nowrap"><When v={l.lastOkAt} /></td>
                <td className="msg">{l.lastError || '—'}</td>
              </tr>);
          })}
          </tbody>
        </table>)}
      </Section>

      <Section title="Browser errors" count={errors.length}>
        {errors.length === 0 ? <p className="empty">No errors logged.</p> : (
        <table>
          <thead><tr><th>When</th><th>User</th><th>Version</th><th>Page</th><th>Message</th></tr></thead>
          <tbody>{errors.map((e, i) => (
            <tr key={i}>
              <td className="nowrap"><When v={e.at} /></td>
              <td>{e.email || '—'}</td>
              <td className="num">{e.version || '—'}</td>
              <td>{e.page || '—'}</td>
              <td className="msg">{e.message}</td>
            </tr>))}
          </tbody>
        </table>)}
      </Section>
    </>
  );
}

function App() {
  const [session, setSession] = useState(undefined);
  const [data, setData] = useState(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    window.sb.auth.getSession().then(({ data }) => setSession(data.session));
    const { data: sub } = window.sb.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const load = useCallback(async () => {
    setBusy(true); setErr('');
    const { data, error } = await window.sb.rpc('admin_overview');
    setBusy(false);
    if (error) { setData(null); setErr(error.code === '42501' ? 'This account is not an admin.' : error.message); }
    else setData(data);
  }, []);

  const userId = session && session.user.id;
  useEffect(() => { if (userId) load(); else setData(null); }, [userId, load]);

  if (session === undefined) return null;
  if (!session) return <div className="wrap"><SignIn /></div>;
  return (
    <div className="wrap">
      <header>
        <h1>Prince Solar admin</h1>
        <span className="who">{session.user.email}</span>
        <button onClick={load} disabled={busy}>{busy ? 'Loading…' : 'Refresh'}</button>
        <button onClick={() => window.sb.auth.signOut()}>Sign out</button>
      </header>
      {err && <p className="card err">{err}</p>}
      {data && <Overview data={data} />}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
