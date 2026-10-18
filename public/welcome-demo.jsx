// The showcase's live demos (Live and Grid), built from the app's own components with
// the example day in window.DEMO. Moved out of welcome.html so it can be built (SOLAR-131).
(() => {
  const D = window.DEMO;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const NB = ' ';
  const hhmm = (h) => String(Math.floor(h)).padStart(2, '0') + ':' + String(Math.floor((h % 1) * 60 + 1e-6)).padStart(2, '0');
  const HMm = (m) => hhmm(m / 60);
  // Same wording as the app's battery time (tabs.jsx fmtDur)
  const fmtDur = (hrs) => { let h = Math.floor(hrs), m = Math.round((hrs - h) * 60); if (m === 60) { h++; m = 0; } return (h > 0 ? h + 'h ' : '') + String(m).padStart(h > 0 ? 2 : 1, '0') + 'm'; };

  // Totals from midnight to hour h, in kWh, plus where the solar went and the peaks.
  function totals(h) {
    const t = { pv: 0, chg: 0, dis: 0, imp: 0, exp: 0, home: 0, toHome: 0, toBatt: 0, toGrid: 0, pvPeak: null, impPeak: null };
    const n = Math.floor(h * 12);
    for (let k = 0; k < n; k++) {
      const r = D.rows[k];
      t.pv += r.pv / 12; t.home += r.home / 12;
      if (r.batt < 0) t.chg -= r.batt / 12; else t.dis += r.batt / 12;
      if (r.grid > 0) t.imp += r.grid / 12; else t.exp -= r.grid / 12;
      const toBatt = r.batt < 0 ? -r.batt : 0, toGrid = r.grid < 0 ? -r.grid : 0;
      t.toBatt += toBatt / 12; t.toGrid += toGrid / 12; t.toHome += (r.pv - toBatt - toGrid) / 12;
      if (r.pv > 0.02 && (!t.pvPeak || r.pv > t.pvPeak.kw)) t.pvPeak = { kw: r.pv, t: k * 5 };
      if (r.grid > 0.05 && (!t.impPeak || r.grid > t.impPeak.kw)) t.impPeak = { kw: r.grid, t: k * 5 };
    }
    return t;
  }

  // The day's 5-minute points as the app's charts take them, empty after hour h.
  const pointsTo = (h) => D.rows.map((r, k) => k <= h * 12 ? {
    t: k * 5, pv: r.pv * 1000, batt: r.batt * 1000, grid: r.off ? 0 : r.grid * 1000, load: r.home * 1000, soc: Math.round(r.soc),
  } : { t: k * 5, pv: null, batt: null, grid: null, load: null, soc: null });

  // The snapshot the app would hand PowerFlow, at hour h.
  function snapshot(h) {
    const now = D.at(h), t = totals(h);
    const battW = Math.abs(now.batt) * 1000, soc = Math.round(now.soc);
    const state = now.batt < -0.005 ? 'charging' : now.batt > 0.005 ? 'discharging' : 'idle';
    let battInfo = null;
    if (state === 'discharging' && battW >= 200) battInfo = fmtDur(Math.max(0, (soc - D.RESERVE) / 100 * D.CAP) / (battW / 1000)) + ' to empty';
    if (state === 'charging' && battW >= 200) battInfo = fmtDur((100 - soc) / 100 * D.CAP / (battW / 1000)) + ' to full';
    return {
      t, battInfo,
      agg: {
        pvNow: now.pv * 1000, loadNow: now.home * 1000,
        battPower: battW, battOut: now.batt * 1000, battState: state, battSoc: soc,
        gridPower: now.off ? 0 : now.grid * 1000, gridPresent: !now.off,
        pvToday: t.pv, battChgToday: t.chg, battDischgToday: t.dis,
        gridFromToday: t.imp, gridToToday: t.exp, loadToday: t.home,
      },
    };
  }

  // A clock for the example day, going round from `start`. Paused while off screen.
  function useDayClock(ref, { start, speed }) {
    const [hour, setHour] = React.useState(reduce ? 18.6 : start);
    const [visible, setVisible] = React.useState(false);
    React.useEffect(() => {
      const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting), { threshold: 0.15 });
      io.observe(ref.current);
      return () => io.disconnect();
    }, []);
    React.useEffect(() => {
      if (reduce || !visible) return;
      const id = setInterval(() => setHour(h => (h + speed) % 24), 50);
      return () => clearInterval(id);
    }, [visible]);
    return hour;
  }

  // The app's header strip around a page.
  const AppWin = ({ page, children }) => (
    <div className="appwin">
      <div className="appwin-head">
        <span className="sun" aria-hidden="true" />
        <span className="plant">Example <span className="plant-word">plant</span> <i className="ph-bold ph-caret-down" aria-hidden="true" /></span>
        <span className="page">{page}</span>
        <div className="status status-live" role="status"><span className="status-dot" /><span className="status-word">Live</span></div>
      </div>
      <div className="appwin-body">{children}</div>
    </div>
  );

  // ---------- Live: the app's Live page, running the example day ----------
  function LiveDemo() {
    const ref = React.useRef(null);
    const hour = useDayClock(ref, { start: 6, speed: 0.05 }); // an hour a second
    const s = snapshot(hour);
    const a = s.agg, t = s.t;
    const suff = t.home > 0 ? Math.max(0, Math.min(100, Math.round((t.home - t.imp) / t.home * 100))) : null;
    return (
      <div ref={ref}>
        <AppWin page="Live">
          <div className="live-grid">
            <window.Card className="flow-card">
              <window.SectionTitle>POWER FLOW</window.SectionTitle>
              <window.PowerFlow agg={a} inverters={2} battInfo={s.battInfo} features={{ hasBattery: true, hasGrid: true }} />
            </window.Card>
            <div className="overview-section">
              <div className="overview-head">
                <window.SectionTitle>OVERVIEW · <span style={{ color: 'var(--text)' }}>today</span></window.SectionTitle>
              </div>
              <div className="today-strip">
                <window.MiniStat label="Made" value={window.fmtEnergySmart(a.pvToday)} color="#3ddc84" />
                <window.MiniStat label="Home" value={window.fmtEnergySmart(a.loadToday)} color="#f87171" />
                <window.MiniStat label="Independence" value={suff != null ? suff + '%' : '—'} color="#22d3ee" bar={suff || 0} />
                <window.MiniStat label="Imported" value={window.fmtEnergySmart(a.gridFromToday)} color="#facc15"
                  sub={<span className={'grid-state ' + (a.gridPresent ? 'on' : 'off')}><span className="gs-dot" />{a.gridPresent ? 'Grid on' : 'Grid off'}</span>} />
              </div>
            </div>
          </div>
        </AppWin>
      </div>
    );
  }
  ReactDOM.createRoot(document.getElementById('liveDemo')).render(<LiveDemo />);

  // Solar and Grid hold still on the example day at 15:00; only Live plays.
  const STOP = 15;

  // ---------- Solar page ----------
  function SolarDemo() {
    const hour = STOP, at = D.at(hour), t = totals(hour);
    const points = React.useMemo(() => pointsTo(hour), []);
    const [nowN, nowU] = window.fmtPowerParts(at.pv * 1000);
    const [todN, todU] = window.fmtEnergyParts(t.pv);
    const dests = [['Home', t.toHome, '#f87171'], ['Battery', t.toBatt, '#a78bfa'], ['Grid', t.toGrid, '#facc15']].filter(d => d[1] >= 0.05);
    const made = dests.reduce((s, d) => s + d[1], 0);
    const rows = D.days.map(r => r.date === D.today ? { ...r, pv: t.pv } : r);
    const best = rows.reduce((b, r) => (r.pv > b.pv ? r : b));
    return (
      <div>
        <AppWin page="Solar">
          <div className="stack solar-tab">
            <div className="solar-stats">
              <window.StatTile label="SOLAR NOW" value={nowN} unit={nowU} accent="#3ddc84" sub={<><b>{Math.round(at.pv / D.KWP * 100)}%</b> of your {D.KWP} kW of panels</>} />
              <window.StatTile label="TODAY" value={todN} unit={todU} accent="#3ddc84" sub={t.pvPeak ? <>Peak <b>{window.fmtPower(t.pvPeak.kw * 1000)}</b> at <b>{HMm(t.pvPeak.t)}</b></> : NB} />
            </div>
            <window.Card>
              <window.SectionTitle>SOLAR · <span style={{ color: 'var(--text)' }}>today</span></window.SectionTitle>
              <window.DayLineChart points={points} field="pv" color="#3ddc84" label="Solar" crop sums={['Made']} empty="No solar yet today." />
            </window.Card>
            <window.Card>
              <window.SectionTitle right={<>Best <b>{window.fmtKwh(best.pv)}</b> on {new Date(best.date).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })}</>}>SOLAR · <span style={{ color: 'var(--text)' }}>last 30 days</span></window.SectionTitle>
              <window.DaysBars rows={rows} field="pv" color="#3ddc84" rgb="61,220,132" word="Solar" label="Solar per day for the last 30 days"
                today={D.today} selected={D.today} earliest={D.days[0].date} onPick={() => {}} />
            </window.Card>
            <window.Card className="wiw">
              <window.SectionTitle right={made >= 0.05 ? <>Made <b>{window.fmtKwh(made)}</b></> : null}>WHERE IT WENT · <span style={{ color: 'var(--text)' }}>today</span></window.SectionTitle>
              {made < 0.05 ? <div className="solar-note">No solar yet today.</div> : <>
                <div className="fbox-bar">{dests.map(([l, v, c]) => <i key={l} style={{ flexGrow: v, background: c }} />)}</div>
                <div className="wiw-figs">
                  {dests.map(([l, v, c]) => { const [n, u] = window.fmtEnergyParts(v); return <div key={l}><b style={{ color: c }}>{n}<span className="u">{u}</span></b><span>{l}</span></div>; })}
                </div>
              </>}
            </window.Card>
          </div>
        </AppWin>
      </div>
    );
  }
  ReactDOM.createRoot(document.getElementById('solarDemo')).render(<SolarDemo />);

  // ---------- Grid page ----------
  // Grid shows the whole example day, to 23:30: bought overnight once the battery reached
  // its reserve, nothing while solar ran the house, nothing again while load-shedding cut the
  // grid 18:00 to 20:30, then bought again late in the evening.
  function GridDemo() {
    const hour = 23.5, at = D.at(hour), t = totals(hour);
    const points = React.useMemo(() => pointsTo(hour), []);
    const w = at.off ? 0 : at.grid * 1000;
    const [nowN, nowU] = window.fmtPowerParts(w > 5 ? w : 0);
    const [todN, todU] = window.fmtEnergyParts(t.imp);
    const rows = D.days.map(r => r.date === D.today ? { ...r, imp: t.imp } : r);
    const most = rows.reduce((b, r) => (r.imp > b.imp ? r : b));
    // the example day's grid cut, as 5-minute buckets, shaded as the app's Grid chart does (SOLAR-125)
    const cut = [D.rows.findIndex(r => r.off), D.rows.findLastIndex(r => r.off)];
    return (
      <div>
        <AppWin page="Grid">
          <div className="stack solar-tab">
            <div className="solar-stats">
              <window.StatTile label="GRID NOW" value={nowN} unit={nowU} accent="#facc15" sub={at.off ? <span style={{ color: '#f87171' }}>The grid is off</span> : w > 5 ? 'Importing' : 'Not importing'} />
              <window.StatTile label="TODAY" value={todN} unit={todU} accent="#facc15" sub={t.impPeak ? <>Peak <b>{window.fmtPower(t.impPeak.kw * 1000)}</b> at <b>{HMm(t.impPeak.t)}</b></> : NB} />
            </div>
            <window.Card>
              <window.SectionTitle right={<window.OutagePill mins={(cut[1] - cut[0] + 1) * 5} what="Grid" />}>GRID · <span style={{ color: 'var(--text)' }}>today</span></window.SectionTitle>
              <window.DayLineChart points={points} field="grid" color="#facc15" label="Grid" sums={['Imported', 'Exported']} importScale outages={[cut]} empty="No grid readings for this day." />
            </window.Card>
            <window.Card>
              <window.SectionTitle right={<>Most <b>{window.fmtKwh(most.imp)}</b> on {new Date(most.date).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })}</>}>IMPORTED · <span style={{ color: 'var(--text)' }}>last 30 days</span></window.SectionTitle>
              <window.DaysBars rows={rows} field="imp" color="#facc15" rgb="250,204,21" word="Imported" label="Energy imported from the grid per day for the last 30 days"
                today={D.today} selected={D.today} earliest={D.days[0].date} onPick={() => {}} />
            </window.Card>
          </div>
        </AppWin>
      </div>
    );
  }
  ReactDOM.createRoot(document.getElementById('gridDemo')).render(<GridDemo />);
})();
