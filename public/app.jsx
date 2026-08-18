// ============================================================================
// app.jsx — shell + live data owner: header, tab bar, fetch/refresh, persistence
// Fetches /api/overview (live snapshot) on a 60s tick, /api/history
// (today's chart) every 5 min, and lazily loads /api/energy per period on demand.
// ============================================================================
const { useState, useEffect, useRef, useCallback } = React;

const DEFAULT_SETTINGS = {
  battPositive: 'discharge',
  reserve: 20,
  battCapacity: 26.5, // 5 × 5.3 kWh banks (SunSynk's API under-reports this)
  // Off by default — the optional per-subject tabs are opt-in from Settings. Trends is
  // no longer listed here: like Live and Settings it is always on, so it needs no flag.
  tabs: { solar: false, battery: false, grid: false, inverters: false },
  tariff: { preset: 'custom', import: 3.40 },
};

function loadSettings() {
  try {
    const s = JSON.parse(localStorage.getItem('synsynk.settings'));
    if (s) return { ...DEFAULT_SETTINGS, ...s, tabs: { ...DEFAULT_SETTINGS.tabs, ...(s.tabs || {}) }, tariff: { ...DEFAULT_SETTINGS.tariff, ...(s.tariff || {}) } };
  } catch (e) {}
  return DEFAULT_SETTINGS;
}

function App() {
  const [settings, setSettings] = useState(loadSettings);
  const [tab, setTab] = useState(() => new URLSearchParams(location.search).get('tab') || localStorage.getItem('synsynk.tab') || 'live');
  const [auto, setAuto] = useState(true);
  const [snap, setSnap] = useState(null);
  const [today, setToday] = useState(null);
  const [energy, setEnergy] = useState({});
  const [pulse, setPulse] = useState(false);
  const [err, setErr] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0); // bumped on manual refresh so the chart re-fetches its current day

  const energyRef = useRef({});
  const inflight = useRef({});
  useEffect(() => { energyRef.current = energy; }, [energy]);

  useEffect(() => { localStorage.setItem('synsynk.settings', JSON.stringify(settings)); }, [settings]);
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

  // initial load
  useEffect(() => { loadLive(); loadToday(); }, []);
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
  if (!snap) {
    return (
      <div className="app">
        <header className="topbar">
          <div className="brand">
            <span className="sun" />
            <div>
              <div className="brand-name">SynSynk<span className="brand-dot"> · </span><span className="brand-live">Live</span></div>
              <div className="brand-sub mono">{err ? 'connection error' : 'connecting to SunSynk…'}</div>
            </div>
          </div>
        </header>
        <div className="card" style={{ marginTop: 8 }}>
          {err
            ? <div style={{ color: 'var(--load)' }}>⚠ {err}<div className="dim" style={{ marginTop: 8, fontSize: 13 }}>Check your credentials in <span className="mono">.env</span> and that the server can reach api.sunsynk.net. Retrying every 60s.</div></div>
            : <div className="dim">Loading live data…</div>}
        </div>
      </div>
    );
  }

  const onlineCount = snap.inverters.filter(i => i.status === 'online').length;
  const offlineCount = snap.inverters.length - onlineCount;
  const sensorIssue = snap.inverters.some(i => window.cleanTemp(i.battTemp) == null);
  const health = offlineCount >= snap.inverters.length ? 'red' : (offlineCount > 0 || sensorIssue) ? 'orange' : 'green';
  const healthTitle = health === 'red' ? 'All inverters offline' : health === 'orange' ? (offlineCount > 0 ? 'An inverter is offline' : 'Sensor issue detected') : 'All systems healthy';

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="sun" />
          <div>
            <div className="brand-name">SynSynk<span className="brand-dot"> · </span><span className="brand-live">Live</span></div>
            <div className="brand-sub mono"><span className={'health-dot health-' + health} title={healthTitle} />updated {window.fmtTime(snap.updated)} · {onlineCount}/{snap.inverters.length} inverters online{sensorIssue && offlineCount === 0 ? ' · sensor issue' : ''}</div>
          </div>
        </div>
        <div className="topbar-actions">
          <label className="auto-toggle">
            <input type="checkbox" checked={auto} onChange={e => setAuto(e.target.checked)} />
            <span>Auto</span>
          </label>
          <button className={'refresh-btn' + (pulse ? ' pulse' : '')} onClick={refresh}>Refresh</button>
        </div>
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
        {tab === 'trends' && <window.TrendsTab refreshKey={refreshKey} auto={auto} settings={settings} />}
        {tab === 'settings' && <window.SettingsTab settings={settings} setSettings={setSettings} />}
      </main>

    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <window.AuthGate><App /></window.AuthGate>
);
