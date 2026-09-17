// ============================================================================
// app.jsx — shell + live data owner: header, tab bar, fetch/refresh, persistence
// Fetches /api/overview (live snapshot) on a 60s tick, /api/history
// (today's chart) every 5 min, and lazily loads /api/energy per period on demand.
// ============================================================================
const { useState, useEffect, useRef, useCallback } = React;

const DEFAULT_SETTINGS = {
  battPositive: 'discharge',
  // battCapacity and reserve used to live here. They are facts about the
  // installation, not per-device preferences, so they now live in app_config and
  // arrive on the snapshot as `config` — one editable copy, shared with the phone
  // alerts, which read the same rows. See migration 0022.
  // Off by default — the optional per-subject tabs are opt-in from Settings. Trends is
  // no longer listed here: like Live and Settings it is always on, so it needs no flag.
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
    status, last,
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

function HeaderStatus({ snap, onRefresh, busy, notice }) {
  const now = useNow(15000);
  // Just after a plant switch the pill names the plant for a moment, so the swap is
  // visibly acknowledged before the freshness word takes over again.
  if (notice) {
    return (
      <div className="topbar-actions">
        <div className="status-pill status-switch" role="status">
          <span className="status-dot" />
          <span className="status-word">Switched</span>
          <span className="status-detail mono">to {notice}</span>
        </div>
        <button className={'refresh-btn' + (busy ? ' busy' : '')} onClick={onRefresh}><span className="refresh-ico" aria-hidden="true">↻</span>Refresh</button>
      </div>
    );
  }
  const { status, word, detail, last } = plantStatus(snap, now);
  return (
    <div className="topbar-actions">
      <div className={'status-pill status-' + status} title={'last reading ' + window.fmtTime(last)}>
        <span className="status-dot" />
        <span className="status-word">{word}</span>
        <span className="status-detail mono">{detail}</span>
        {/* A freshly linked plant: the last 60 days arrive over a day or two of
            six-hourly runs (0048). The arc says it is working, the bar how far. Once
            every one of the 60 days has a chart the pill is quiet even if the
            inverter-history walk is still topping up; the charts say so themselves. */}
        {snap.sync && snap.sync.pending && snap.sync.days < snap.sync.window && (() => {
          const pct = Math.round(100 * (snap.sync.days || 0) / (snap.sync.window || 60));
          return (
            <span className="status-sync" title={`${snap.sync.days} of ${snap.sync.window} days so far`}>
              <span className="sync-arc" aria-hidden="true" />Fetching history
              <span className="sync-bar"><i style={{ width: Math.max(4, pct) + '%' }} /></span>
              <span className="sync-pct mono">{pct}%</span>
            </span>
          );
        })()}
      </div>
      {/* The button takes the pill's colour once something is wrong, and reads Retry when
          nothing is reporting. The icon spins for as long as a fetch is in flight. */}
      <button className={'refresh-btn refresh-' + status + (busy ? ' busy' : '')} aria-busy={busy} onClick={onRefresh}><span className="refresh-ico" aria-hidden="true">↻</span>{status === 'offline' ? 'Retry' : 'Refresh'}</button>
    </div>
  );
}

// Plant name under the product name; becomes the selector once there is more than one.
function BrandLine({ snap, me, plantId, onPlant }) {
  const plants = me?.plants || [];
  const name = plants.find(p => p.id === plantId)?.name || snap?.plant?.name || '';
  return (
    <div>
      <div className="brand-name">Prince Solar</div>
      <div className="brand-sub mono">{plants.length > 1 ? <PlantSelect me={me} plantId={plantId} onChange={onPlant} /> : name}</div>
    </div>
  );
}

function PlantSelect({ me, plantId, onChange }) {
  const plants = me?.plants || [];
  if (plants.length < 2) return null;
  const label = (p) => p.name || ('Plant ' + p.id);
  const current = plants.find(p => p.id === plantId);
  // A select is as wide as its longest option, which left a gap before the chevron for
  // every shorter name. The hidden copy of the chosen name sizes the box instead.
  return (
    <span className="plant-pick">
      <span className="plant-pick-size" aria-hidden="true">{current ? label(current) : ''}</span>
      <select className="plant-select" value={plantId ?? ''} onChange={e => onChange(e.target.value)} title="Switch plant" aria-label="Plant">
        {plants.map(p => <option key={p.id} value={p.id}>{label(p)}</option>)}
      </select>
    </span>
  );
}

function tabsFor(settings) {
  return [
    { id: 'live', label: 'Live' },
    settings.tabs.solar && { id: 'solar', label: 'Solar' },
    settings.tabs.battery && { id: 'battery', label: 'Battery' },
    settings.tabs.grid && { id: 'grid', label: 'Grid' },
    settings.tabs.inverters && { id: 'inverters', label: 'Inverters' },
    { id: 'trends', label: 'Trends' },
    { id: 'settings', label: 'Settings' },
  ].filter(Boolean);
}

function LiveSkeleton() {
  return (
    <div className="live-grid">
      <div className="overview-section">
        <div className="overview-head">
          <div className="section-title">OVERVIEW · <span style={{ color: 'var(--text)' }}>today</span></div>
          <window.Segmented size="sm" value="today" onChange={() => {}}
            options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]} />
        </div>
        {/* The real tiles in loading mode, with the same meter and second line the live
            ones carry, so the row lands at the same height. */}
        <div className="today-strip">
          <window.MiniStat loading label="Generated" />
          <window.MiniStat loading label="Home" />
          <window.MiniStat loading label="Self-sufficiency" bar={0} />
          <window.MiniStat loading label="Imported" sub={' '} />
          <window.MiniStat loading label="Est. saved" sub={' '} />
        </div>
      </div>
      {/* A battery is assumed until the snapshot says otherwise, as LiveTab does */}
      <window.BalanceSkeleton />
      <div className="card flow-card">
        <window.SectionTitle right={<button className="flow-fs-btn" disabled><window.FsEnterIcon /><span>Fullscreen</span></button>}>POWER FLOW</window.SectionTitle>
        {/* the summary sentence opens the card, one line of its height */}
        <div className="flow-narrative" style={{ height: 23, display: 'flex', alignItems: 'center' }}><window.Skeleton w={300} h={12} r={6} style={{ maxWidth: '80%' }} /></div>
        {/* sized in CSS to the diagram's proportions, which change with the card width */}
        <window.Skeleton className="flow-skel" h="auto" r={12} />
      </div>
      <div className="card chart-card">
        {/* The real chart with no data yet: its day picker and legend draw for real and
            the plot area is its own skeleton, so labels show and the height matches. */}
        <window.HistoryView today={null} refreshKey={0} locked />
      </div>
    </div>
  );
}

