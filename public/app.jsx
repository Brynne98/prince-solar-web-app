// ============================================================================
// app.jsx — shell + live data owner: header, tab bar, fetch/refresh, persistence
// Fetches /api/overview (live snapshot) on a 60s tick, /api/history
// (today's chart) every 5 min, and lazily loads /api/energy per period on demand.
// ============================================================================
const { useState, useEffect, useRef, useCallback } = React;

const DEFAULT_SETTINGS = {
  // which way round battery power reads: 'discharge' = + powering the house, 'charge' = + charging
  battPositive: 'discharge',
  // battCapacity and reserve used to live here. They are facts about the
  // installation, not per-device preferences, so they now live in app_config and
  // arrive on the snapshot as `config` — one editable copy, shared with the phone
  // alerts, which read the same rows. See migration 0022.
  // Off by default — the optional per-subject tabs are opt-in from Settings.
  tabs: { solar: false, battery: false, grid: false, inverters: false },
};

function loadSettings() {
  try {
    const s = JSON.parse(localStorage.getItem('synsynk.settings'));
    if (s) return { ...DEFAULT_SETTINGS, ...s, tabs: { ...DEFAULT_SETTINGS.tabs, ...(s.tabs || {}) } };
  } catch (e) {}
  return DEFAULT_SETTINGS;
}

// "2 min ago" for the header; ticks with useNow so it stays honest between refreshes.
function fmtAgo(d, now) {
  const s = Math.max(0, Math.round((now - d.getTime()) / 1000));
  if (s < 45) return 'just now';
  const m = Math.round(s / 60);
  if (m < 90) return m + ' min ago';
  const h = Math.round(m / 60);
  if (h < 36) return h + 'h ago';
  return window.fmtTime(d);
}
function useNow(ms) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), ms); return () => clearInterval(t); }, [ms]);
  return now;
}

// Header status: one word, coloured. Live = fresh data and every inverter up;
// Stale = the poller is behind (> 3 min) or an inverter is down; Offline = no data
// for 15 min or nothing reporting.
function plantStatus(snap, now) {
  const online = snap.inverters.filter(i => i.status === 'online').length;
  const total = snap.inverters.length;
  const offline = total - online;
  const last = snap.lastReading || snap.updated;
  const ageS = (now - last.getTime()) / 1000;
  const status = (total > 0 && offline >= total) || ageS > 900 ? 'offline' : (offline > 0 || ageS > 180) ? 'stale' : 'live';
  return {
    status, last, old: ageS > 180,
    word: { live: 'Live', stale: 'Stale', offline: 'Offline' }[status],
    detail: offline > 0 ? offline + ' of ' + total + ' inverters offline' : 'updated ' + fmtAgo(last, now),
  };
}

// The same status on the fullscreen flow, which covers the header. Its own clock, so
// the tick re-renders this line and not the Live tab.
function WallStatus({ snap }) {
  const s = plantStatus(snap, useNow(15000));
  return (
    <span className={'wall-status status-' + s.status} title={'last reading ' + window.fmtTime(s.last)}>
      <span className="status-dot" />
      <span className="status-word">{s.word}</span>
      <span className="status-detail mono">{s.detail}</span>
    </span>
  );
}
window.WallStatus = WallStatus;

// ---- the frame (SOLAR-13) ---------------------------------------------------
// A sidebar of pages with the account at its foot, a header with the plant and its
// status, and on a phone a bottom bar instead of the sidebar. Tablet (600–1023 px)
// narrows the sidebar to an icon rail in CSS; nothing here knows the width.

const NAV_ICONS = {
  live: '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
  solar: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  battery: '<rect x="2" y="7" width="16" height="10" rx="2"/><path d="M22 11v2M6 11v2M10 11v2"/>',
  grid: '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/>',
  inverters: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 12h4"/><circle cx="16" cy="12" r="2"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
  more: '<circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>',
  account: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  signout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
};
// fixed strings from the table above, never data
const Icon = ({ id }) => <svg className="ico" viewBox="0 0 24 24" aria-hidden="true" dangerouslySetInnerHTML={{ __html: NAV_ICONS[id] }} />;

