// ============================================================================
// tabs.jsx — the individual views. Live / Solar / Battery / Grid / Inverters / Settings
// (History lives in chart.jsx as <HistoryView/>)
// Week/Month/Year aggregates come from the live `energy` cache owned by <App>;
// `onNeedEnergy(period)` asks App to lazily fetch a period it hasn't loaded yet.
// ============================================================================
const { Card, StatTile, Metric, Badge, Segmented, Toggle, SectionTitle, Sparkline,
  fmtPower, fmtPowerParts, fmtKwh, fmtRand, cleanTemp, COLORS: CC } = window;

const FsEnterIcon = () => <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M2 6V2h4M14 6V2h-4M2 10v4h4M14 10v4h-4" /></svg>;
const FsExitIcon = () => <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M6 2v4H2M10 2v4h4M6 14v-4H2M10 14v-4h4" /></svg>;

// circular SOC gauge -----------------------------------------------------------
function Gauge({ value, color, size = 168, label, sub }) {
  const r = size / 2 - 12, cx = size / 2, c = 2 * Math.PI * r;
  const off = c * (1 - value / 100);
  return (
    <div className="gauge" style={{ width: size, height: size }}>
      <svg width={size} height={size}>
        <circle cx={cx} cy={cx} r={r} fill="none" stroke="rgba(255,255,255,0.07)" strokeWidth="9" />
        <circle cx={cx} cy={cx} r={r} fill="none" stroke={color} strokeWidth="9" strokeLinecap="round"
          strokeDasharray={c} strokeDashoffset={off} transform={`rotate(-90 ${cx} ${cx})`}
          style={{ transition: 'stroke-dashoffset .6s ease' }} />
      </svg>
      <div className="gauge-center">
        <div className="gauge-val mono" style={{ color }}>{value}<span className="gauge-pct">%</span></div>
        {label && <div className="gauge-label">{label}</div>}
        {sub && <div className="gauge-sub">{sub}</div>}
      </div>
    </div>
  );
}