// Shown while the session and the SunSynk link are still being checked, before App
// mounts. Same shell as App's own not-yet-loaded gate, so the hand-over does not flash.
function BootShell() {
  // No remembered tab means this browser hasn't shown this account a dashboard since the
  // last sign-out: most likely a new account on its way to Connect SunSynk. A skeleton
  // would flash a dashboard it will never get, so show the empty sign-in backdrop.
  if (!localStorage.getItem('synsynk.tab')) return <div className="login-wrap" />;
  const tabs = tabsFor(loadSettings());
  const saved = new URLSearchParams(location.search).get('tab') || localStorage.getItem('synsynk.tab');
  const tab = tabs.some(t => t.id === saved) ? saved : 'live';
  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="sun" />
          <div>
            <div className="brand-name">Prince Solar</div>
            <div className="brand-sub mono">connecting to SunSynk…</div>
          </div>
        </div>
        <div className="topbar-actions">
          <div className="status-pill status-idle"><span className="status-dot" /><span className="status-word">Connecting</span></div>
          <button className="refresh-btn" disabled><span className="refresh-ico" aria-hidden="true">↻</span>Refresh</button>
        </div>
      </header>
      <nav className="tabbar" role="tablist" aria-busy="true">
        {tabs.map(t => <button key={t.id} className={'tab' + (tab === t.id ? ' active' : '')} role="tab" aria-selected={tab === t.id} disabled>{t.label}</button>)}
      </nav>
      <main className="content" aria-busy="true">
        {tab !== 'trends' && tab !== 'settings' && <LiveSkeleton />}
      </main>
    </div>
  );
}

