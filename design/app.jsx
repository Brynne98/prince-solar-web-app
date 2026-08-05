// ============================================================================
// app.jsx — shell: header, tab bar, live tick, persistence
// ============================================================================
const { useState, useEffect, useRef } = React;

const SUNC = '#f5b545';
function IconSun() {
  const rays = [0, 45, 90, 135, 180, 225, 270, 315].map(a => { const r = a * Math.PI / 180; return <line key={a} x1={(8 + Math.cos(r) * 4.8).toFixed(1)} y1={(8 + Math.sin(r) * 4.8).toFixed(1)} x2={(8 + Math.cos(r) * 6.6).toFixed(1)} y2={(8 + Math.sin(r) * 6.6).toFixed(1)} />; });
  return <svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke={SUNC} strokeWidth="1.4" strokeLinecap="round"><circle cx="8" cy="8" r="3" />{rays}</svg>;
}
function IconSunrise() {
  return <svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke={SUNC} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"><line x1="1.5" y1="13" x2="14.5" y2="13" /><path d="M4 13 a4 4 0 0 1 8 0" /><path d="M8 1.4 V4.4 M6 3 L8 1.2 L10 3" /></svg>;
}
function IconSunset() {
  return <svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke={SUNC} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"><line x1="1.5" y1="13" x2="14.5" y2="13" /><path d="M4 13 a4 4 0 0 1 8 0" /><path d="M8 4.6 V1.4 M6 2.8 L8 4.6 L10 2.8" /></svg>;
}

const DEFAULT_SETTINGS = {
  showSavings: true,
  filterBadSensors: true,
  battPositive: 'discharge',
  reserve: 20,
  tabs: { solar: true, battery: true, grid: true, inverters: true },
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
  const [tab, setTab] = useState(() => localStorage.getItem('synsynk.tab') || 'live');
  const [auto, setAuto] = useState(true);
  const [snap, setSnap] = useState(() => window.makeSnapshot(0));
  const [pulse, setPulse] = useState(false);

  useEffect(() => { localStorage.setItem('synsynk.settings', JSON.stringify(settings)); }, [settings]);
  useEffect(() => { localStorage.setItem('synsynk.tab', tab); }, [tab]);

  const refresh = () => { setSnap(window.makeSnapshot(1)); setPulse(true); setTimeout(() => setPulse(false), 500); };
  useEffect(() => {
    if (!auto) return;
    const id = setInterval(refresh, 5000);
    return () => clearInterval(id);
  }, [auto]);

  const TABS = [
    { id: 'live', label: 'Live' },
    settings.tabs.solar && { id: 'solar', label: 'Solar' },
    settings.tabs.battery && { id: 'battery', label: 'Battery' },
    settings.tabs.grid && { id: 'grid', label: 'Grid' },
    settings.tabs.inverters && { id: 'inverters', label: 'Inverters' },
    { id: 'settings', label: 'Settings' },
  ].filter(Boolean);

  // if active tab got hidden, fall back to live
  useEffect(() => { if (!TABS.some(t => t.id === tab)) setTab('live'); }, [settings.tabs]);

  const onlineCount = snap.inverters.filter(i => i.status === 'online').length;
  const offlineCount = snap.inverters.length - onlineCount;
  const sensorIssue = snap.inverters.some(i => window.cleanTemp(i.battTemp) == null);
  const health = offlineCount >= snap.inverters.length ? 'red' : (offlineCount > 0 || sensorIssue) ? 'orange' : 'green';
  const healthTitle = health === 'red' ? 'All inverters offline' : health === 'orange' ? (offlineCount > 0 ? 'An inverter is offline' : 'Sensor issue detected') : 'All systems healthy';
  const wx = snap.weather;
  const toMin = s => { const [h, m] = s.split(':').map(Number); return h * 60 + m; };
  const dayFrac = wx ? Math.max(0, Math.min(1, ((wx.nowMin ?? 845) - toMin(wx.sunrise)) / (toMin(wx.sunset) - toMin(wx.sunrise)))) : 0;

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
        {wx && (
          <div className="header-weather">
            <div className="hw-item"><IconSun /><span className="hw-val mono">{wx.temp}°C</span><span className="hw-cap">{wx.desc}</span></div>
            <span className="hw-sep" />
            <div className="hw-daylight">
              <IconSunrise /><span className="hw-time mono">{wx.sunrise}</span>
              <div className="hw-track" title="daylight progress"><div className="hw-track-fill" style={{ width: (dayFrac * 100) + '%' }} /><div className="hw-marker" style={{ left: (dayFrac * 100) + '%' }} /></div>
              <span className="hw-time mono">{wx.sunset}</span><IconSunset />
            </div>
          </div>
        )}
        <div className="topbar-actions">
          <label className="auto-toggle">
            <input type="checkbox" checked={auto} onChange={e => setAuto(e.target.checked)} />
            <span>Auto</span>
          </label>
          <button className={'refresh-btn' + (pulse ? ' pulse' : '')} onClick={refresh}>Refresh</button>
        </div>
      </header>

      <nav className="tabbar" role="tablist">
        {TABS.map(t => (
          <button key={t.id} className={'tab' + (tab === t.id ? ' active' : '')} onClick={() => setTab(t.id)} role="tab" aria-selected={tab === t.id}>
            {t.label}
          </button>
        ))}
      </nav>

      <main className="content">
        {tab === 'live' && <window.LiveTab snap={snap} settings={settings} />}
        {tab === 'solar' && <window.SolarTab snap={snap} />}
        {tab === 'battery' && <window.BatteryTab snap={snap} settings={settings} />}
        {tab === 'grid' && <window.GridTab snap={snap} settings={settings} />}
        {tab === 'inverters' && <window.InvertersTab snap={snap} />}
        {tab === 'settings' && <window.SettingsTab settings={settings} setSettings={setSettings} />}
      </main>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
