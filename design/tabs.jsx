// ============================================================================
// tabs.jsx — the individual views. Live / Solar / Battery / Grid / Inverters / Settings
// (History lives in chart.jsx as <HistoryView/>)
// ============================================================================
const { Card, StatTile, Metric, Badge, Segmented, Toggle, SectionTitle, Sparkline,
  fmtPower, fmtPowerParts, fmtKwh, fmtRand, cleanTemp, COLORS: CC } = window;

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

// ---------------------------------------------------------------- LIVE
function LiveTab({ snap, settings }) {
  const a = snap.aggregate;
  const [bv, bu] = fmtPowerParts(a.battPower);
  const [gv, gu] = fmtPowerParts(Math.abs(a.gridPower));
  const [lv, lu] = fmtPowerParts(a.loadNow);
  const [sv, su] = fmtPowerParts(a.pvNow);
  // ---- battery runtime estimate (at current draw, down to user-set reserve) ----
  const RESERVE = settings.reserve ?? 20;
  const availKwh = Math.max(0, (a.battSoc - RESERVE) / 100 * window.BATT_CAPACITY_KWH);
  const headroomKwh = Math.max(0, (100 - a.battSoc) / 100 * window.BATT_CAPACITY_KWH);
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

  // ---- period overview: Today / Week / Month / Year / Lifetime ----
  const [period, setPeriod] = React.useState('today');
  const heavy = React.useMemo(() => {
    if (period === 'week' || period === 'month' || period === 'year') {
      const n = period === 'week' ? 7 : period === 'month' ? 30 : 365;
      const days = window.simulateDays(n, new Date(2026, 4, 29));
      return days.reduce((o, d) => ({ pv: o.pv + d.pv, load: o.load + d.load, imp: o.imp + d.imp, chg: o.chg + d.chg, dischg: o.dischg + d.dischg }), { pv: 0, load: 0, imp: 0, chg: 0, dischg: 0 });
    }
    return null;
  }, [period]);
  const rate = settings.tariff.import;
  let pPv, pLoad, pImp, pChg, pDischg;
  if (period === 'today') { pPv = a.pvToday; pLoad = a.loadToday; pImp = a.gridFromToday; pChg = a.battChgToday; pDischg = a.battDischgToday; }
  else if (period === 'lifetime') { pPv = a.pvTotal; pLoad = a.loadTotal; pImp = a.gridFromTotal; pChg = a.battChgTotal; pDischg = a.battDischgTotal; }
  else { pPv = heavy.pv; pLoad = heavy.load; pImp = heavy.imp; pChg = heavy.chg; pDischg = heavy.dischg; }
  const pSuff = pLoad > 0 ? Math.min(100, Math.round(((pLoad - pImp) / pLoad) * 100)) : 0;
  const pSaved = Math.max(0, pLoad - pImp) * rate;
  const periodWord = { today: 'today', week: 'past 7 days', month: 'past 30 days', year: 'past year', lifetime: 'all-time' }[period];

  return (
    <div className="live-grid">
      <Card className="flow-card">
        <SectionTitle>POWER FLOW</SectionTitle>
        <window.PowerFlow agg={a} inverters={snap.inverters.filter(i => i.status === 'online').length} battInfo={battInfo} />
      </Card>

      <Card className="chart-card">
        <window.HistoryView tariff={settings.tariff} showSavings={settings.showSavings} />
      </Card>

      <div className="overview-section">
        <div className="overview-head">
          <SectionTitle>OVERVIEW · <span style={{ color: 'var(--text)' }}>{periodWord}</span></SectionTitle>
          <Segmented size="sm"
            options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]}
            value={period} onChange={setPeriod} />
        </div>
        <div className="today-strip">
          <MiniStat label="Generated" value={window.fmtEnergySmart(pPv)} color={CC.pv}
            info="Total solar energy your panels produced over the selected period." />
          <MiniStat label="Consumed" value={window.fmtEnergySmart(pLoad)} color={CC.load}
            info="Total energy your home used over the selected period, summed across all inverters." />
          <MiniStat label="Self-sufficiency" value={pSuff + '%'} color={CC.soc} bar={pSuff}
            info="Share of your home’s energy that came from your own solar + battery rather than the grid. 100% = fully off-grid for the period." />
          <MiniStat label="Imported" value={window.fmtEnergySmart(pImp)} color={CC.grid}
            info="Energy drawn from the grid over the selected period." />
          {settings.showSavings && <MiniStat label="Est. saved" value={window.fmtRandSmart(pSaved)} color={CC.batt}
            info="Rough money saved = the grid energy you avoided buying (your consumption not supplied by the grid) valued at your import rate. Set the rate in Settings." />}
        </div>
      </div>
    </div>
  );
}
function MiniStat({ label, value, color, sub, bar, info }) {
  return (
    <Card className="mini-stat">
      <div className="mini-label">{label}{info && <window.InfoDot text={info} />}</div>
      <div className="mini-value mono" style={{ color }}>{value}</div>
      {bar != null && <div className="meter sm"><div className="meter-fill" style={{ width: bar + '%', background: color }} /></div>}
      {sub && <div className="mini-sub mono">{sub}</div>}
    </Card>
  );
}

