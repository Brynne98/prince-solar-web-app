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
  if (h < 36) return h + ' h ago';
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
function HeaderStatus({ snap, onRefresh, pulse }) {
  const now = useNow(15000);
  const online = snap.inverters.filter(i => i.status === 'online').length;
  const total = snap.inverters.length;
  const offline = total - online;
  const last = snap.lastReading || snap.updated;
  const ageS = (now - last.getTime()) / 1000;
  const status = (total > 0 && offline >= total) || ageS > 900 ? 'offline' : (offline > 0 || ageS > 180) ? 'stale' : 'live';
  const word = { live: 'Live', stale: 'Stale', offline: 'Offline' }[status];
  const detail = offline > 0 ? offline + ' of ' + total + ' inverters offline' : 'updated ' + fmtAgo(last, now);
  return (
    <div className="topbar-actions">
      <div className={'status-pill status-' + status} title={'last reading ' + window.fmtTime(last)}>
        <span className="status-dot" />
        <span className="status-word">{word}</span>
        <span className="status-detail mono">{detail}</span>
      </div>
      <button className={'refresh-btn' + (pulse ? ' pulse' : '')} onClick={onRefresh} title="Refresh now"><span className="refresh-ico" aria-hidden="true">↻</span>Refresh</button>
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
  return (
    <select className="plant-select" value={plantId ?? ''} onChange={e => onChange(e.target.value)} title="Switch plant" aria-label="Plant">
      {plants.map(p => <option key={p.id} value={p.id}>{p.name || ('Plant ' + p.id)}</option>)}
    </select>
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
  const [pulse, setPulse] = useState(false);
  const [err, setErr] = useState(null);
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

  const loadLive = useCallback(async () => {
    try { setSnap(await window.fetchSnapshot()); setErr(null); }
    catch (e) { setErr(e.message); }
  }, []);
  const loadToday = useCallback(async () => {
    try { setToday(await window.fetchDay()); } catch (e) { /* chart shows its own placeholder */ }
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
  const switchPlant = (id) => {
    const cfg = (me?.plants || []).find(p => p.id === Number(id))?.config;
    window.setCurrentPlant(id, cfg?.currency);
    setPlantId(Number(id));
    window.savePrefs({ lastPlant: Number(id) }).catch(() => {});
    setEnergy({}); energyRef.current = {}; setSnap(null); setToday(null);
    loadLive(); loadToday(); setRefreshKey(k => k + 1);
  };
  const reloadPlantConfig = () => loadMe().then(loadLive);

  // initial load: who am I and which plant, then the data
  useEffect(() => { loadMe().then(() => { loadLive(); loadToday(); }); }, []);
  // auto refresh: live every 60s (matches SunSynk's cadence), today every 5 min
  useEffect(() => {
    if (!auto) return;
    const a = setInterval(loadLive, 60000);
    const b = setInterval(() => { loadToday(); refreshEnergy(); }, 300000);
    return () => { clearInterval(a); clearInterval(b); };
  }, [auto]);

  const refresh = () => { loadLive(); loadToday(); refreshEnergy(); setRefreshKey(k => k + 1); setPulse(true); setTimeout(() => setPulse(false), 600); };

  const TABS = [
    { id: 'live', label: 'Live' },
    settings.tabs.solar && { id: 'solar', label: 'Solar' },
    settings.tabs.battery && { id: 'battery', label: 'Battery' },
    settings.tabs.grid && { id: 'grid', label: 'Grid' },
    settings.tabs.inverters && { id: 'inverters', label: 'Inverters' },
    { id: 'trends', label: 'Trends' },
    { id: 'settings', label: 'Settings' },
  ].filter(Boolean);
  useEffect(() => { if (!TABS.some(t => t.id === tab)) setTab('live'); }, [settings.tabs]);

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
            <div>
              <div className="brand-name">Prince Solar</div>
              <div className="brand-sub mono">{err ? 'connection error' : 'connecting to SunSynk…'}</div>
            </div>
          </div>
          <div className="topbar-actions">
            <div className="status-pill status-idle"><span className="status-dot" /><span className="status-word">Connecting</span></div>
            <button className="refresh-btn" disabled><span className="refresh-ico" aria-hidden="true">↻</span>Refresh</button>
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

        {err && <div className="card" style={{ marginBottom: 20, borderColor: 'rgba(255,125,107,0.35)' }}>
          <div style={{ color: 'var(--load)' }}>⚠ {err}<div className="dim" style={{ marginTop: 8, fontSize: 13 }}>Check your credentials in <span className="mono">.env</span> and that the server can reach api.sunsynk.net. Retrying every 60s.</div></div>
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
            <div className="live-grid">
              <div className="overview-section">
                <div className="overview-head">
                  <div className="section-title">OVERVIEW · <span style={{ color: 'var(--text)' }}>today</span></div>
                  <window.Segmented size="sm" value="today" onChange={() => {}}
                    options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]} />
                </div>
                <div className="today-strip">
                  {['Generated', 'Consumed', 'Self-sufficiency', 'Imported', 'Est. saved']
                    .map(l => <window.SkeletonTile key={l} label={l} />)}
                </div>
              </div>
              <div className="card flow-card">
                <div className="section-title">POWER FLOW</div>
                {/* .flow-wrap measures 577px with data in it */}
                <window.Skeleton h={577} r={12} />
              </div>
              <div className="card chart-card">
                {/* the day-picker row is static UI we can't populate yet: reserve its
                    33px without shimmering, then skeleton the 620px plot area */}
                <div style={{ height: 33 }} />
                <window.Skeleton h={620} r={12} style={{ marginTop: 16 }} />
              </div>
            </div>
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
        <HeaderStatus snap={snap} onRefresh={refresh} pulse={pulse} />
      </header>

      {err && <div className="card" style={{ marginBottom: 16, borderColor: 'rgba(255,125,107,0.35)', color: 'var(--load)', fontSize: 13 }}>⚠ Last refresh failed: {err} — showing last good reading.</div>}

      <nav className="tabbar" role="tablist">
        {TABS.map(t => (
          <button key={t.id} className={'tab' + (tab === t.id ? ' active' : '')} onClick={() => setTab(t.id)} role="tab" aria-selected={tab === t.id}>
            {t.label}
          </button>
        ))}
      </nav>

      <main className="content">
        {tab === 'live' && <window.LiveTab snap={snap} settings={settings} today={today} energy={energy} onNeedEnergy={onNeedEnergy} refreshKey={refreshKey} />}
        {tab === 'solar' && <window.SolarTab snap={snap} energy={energy} onNeedEnergy={onNeedEnergy} />}
        {tab === 'battery' && <window.BatteryTab snap={snap} settings={settings} />}
        {tab === 'grid' && <window.GridTab snap={snap} settings={settings} />}
        {tab === 'inverters' && <window.InvertersTab snap={snap} />}
        {tab === 'trends' && <window.TrendsTab refreshKey={refreshKey} auto={auto} settings={settings} config={snap?.config} />}
        {tab === 'settings' && <window.SettingsTab settings={settings} setSettings={setSettings} config={snap?.config} me={me} plantId={plantId} onPlantConfigSaved={reloadPlantConfig} />}
      </main>

    </div>
  );
}

const legalPage = new URLSearchParams(location.search).get('page');
ReactDOM.createRoot(document.getElementById('root')).render(
  legalPage === 'terms' || legalPage === 'privacy'
    ? <window.LegalPage which={legalPage} />
    : <window.AuthGate><window.LinkGate><App /></window.LinkGate></window.AuthGate>
);