// An open menu closes on a click elsewhere or Escape (focus goes back to its button), and
// takes the arrow keys while focus is inside it. No keyboard shortcuts beyond that, by decision.
function usePopover() {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return;
    const away = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const key = e => { if (e.key === 'Escape') { setOpen(false); ref.current?.querySelector('button')?.focus(); } };
    document.addEventListener('pointerdown', away);
    document.addEventListener('keydown', key);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', key); };
  }, [open]);
  return [open, setOpen, ref];
}
function MenuList({ className, label, children }) {
  const ref = useRef(null);
  useEffect(() => { (ref.current.querySelector('[aria-checked="true"]') || ref.current.querySelector('button'))?.focus(); }, []);
  const keys = e => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
    const items = [...ref.current.querySelectorAll('button:not(:disabled)')], i = items.indexOf(document.activeElement);
    const n = e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : (i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[n]?.focus(); e.preventDefault();
  };
  return <div className={'menu ' + className} role="menu" aria-label={label} ref={ref} onKeyDown={keys}>{children}</div>;
}

// The plant on screen, left in the header; a menu once there is more than one.
function PlantMenu({ me, plantId, onPlant, fallback }) {
  const plants = me?.plants || [];
  const label = (p) => p.name || ('Plant ' + p.id);
  const current = plants.find(p => p.id === plantId);
  const name = current ? label(current) : (fallback || '');
  const [open, setOpen, ref] = usePopover();
  if (plants.length < 2 || !onPlant) return <div className="plant"><span className="plant-btn static"><span className="plant-name">{name}</span></span></div>;
  return (
    <div className="plant" ref={ref}>
      <button type="button" className="plant-btn" aria-haspopup="menu" aria-expanded={open} aria-label={'Plant: ' + name + '. Switch plant'} onClick={() => setOpen(o => !o)}>
        <span className="plant-name">{name}</span><Icon id="chevron" />
      </button>
      {open && (
        <MenuList className="plant-menu" label="Plants">
          {plants.map(p => (
            <button key={p.id} type="button" role="menuitemradio" aria-checked={p.id === plantId}
                    onClick={() => { setOpen(false); if (p.id !== plantId) onPlant(p.id); }}>
              <span className="tick" aria-hidden="true">{p.id === plantId ? '✓' : ''}</span><span className="nm">{label(p)}</span>
            </button>
          ))}
        </MenuList>
      )}
    </div>
  );
}

// The person: avatar, name and plant count in the sidebar; the avatar alone in a phone's
// header. A dead SunSynk login puts a red dot on the avatar and on Account.
function AccountMenu({ user, plantCount, alert, onAccount, active, variant }) {
  const [open, setOpen, ref] = usePopover();
  const sub = alert ? 'Reconnect a login' : plantCount + (plantCount === 1 ? ' plant' : ' plants');
  return (
    <div className={'acct acct-' + variant} ref={ref}>
      <button type="button" className={'acct-btn' + (alert ? ' needs' : '')} aria-haspopup="menu" aria-expanded={open}
              aria-current={active ? 'page' : undefined} onClick={() => setOpen(o => !o)}
              aria-label={'Account menu' + (alert ? '. A SunSynk login needs reconnecting' : '')}>
        <span className="avatar" aria-hidden="true">{user.initials}</span>
        {variant === 'rail' && <span className="who" aria-hidden="true"><b>{user.name}</b><span className={alert ? 'warn' : ''}>{sub}</span></span>}
      </button>
      {open && (
        <MenuList className="acct-menu" label="Account">
          <div className="menu-email">{user.email}</div>
          <button type="button" onClick={() => { setOpen(false); onAccount(); }}>
            <Icon id="account" />Account{alert && <span className="dot" aria-label="A login needs reconnecting" />}
          </button>
          <hr />
          <window.SignOutButton className="menu-signout"><Icon id="signout" />Sign out</window.SignOutButton>
        </MenuList>
      )}
    </div>
  );
}