// Battery-balance banner — watches the SOC/voltage spread between the two inverter
// banks (the desync signal) while the charge current is being pushed up. Polls every
// 60 s on its own. Subtle when Balanced, loud when Drifting.
function BatteryBalanceBanner({ refreshKey }) {
  const [b, setB] = React.useState(null);
  React.useEffect(() => {
    let alive = true;
    const load = () => window.fetchBalance().then((d) => { if (alive) setB(d); }).catch(() => {});
    load();
    const id = setInterval(load, 60000);
    return () => { alive = false; clearInterval(id); };
  }, [refreshKey]);
  if (!b || b.status === 'unknown') return null;
  const COL = { balanced: '#3ddc84', watch: '#f5b545', drifting: '#f5664e' };
  const c = COL[b.status] || '#7c8794';
  const label = { balanced: 'Balanced', watch: 'Watch', drifting: 'Drifting' }[b.status];
  // Status carries the desync detail (spread / voltage / 3-day peak) in its tooltip,
  // so the banner itself stays to a status + three clean stats.
  const statusTip = b.stale
    ? 'No recent paired reading from both banks'
    : `Banks ${b.socSpread ?? 0}% / ${b.vSpread ?? 0} V apart`
      + (b.max72h != null ? ` · peak ${b.max72h}% over 3 days` : '')
      + (b.pending ? ' · elevated now — flags only if it holds 10 min' : '');
  return (
    <div className={'batt-balance ' + b.status}>
      <span className="bb-dot" style={{ background: c }} />
      <span className="bb-title">Battery</span>
      <span className="bb-status" style={{ color: c }} title={statusTip}>
        {label}{b.status === 'drifting' ? ' ⚠' : b.status === 'balanced' ? ' ✓' : ''}
      </span>
      <span className="bb-div" />
      <div className="bb-stats">
        <span className="bb-stat" title={statusTip}>
          <span className="bb-k">SOC</span><b className="mono">{(b.banks || []).map((x) => x.soc).join(' / ')}%</b>
        </span>
        {b.tempC != null && (
          <span className={'bb-stat' + (b.tempHot ? ' bb-hot' : '')} title="Pack temperature. LFP lasts longest below ~25°C; ageing climbs past ~35°C.">
            <span className="bb-k">Temp</span><b className="mono">{b.tempC}°{b.tempHot ? ' ⚠' : ''}</b>
          </span>
        )}
        {b.hrsAtFullToday != null && (
          <span className="bb-stat" title="Hours at ≥98% charge today. Brief is healthy and keeps the BMS calibrated; long spells in summer heat are what to avoid.">
            <span className="bb-k">Full</span><b className="mono">{b.hrsAtFullToday}h</b>
          </span>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- LIVE
function LiveTab({ snap, settings, today, energy, onNeedEnergy, refreshKey }) {
  const a = snap.aggregate;
  // Typical charge at this hour, from complete days over the last week
  // (same default window as Trends). Fetched on mount / manual refresh —
  // the 24-hour profile barely moves, and the live snapshot tick (60s) is
  // enough to roll the displayed hour at :00.
  const [hourly, setHourly] = React.useState(null);
  React.useEffect(() => {
    let alive = true;
    window.fetchHourly().then((d) => { if (alive) setHourly(d); }).catch(() => {});
    return () => { alive = false; };
  }, [refreshKey]);
  const hourNow = (snap.updated instanceof Date ? snap.updated : new Date()).getHours();
  const typicalRow = (hourly && hourly.hours || []).find((h) => Number(h.hour) === hourNow);
  const typicalSoc = typicalRow && typicalRow.soc != null && Number.isFinite(Number(typicalRow.soc))
    ? Math.round(Number(typicalRow.soc)) : null;
  const typicalHour = typicalSoc != null ? hourNow : null;
  // ---- battery runtime estimate (at current draw, down to the configured reserve) ----
  // Pack figures come from app_config via the snapshot, so these agree with the
  // phone alerts by construction. The literals are only a pre-first-fetch fallback.
  const RESERVE = snap.config?.reserve ?? 20;
  const cap = snap.config?.battCapacity ?? 26.5;
  const availKwh = Math.max(0, (a.battSoc - RESERVE) / 100 * cap);
  const headroomKwh = Math.max(0, (100 - a.battSoc) / 100 * cap);
  const fmtDur = (hrs) => { let h = Math.floor(hrs), m = Math.round((hrs - h) * 60); if (m === 60) { h++; m = 0; } return (h > 0 ? h + 'h ' : '') + String(m).padStart(h > 0 ? 2 : 1, '0') + 'm'; };
  const fmtEta = (hrs) => {
    const d = new Date(snap.updated.getTime() + hrs * 3600000);
    return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) + ', ' + d.toLocaleDateString('en', { weekday: 'short', day: 'numeric', month: 'short' });
  };
  let battEta = null, battInfo = null;
  if (a.battState === 'discharging' && a.battPower > 50) {
    const hrs = availKwh / (a.battPower / 1000);
    battEta = <span className="batt-eta"><span className="bel">≈ <b>{fmtDur(hrs)}</b> until {RESERVE}% reserve</span><span className="bel sub">~{fmtEta(hrs)}</span></span>;
    battInfo = `${fmtDur(hrs)} to empty`;
  } else if (a.battState === 'charging' && a.battPower > 50) {
    const hrs = headroomKwh / (a.battPower / 1000);
    battEta = <span className="batt-eta"><span className="bel">≈ <b>{fmtDur(hrs)}</b> to full</span><span className="bel sub">~{fmtEta(hrs)}</span></span>;
    battInfo = `${fmtDur(hrs)} to full`;
  }

  // ---- power-flow fullscreen (wall-dashboard mode) ----
  const flowRef = React.useRef(null);
  const [isFs, setIsFs] = React.useState(false);
  const [cursorHidden, setCursorHidden] = React.useState(false);
  const fsEl = () => document.fullscreenElement || document.webkitFullscreenElement;
  const toggleFlowFs = () => {
    const el = flowRef.current; if (!el) return;
    if (fsEl()) (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    else (el.requestFullscreen || el.webkitRequestFullscreen).call(el);
  };
  React.useEffect(() => {
    const onChange = () => {
      const on = fsEl() === flowRef.current;
      setIsFs(on);
      if (!on) setCursorHidden(false);
      try { on ? localStorage.setItem('synsynk.flowFs', '1') : localStorage.removeItem('synsynk.flowFs'); } catch (e) {}
    };
    document.addEventListener('fullscreenchange', onChange);
    document.addEventListener('webkitfullscreenchange', onChange);
    return () => { document.removeEventListener('fullscreenchange', onChange); document.removeEventListener('webkitfullscreenchange', onChange); };
  }, []);
  // auto-hide the cursor after a few idle seconds while fullscreen (wall display)
  React.useEffect(() => {
    if (!isFs) return;
    let t;
    const arm = () => { setCursorHidden(false); clearTimeout(t); t = setTimeout(() => setCursorHidden(true), 3000); };
    arm();
    window.addEventListener('mousemove', arm);
    return () => { clearTimeout(t); window.removeEventListener('mousemove', arm); };
  }, [isFs]);
  // remember the dashboard: if we left in fullscreen, re-enter on the first interaction
  // (browsers require a user gesture, so we can't auto-enter on load alone)
  React.useEffect(() => {
    let armed = false;
    try { armed = localStorage.getItem('synsynk.flowFs') === '1'; } catch (e) {}
    if (!armed) return;
    const resume = () => { cleanup(); if (!fsEl() && flowRef.current) { try { (flowRef.current.requestFullscreen || flowRef.current.webkitRequestFullscreen).call(flowRef.current); } catch (e) {} } };
    const cleanup = () => { window.removeEventListener('pointerdown', resume); window.removeEventListener('keydown', resume); };
    window.addEventListener('pointerdown', resume, { once: true });
    window.addEventListener('keydown', resume, { once: true });
    return cleanup;
  }, []);

  // ---- period-over-period trend arrows on the Overview cards ----
  const [cmp, setCmp] = React.useState(null);
  React.useEffect(() => { window.fetchCompare().then(setCmp).catch(() => {}); }, [refreshKey]);

  // ---- period overview: Today / Week / Month / Year / Lifetime ----
  const [period, setPeriod] = React.useState('today');
  const isAgg = period === 'week' || period === 'month' || period === 'year' || period === 'lifetime';
  React.useEffect(() => { if (isAgg && !energy[period]) onNeedEnergy(period); }, [period, energy]);
  const heavy = React.useMemo(() => {
    if (!isAgg) return null;
    const rows = energy[period];
    if (!rows) return null;
    return rows.reduce((o, d) => ({ pv: o.pv + d.pv, load: o.load + d.load, imp: o.imp + d.imp, chg: o.chg + d.chg, dischg: o.dischg + d.dischg }), { pv: 0, load: 0, imp: 0, chg: 0, dischg: 0 });
  }, [period, energy]);
  const rate = settings.tariff.import;
  let pPv, pLoad, pImp;
  if (period === 'today') { pPv = a.pvToday; pLoad = a.loadToday; pImp = a.gridFromToday; }
  else if (heavy) { pPv = heavy.pv; pLoad = heavy.load; pImp = heavy.imp; }
  else { pPv = pLoad = pImp = null; } // aggregate period still loading
  // clamp to 0–100: import can exceed load when the grid charges the battery,
  // which would otherwise drive this negative (and break the bar).
  const pSuff = (pLoad != null && pLoad > 0) ? Math.max(0, Math.min(100, Math.round(((pLoad - pImp) / pLoad) * 100))) : null;
  const pSaved = (pLoad != null) ? Math.max(0, pLoad - pImp) * rate : null;
  const pending = isAgg && !energy[period];
  const periodWord = { today: 'today', week: 'this week', month: 'this month', year: 'this year', lifetime: 'all-time' }[period];
  // trend vs the same elapsed slice of the previous period. Suppress "today" until
  // midday — a partial morning vs a full yesterday reads as a misleading drop.
  const showCmp = period !== 'today' || new Date().getHours() >= 12;
  // "current" = the live value shown in the tile (pPv/pLoad/…) so the arrow stays
  // consistent with the number AND moves on every refresh; "previous" comes from
  // the compare endpoint (same elapsed slice of the prior period).
  const prev = (showCmp && cmp && cmp[period]) ? cmp[period].prev : null;
  // A zero baseline is not the same as "nothing to compare". Zero then zero is a real
  // result — no change — and dropping the badge made a steady 0.0 kWh import look like
  // missing data. Zero then something has no meaningful percentage, so hand the badge
  // Infinity and let it fall back to the absolute kWh change it already knows how to show.
  // Did the previous period log anything at all? If it recorded generation or
  // consumption then a zero import is a REAL zero, not a gap — which is the common
  // case here, since plenty of days import nothing. Without this test both look
  // identical and the badge has to stay silent.
  const prevHasData = !!prev && ((prev.pv || 0) > 0 || (prev.load || 0) > 0);
  const pct = (c, p) => {
    if (c == null || p == null) return null;
    // Zero then zero is no change. Zero then something has no meaningful percentage,
    // so hand the badge Infinity and let it fall back to the absolute kWh change —
    // but only when the previous period actually logged data, otherwise a logger
    // outage would read as a rise from nothing.
    if (p === 0) return c === 0 ? 0 : (prevHasData ? Infinity : null);
    return ((c - p) / p) * 100;
  };
  const tGen = prev ? pct(pPv, prev.pv) : null;
  const tCon = prev ? pct(pLoad, prev.load) : null;
  const tImp = prev ? pct(pImp, prev.imp) : null;
  // absolute kWh change, the hybrid fallback when a % would explode off a tiny baseline
  const dGen = prev ? (pPv - prev.pv) : null;
  const dCon = prev ? (pLoad - prev.load) : null;
  const dImp = prev ? (pImp - prev.imp) : null;
  const prevSuff = (prev && prev.load > 0) ? Math.max(0, Math.min(100, ((prev.load - prev.imp) / prev.load) * 100)) : null;
  const tSuff = (pSuff != null && prevSuff != null) ? (pSuff - prevSuff) : null;
  const cmpWord = { today: 'vs yesterday', week: 'vs last week', month: 'vs last month', year: 'vs last year' }[period];

  return (
    <div className="live-grid">
      <BatteryBalanceBanner refreshKey={refreshKey} />
      <div className={'flow-fs-wrap' + (cursorHidden ? ' cursor-hidden' : '')} ref={flowRef}>
        <Card className="flow-card">
          <SectionTitle right={
            <button className="flow-fs-btn" onClick={toggleFlowFs} title={isFs ? 'Exit fullscreen (Esc)' : 'Fullscreen — wall-dashboard mode'} aria-label="Toggle fullscreen">
              {isFs ? <FsExitIcon /> : <FsEnterIcon />}<span>{isFs ? 'Exit' : 'Fullscreen'}</span>
            </button>
          }>POWER FLOW</SectionTitle>
          <window.PowerFlow agg={a} inverters={snap.inverters.filter(i => i.status === 'online').length} battInfo={battInfo} typicalSoc={typicalSoc} typicalHour={typicalHour} />
        </Card>
      </div>

      <Card className="chart-card">
        <window.HistoryView today={today} refreshKey={refreshKey} />
      </Card>

      <div className="overview-section">
        <div className="overview-head">
          <SectionTitle>OVERVIEW · <span style={{ color: 'var(--text)' }}>{periodWord}</span></SectionTitle>
          <Segmented size="sm"
            options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]}
            value={period} onChange={setPeriod} />
        </div>
        <div className="today-strip">
          <MiniStat loading={pending} label="Generated" value={window.fmtEnergySmart(pPv)} color={CC.pv} trend={tGen} trendDelta={dGen} trendTitle={cmpWord}
            info="Total solar energy your panels produced over the selected period." />
          <MiniStat loading={pending} label="Consumed" value={window.fmtEnergySmart(pLoad)} color={CC.load} trend={tCon} trendDelta={dCon} trendInvert trendTitle={cmpWord}
            info="Total energy your home used over the selected period, summed across all inverters." />
          <MiniStat loading={pending} label="Self-sufficiency" value={pSuff != null ? pSuff + '%' : '—'} color={CC.soc} bar={pSuff || 0} trend={tSuff} trendTitle={cmpWord}
            info="Share of your home’s energy that came from your own solar + battery rather than the grid. 100% = fully off-grid for the period." />
          <MiniStat loading={pending} label="Imported" value={window.fmtEnergySmart(pImp)} color={CC.grid} trend={tImp} trendDelta={dImp} trendInvert trendTitle={cmpWord}
            info="Energy drawn from the grid over the selected period."
            sub={a.gridPresent == null ? null : (
              // Presence, not usage: mains voltage is there even when you draw nothing
              // from it, so this stays ON through a sunny self-powered afternoon.
              <span className={'grid-state ' + (a.gridPresent ? 'on' : 'off')}
                    title={a.gridPresent
                      ? 'Mains voltage detected. This reads ON whenever the utility is live, even when you are drawing nothing from it.'
                      : 'No mains voltage on any inverter — the utility supply is down.'}>
                <span className="gs-dot" />{a.gridPresent ? 'Grid on' : 'Grid off'}
              </span>
            )} />
          <MiniStat loading={pending} label="Est. saved" value={window.fmtRandSmart(pSaved)} color={CC.batt}
            info="Rough money saved = the grid energy you avoided buying (your consumption not supplied by the grid) valued at your import rate. Set the rate in Settings." />
        </div>
      </div>

    </div>
  );
}
function TrendBadge({ pct, unit = '%', invert, title, delta }) {
  if (pct == null) return null;                       // only hide when there is no prior period
  const usable = Number.isFinite(delta);
  if (!Number.isFinite(pct) && !usable) return null;  // grew from zero and no kWh figure to show
  const mag = Math.abs(pct);
  if (mag < 0.05) return <span className="trend-badge flat" title={(title || 'vs previous period') + ' — no change'}>0{unit}</span>; // dead flat: neutral, no arrow
  const up = pct >= 0;
  const good = invert ? !up : up;
  // Hybrid: show the % normally, but when it explodes off a near-zero baseline
  // (0.1 → 4.9 kWh would read +4800%), fall back to the absolute kWh change, which
  // is always meaningful. Threshold ≥200% (a 3×+ jump).
  let label;
  if ((mag >= 200 || !Number.isFinite(mag)) && usable) {
    const d = Math.abs(delta);
    label = (d < 10 ? d.toFixed(1) : String(Math.round(d))) + ' kWh';
  } else {
    label = (mag < 1 ? mag.toFixed(1) : String(Math.round(mag))) + unit; // decimal under 1% so a tiny change isn't shown as "0%"
  }
  return <span className={'trend-badge ' + (good ? 'good' : 'bad')} title={title || 'vs previous period'}>{up ? '▲' : '▼'} {label}</span>;
}
function MiniStat({ label, value, color, sub, bar, info, trend, trendUnit, trendInvert, trendTitle, trendDelta, loading }) {
  return (
    <Card className="mini-stat">
      <div className="mini-label">{label}{info && <window.InfoDot text={info} />}</div>
      {/* a shimmer beats an em-dash: switching to Week/Month refetches, and "—" reads as
          "no data" rather than "fetching" */}
      {loading
        ? <div className="mini-value"><window.Skeleton w="70%" h={26} /></div>
        : <div className="mini-value mono" style={{ color }}><span className="mv-num">{value}</span><TrendBadge pct={trend} unit={trendUnit} invert={trendInvert} title={trendTitle} delta={trendDelta} /></div>}
      {bar != null && !loading && <div className="meter sm"><div className="meter-fill" style={{ width: Math.max(0, Math.min(100, bar)) + '%', background: color }} /></div>}
      {bar != null && loading && <window.Skeleton h={5} r={4} style={{ marginTop: 8 }} />}
      {sub && <div className="mini-sub mono">{sub}</div>}
    </Card>
  );
}


// ---------------------------------------------------------------- SOLAR
function SolarTab({ snap, energy, onNeedEnergy }) {
  const a = snap.aggregate;
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);
  const sumPv = (rows) => (rows ? rows.reduce((s, d) => s + d.pv, 0) : null);
  const gen = { week: sumPv(energy.week), month: sumPv(energy.month), year: sumPv(energy.year), lifetime: sumPv(energy.lifetime) };
  const EP = window.fmtEnergyParts;
  // k is null until that period's rows arrive — shimmer instead of an em-dash
  const card = (label, k) => { const [v, u] = EP(k); return <StatTile loading={k == null} label={label} value={v} unit={u ? ' ' + u : ''} accent={CC.pv} />; };
  return (
    <div className="stack">
      <div className="solar-stats">
        <StatTile label="SOLAR NOW" value={fmtPowerParts(a.pvNow)[0]} unit={' ' + fmtPowerParts(a.pvNow)[1]} accent={CC.pv} />
        {card('TODAY', a.pvToday)}
        {card('THIS WEEK', gen.week)}
        {card('THIS MONTH', gen.month)}
        {card('THIS YEAR', gen.year)}
        {card('LIFETIME', gen.lifetime)}
      </div>
      <Card>
        <SectionTitle>SOLAR STRINGS</SectionTitle>
        {snap.inverters.map(inv => (
          <div className="string-group" key={inv.sn}>
            <div className="string-group-head">
              <div className="sgh-left">
                <span className="sgh-name mono">{inv.alias}</span>
                <span className="sgh-sn mono dim">SN {inv.sn}</span>
              </div>
              <span className="sgh-pv mono" style={{ color: CC.pv }}>{fmtPower(inv.pvNow)} · {fmtKwh(inv.pvToday)} today</span>
            </div>
            <div className="string-grid">
              {inv.strings.map(s => {
                const dead = s.v < 1.5 && s.p < 5;
                const idle = s.p < 5;
                return (
                  <div className={'string-card' + (dead ? ' warn' : '')} key={inv.sn + s.no}>
                    <div className="string-head">
                      <div className="string-title">String {s.no}</div>
                      {dead ? <Badge tone="warn" dot>check</Badge> : idle ? <Badge tone="neutral">idle</Badge> : <Badge tone="ok" dot>active</Badge>}
                    </div>
                    <div className="string-power mono" style={{ color: idle ? 'var(--muted)' : CC.pv }}>{fmtPower(s.p)}</div>
                    <div className="string-row"><span>Voltage</span><span className="mono">{s.v.toFixed(1)} V</span></div>
                    <div className="string-row"><span>Current</span><span className="mono">{s.i.toFixed(1)} A</span></div>
                    <div className="string-row"><span>Today</span><span className="mono" style={{ color: CC.pv }}>{fmtKwh(s.today)}</span></div>
                  </div>
                );
              })}
            </div>
          </div>
        ))}
        <div className="hint-line">Strings reading ~1&nbsp;V / 0&nbsp;W are normal at night, but worth a look if it persists at midday (shading, a tripped breaker, or a failed string).</div>
      </Card>
    </div>
  );
}

// ---------------------------------------------------------------- BATTERY
function BatteryTab({ snap, settings }) {
  const a = snap.aggregate;
  const reserve = snap.config?.reserve ?? 20;
  const cap = snap.config?.battCapacity ?? 26.5;
  const banks = snap.inverters.filter(i => i.numberOfBatteries > 0).length;
  const modules = snap.inverters.reduce((n, i) => n + (i.numberOfBatteries || 0), 0);
  return (
    <div className="stack">
      <div className="batt-top">
        <Card className="batt-gauge-card">
          <Gauge value={a.battSoc} color={CC.batt} label={a.battState} sub={fmtPower(a.battPower)} />
          <div className="batt-gauge-meta">
            <Metric label="Pack voltage" value={a.battVoltage.toFixed(1)} unit=" V" />
            <Metric label="Current" value={a.battCurrent.toFixed(1)} unit=" A" accent={a.battCurrent < 0 ? CC.batt : CC.pv} />
            <Metric label="Temperature" value={cleanTemp(a.battTemp) != null ? a.battTemp.toFixed(1) : '—'} unit={cleanTemp(a.battTemp) != null ? ' °C' : ''} />
          </div>
        </Card>
        <Card className="grow">
          <SectionTitle>THROUGHPUT TODAY</SectionTitle>
          <div className="throughput">
            <div><div className="tp-label">Charged</div><div className="tp-val mono" style={{ color: CC.batt }}>+{a.battChgToday} kWh</div></div>
            <div><div className="tp-label">Discharged</div><div className="tp-val mono" style={{ color: CC.load }}>−{a.battDischgToday} kWh</div></div>
            <div><div className="tp-label">Capacity</div><div className="tp-val mono">{cap.toFixed(1)} kWh</div></div>
            <div><div className="tp-label">Est. cycles today</div><div className="tp-val mono">{(a.battDischgToday / cap).toFixed(2)}</div></div>
          </div>
          <div className="meter-head">
            <span className="meter-cap">State of charge</span>
            <span className="mono" style={{ color: CC.batt }}>{a.battSoc}%</span>
          </div>
          <div className="meter big">
            <div className="meter-fill" style={{ width: a.battSoc + '%', background: CC.batt }} />
            <div className="reserve-mark" style={{ left: reserve + '%' }} title={`reserve ${reserve}%`} />
          </div>
          <div className="meter-scale"><span>0%</span><span>100%</span></div>
          <div className="hint-line">The bar is your battery’s charge level; the tick marks the <b>{reserve}%</b> reserve floor where discharge stops (~{(Math.max(0, (a.battSoc - reserve) / 100 * cap)).toFixed(1)} kWh usable above it). Sign convention: <b>{settings.battPositive === 'charge' ? 'positive = charging' : 'negative current = charging'}</b> (set in Settings).</div>
        </Card>
      </div>
      <Card>
        <SectionTitle right={<span className="dim">{banks} {banks === 1 ? 'bank' : 'banks'} · {modules} {modules === 1 ? 'battery' : 'batteries'} · single bank per inverter</span>}>PER INVERTER</SectionTitle>
        <div className="duo">
          {snap.inverters.map(inv => {
            const t = cleanTemp(inv.battTemp);
            return (
              <div className="mini-panel" key={inv.sn}>
                <div className="mp-head"><span className="mono">{inv.alias}</span><span className="dim mono">{inv.numberOfBatteries} × bank · {inv.battCap} Ah</span></div>
                <div className="mp-grid">
                  <Metric label="Power" value={fmtPower(inv.battPower)} accent={CC.batt} />
                  <Metric label="Charge" value={inv.battSoc} unit="%" accent={CC.batt} />
                  <Metric label="Voltage" value={inv.battVolt.toFixed(1)} unit=" V" />
                  <Metric label="Temp" value={t != null ? inv.battTemp.toFixed(1) : 'bad sensor'} unit={t != null ? ' °C' : ''} accent={t == null ? CC.load : null} />
                </div>
              </div>
            );
          })}
        </div>
      </Card>
    </div>
  );
}

// ---------------------------------------------------------------- GRID
function GridTab({ snap, settings }) {
  const a = snap.aggregate;
  const selfSuff = a.loadToday > 0 ? Math.max(0, Math.min(100, Math.round(((a.loadToday - a.gridFromToday) / a.loadToday) * 100))) : 0;
  const rate = settings.tariff.import;
  const wouldPay = a.loadToday * rate;                              // all consumption bought from grid
  const cost = a.gridFromToday * rate;                             // what you actually paid the grid
  const saved = Math.max(0, a.loadToday - a.gridFromToday) * rate;  // avoided cost = wouldPay − cost
  return (
    <div className="stack">
      <div className="trio">
        <StatTile label="GRID NOW" value={fmtPowerParts(Math.abs(a.gridPower))[0]} unit={' ' + fmtPowerParts(Math.abs(a.gridPower))[1]} accent={CC.grid}
          sub={a.gridPower > 0 ? 'importing' : 'idle'} />
        <StatTile label="IMPORTED TODAY" value={a.gridFromToday} unit=" kWh" accent={CC.grid} sub={<>lifetime <b>{a.gridFromTotal.toLocaleString()} kWh</b></>} />
        <StatTile label="SELF-SUFFICIENCY" value={selfSuff} unit="%" accent={CC.soc} bar={selfSuff} sub="of load met without the grid" />
      </div>
      <div className="duo">
        <Card>
          <SectionTitle>GRID QUALITY</SectionTitle>
          <div className="mp-grid">
            <Metric label="Frequency" value={a.gridFreq.toFixed(2)} unit=" Hz" />
            <Metric label="Power factor" value={a.gridPf.toFixed(2)} />
            <Metric label="Voltage L1" value={snap.inverters[0].phases[0].volt.toFixed(1)} unit=" V" />
            <Metric label="Status" value={a.gridPower > 0 ? 'importing' : 'grid-tied'} />
          </div>
        </Card>
        <Card accent={CC.batt}>
            <SectionTitle right={<span className="dim">{window.TARIFF_PRESETS[settings.tariff.preset].label}</span>}>COST & SAVINGS · TODAY</SectionTitle>
            <div className="savings-row">
              <div><div className="tp-label">Would've paid</div><div className="tp-val mono" style={{ color: CC.grid }}>{fmtRand(wouldPay)}</div></div>
              <div><div className="tp-label">Grid cost</div><div className="tp-val mono" style={{ color: CC.load }}>{fmtRand(cost)}</div></div>
              <div><div className="tp-label">Saved</div><div className="tp-val mono" style={{ color: CC.batt }}>{fmtRand(saved)}</div></div>
            </div>
          <div className="hint-line">All {fmtKwh(a.loadToday)} you used today @ {fmtRand(rate)}/kWh would've cost <b>{fmtRand(wouldPay)}</b>; you only bought {fmtKwh(a.gridFromToday)} from the grid, so you saved the difference. (Battery charged from the grid nets out, since it shows as import.) Edit the rate in Settings.</div>
        </Card>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- INVERTERS
function InvertersTab({ snap }) {
  return (
    <div className="stack">
      <SectionTitle right={<span className="dim">{snap.inverters.length} units · {snap.plant.name}</span>}>INVERTERS</SectionTitle>
      <div className="duo">
        {snap.inverters.map(inv => {
          const t = cleanTemp(inv.battTemp);
          return (
            <Card key={inv.sn} className="inv-card">
              <div className="inv-head">
                <div>
                  <div className="inv-sn">{inv.sn}</div>
                  <div className="inv-meta mono dim">{inv.model} · fw {inv.soft} · {inv.commissioned}</div>
                </div>
                <Badge tone={inv.status === 'online' ? 'ok' : 'warn'} dot>{inv.status}</Badge>
              </div>
              <div className="inv-grid">
                <Metric label="Solar" value={fmtPower(inv.pvNow)} accent={CC.pv} />
                <Metric label="Output" value={fmtPower(inv.output)} />
                <Metric label="Battery" value={fmtPower(inv.battPower)} accent={CC.batt} />
                <Metric label="Charge" value={inv.battSoc} unit="%" accent={CC.batt} />
                <Metric label="Grid" value={fmtPower(inv.grid)} accent={CC.grid} />
                <Metric label="Home" value={fmtPower(inv.load)} accent={CC.load} />
                <Metric label="Batt temp" value={t != null ? inv.battTemp.toFixed(1) : 'bad sensor'} unit={t != null ? ' °C' : ''} accent={t == null ? CC.load : null} />
                <Metric label="Today PV" value={fmtKwh(inv.pvToday)} accent={CC.pv} />
              </div>
              {t == null && <div className="inv-warn">⚠ Battery temp sensor reading invalid (≤ −50 °C) — filtered.</div>}
            </Card>
          );
        })}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- SETTINGS
// The signed-in user's SunSynk link: what's connected, since when, and the one
// revocation they have. Disconnect wipes the stored token; history stays. A reload
// afterwards lands on the Connect screen, because there's no active link left.
function SunSynkConnectionCard() {
  const { useState } = React;
  const { loading, accounts } = window.useLinkStatus(0);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const acc = accounts.find(a => a.status !== 'disabled');
  const fmt = (iso) => iso ? new Date(iso).toLocaleString('en-ZA', { dateStyle: 'medium', timeStyle: 'short' }) : '—';
  const disconnect = async () => {
    if (!acc) return;
    if (!confirm(`Disconnect ${acc.sunsynk_username}? Logging for its plants stops until you connect again. Your history is kept.`)) return;
    setBusy(true); setErr(null);
    try { await window.disconnectSunsynk(acc.account_id); location.reload(); }
    catch (e) { setErr(e.message); setBusy(false); }
  };
  return (
    <Card>
      <SectionTitle>SUNSYNK CONNECTION</SectionTitle>
      {loading ? <div className="field-note">Loading…</div> : !acc ? (
        <div className="field-note">No SunSynk account connected.</div>
      ) : (
        <>
          <div className="field">
            <label>Account</label>
            <div className="input mono" style={{ opacity: 0.85 }}>{acc.sunsynk_username}</div>
          </div>
          <div className="field" style={{ marginTop: 12 }}>
            <label>Status</label>
            <div className="input mono" style={{ color: acc.status === 'active' ? 'var(--good, #7ee2a0)' : 'var(--warn, #f0b35a)' }}>
              {acc.status === 'active' ? 'Connected' : 'Needs reconnecting'}
              {acc.status === 'active' && acc.last_ok_at ? ` · last read ${fmt(acc.last_ok_at)}` : ''}
            </div>
          </div>
          <div className="field-note">
            Connected {fmt(acc.linked_at)} · {(acc.plants || []).map(p => p.plant_name || p.plant_id).join(', ') || 'no plants visible'}
          </div>
          <div className="field-note" style={{ marginTop: 10 }}>
            Your SunSynk password was exchanged for a token and never stored. Disconnecting deletes that token.
          </div>
          <button type="button" className="ghost-btn" onClick={disconnect} disabled={busy}
                  style={{ marginTop: 12, borderColor: 'var(--bad, #e06c75)', color: 'var(--bad, #e06c75)' }}>
            {busy ? 'Disconnecting…' : 'Disconnect SunSynk'}
          </button>
          {err && <div className="field-note" style={{ color: 'var(--bad, #e06c75)' }}>{err}</div>}
        </>
      )}
    </Card>
  );
}

function SettingsTab({ settings, setSettings, config }) {
  const set = (patch) => setSettings(s => ({ ...s, ...patch }));
  // Read-only: app_config is authoritative, because the phone alerts read the same
  // rows. A second editable copy here is exactly how the two used to drift.
  const cap = config?.battCapacity, reserve = config?.reserve;
  // Settings only, and nothing but the number — no rule above it, no card around it.
  const version = <div className="app-version mono">{window.APP_VERSION}</div>;
  const setTariff = (patch) => setSettings(s => ({ ...s, tariff: { ...s.tariff, ...patch } }));
  const presets = window.TARIFF_PRESETS;
  const applyPreset = (key) => {
    const p = presets[key];
    setTariff({ preset: key, import: p.import });
  };
  return (
    <>
    <div className="settings-grid">
      <Card>
        <SectionTitle>TARIFF · SOUTH AFRICA</SectionTitle>
        <div className="field">
          <label>Tariff preset</label>
          <select className="select" value={settings.tariff.preset} onChange={e => applyPreset(e.target.value)}>
            {Object.entries(presets).map(([k, p]) => <option key={k} value={k}>{p.label}</option>)}
          </select>
          <div className="field-note">{presets[settings.tariff.preset].note}</div>
        </div>
        <div className="field">
          <label>Import rate (R/kWh)</label>
          <input className="input mono" type="number" step="0.01" value={settings.tariff.import}
            onChange={e => setTariff({ import: +e.target.value, preset: 'custom' })} />
        </div>
        <div className="field-note">Tip: your exact rate is on your latest municipal bill or prepaid token receipt. Most municipalities also publish a “tariff booklet 2025/26”.</div>
      </Card>

      <Card>
        <SectionTitle>DISPLAY</SectionTitle>
        <div className="field">
          <label>Battery sign convention</label>
          <Segmented options={[{ value: 'discharge', label: 'Positive = discharging' }, { value: 'charge', label: 'Positive = charging' }]}
            value={settings.battPositive} onChange={v => set({ battPositive: v })} />
        </div>
        <div className="field" style={{ marginTop: 16 }}>
          <label>Battery capacity (kWh)</label>
          <div className="input mono" style={{ opacity: 0.75 }}>{cap ?? '—'}</div>
          <div className="field-note">Total pack energy across all banks — e.g. 5 batteries × 5.3 kWh = 26.5 kWh. Runtime &amp; cycle estimates use it. Set in the database (<span className="mono">app_config.BATTERY_KWH</span>), which the phone alerts read too.</div>
        </div>
        <div className="field" style={{ marginTop: 16 }}>
          <label>Battery stopping reserve — <span className="mono" style={{ color: 'var(--soc)' }}>{reserve ?? '—'}%</span></label>
          <input className="range" type="range" min="5" max="50" step="1" value={reserve ?? 20} readOnly disabled />
          <div className="field-note">The SOC your system stops discharging at. Runtime estimates and the battery reserve marker use it. Set in the database (<span className="mono">app_config.BATTERY_RESERVE_PCT</span>), which the phone alerts read too.</div>
        </div>
      </Card>

      <SunSynkConnectionCard />

      <Card>
        <SectionTitle>TABS</SectionTitle>
        <div className="field-note" style={{ marginTop: 0, marginBottom: 10 }}>Show the extra tabs you want. Live, History, Trends &amp; Settings always stay.</div>
        {[['solar', 'Solar (PV strings)'], ['battery', 'Battery'], ['grid', 'Grid & savings'], ['inverters', 'Inverters']].map(([k, l]) => (
          <Toggle key={k} label={l} checked={settings.tabs[k]} onChange={v => set({ tabs: { ...settings.tabs, [k]: v } })} />
        ))}
      </Card>
    </div>
    {version}
    </>
  );
}

Object.assign(window, { LiveTab, SolarTab, BatteryTab, GridTab, InvertersTab, SettingsTab });