// ---------------------------------------------------------------- SOLAR
function SolarTab({ snap }) {
  const a = snap.aggregate;
  const gen = React.useMemo(() => {
    const sum = n => window.simulateDays(n, new Date(2026, 4, 29)).reduce((s, d) => s + d.pv, 0);
    return { week: sum(7), month: sum(30), year: sum(365) };
  }, []);
  const EP = window.fmtEnergyParts;
  const card = (label, k) => { const [v, u] = EP(k); return <StatTile label={label} value={v} unit={' ' + u} accent={CC.pv} />; };
  return (
    <div className="stack">
      <div className="solar-stats">
        <StatTile label="SOLAR NOW" value={fmtPowerParts(a.pvNow)[0]} unit={' ' + fmtPowerParts(a.pvNow)[1]} accent={CC.pv} />
        {card('TODAY', a.pvToday)}
        {card('THIS WEEK', gen.week)}
        {card('THIS MONTH', gen.month)}
        {card('THIS YEAR', gen.year)}
        {card('LIFETIME', a.pvTotal)}
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
        <div className="hint-line">String 1 on {snap.inverters[0].alias} reads ~1&nbsp;V / 0&nbsp;W — normal at night, but worth a look if it persists at midday (shading, tripped breaker, or a failed string).</div>
      </Card>
    </div>
  );
}

// ---------------------------------------------------------------- BATTERY
function BatteryTab({ snap, settings }) {
  const a = snap.aggregate;
  const reserve = settings.reserve ?? 20;
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
            <div><div className="tp-label">Capacity</div><div className="tp-val mono">{window.BATT_CAPACITY_KWH.toFixed(1)} kWh</div></div>
            <div><div className="tp-label">Est. cycles today</div><div className="tp-val mono">{(a.battDischgToday / window.BATT_CAPACITY_KWH).toFixed(2)}</div></div>
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
          <div className="hint-line">The bar is your battery’s charge level; the tick marks the <b>{reserve}%</b> reserve floor where discharge stops (~{(Math.max(0, (a.battSoc - reserve) / 100 * window.BATT_CAPACITY_KWH)).toFixed(1)} kWh usable above it). Sign convention: <b>{settings.battPositive === 'charge' ? 'positive = charging' : 'negative current = charging'}</b> (set in Settings).</div>
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
  const selfSuff = Math.min(100, Math.round(((a.loadToday - a.gridFromToday) / a.loadToday) * 100));
  const cost = a.gridFromToday * settings.tariff.import;
  const saved = Math.max(0, a.loadToday - a.gridFromToday) * settings.tariff.import;
  const reliance = Math.round((a.gridFromToday / a.loadToday) * 100);
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
            <Metric label="Status" value="grid-tied" />
          </div>
        </Card>
        {settings.showSavings && (
          <Card accent={CC.batt}>
            <SectionTitle right={<span className="dim">{window.TARIFF_PRESETS[settings.tariff.preset].label}</span>}>COST & SAVINGS · TODAY</SectionTitle>
            <div className="savings-row">
              <div><div className="tp-label">Est. saved</div><div className="tp-val mono" style={{ color: CC.batt }}>{fmtRand(saved)}</div></div>
              <div><div className="tp-label">Grid cost</div><div className="tp-val mono" style={{ color: CC.load }}>{fmtRand(cost)}</div></div>
              <div><div className="tp-label">Grid reliance</div><div className="tp-val mono" style={{ color: CC.grid }}>{reliance}%</div></div>
            </div>
            <div className="hint-line">Saved = grid energy you avoided buying, valued @ {fmtRand(settings.tariff.import)}/kWh. Edit the rate in Settings.</div>
          </Card>
        )}
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
              {t == null && <div className="inv-warn">⚠ Battery temp sensor reading −100 °C — filtered as invalid.</div>}
            </Card>
          );
        })}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- SETTINGS
function SettingsTab({ settings, setSettings }) {
  const set = (patch) => setSettings(s => ({ ...s, ...patch }));
  const setTariff = (patch) => setSettings(s => ({ ...s, tariff: { ...s.tariff, ...patch } }));
  const presets = window.TARIFF_PRESETS;
  const applyPreset = (key) => {
    const p = presets[key];
    setTariff({ preset: key, import: p.import });
  };
  return (
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
        <Toggle label="Cost & savings layer" hint="Show Rand values across the dashboard" checked={settings.showSavings} onChange={v => set({ showSavings: v })} />
        <Toggle label="Filter bad sensor values" hint="Hide impossible readings (e.g. −100 °C battery temp)" checked={settings.filterBadSensors} onChange={v => set({ filterBadSensors: v })} />
        <div className="field" style={{ marginTop: 14 }}>
          <label>Battery sign convention</label>
          <Segmented options={[{ value: 'discharge', label: 'Positive = discharging' }, { value: 'charge', label: 'Positive = charging' }]}
            value={settings.battPositive} onChange={v => set({ battPositive: v })} />
        </div>
        <div className="field" style={{ marginTop: 16 }}>
          <label>Battery stopping reserve — <span className="mono" style={{ color: 'var(--soc)' }}>{settings.reserve}%</span></label>
          <input className="range" type="range" min="5" max="50" step="1" value={settings.reserve}
            onChange={e => set({ reserve: +e.target.value })} />
          <div className="field-note">The SOC your system stops discharging at. Runtime estimates and the battery reserve marker use this.</div>
        </div>
      </Card>

      <Card>
        <SectionTitle>TABS</SectionTitle>
        <div className="field-note" style={{ marginTop: 0, marginBottom: 10 }}>Hide tabs you don’t use. Live, History &amp; Settings always stay.</div>
        {[['solar', 'Solar (PV strings)'], ['battery', 'Battery'], ['grid', 'Grid & savings'], ['inverters', 'Inverters']].map(([k, l]) => (
          <Toggle key={k} label={l} checked={settings.tabs[k]} onChange={v => set({ tabs: { ...settings.tabs, [k]: v } })} />
        ))}
      </Card>
    </div>
  );
}

Object.assign(window, { LiveTab, SolarTab, BatteryTab, GridTab, InvertersTab, SettingsTab });