function Sidebar({ tabs, tab, onTab, account }) {
  return (
    <aside className="rail">
      <div className="rail-logo"><span className="sun" aria-hidden="true" /><span className="app-name">Prince Solar</span></div>
      <nav className="nav" aria-label="Pages">
        {tabs.map(t => (
          <button key={t.id} type="button" className={t.id === 'settings' ? 'nav-settings' : undefined} aria-current={tab === t.id ? 'page' : undefined}
                  onClick={onTab && (() => onTab(t.id))} disabled={!onTab}>
            <Icon id={t.id} /><span className="t">{t.label}</span>
          </button>
        ))}
      </nav>
      {account && <AccountMenu {...account} variant="rail" />}
    </aside>
  );
}

// Phone: at most five slots, Settings always the last. More than four pages: the first
// three, then More, which opens a sheet with the rest.
function PhoneBar({ tabs, tab, onTab }) {
  const [more, setMore] = useState(false);
  const pages = tabs.filter(t => t.id !== 'settings');
  const settingsTab = tabs.find(t => t.id === 'settings');
  const split = pages.length > 4;
  const bar = split ? pages.slice(0, 3) : pages;
  const rest = split ? pages.slice(3) : [];
  const go = (id) => { setMore(false); onTab && onTab(id); };
  useEffect(() => {
    if (!more) return;
    const key = e => { if (e.key === 'Escape') { setMore(false); document.querySelector('.phonebar .more-btn')?.focus(); } };
    document.addEventListener('keydown', key);
    document.querySelector('.sheet button')?.focus();
    return () => document.removeEventListener('keydown', key);
  }, [more]);
  const slot = (t) => (
    <button key={t.id} type="button" aria-current={tab === t.id ? 'page' : undefined} onClick={() => go(t.id)} disabled={!onTab}>
      <Icon id={t.id} /><span>{t.label}</span>
    </button>
  );
  return (
    <>
      <nav className="phonebar" aria-label="Pages">
        {bar.map(slot)}
        {split && (
          <button type="button" className={'more-btn' + (rest.some(t => t.id === tab) ? ' on' : '')} aria-expanded={more} aria-haspopup="dialog"
                  onClick={() => setMore(m => !m)} disabled={!onTab}>
            <Icon id="more" /><span>More</span>
          </button>
        )}
        {settingsTab && slot(settingsTab)}
      </nav>
      {more && (
        <div className="sheet" onClick={e => { if (e.target === e.currentTarget) setMore(false); }}>
          <div className="sheet-panel" role="dialog" aria-label="More pages">
            <div className="sheet-grip" aria-hidden="true" />
            {rest.map(slot)}
          </div>
        </div>
      )}
    </>
  );
}

// Status word right of the plant, coloured; the age only once it is worth reading.
function HeaderStatus({ snap, onRefresh, busy, idleWord }) {
  const now = useNow(15000);
  if (!snap) {
    return (
      <>
        <div className="status status-idle" role="status"><span className="status-dot" /><span className="status-word">{idleWord}</span></div>
        <button type="button" className={'refresh' + (busy ? ' busy' : '')} aria-label="Refresh" title="Refresh" disabled><Icon id="refresh" /></button>
      </>
    );
  }
  const s = plantStatus(snap, now);
  return (
    <>
      <div className={'status status-' + s.status} title={'Last reading ' + window.fmtTime(s.last)} role="status">
        <span className="status-dot" />
        <span className="status-word">{s.word}</span>
        {s.old && <span className="status-age mono">{fmtAgo(s.last, now).replace(' ago', '')}</span>}
        {/* A freshly linked plant: the last 60 days arrive over a day or two of
            six-hourly runs (0048). Quiet once every day has a chart. */}
        {snap.sync && snap.sync.pending && snap.sync.days < snap.sync.window && (() => {
          const pct = Math.round(100 * (snap.sync.days || 0) / (snap.sync.window || 60));
          return (
            <span className="status-sync" title={`${snap.sync.days} of ${snap.sync.window} days so far`}>
              <span className="sync-arc" aria-hidden="true" />Fetching history
              <span className="sync-pct mono">{pct}%</span>
            </span>
          );
        })()}
      </div>
      {/* takes the status colour once something is wrong, and reads Retry when nothing reports */}
      <button type="button" className={'refresh refresh-' + s.status + (busy ? ' busy' : '')} aria-busy={busy} onClick={onRefresh}
              aria-label={s.status === 'offline' ? 'Retry' : 'Refresh'} title={s.status === 'offline' ? 'Retry' : 'Refresh'}>
        <Icon id="refresh" />{s.status === 'offline' && <span className="lbl">Retry</span>}
      </button>
    </>
  );
}