function App() {
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
  // "Set your rate", "Set pack size": jump to that Settings section and flash it once.
  // SettingsTab opens whichever section synsynk.section names when it mounts.
  const openSettings = (section) => {
    localStorage.setItem('synsynk.section', section);
    setFlashSection(section); setTab('settings'); window.scrollTo({ top: 0 });
  };
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
  const loadLive = useCallback(async (spin = true) => {
    const t0 = Date.now();
    if (spin) setBusy(b => b + 1);
    try { setSnap(await window.fetchSnapshot()); setErr(null); }
    catch (e) { setErr(e.message); }
    finally { if (spin) setTimeout(() => setBusy(b => b - 1), Math.ceil((Date.now() - t0) / 800) * 800 - (Date.now() - t0)); }
  }, []);
  const loadToday = useCallback(async () => {
    try { setToday(await window.fetchDay()); } catch (e) { /* chart shows its own placeholder */ }
  }, []);
  // Battery balance is asked for alongside the snapshot, not after Live has drawn, and
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
  const reloadPlantConfig = () => {
    const before = window.CURRENT_PLANT;
    return loadMe().then(() => {
      if (window.CURRENT_PLANT !== before) setBalance(undefined);
      loadLive(); loadBalance();
    });
  };

  // initial load: who am I and which plant, then the data
  useEffect(() => { loadMe().then(() => { loadLive(); loadToday(); loadBalance(); }); }, []);
  // auto refresh: live every 60s (matches SunSynk's cadence), today and battery balance every 5 min
  useEffect(() => {
    if (!auto) return;
    const a = setInterval(() => loadLive(false), 60000);
    const b = setInterval(() => { loadToday(); refreshEnergy(); loadBalance(); }, 300000);
    return () => { clearInterval(a); clearInterval(b); };
  }, [auto]);

  const refresh = () => { if (busy) return; loadLive(); loadToday(); refreshEnergy(); loadBalance(); setRefreshKey(k => k + 1); };

  const TABS = tabsFor(settings);
  useEffect(() => { if (!TABS.some(t => t.id === tab)) setTab('live'); }, [settings.tabs]);
  // On a phone the tab bar scrolls sideways, so the active tab can sit off-screen after
  // a reload or a tap on the last visible one. Bring it into view; a no-op on desktop.
  useEffect(() => { document.querySelector('.tab.active')?.scrollIntoView({ inline: 'nearest', block: 'nearest' }); }, [tab, !!snap]);

  // ---- not-yet-loaded gate ----
  //
  // Renders the whole shell — topbar, tabs, page layout — with skeletons where the data
  // will go, rather than a bare "Loading…" card. The old gate withheld even the tab bar,
  // so there was nothing to look at until the snapshot landed.
  if (!snap) {
    return (
      <div className="app">
        <header className="topbar">
          <div className="brand">
            <span className="sun" />
            {/* The selector stays put while a switch loads; it vanishing mid-switch
                read as the app losing the plant. */}
            {me && (me.plants || []).length > 1 && !err
              ? <BrandLine snap={null} me={me} plantId={plantId} onPlant={switchPlant} />
              : <div>
                  <div className="brand-name">Prince Solar</div>
                  <div className="brand-sub mono">{err ? 'connection error' : 'connecting to SunSynk…'}</div>
                </div>}
          </div>
          <div className="topbar-actions">
            {notice
              ? <div className="status-pill status-switch" role="status"><span className="status-dot" /><span className="status-word">Switching</span><span className="status-detail mono">to {notice}</span></div>
              : <div className="status-pill status-idle"><span className="status-dot" /><span className="status-word">Connecting</span></div>}
            <button className={'refresh-btn' + (busy ? ' busy' : '')} disabled><span className="refresh-ico" aria-hidden="true">↻</span>Refresh</button>
          </div>
        </header>

        {/* Tabs stay live while loading: there is no reason to trap someone on Live
            just because the first snapshot hasn't landed. */}
        <nav className="tabbar" role="tablist" aria-busy="true">
          {TABS.map(t => (
            <button key={t.id} className={'tab' + (tab === t.id ? ' active' : '')}
                    onClick={() => setTab(t.id)} role="tab" aria-selected={tab === t.id}>{t.label}</button>
          ))}
        </nav>

        {err && <div className="card" style={{ marginBottom: 20, borderColor: 'rgba(248,113,113,0.35)' }}>
          <div style={{ color: 'var(--load)' }}>⚠ Can't reach the server.<div className="dim" style={{ marginTop: 8, fontSize: 13 }}>Retrying every 60 seconds; nothing to do on your side.</div></div>
        </div>}

        <main className="content" aria-busy="true">
          {/* Static chrome renders for real — titles, tab rows, segmented controls and
              tile labels are not data and have no business shimmering. Only values and
              plot areas get skeletons; control rows that can't be rendered yet get an
              inert spacer of the right height so nothing jumps either. */}
          {tab === 'trends' ? (
            // Like Settings, Trends never touches the snapshot — it fetches its own
            // aggregates. So render the real thing and let its own ChartSkeleton cover
            // the wait. A hand-built copy here drifted immediately: it hardcoded the
            // Energy view while TrendsTab actually defaults to Battery.
            <window.TrendsTab refreshKey={refreshKey} auto={auto} settings={settings} config={snap?.config} />
          ) : tab === 'settings' ? (
            // Still nothing to wait for: the pack figures come off the snapshot but
            // render as '—' until it lands, so Settings draws in full while the API is
            // still answering. Showing it a loading state was pure theatre.
            <window.SettingsTab settings={settings} setSettings={setSettings} config={snap?.config} me={me} plantId={plantId} onPlantConfigSaved={reloadPlantConfig} />
          ) : (
            <LiveSkeleton />
          )}
        </main>
      </div>
    );
  }

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="sun" />
          <BrandLine snap={snap} me={me} plantId={plantId} onPlant={switchPlant} />
        </div>
        <HeaderStatus snap={snap} onRefresh={refresh} busy={busy > 0} notice={notice} />
      </header>

      {/* The raw error is logged by window.onerror's sibling in the fetch path; on screen it
          was a Postgres or JWT string a homeowner cannot act on. */}
      {err && <div className="card" style={{ marginBottom: 16, borderColor: 'rgba(248,113,113,0.35)', color: 'var(--load)', fontSize: 13 }} title={String(err)}>⚠ Couldn't refresh; showing the last good reading.</div>}

      <nav className="tabbar" role="tablist">
        {TABS.map(t => (
          <button key={t.id} className={'tab' + (tab === t.id ? ' active' : '')} onClick={() => setTab(t.id)} role="tab" aria-selected={tab === t.id}>
            {t.label}
          </button>
        ))}
      </nav>

      <main className="content">
        {tab === 'live' && <window.LiveTab snap={snap} settings={settings} today={today} energy={energy} onNeedEnergy={onNeedEnergy} refreshKey={refreshKey} balance={balance}
          onOpenSettings={openSettings} />}
        {tab === 'solar' && <window.SolarTab snap={snap} energy={energy} onNeedEnergy={onNeedEnergy} />}
        {tab === 'battery' && <window.BatteryTab snap={snap} settings={settings} onOpenSettings={openSettings} />}
        {tab === 'grid' && <window.GridTab snap={snap} settings={settings} refreshKey={refreshKey} onOpenSettings={openSettings} />}
        {tab === 'inverters' && <window.InvertersTab snap={snap} settings={settings} refreshKey={refreshKey} />}
        {tab === 'trends' && <window.TrendsTab refreshKey={refreshKey} auto={auto} settings={settings} config={snap?.config} />}
        {tab === 'settings' && <window.SettingsTab settings={settings} setSettings={setSettings} config={snap?.config} me={me} plantId={plantId} onPlantConfigSaved={reloadPlantConfig}
          flash={flashSection} onFlashed={() => setFlashSection(null)} />}
      </main>

    </div>
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
    : <window.AuthGate fallback={<BootShell />}><window.LinkGate fallback={<BootShell />}><App /></window.LinkGate></window.AuthGate>
);