// Says on the page when its numbers are old, and why. Grid off is news, not a fault: calm purple.
function PageNotice({ snap, cutOff, onReconnect }) {
  const s = plantStatus(snap, useNow(15000));
  const at = window.fmtTime(s.last);
  const a = snap.aggregate || {};
  if (s.status === 'offline' && cutOff) return (
    <div className="notice offline" role="alert">
      <p><b>SunSynk login stopped working.</b> Readings paused at {at}.</p>
      <button type="button" className="save-btn" onClick={onReconnect}>Reconnect</button>
    </div>
  );
  if (s.status === 'offline') return (
    <div className="notice offline" role="alert">
      <p><b>{s.old ? 'No readings since ' + at + '.' : 'No inverter is reporting.'}</b></p>
    </div>
  );
  // stale readings still say the grid is off, so both banners can show
  return (
    <>
      {s.status === 'stale' && (
        <div className="notice stale" role="status">
          <p>{s.old ? <><b>Last reading at {at},</b> {fmtAgo(s.last, Date.now())}.</> : <b>{s.detail}.</b>}</p>
        </div>
      )}
      {a.gridPresent === false && snap.features?.hasGrid !== false && (
        <div className="notice gridoff" role="status">
          <p><b>Grid off.</b> {snap.features?.hasBattery === false ? 'Running on solar.' : 'Running on solar and battery.'}</p>
        </div>
      )}
    </>
  );
}

function tabsFor(settings) {
  return [
    { id: 'live', label: 'Live' },
    settings.tabs.solar && { id: 'solar', label: 'Solar' },
    settings.tabs.grid && { id: 'grid', label: 'Grid' },
    settings.tabs.battery && { id: 'battery', label: 'Battery' },
    settings.tabs.inverters && { id: 'inverters', label: 'Inverters' },
    { id: 'settings', label: 'Settings' },
  ].filter(Boolean);
}
// Account is a page too, reached from the account menu rather than the page list.
const pageOk = (tabs, id) => id === 'account' || tabs.some(t => t.id === id);

// Back to the top of the page: the frame's body scrolls beside a sidebar, the document on a phone.
const toTop = () => { document.querySelector('.frame-body')?.scrollTo({ top: 0 }); window.scrollTo({ top: 0 }); };

// The frame around every page: sidebar, header, content, phone bar.
function Frame({ tabs, tab, onTab, head, account, busy, children }) {
  return (
    <div className="frame">
      <Sidebar tabs={tabs} tab={tab} onTab={onTab} account={account} />
      <div className="frame-body">
        <header className="head">
          {head}
          {account && <AccountMenu {...account} variant="head" />}
        </header>
        <main className="content" aria-busy={busy || undefined}>{children}</main>
      </div>
      <PhoneBar tabs={tabs} tab={tab} onTab={onTab} />
    </div>
  );
}

// Shown while the session and the SunSynk link are still being checked, before App
// mounts. Same frame as App's own not-yet-loaded gate, so the hand-over does not flash.
function BootShell() {
  // No remembered tab means this browser hasn't shown this account a dashboard since the
  // last sign-out: most likely a new account on its way to Connect SunSynk. A skeleton
  // would flash a dashboard it will never get, so show the empty sign-in backdrop.
  if (!localStorage.getItem('synsynk.tab')) return <div className="login-wrap" />;
  const tabs = tabsFor(loadSettings());
  const saved = new URLSearchParams(location.search).get('tab') || localStorage.getItem('synsynk.tab');
  const tab = pageOk(tabs, saved) ? saved : 'live';
  return (
    <Frame tabs={tabs} tab={tab} busy head={<><PlantMenu fallback="Connecting to SunSynk…" /><HeaderStatus idleWord="Connecting" /></>}>
      {tab !== 'settings' && tab !== 'account' && <window.TabSkeleton tab={tab} />}
    </Frame>
  );
}

function App({ links }) {
  const [settings, setSettings] = useState(loadSettings);
  // plan, preferences and plants for the signed-in user (api_me). Preferences from
  // the server win over the localStorage cache so a new device looks the same.
  const [me, setMe] = useState(null);
  const [plantId, setPlantId] = useState(null);
  const prefsLoaded = useRef(false);
  const [tab, setTab] = useState(() => new URLSearchParams(location.search).get('tab') || localStorage.getItem('synsynk.tab') || 'live');
  const auto = true; // refresh runs on its own; the header button forces one now
  const [snap, setSnap] = useState(null);
  const [today, setToday] = useState(null);
  const [energy, setEnergy] = useState({});
  // > 0 while a snapshot fetch is in flight; the Refresh icon spins on it. Held to a
  // whole number of 800 ms turns so it never stops mid-rotation.
  const [busy, setBusy] = useState(0);
  const [err, setErr] = useState(null);
  const [flashSection, setFlashSection] = useState(null); // a Settings section to flash once on arrival
  // "Set your rate", "Set pack size", Reconnect: open the page that holds that section
  // (logins are on Account) and flash it once; the section scrolls itself into view.
  const openSettings = (section) => {
    setFlashSection(section); setTab(section === 'connection' ? 'account' : 'settings'); toTop();
  };
  // The signed-in person, for the account menu: name, initials, email.
  const [user, setUser] = useState({ name: '', initials: '', email: '' });
  useEffect(() => {
    window.sb.auth.getSession().then(({ data }) => {
      const u = data?.session?.user; if (!u) return;
      const email = u.email || '';
      const name = u.user_metadata?.full_name || u.user_metadata?.name || email.split('@')[0];
      const initials = name.split(/[\s._-]+/).filter(Boolean).slice(0, 2).map(w => w[0].toUpperCase()).join('');
      setUser({ name, initials, email });
    }).catch(() => {});
  }, []);
  // Settings with unsaved plant edits holds the plant where it is; a switch asked for
  // meanwhile bumps switchBlocked, and the save bar says why nothing happened.
  const settingsDirty = useRef(false);
  const [switchBlocked, setSwitchBlocked] = useState(0);
  const [refreshKey, setRefreshKey] = useState(0); // bumped on manual refresh so the chart re-fetches its current day

  const energyRef = useRef({});
  const inflight = useRef({});
  useEffect(() => { energyRef.current = energy; }, [energy]);

  useEffect(() => {
    localStorage.setItem('synsynk.settings', JSON.stringify(settings));
    if (!prefsLoaded.current) return;
    const t = setTimeout(() => window.savePrefs({ battPositive: settings.battPositive, tabs: settings.tabs }).catch(() => {}), 600);
    return () => clearTimeout(t);
  }, [settings]);
  useEffect(() => { localStorage.setItem('synsynk.tab', tab); }, [tab]);

  // spin = false on the 60 s auto tick, so the icon only turns for something the
  // person asked for (a click, first load, a plant switch).
  // A tablet waking from sleep often fails its first check while wifi reconnects, so an
  // automatic check only raises the banner on the second failure in a row, and a failure
  // is retried in 10 s (three times) rather than waiting for the next minute's tick.
  const liveFails = useRef(0);
  const liveRetry = useRef(null);
  const loadLive = useCallback(async (spin = true) => {
    const t0 = Date.now();
    if (spin) setBusy(b => b + 1);
    clearTimeout(liveRetry.current);
    try { setSnap(await window.fetchSnapshot()); setErr(null); liveFails.current = 0; }
    catch (e) {
      liveFails.current += 1;
      if (spin || liveFails.current >= 2) setErr(e.message);
      if (liveFails.current <= 3) liveRetry.current = setTimeout(() => loadLive(false), 10000);
    }
    finally { if (spin) setTimeout(() => setBusy(b => b - 1), Math.ceil((Date.now() - t0) / 800) * 800 - (Date.now() - t0)); }
  }, []);
  const loadToday = useCallback(async () => {
    try { setToday(await window.fetchDay()); } catch (e) { /* chart shows its own placeholder */ }
  }, []);
  // Battery balance is asked for alongside the snapshot, not after Battery has drawn, and
  // refreshed every 5 min: pack drift, temperature and hours at full move slowly, and it is
  // the heaviest query on the screen. undefined = loading; null = failed with nothing to keep.
  // Only the latest request's reply is kept, so a slow one from an earlier plant or refresh
  // cannot overwrite a newer answer.
  const [balance, setBalance] = useState(undefined);
  const balanceSeq = useRef(0);
  const loadBalance = useCallback(() => {
    const seq = ++balanceSeq.current;
    window.fetchBalance().then(d => {
      if (seq === balanceSeq.current) setBalance(v => d ?? (v === undefined ? null : v));
    });
  }, []);
  const onNeedEnergy = useCallback((period) => {
    if (energyRef.current[period] || inflight.current[period]) return;
    inflight.current[period] = true;
    window.fetchEnergy(period)
      .then(rows => setEnergy(e => ({ ...e, [period]: rows })))
      .catch(() => {})
      .finally(() => { inflight.current[period] = false; });
  }, []);
  // Refetch every already-loaded period together so their totals stay current AND
  // mutually consistent (e.g. Year and Lifetime share today's growing total rather
  // than each being frozen at whenever it was first opened). Updates in place — no flicker.
  const refreshEnergy = useCallback(() => {
    Object.keys(energyRef.current).forEach((period) => {
      window.fetchEnergy(period).then(rows => setEnergy(e => ({ ...e, [period]: rows }))).catch(() => {});
    });
  }, []);

  const loadMe = useCallback(async () => {
    try {
      const m = await window.fetchMe();
      setMe(m);
      const ids = (m.plants || []).map(p => p.id);
      const wanted = m.prefs && ids.includes(Number(m.prefs.lastPlant)) ? Number(m.prefs.lastPlant) : (ids[0] ?? null);
      const cfg = (m.plants || []).find(p => p.id === wanted)?.config;
      window.setCurrentPlant(wanted, cfg?.currency);
      setPlantId(wanted);
      if (m.prefs && (m.prefs.battPositive || m.prefs.tabs)) {
        setSettings(s => ({ ...s, ...(m.prefs.battPositive ? { battPositive: m.prefs.battPositive } : {}), tabs: { ...s.tabs, ...(m.prefs.tabs || {}) } }));
      }
      prefsLoaded.current = true;
      // how much history this plant has — drives the "collecting your first day" copy
      window.fetchTrends().then(t => { window.PLANT_DAYS = t?.stats?.days ?? null; }).catch(() => {});
    } catch (e) { setErr(e.message); }
  }, []);
  // Name of the plant just switched to, shown in the status pill until the new
  // snapshot has been on screen for a moment; null the rest of the time.
  const [notice, setNotice] = useState(null);
  useEffect(() => {
    if (!notice) return;
    // A failed load leaves snap null; the pill must not sit on "Switching" forever.
    if (err) { setNotice(null); return; }
    if (!snap) return;
    const t = setTimeout(() => setNotice(null), 2500);
    return () => clearTimeout(t);
  }, [notice, snap, err]);
  const switchPlant = (id) => {
    if (tab === 'settings' && settingsDirty.current) { setSwitchBlocked(n => n + 1); return; }
    const plant = (me?.plants || []).find(p => p.id === Number(id));
    const cfg = plant?.config;
    window.setCurrentPlant(id, cfg?.currency);
    setPlantId(Number(id));
    setNotice(plant?.name || ('Plant ' + id));
    window.savePrefs({ lastPlant: Number(id) }).catch(() => {});
    setEnergy({}); energyRef.current = {}; setSnap(null); setToday(null); setBalance(undefined);
    // how much history THIS plant has — the empty-state copy reads it
    window.PLANT_DAYS = null; window.SYNC = null; syncDaysRef.current = null;
    window.fetchTrends().then(t => { window.PLANT_DAYS = t?.stats?.days ?? null; }).catch(() => {});
    loadLive(); loadToday(); loadBalance(); setRefreshKey(k => k + 1);
  };
  // Fresh-link sync state (0048) rides on every snapshot; the empty-state copy reads
  // it from window.SYNC during render, so it is assigned here in the render path,
  // before any child renders (an effect would run after they had already painted
  // with the previous value). When the walk lands more days, the logged-days count
  // that drives "only N days so far" is refreshed too, so it does not stick at 2.
  window.SYNC = snap?.sync ?? null;
  const syncDaysRef = useRef(null);
  useEffect(() => {
    const sync = snap?.sync ?? null;
    if (!sync) return;
    if (syncDaysRef.current != null && sync.days !== syncDaysRef.current) {
      window.fetchTrends().then(t => { window.PLANT_DAYS = t?.stats?.days ?? null; }).catch(() => {});
    }
    syncDaysRef.current = sync.days;
  }, [snap]);
  // A config save can change which plant is shown (a removed login); the balance follows it.
  // A reconnected login also clears the banner, so the gate's list is read again.
  const reloadPlantConfig = () => {
    const before = window.CURRENT_PLANT;
    links.refresh();
    return loadMe().then(() => {
      if (window.CURRENT_PLANT !== before) setBalance(undefined);
      loadLive(); loadBalance();
    });
  };

  // initial load: who am I and which plant, then the data
  useEffect(() => { loadMe().then(() => { loadLive(); loadToday(); loadBalance(); }); }, []);
  // auto refresh: live every minute (matches SunSynk's cadence), today and battery balance every
  // 5th minute. On the clock, not from page load: every open device asks at :15, after the
  // poller's reading has landed (by ~:06), so devices side by side show the same numbers (SOLAR-33).
  useEffect(() => {
    if (!auto) return;
    let a;
    const next = () => { const ms = 60000 - (Date.now() - 15000) % 60000; a = setTimeout(tick, ms < 1000 ? ms + 60000 : ms); };
    const tick = () => {
      loadLive(false);
      if (new Date().getMinutes() % 5 === 0) { loadToday(); refreshEnergy(); loadBalance(); }
      next();
    };
    next();
    // timers sleep with a tablet's screen; catch up the moment it is back or online again
    const wake = () => { if (document.visibilityState === 'visible') { loadLive(false); loadToday(); refreshEnergy(); loadBalance(); } };
    document.addEventListener('visibilitychange', wake);
    window.addEventListener('online', wake);
    return () => {
      clearTimeout(a); clearTimeout(liveRetry.current);
      document.removeEventListener('visibilitychange', wake); window.removeEventListener('online', wake);
    };
  }, [auto]);

  const refresh = () => { if (busy) return; loadLive(); loadToday(); refreshEnergy(); loadBalance(); setRefreshKey(k => k + 1); };

  const TABS = tabsFor(settings);
  useEffect(() => { if (!pageOk(TABS, tab)) setTab('live'); }, [settings.tabs]);
  const go = (id) => { setTab(id); toTop(); };
  const loginDead = links.accounts.some(a => a.status === 'needs_relink');
  const account = { user, plantCount: (me?.plants || []).length, alert: loginDead, onAccount: () => go('account'), active: tab === 'account' };
  const plantMenu = <PlantMenu me={me} plantId={plantId} onPlant={switchPlant} fallback={snap?.plant?.name} />;
  const settingsPage = <window.SettingsTab me={me} plantId={plantId} settings={settings} setSettings={setSettings} onPlantConfigSaved={reloadPlantConfig}
    flash={flashSection} onFlashed={() => setFlashSection(null)} onDirty={d => { settingsDirty.current = d; }} switchBlocked={switchBlocked} />;
  const accountPage = <window.AccountTab onPlantConfigSaved={reloadPlantConfig}
    flash={flashSection} onFlashed={() => setFlashSection(null)} />;

  // ---- not-yet-loaded gate ----
  //
  // The whole frame with skeletons where the data will go. Pages stay live while loading:
  // there is no reason to trap someone on Live because the first snapshot hasn't landed.
  if (!snap) {
    return (
      <Frame tabs={TABS} tab={tab} onTab={go} account={me ? account : null} busy
        head={<>{(me?.plants || []).length > 0 && !err ? plantMenu : <PlantMenu fallback={err ? 'Connection error' : 'Connecting to SunSynk…'} />}
          <HeaderStatus idleWord={notice ? 'Switching' : 'Connecting'} busy={busy > 0} /></>}>
        {err && <div className="notice offline" role="alert"><p><b>Can't reach the server.</b> Retrying every minute.</p></div>}
        {/* Settings and Account never touch the snapshot: they draw for real. */}
        {tab === 'settings' ? settingsPage
          : tab === 'account' ? accountPage
          : <window.TabSkeleton tab={tab} />}
      </Frame>
    );
  }

  const plantLogins = links.accounts.filter(a => a.status !== 'disabled' && (a.plants || []).some(p => String(p.plant_id) === String(plantId)));
  const plantCutOff = plantLogins.length > 0 && !plantLogins.some(a => a.status === 'active') && !!snap && plantStatus(snap, Date.now()).status === 'offline';

  const dataPage = tab !== 'settings' && tab !== 'account';
  const old = dataPage && plantStatus(snap, Date.now()).old;
  return (
    <Frame tabs={TABS} tab={tab} onTab={go} account={account}
      head={<>{plantMenu}<HeaderStatus snap={snap} onRefresh={refresh} busy={busy > 0} /></>}>
      {/* The raw error stays in the title; on screen it was a Postgres or JWT string a
          homeowner cannot act on. */}
      {err && <div className="notice stale" role="status" title={String(err)}><p><b>Couldn't refresh.</b> Showing the last good reading.</p></div>}
      {/* For the plant on screen. A plant still read through someone else's copy of the
          login stays quiet; a dead login still marks the avatar and Account with a dot. */}
      {dataPage && <PageNotice snap={snap} cutOff={plantCutOff} onReconnect={() => openSettings('connection')} />}
      <div className={'page' + (old ? ' old' : '')}>
        {tab === 'live' && <window.LiveTab snap={snap} settings={settings} today={today} energy={energy} onNeedEnergy={onNeedEnergy} refreshKey={refreshKey}
          onOpenSettings={openSettings} />}
        {tab === 'solar' && <window.SolarTab snap={snap} energy={energy} onNeedEnergy={onNeedEnergy} today={today} refreshKey={refreshKey} onOpenSettings={openSettings} />}
        {tab === 'battery' && <window.BatteryTab snap={snap} settings={settings} energy={energy} onNeedEnergy={onNeedEnergy} today={today} refreshKey={refreshKey} balance={balance} onOpenSettings={openSettings} />}
        {tab === 'grid' && <window.GridTab snap={snap} settings={settings} energy={energy} onNeedEnergy={onNeedEnergy} today={today} refreshKey={refreshKey} onOpenSettings={openSettings} />}
        {tab === 'inverters' && <window.InvertersTab snap={snap} settings={settings} refreshKey={refreshKey} />}
        {tab === 'settings' && settingsPage}
        {tab === 'account' && accountPage}
      </div>
    </Frame>
  );
}

// A crash in someone's browser used to be invisible. Report it (once per message
// per session) to client_errors; the table caps a runaway loop at 50/hour.
(function () {
  const seen = new Set();
  const report = (message, stack) => {
    try {
      const key = String(message).slice(0, 200);
      if (seen.has(key) || seen.size > 20 || !window.sb) return;
      seen.add(key);
      window.sb.auth.getSession().then(({ data }) => {
        const uid = data?.session?.user?.id;
        if (!uid) return;
        return window.sb.from('client_errors').insert({
          user_id: uid, plant_id: window.CURRENT_PLANT ?? null, app_version: window.APP_VERSION,
          page: location.pathname + location.search, message: String(message), stack: stack ? String(stack) : null,
          user_agent: navigator.userAgent,
        });
      }).catch(() => {});
    } catch (e) {}
  };
  window.addEventListener('error', (e) => report(e.message || e.error, e.error && e.error.stack));
  window.addEventListener('unhandledrejection', (e) => report((e.reason && e.reason.message) || e.reason, e.reason && e.reason.stack));
  window.reportClientError = report;
})();

const legalPage = new URLSearchParams(location.search).get('page');
ReactDOM.createRoot(document.getElementById('root')).render(
  legalPage === 'terms' || legalPage === 'privacy'
    ? <window.LegalPage which={legalPage} />
    : <window.AuthGate fallback={<BootShell />}><window.LinkGate fallback={<BootShell />}>{(links) => <App links={links} />}</window.LinkGate></window.AuthGate>
);
