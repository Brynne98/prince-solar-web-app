// ============================================================================
// tabs.jsx — the individual views. Live / Solar / Battery / Grid / Inverters / Settings
// (History lives in chart.jsx as <HistoryView/>)
// Week/Month/Year aggregates come from the live `energy` cache owned by <App>;
// `onNeedEnergy(period)` asks App to lazily fetch a period it hasn't loaded yet.
// ============================================================================
const { Card, StatTile, Metric, Badge, Segmented, Toggle, SectionTitle, Sparkline,
  fmtPower, fmtPowerParts, battShown, fmtKwh, fmtRand, cleanTemp, COLORS: CC } = window;

const FsEnterIcon = () => <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M2 6V2h4M14 6V2h-4M2 10v4h4M14 10v4h-4" /></svg>;
const TrashIcon = () => <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M2.5 4.5h11M6.5 4.5v-2h3v2M4 4.5l.6 9h6.8l.6-9M6.75 7v4M9.25 7v4" /></svg>;
const FsExitIcon = () => <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M6 2v4H2M10 2v4h4M6 14v-4H2M10 14v-4h4" /></svg>;

// Battery-balance banner — watches the SOC/voltage spread between the two inverter
// banks (the desync signal) while the charge current is being pushed up. Its data is
// fetched by App. Subtle when Balanced, loud when Drifting.
// The banner's own frame with shimmering values, so it lands at its height. Also drawn by
// App's loading shell, so the row is there from the first paint rather than after the
// snapshot. Each value keeps a space of text in the mono face, so the line is as tall as a
// real one; top-aligned, because a clipped inline block otherwise sits on the baseline and adds 4px.
function BalanceSkeleton() {
  const bar = (w) => <b className="mono skel" style={{ display: 'inline-block', verticalAlign: 'top', width: w, borderRadius: 5 }}>{' '}</b>;
  return (
    <div className="batt-balance" role="status" aria-busy="true" aria-label="Loading battery balance">
      <span className="bb-dot skel" aria-hidden="true" />
      <span className="bb-title" aria-hidden="true">Battery</span>
      <span className="bb-status" aria-hidden="true">{bar(70)}</span>
      <span className="bb-div" />
      <div className="bb-stats" aria-hidden="true">
        <span className="bb-stat"><span className="bb-k">Charge</span>{bar(64)}</span>
        <span className="bb-stat"><span className="bb-k">Temp</span>{bar(30)}</span>
        <span className="bb-stat"><span className="bb-k">Full today</span>{bar(34)}</span>
      </div>
    </div>
  );
}

// b comes from App (fetched with the snapshot, refreshed every 5 min): undefined = loading.
function BatteryBalanceBanner({ b }) {
  if (b === undefined) return <BalanceSkeleton />;
  if (!b || b.status === 'unknown') return null;
  const COL = { balanced: '#3ddc84', watch: '#f59e0b', drifting: '#f87171' };
  const c = COL[b.status] || '#7c8794';
  // 'single' is one bank with nothing to compare against: still worth the charge and
  // temperature stats, but the status word must say so rather than render blank.
  const label = { balanced: 'Balanced', watch: 'Watch', drifting: 'Drifting', single: 'One pack' }[b.status] || 'Unknown';
  // Status carries the desync detail (spread / voltage / 3-day peak) in its tooltip,
  // so the banner itself stays to a status + three clean stats.
  const statusTip = b.status === 'single'
    ? 'One battery pack, so there is nothing to drift apart'
    : b.stale
    ? 'No recent paired reading from both packs'
    : `Packs ${b.socSpread ?? 0}% / ${b.vSpread ?? 0} V apart`
      + (b.max72h != null ? ` · peak ${b.max72h}% over 3 days` : '')
      + (b.pending ? ' · elevated now — flags only if it holds 10 min' : '');
  return (
    <div className={'batt-balance ' + b.status}>
      <span className="bb-dot" style={{ background: c }} />
      <span className="bb-title">Battery</span>
      <span className="bb-status" style={{ color: c }} title={statusTip}>
        {label}{b.status === 'drifting' ? ' ⚠' : b.status === 'watch' ? ' !' : b.status === 'balanced' ? ' ✓' : ''}
      </span>
      <span className="bb-div" />
      <div className="bb-stats">
        <span className="bb-stat" title={statusTip}>
          <span className="bb-k">Charge</span><b className="mono">{(b.banks || []).map((x) => x.soc).join(' / ')}%</b>
        </span>
        {b.tempC != null && (
          <span className={'bb-stat' + (b.tempHot ? ' bb-hot' : '')} title="Battery temperature. It lasts longest below ~25°C; heat above ~35°C shortens its life.">
            <span className="bb-k">Temp</span><b className="mono">{b.tempC}°{b.tempHot ? ' ⚠' : ''}</b>
          </span>
        )}
        {b.hrsAtFullToday != null && (
          <span className="bb-stat" title="Hours at 98% charge or more today. A short spell is healthy and keeps the battery's charge reading accurate; long spells in summer heat are what to avoid.">
            <span className="bb-k">Full today</span><b className="mono">{b.hrsAtFullToday}h</b>
          </span>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- LIVE
// ---- loading skeletons ------------------------------------------------------
// Each tab's shape while the first snapshot is still on its way. They sit beside the tab
// they stand in for, so a card added to one is a card missing from the other in plain
// sight. Static chrome — titles, labels, the day picker — draws for real; only values and
// plot areas shimmer. Nothing here fetches: these also draw App's boot shell, which runs
// before the session has been checked.

// The plot area a skeleton cannot draw: the day picker renders for real but locked, the
// legend gets an inert row of its own height, and the chart is a block at the height
// useChartSize gives the real one.
function DayChartSkeleton({ legend }) {
  const pick = useDayPicker(null);
  return (
    <>
      <DateBar pick={pick} earliest={null} locked />
      {legend && <div className="legend-row" style={{ height: 31 }} aria-hidden="true" />}
      <window.Skeleton className="chart-skel" h="auto" r={12} />
    </>
  );
}

// A tile's second line, held open while the words for it are still coming: a plain space
// collapses to a zero-height line box, and the tile lands 17px short of the real one.
const NBSP = '\u00a0';

// A readout whose number hasn't arrived. The label is static and draws for real.
function skelVal(w) {
  return <window.Skeleton w={w} h={19} r={5} style={{ display: 'inline-block', verticalAlign: 'top', marginTop: 3 }} />;
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
          <MiniStat loading label="Generated" />
          <MiniStat loading label="Home" />
          <MiniStat loading label="Self-sufficiency" bar={0} />
          <MiniStat loading label="Imported" sub={' '} />
          <MiniStat loading label="Est. saved" sub={' '} />
        </div>
      </div>
      {/* A battery is assumed until the snapshot says otherwise, as LiveTab does */}
      <BalanceSkeleton />
      <div className="card flow-card">
        <SectionTitle right={<button className="flow-fs-btn" disabled><FsEnterIcon /><span>Fullscreen</span></button>}>POWER FLOW</SectionTitle>
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

function LiveTab({ snap, settings, today, energy, onNeedEnergy, refreshKey, balance, onOpenSettings }) {
  const a = snap.aggregate;
  const feat = snap.features || {};
  const hasBatt = feat.hasBattery !== false;
  const hasGrid = feat.hasGrid !== false;
  const tz = snap.config?.timezone;
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
  const hourNow = window.plantHour(tz, snap.updated instanceof Date ? snap.updated : new Date());
  const typicalRow = (hourly && hourly.hours || []).find((h) => Number(h.hour) === hourNow);
  const typicalSoc = typicalRow && typicalRow.soc != null && Number.isFinite(Number(typicalRow.soc))
    ? Math.round(Number(typicalRow.soc)) : null;
  const typicalHour = typicalSoc != null ? hourNow : null;
  // ---- battery runtime estimate (at current draw, down to the configured reserve) ----
  // Pack figures come from app_config via the snapshot, so these agree with the
  // phone alerts by construction. The literals are only a pre-first-fetch fallback.
  const RESERVE = snap.config?.reserve ?? 20;
  // null until the owner sets the pack size in Settings; no guessing another plant's pack
  const cap = snap.config?.battCapacity ?? null;
  const availKwh = cap ? Math.max(0, (a.battSoc - RESERVE) / 100 * cap) : null;
  const headroomKwh = cap ? Math.max(0, (100 - a.battSoc) / 100 * cap) : null;
  const fmtDur = (hrs) => { let h = Math.floor(hrs), m = Math.round((hrs - h) * 60); if (m === 60) { h++; m = 0; } return (h > 0 ? h + 'h ' : '') + String(m).padStart(h > 0 ? 2 : 1, '0') + 'm'; };
  const fmtEta = (hrs) => {
    const d = new Date(snap.updated.getTime() + hrs * 3600000);
    return window.fmtPlantTime(d, tz) + ', ' + d.toLocaleDateString('en', { weekday: 'short', day: 'numeric', month: 'short', timeZone: tz || undefined });
  };
  let battEta = null, battInfo = null;
  if (!hasBatt) { /* nothing to estimate */ }
  else if (!cap) { battInfo = 'Set pack size'; } // a link on the flow's battery node
  else if (a.battState === 'discharging' && a.battPower > 50) {
    const hrs = availKwh / (a.battPower / 1000);
    battEta = <span className="batt-eta"><span className="bel">≈ <b>{fmtDur(hrs)}</b> until {RESERVE}% reserve</span><span className="bel sub">~{fmtEta(hrs)}</span></span>;
    battInfo = `${fmtDur(hrs)} to empty`;
  } else if (a.battState === 'charging' && a.battPower > 50) {
    const hrs = headroomKwh / (a.battPower / 1000);
    battEta = <span className="batt-eta"><span className="bel">≈ <b>{fmtDur(hrs)}</b> to full</span><span className="bel sub">~{fmtEta(hrs)}</span></span>;
    battInfo = `${fmtDur(hrs)} to full`;
  }

  // ---- power-flow fullscreen (wall-dashboard mode) ----
  // Wall mode is a class on the wrapper, with the Fullscreen API asked for on top. An iPad
  // home-screen app has no such API and a browser may refuse; either way the wrapper
  // still covers the page, which on a chromeless screen is the same thing.
  const flowRef = React.useRef(null);
  const [wall, setWall] = React.useState(false);
  const [idle, setIdle] = React.useState(false);
  const idleRef = React.useRef(false);
  const revealedAt = React.useRef(0);
  const stacked = useFlowMobile();
  const fsEl = () => document.fullscreenElement || document.webkitFullscreenElement;
  // Remembered here, not in an effect on `wall`: that effect's first run would clear the
  // flag before the re-enter effect below could read it.
  const rememberWall = on => { try { on ? localStorage.setItem('synsynk.flowFs', '1') : localStorage.removeItem('synsynk.flowFs'); } catch (e) {} };
  const enterWall = () => {
    const el = flowRef.current; if (!el) return;
    setWall(true); rememberWall(true);
    const req = el.requestFullscreen || el.webkitRequestFullscreen;
    try { const p = req && req.call(el); if (p && p.catch) p.catch(() => {}); } catch (e) {}
  };
  const exitWall = () => {
    setWall(false); rememberWall(false);
    const exit = document.exitFullscreen || document.webkitExitFullscreen;
    try { const p = fsEl() && exit.call(document); if (p && p.catch) p.catch(() => {}); } catch (e) {}
  };
  // Esc in real fullscreen is handled by the browser; follow it out
  React.useEffect(() => {
    const onChange = () => { if (!fsEl()) { setWall(false); rememberWall(false); } };
    document.addEventListener('fullscreenchange', onChange);
    document.addEventListener('webkitfullscreenchange', onChange);
    return () => { document.removeEventListener('fullscreenchange', onChange); document.removeEventListener('webkitfullscreenchange', onChange); };
  }, []);
  // After 3 idle seconds the Exit button and cursor hide; a move, tap or key brings them back.
  // A tap that reveals Exit must not also press it: Safari fires its click after the reveal.
  React.useEffect(() => {
    if (!wall) return;
    let t;
    const wake = e => {
      if (idleRef.current && e && e.type === 'pointerdown') revealedAt.current = Date.now();
      idleRef.current = false; setIdle(false);
      clearTimeout(t); t = setTimeout(() => { idleRef.current = true; setIdle(true); }, 3000);
    };
    const onKey = e => { if (e.key === 'Escape') exitWall(); else wake(); };
    wake();
    window.addEventListener('mousemove', wake);
    window.addEventListener('pointerdown', wake);
    window.addEventListener('keydown', onKey);
    return () => {
      clearTimeout(t); idleRef.current = false; setIdle(false);
      window.removeEventListener('mousemove', wake); window.removeEventListener('pointerdown', wake); window.removeEventListener('keydown', onKey);
    };
  }, [wall]);
  // A wall tablet must not lock itself while showing the flow. The lock drops whenever the
  // page is hidden, so it is asked for again on return.
  React.useEffect(() => {
    if (!wall || !('wakeLock' in navigator)) return;
    let lock = null, pending = false, gone = false;
    const ask = () => {
      if (gone || pending || document.visibilityState !== 'visible' || (lock && !lock.released)) return;
      pending = true;
      navigator.wakeLock.request('screen').then(l => {
        pending = false;
        if (gone) { l.release().catch(() => {}); return; }
        // the system can drop it while the page is showing (low power); ask again
        lock = l; l.addEventListener('release', ask);
      }).catch(() => { pending = false; });
    };
    ask();
    document.addEventListener('visibilitychange', ask);
    return () => { gone = true; document.removeEventListener('visibilitychange', ask); if (lock) lock.release().catch(() => {}); };
  }, [wall]);
  // The stacked layout is HTML at phone sizes, so on a wall it is zoomed to fill the room
  // under the sentence. It is measured at zoom 1 and set back in the same task, so the
  // observer sees one settled size and cannot feed itself.
  React.useEffect(() => {
    const wrap = flowRef.current;
    if (!wall || !stacked || !wrap) return;
    const card = wrap.querySelector('.flow-card');
    const fit = () => {
      const m = wrap.querySelector('.mflow'), n = wrap.querySelector('.flow-narrative');
      if (!m || !n) return;
      wrap.style.setProperty('--wall-zoom', '1');
      const room = card.clientHeight - n.offsetHeight - parseFloat(getComputedStyle(n).marginBottom);
      if (!m.offsetWidth || !m.offsetHeight) return;
      const z = Math.min(card.clientWidth / m.offsetWidth, room / m.offsetHeight);
      if (z > 0) wrap.style.setProperty('--wall-zoom', z.toFixed(3));
    };
    const ro = new ResizeObserver(fit);
    [card, wrap.querySelector('.flow-narrative'), wrap.querySelector('.mflow')].forEach(el => el && ro.observe(el));
    return () => { ro.disconnect(); wrap.style.removeProperty('--wall-zoom'); };
  }, [wall, stacked]);
  // remember the dashboard: if we left in fullscreen, re-enter on the first interaction
  // (browsers require a user gesture, so we can't auto-enter on load alone)
  React.useEffect(() => {
    let armed = false;
    try { armed = localStorage.getItem('synsynk.flowFs') === '1'; } catch (e) {}
    if (!armed) return;
    const resume = () => { cleanup(); enterWall(); };
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
    return rows.reduce((o, d) => ({ pv: o.pv + (d.pv || 0), load: o.load + (d.load || 0), imp: o.imp + (d.imp || 0), exp: o.exp + (d.exp || 0), chg: o.chg + (d.chg || 0), dischg: o.dischg + (d.dischg || 0) }), { pv: 0, load: 0, imp: 0, exp: 0, chg: 0, dischg: 0 });
  }, [period, energy]);
  const rate = snap.config?.tariffImport ?? 0;
  const rateExp = snap.config?.tariffExport ?? 0;
  let pPv, pLoad, pImp, pExp;
  if (period === 'today') { pPv = a.pvToday; pLoad = a.loadToday; pImp = hasGrid ? a.gridFromToday : 0; pExp = hasGrid ? a.gridToToday : 0; }
  else if (heavy) { pPv = heavy.pv; pLoad = heavy.load; pImp = hasGrid ? heavy.imp : 0; pExp = hasGrid ? heavy.exp : 0; }
  else { pPv = pLoad = pImp = pExp = null; } // aggregate period still loading
  // clamp to 0–100: import can exceed load when the grid charges the battery,
  // which would otherwise drive this negative (and break the bar).
  const pSuff = (pLoad != null && pLoad > 0) ? Math.max(0, Math.min(100, Math.round(((pLoad - pImp) / pLoad) * 100))) : null;
  // avoided purchases at the import rate, plus anything sold at the feed-in rate
  const pSaved = (pLoad != null) ? Math.max(0, pLoad - pImp) * rate + (pExp || 0) * rateExp : null;
  // Show an Exported tile when this plant sells (a feed-in rate is set, or it has exported)
  // Only plants paid for export get an Exported tile. Every grid-tied inverter leaks a
  // few Wh of backflow, so a non-zero counter alone is not a sign the site sells.
  const showExport = hasGrid && rateExp > 0;
  const pending = isAgg && !energy[period];
  const periodWord = { today: 'today', week: 'this week', month: 'this month', year: 'this year', lifetime: 'all-time' }[period];
  // trend vs the same elapsed slice of the previous period. Suppress "today" until
  // midday — a partial morning vs a full yesterday reads as a misleading drop.
  const showCmp = period !== 'today' || window.plantHour(tz) >= 12;
  // "current" = the live value shown in the tile (pPv/pLoad/…) so the arrow stays
  // consistent with the number AND moves on every refresh; "previous" comes from
  // the compare endpoint (same elapsed slice of the prior period).
  // The compare endpoint pairs each day of the current slice with its counterpart
  // in the previous period and sums only the pairs where both days have a record
  // (0037). So for Week/Month/Year the current side must be that paired sum too,
  // not the live tile total, or a plant logging since mid-year would compare a
  // full slice against a few matched days. Today is a single pair, so the live
  // value is used there and the arrow keeps moving on every refresh.
  const MIN_DAYS = { today: 1, week: 2, month: 3, year: 3 };
  const cmpRow = (showCmp && cmp && cmp[period]) ? cmp[period] : null;
  const cmpDays = cmpRow ? (cmpRow.days || 0) : 0;
  const prev = (cmpRow && cmpDays >= (MIN_DAYS[period] || 1)) ? cmpRow.prev : null;
  const useLive = period === 'today';
  const cPv = useLive ? pPv : (cmpRow ? cmpRow.cur.pv : null);
  const cLoad = useLive ? pLoad : (cmpRow ? cmpRow.cur.load : null);
  const cImp = useLive ? pImp : (cmpRow ? cmpRow.cur.imp : null);
  const cSuff = useLive ? pSuff : ((cmpRow && cmpRow.cur.load > 0) ? Math.max(0, Math.min(100, ((cmpRow.cur.load - cmpRow.cur.imp) / cmpRow.cur.load) * 100)) : null);
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
  const tGen = prev ? pct(cPv, prev.pv) : null;
  const tCon = prev ? pct(cLoad, prev.load) : null;
  const tImp = prev ? pct(cImp, prev.imp) : null;
  // absolute kWh change, the hybrid fallback when a % would explode off a tiny baseline
  const dGen = prev ? (cPv - prev.pv) : null;
  const dCon = prev ? (cLoad - prev.load) : null;
  const dImp = prev ? (cImp - prev.imp) : null;
  const prevSuff = (prev && prev.load > 0) ? Math.max(0, Math.min(100, ((prev.load - prev.imp) / prev.load) * 100)) : null;
  const tSuff = (cSuff != null && prevSuff != null) ? (cSuff - prevSuff) : null;
  // "vs last year, 40 of 120 days compared" — say when the arrow rests on a subset
  const cmpBase = { today: 'vs yesterday', week: 'vs last week', month: 'vs last month', year: 'vs last year' }[period];
  const partial = !!(cmpBase && cmpRow && !useLive && prev && cmpDays < (cmpRow.span || 0));
  const cmpWord = partial ? cmpBase + ', ' + cmpDays + ' of ' + cmpRow.span + ' days compared' : cmpBase;
  // Est. saved trend: avoided import at today's rate, both sides from the paired
  // compare rows (they carry no export). A plant paid for export gets no arrow, since
  // the tile's figure includes feed-in and the arrow could not.
  const avoided = (load, imp) => Math.max(0, load - imp) * rate;
  const cSaved = useLive ? (pLoad != null ? avoided(pLoad, pImp) : null) : (cmpRow ? avoided(cmpRow.cur.load, cmpRow.cur.imp) : null);
  const prevSaved = prev ? avoided(prev.load, prev.imp) : null;
  const moneyTrend = rate > 0 && !(rateExp > 0);
  const tSaved = moneyTrend ? pct(cSaved, prevSaved) : null;
  const dSaved = (moneyTrend && prev && cSaved != null) ? cSaved - prevSaved : null;

  return (
    <div className="live-grid">
      {hasBatt && <BatteryBalanceBanner b={balance} />}
      <div className={'flow-fs-wrap' + (wall ? ' wall' : '') + (wall && idle ? ' idle' : '')} ref={flowRef}>
        {wall && (
          <div className="wall-bar">
            <window.WallStatus snap={snap} />
            <button className="flow-fs-btn wall-exit" title="Exit fullscreen (Esc)"
              onClick={() => { if (Date.now() - revealedAt.current > 400) exitWall(); }}>
              <FsExitIcon /><span>Exit</span>
            </button>
          </div>
        )}
        <Card className="flow-card">
          {!wall && <SectionTitle right={
            <button className="flow-fs-btn" onClick={enterWall}>
              <FsEnterIcon /><span>Fullscreen</span>
            </button>
          }>POWER FLOW</SectionTitle>}
          <window.PowerFlow agg={a} inverters={snap.inverters.filter(i => i.status === 'online').length} battInfo={battInfo} onBattInfo={hasBatt && !cap && !wall ? () => onOpenSettings('battery') : undefined} typicalSoc={typicalSoc} typicalHour={typicalHour} features={{ ...feat, sells: rateExp > 0 }} />
        </Card>
      </div>

      <Card className="chart-card">
        <window.HistoryView today={today} refreshKey={refreshKey} battPositive={settings.battPositive} />
      </Card>

      <div className="overview-section">
        <div className="overview-head">
          <SectionTitle>OVERVIEW · <span style={{ color: 'var(--text)' }}>{periodWord}</span></SectionTitle>
          <Segmented size="sm"
            options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]}
            value={period} onChange={setPeriod} />
        </div>
        {/* On a phone there is no hover, so a thin comparison base is said on screen. */}
        {partial && <div className="cmp-note">Arrows compare {cmpDays} of {cmpRow.span} days with the {cmpBase.replace('vs ', '')}. The rest have no record on one side.</div>}
        <div className="today-strip">
          <MiniStat loading={pending} label="Generated" value={window.fmtEnergySmart(pPv)} color={CC.pv} trend={tGen} trendDelta={dGen} trendTitle={cmpWord}
            info="Total solar energy your panels produced over the selected period." />
          <MiniStat loading={pending} label="Home" value={window.fmtEnergySmart(pLoad)} color={CC.load} trend={tCon} trendDelta={dCon} trendInvert trendTitle={cmpWord}
            info="Total energy your home used over the selected period, summed across all inverters." />
          <MiniStat loading={pending} label="Self-sufficiency" value={pSuff != null ? pSuff + '%' : '—'} color={CC.soc} bar={pSuff || 0} trend={tSuff} trendTitle={cmpWord}
            info="Share of your home’s energy that came from your own solar + battery rather than the grid. 100% = fully off-grid for the period." />
          {showExport && <MiniStat loading={pending} label="Exported" value={window.fmtEnergySmart(pExp)} color={CC.grid}
            info={'Energy sent to the grid over the selected period' + (rateExp > 0 ? ', paid at your feed-in rate.' : '.')} />}
          {hasGrid && <MiniStat loading={pending} label="Imported" value={window.fmtEnergySmart(pImp)} color={CC.grid} trend={tImp} trendDelta={dImp} trendInvert trendTitle={cmpWord}
            info="Energy drawn from the grid over the selected period."
            sub={a.gridPresent == null ? (
              // No inverter has reported mains voltage yet; a blank here read as a
              // chip that failed to load.
              <span className="grid-state unknown"><span className="gs-dot" />Grid unknown</span>
            ) : (
              // Presence, not usage: mains voltage is there even when you draw nothing
              // from it, so this stays ON through a sunny self-powered afternoon.
              <span className={'grid-state ' + (a.gridPresent ? 'on' : 'off')}
                    title={a.gridPresent
                      ? 'Mains voltage detected. This reads ON whenever the utility is live, even when you are drawing nothing from it.'
                      : 'No mains voltage on any inverter — the utility supply is down.'}>
                <span className="gs-dot" />{a.gridPresent ? (a.phaseDown ? 'Phase down' : 'Grid on') : 'Grid off'}
              </span>
            )} />}
          {!hasGrid && <MiniStat loading={pending} label="Grid" value="Off-grid" color={CC.grid}
            info="This plant has no grid connection. Everything the home uses comes from solar and the battery." />}
          <MiniStat loading={pending} label="Est. saved" color={CC.batt}
            value={(rate > 0 || rateExp > 0) ? window.fmtRandSmart(pSaved) : '—'}
            trend={tSaved} trendDelta={dSaved} trendDeltaFmt={window.fmtRandSmart} trendTitle={cmpWord}
            // no rate yet: the line under the dash opens Settings on Tariff
            sub={!(rate > 0 || rateExp > 0) ? <button type="button" className="mini-link" onClick={() => onOpenSettings('tariff')}>Set your rate</button> : undefined}
            info={'Rough money saved = the grid energy you avoided buying (your consumption not supplied by the grid) valued at your electricity rate' + (rateExp > 0 ? ', plus what you exported at your feed-in rate' : '') + '. Set your rate in Settings.'} />
        </div>
      </div>

    </div>
  );
}
function TrendBadge({ pct, unit = '%', invert, title, delta, deltaFmt }) {
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
    label = deltaFmt ? deltaFmt(d) : (d < 10 ? d.toFixed(1) : String(Math.round(d))) + ' kWh';
  } else {
    label = (mag < 1 ? mag.toFixed(1) : String(Math.round(mag))) + unit; // decimal under 1% so a tiny change isn't shown as "0%"
  }
  return <span className={'trend-badge ' + (good ? 'good' : 'bad')} title={title || 'vs previous period'}>{up ? '▲' : '▼'} {label}</span>;
}
function MiniStat({ label, value, color, sub, bar, info, trend, trendUnit, trendInvert, trendTitle, trendDelta, trendDeltaFmt, loading }) {
  return (
    <Card className="mini-stat">
      <div className="mini-label">{label}{info && <window.InfoDot text={info} />}</div>
      {/* a shimmer beats an em-dash: switching to Week/Month refetches, and "—" reads as
          "no data" rather than "fetching" */}
      {loading
        ? <div className="mini-value"><window.Skeleton w="70%" h={26} /></div>
        : <div className="mini-value mono" style={{ color }}><span className="mv-num">{value}</span><TrendBadge pct={trend} unit={trendUnit} invert={trendInvert} title={trendTitle} delta={trendDelta} deltaFmt={trendDeltaFmt} /></div>}
      {bar != null && !loading && <div className="meter sm"><div className="meter-fill" style={{ width: Math.max(0, Math.min(100, bar)) + '%', background: color }} /></div>}
      {bar != null && loading && <window.Skeleton h={5} r={4} style={{ marginTop: 8 }} />}
      {sub && <div className="mini-sub mono">{sub}</div>}
    </Card>
  );
}


// ---------------------------------------------------------------- SOLAR
// What the panels made (now, today, week, month, year, lifetime), a day's solar line
// with its peak, where that solar went, when the battery fills, the strings as they
// read now, and the last 30 days.

// YYYY-MM-DD at the plant, not on the viewer's device
function plantDateStr(tz, d = new Date()) {
  try { if (tz) return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d); } catch (e) {}
  return window.localDateStr(d);
}
const shortDate = (s, opts = { weekday: 'short', day: 'numeric', month: 'short' }) => {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString('en-GB', opts);
};

// Every total is the days before today plus today's live figure, and the current month is
// rebuilt from its days: the nightly sync (02:15 UTC) writes today's cached row, and the
// month holding it, at whatever today was then. Today's row is therefore still dropped here
// and replaced with the live figure. Yesterday used to read low for the same reason; since
// 0058 the server serves any day whose cached row is unfinished from agg_minute instead.
// A null in any row reads as NaN, which shows "—" rather than a confident smaller total.
// `key` is the row's field (pv, imp, dischg) and `now` today's live figure for it; the
// Solar, Grid and Battery tabs all total their subject this way.
function periodTotals(key, now, energy, today) {
  const sum = (rows) => rows.reduce((s, r) => s + (r[key] == null ? NaN : r[key]), 0);
  const days = (rows) => (rows ? sum(rows.filter(r => r.date < today)) + (now || 0) : null);
  // month rows carry no year; they come oldest first, so this month can only be the last
  const isThisMonth = (rows, r, i) => i === rows.length - 1 && r.date === today.slice(5, 7);
  const monthRow = (energy.year || []).find((r, i, rows) => isThisMonth(rows, r, i));
  const week = days(energy.week);
  // If this month's daily rows haven't synced yet (a fresh link, or a sync that ran out of
  // time), today alone would undercount it; the cached month total is closer.
  const haveDays = energy.month && energy.month.some(r => r.date < today);
  const month = energy.month == null ? null
    : !haveDays && monthRow ? Math.max(monthRow[key] || 0, now || 0) : days(energy.month);
  const withMonth = (rows) => (rows && month != null ? sum(rows.filter((r, i) => !isThisMonth(rows, r, i))) + month : null);
  return { week, month, year: withMonth(energy.year), lifetime: withMonth(energy.lifetime) };
}

// "since 25 May 2026" from the first lifetime month with solar. Rows are oldest first
// with no year, so walk back from this month and step a year whenever the month number
// does not fall. The day comes from the earliest daily row when it sits in that month
// (daily rows reach back six months; monthly ones to the start of the plant).
function lifetimeSince(rows, earliest, today) {
  if (!rows || !rows.length) return null;
  const years = new Array(rows.length);
  let y = Number(today.slice(0, 4));
  if (Number(rows[rows.length - 1].date) > Number(today.slice(5, 7))) y--;
  for (let i = rows.length - 1; i >= 0; i--) {
    if (i < rows.length - 1 && Number(rows[i].date) >= Number(rows[i + 1].date)) y--;
    years[i] = y;
  }
  const i = rows.findIndex(r => (r.pv || 0) > 0);
  if (i < 0) return null;
  const ym = years[i] + '-' + rows[i].date;
  return 'since ' + (earliest && earliest.startsWith(ym)
    ? shortDate(earliest, { day: 'numeric', month: 'short', year: 'numeric' })
    : shortDate(ym + '-01', { month: 'short', year: 'numeric' }));
}

// Where a day's solar went inside the house, from its 5-minute points: the house first,
// then the battery. What is left is export, backflow or rounding, and none of those are
// this tab's subject — the grid has its own tab.
function solarSplit(points) {
  let home = 0, batt = 0;
  const kwh = 5 / 60 / 1000;
  points.forEach(p => {
    if (p.pv == null || p.load == null) return;
    const pv = Math.max(0, p.pv), toHome = Math.min(pv, Math.max(0, p.load));
    const toBatt = Math.min(pv - toHome, p.batt != null && p.batt < 0 ? -p.batt : 0); // day series: − = charging
    home += toHome * kwh; batt += toBatt * kwh;
  });
  return { home, batt };
}

// One day of one reading as a line: solar (cropped to first light and the last reading),
// grid import, or the battery's charge on a fixed 0-100% scale with the reserve dashed.
// The reading under the pointer shows beside it.
function DayLineChart({ points, field, color, label, crop, pct, reserve, empty }) {
  const [ref, width, height] = useChartSize([220, 300]);
  const [hover, setHover] = React.useState(null);
  const mobile = width < 560;
  const v = i => points[i][field];
  const has = [];
  points.forEach((p, i) => { if (p[field] != null && (!crop || p[field] > 20)) has.push(i); });
  const hp = hover != null && points[hover] && v(hover) != null ? hover : null;
  let body = null, tip = null;
  if (has.length > 1) {
    const last = points.length - 1;
    // Solar is cropped to the lit hours; anything else keeps the whole day, since grid
    // and charge tell most of their story after dark.
    const i0 = crop ? Math.max(0, has[0] - 6) : 0;
    const i1 = crop ? Math.min(last, has[has.length - 1] + 6) : last;
    const m = { l: mobile ? 32 : 38, r: 12, t: 24, b: 30 };
    const innerW = Math.max(40, width - m.l - m.r), innerH = height - m.t - m.b;
    let peak = i0;
    for (let i = i0; i <= i1; i++) if ((v(i) || 0) > (v(peak) || 0)) peak = i;
    const { lo, hi, ticks } = pct ? { lo: 0, hi: 100, ticks: [0, 25, 50, 75, 100] } : niceScale(0, v(peak) || 0, 4);
    // the x axis is the clock: the lit hours for solar, the whole day otherwise, so today's
    // line stops at the last reading rather than stretching to fill the width
    const t0 = crop ? points[i0].t : 0, t1 = crop ? points[i1].t : 1435;
    const x = i => m.l + ((points[i].t - t0) / Math.max(5, t1 - t0)) * innerW;
    const y = val => m.t + innerH - ((val - lo) / (hi - lo)) * innerH;
    // runs of readings; a missing bucket breaks the line
    const runs = [];
    for (let i = i0; i <= i1; i++) {
      if (v(i) == null) { runs.push(null); continue; }
      if (!runs.length || runs[runs.length - 1] == null) runs.push([]);
      runs[runs.length - 1].push(i);
    }
    const P = i => x(i).toFixed(1) + ' ' + y(v(i)).toFixed(1);
    const base = y(0).toFixed(1);
    const line = runs.filter(Boolean).map(r => 'M' + r.map(P).join(' L')).join(' ');
    const area = runs.filter(Boolean).map(r => `M${x(r[0]).toFixed(1)} ${base} L` + r.map(P).join(' L') + ` L${x(r[r.length - 1]).toFixed(1)} ${base} Z`).join(' ');
    const step = mobile ? 360 : 180;
    const xt = [];
    for (let t = Math.ceil(t0 / step) * step; t <= t1; t += step) xt.push(t);
    const xt5 = t => m.l + ((t - t0) / Math.max(5, t1 - t0)) * innerW;
    const idxAt = (clientX, el) => {
      const mx = clientX - el.getBoundingClientRect().left;
      const t = t0 + ((mx - m.l) / innerW) * (t1 - t0);
      return Math.max(i0, Math.min(i1, Math.round((t - points[0].t) / 5)));
    };
    const fmt = val => (pct ? Math.round(val) + '%' : fmtPower(val));
    body = (
      <svg width={width} height={height} className="chart-svg" role="img" aria-label={label + ' over the day'} style={{ cursor: 'crosshair' }}
        onPointerMove={e => setHover(idxAt(e.clientX, e.currentTarget))}
        onPointerDown={e => setHover(idxAt(e.clientX, e.currentTarget))}
        onPointerLeave={() => setHover(null)}>
        {ticks.map((t, k) => (
          <g key={k}>
            <line x1={m.l} x2={m.l + innerW} y1={y(t)} y2={y(t)} stroke={t === 0 ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.05)'} />
            <text x={m.l - 8} y={y(t) + 3} textAnchor="end" className="ax">{pct ? t : +(t / 1000).toFixed(1)}</text>
          </g>
        ))}
        <text x={m.l - 8} y={m.t - 10} textAnchor="end" className="ax" fillOpacity="0.55">{pct ? '%' : 'kW'}</text>
        {xt.map(t => <text key={t} x={xt5(t)} y={m.t + innerH + 20} textAnchor="middle" className="ax">{HM(t)}</text>)}
        {reserve != null && (
          <g>
            <line x1={m.l} x2={m.l + innerW} y1={y(reserve)} y2={y(reserve)} stroke={color} strokeOpacity="0.55" strokeDasharray="4 4" />
            <text x={m.l + innerW - 4} y={y(reserve) - 6} textAnchor="end" className="ax">reserve {reserve}%</text>
          </g>
        )}
        <path d={area} fill={color} fillOpacity="0.14" />
        <path d={line} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" />
        {hp != null && (
          <g>
            <line x1={x(hp)} x2={x(hp)} y1={m.t} y2={m.t + innerH} stroke="rgba(255,255,255,0.25)" />
            <circle cx={x(hp)} cy={y(v(hp))} r="3" fill={color} stroke="#0b0e12" strokeWidth="1.5" />
          </g>
        )}
      </svg>
    );
    if (hp != null) {
      tip = (
        <div className="chart-tip" style={{ left: tipLeftFor(x(hp), width, 168), top: 12 }}>
          <div className="tip-time">{HM(points[hp].t)}</div>
          <div className="tip-row"><span className="tip-dot" style={{ background: color }} /><span className="tip-l">{label}</span><span className="tip-v mono">{fmt(v(hp))}</span></div>
        </div>
      );
    }
  }
  return (
    <div className="chart-area" ref={ref} style={{ position: 'relative', height }}>
      {body || <div className="solar-empty" style={{ height }}>{empty}</div>}
      {tip}
    </div>
  );
}

// One reading per day for the last 30 days (solar made, grid bought, battery gave out).
// The biggest finished day is solid; the bar under the pointer brightens and shows its date
// and total; clicking one opens that day in the chart above, whose day is outlined here.
// `rgb` is `color` as "r,g,b", for the lighter fills.
function DaysBars({ rows, field, color, rgb, word, label, today, selected, earliest, onPick }) {
  const [ref, width, height] = useChartSize([170, 220]);
  const [hover, setHover] = React.useState(null);
  const mobile = width < 560;
  const m = { l: 30, r: 4, t: 22, b: 24 };
  const innerW = Math.max(40, width - m.l - m.r), innerH = height - m.t - m.b;
  const { lo, hi, ticks } = niceScale(0, Math.max(10, ...rows.map(r => r[field] || 0)), 2);
  const y = v => m.t + innerH - ((v - lo) / (hi - lo)) * innerH;
  const slot = innerW / rows.length, bw = Math.max(3, slot * 0.66);
  const past = rows.filter(r => r.date !== today);
  const best = past.length ? past.reduce((b, r) => ((r[field] || 0) > (b[field] || 0) ? r : b)) : null;
  const firstOfMonth = rows.findIndex((r, i) => i > 2 && r.date.endsWith('-01'));
  const idxAt = (clientX, el) => Math.max(0, Math.min(rows.length - 1, Math.floor((clientX - el.getBoundingClientRect().left - m.l) / slot)));
  const can = (r) => !earliest || r.date >= earliest;
  const h = hover != null ? rows[hover] : null;
  const dateLabel = (r, opts) => shortDate(r.date, opts || { day: 'numeric', month: 'short' });
  const fill = (a) => 'rgba(' + rgb + ',' + a + ')';
  return (
    <div className="chart-area" ref={ref} style={{ position: 'relative', height }}>
      <svg width={width} height={height} className="chart-svg" role="img" aria-label={label}
        style={{ cursor: h && can(h) ? 'pointer' : 'default' }}
        onPointerMove={e => setHover(idxAt(e.clientX, e.currentTarget))}
        onPointerDown={e => setHover(idxAt(e.clientX, e.currentTarget))}
        onPointerLeave={() => setHover(null)}
        onClick={e => { const r = rows[idxAt(e.clientX, e.currentTarget)]; if (can(r)) onPick(r.date); }}>
        {ticks.map((v, k) => (
          <g key={k}>
            <line x1={m.l} x2={m.l + innerW} y1={y(v)} y2={y(v)} stroke={v === 0 ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.05)'} />
            <text x={m.l - 7} y={y(v) + 3} textAnchor="end" className="ax">{v}</text>
          </g>
        ))}
        <text x={m.l - 7} y={m.t - 10} textAnchor="end" className="ax" fillOpacity="0.55">kWh</text>
        {h && <rect x={m.l + slot * hover} y={m.t} width={slot} height={innerH} fill="rgba(255,255,255,0.04)" />}
        {rows.map((r, i) => {
          const cx = m.l + slot * i + slot / 2, top = y(r[field] || 0), isToday = r.date === today;
          return (
            <rect key={r.date} x={cx - bw / 2} y={top} width={bw} height={Math.max(0, y(0) - top)} rx={Math.min(2, bw / 2)}
              fill={isToday ? fill(0.16) : r === best ? color : hover === i ? fill(0.7) : fill(0.38)}
              stroke={r.date === selected ? 'var(--text)' : isToday ? color : 'none'} strokeWidth={r.date === selected ? 1.5 : 1}
              strokeDasharray={isToday && r.date !== selected ? '2 2' : undefined}
              style={{ transition: 'fill .12s' }} />
          );
        })}
        <text x={m.l + slot / 2} y={height - 6} textAnchor="start" className="ax">{dateLabel(rows[0])}</text>
        {firstOfMonth > 0 && firstOfMonth < rows.length - 4 && <text x={m.l + slot * firstOfMonth + slot / 2} y={height - 6} textAnchor="middle" className="ax">{dateLabel(rows[firstOfMonth])}</text>}
        <text x={m.l + innerW - slot / 2} y={height - 6} textAnchor="end" className="ax">{rows[rows.length - 1].date === today ? 'Today' : dateLabel(rows[rows.length - 1])}</text>
      </svg>
      {h && (
        <div className="chart-tip" style={{ left: tipLeftFor(m.l + slot * hover + slot / 2, width, 168), top: 8 }}>
          <div className="tip-time">{shortDate(h.date)}</div>
          <div className="tip-row"><span className="tip-dot" style={{ background: color }} /><span className="tip-l">{word}</span><span className="tip-v mono">{fmtKwh(h[field])}{h.date === today ? ' so far' : ''}</span></div>
          {can(h) && h.date !== selected && <div className="tip-hint">{mobile ? 'Tap' : 'Click'} to see this day</div>}
        </div>
      )}
    </div>
  );
}

// The day a tab's chart and cards are on. Today is the live series App already holds; a
// past day is fetched. While a newly picked day loads, the day already on screen stays,
// dimmed as Trends does, so its title and cards don't blank out and flash. `dim` goes on
// whatever shows that day.
function useShownDay(pick, today, refreshKey) {
  const [loaded, setLoaded] = React.useState(null); // { date, data }
  React.useEffect(() => {
    if (pick.isToday) return;
    let alive = true;
    window.fetchDay(pick.date)
      .then(r => { if (alive) setLoaded({ date: pick.date, data: r }); })
      .catch(() => { if (alive) setLoaded({ date: pick.date, data: { points: [], totals: {}, failed: true } }); });
    return () => { alive = false; };
  }, [pick.date, pick.isToday, refreshKey]);
  const shownRef = React.useRef(null);
  const ready = pick.isToday ? { isToday: true, date: pick.date, data: today }
    : loaded && loaded.date === pick.date ? { isToday: false, date: pick.date, data: loaded.data } : null;
  if (ready) shownRef.current = ready;
  const view = ready || shownRef.current || { isToday: pick.isToday, date: pick.date, data: null };
  const dim = { 'aria-busy': !ready, style: { opacity: ready ? 1 : 0.45, transition: 'opacity .15s' } };
  const day = view.data;
  return { view, dim, day, points: (day && day.points) || [], dayWord: view.isToday ? 'today' : shortDate(view.date) };
}

// A day with nothing to draw, in words, or null. `approx` means no 5-minute readings (before
// logging began, or the first half hour of a new plant), which is not a day with no sun.
function dayProblem(view, day, points) {
  if (!day) return null;
  if (day.failed) return 'Couldn’t load this day.';
  if (day.approx || !points.length) return view.isToday ? 'Collecting today’s first readings.' : 'No 5-minute readings for this day.';
  return null;
}

// The last 30 days of plant totals, for a tab's bars: null loading, false failed.
function useDaily(refreshKey) {
  const [daily, setDaily] = React.useState(null);
  const load = React.useCallback(() => {
    setDaily(null);
    window.fetchTrendDaily(30).then(setDaily).catch(() => setDaily(false));
  }, []);
  React.useEffect(load, [refreshKey]);
  return [daily, load];
}

// Scroll a tab's day card into view after a bar picked its day.
function scrollToDay(id) {
  const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const card = document.getElementById(id); // scroll-margin-top leaves the gap above it
  card && card.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' });
}

const titled = (title, word) => <>{title} · <span style={{ color: 'var(--text)' }}>{word}</span></>;

// A week or month tile's trend, with the Live overview's pairing: matched days before today,
// and at least `min` of them. Solar needs something last period to compare with. Grid import
// (invert: less is better) often really is zero, so a zero last period counts whenever that
// period logged anything at all; a rise from zero shows as kWh.
function periodTrend(cmp, k, key, min, word, invert) {
  const r = cmp && cmp[k];
  if (!r || (r.days || 0) < min || r.cur[key] == null || r.prev[key] == null) return null;
  const c = r.cur[key], p = r.prev[key];
  const logged = (r.prev.pv || 0) > 0 || (r.prev.load || 0) > 0;
  if (!(p > 0) && !(invert && logged)) return null;
  const pct = p > 0 ? ((c - p) / p) * 100 : (c === 0 ? 0 : Infinity);
  return <><TrendBadge pct={pct} delta={c - p} invert={invert} title={'vs ' + word + ', ' + r.days + ' matched days'} /> on {word}</>;
}

// Six tiles, the day's chart, the month's bars and the pair of cards under them. PANELS is
// left out: a plant may report no strings at all, and the card sits below the fold anyway.
function SolarSkeleton() {
  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        {/* "30% of your 15.9 kW of panels" runs to two lines on a phone, so Solar now
            holds two there; the rest hold one. */}
        {['SOLAR NOW', 'TODAY', 'THIS WEEK', 'THIS MONTH', 'THIS YEAR', 'LIFETIME']
          .map(l => <StatTile key={l} label={l} loading sub={l === 'SOLAR NOW' ? <span className="sub-hold-2">{NBSP}</span> : NBSP} />)}
      </div>
      <Card>
        <SectionTitle>{titled('GENERATION', 'today')}</SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle>{titled('GENERATION', 'last 30 days')}</SectionTitle>
        <window.Skeleton className="bars-skel" h="auto" r={10} />
      </Card>
      <div className="solar-row">
        <Card>
          <SectionTitle>{titled('WHERE IT WENT', 'today')}</SectionTitle>
          <window.Skeleton h={64} r={10} />
        </Card>
        <Card>
          <SectionTitle>GEYSER, POOL PUMP, WASHING</SectionTitle>
          <window.Skeleton h={90} r={10} />
        </Card>
      </div>
    </div>
  );
}

function SolarTab({ snap, energy, onNeedEnergy, today, refreshKey, onOpenSettings }) {
  const a = snap.aggregate;
  const cfg = snap.config || {};
  const feat = snap.features || {};
  const tz = cfg.timezone;
  const plantToday = plantDateStr(tz);
  const rateExp = cfg.tariffExport ?? 0; // only to decide whether the plant sells; no money on this tab
  const hasGrid = feat.hasGrid !== false;
  const hasBatt = feat.hasBattery !== false;
  const sells = hasGrid && rateExp > 0;
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);

  // ---- totals ----
  const [cmp, setCmp] = React.useState(null);
  const [earliest, setEarliest] = React.useState(null);
  React.useEffect(() => { window.fetchCompare().then(setCmp).catch(() => {}); }, [refreshKey]);
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);
  const tot = periodTotals('pv', a.pvToday, energy, plantToday);
  const EP = window.fmtEnergyParts;
  // Every tile keeps its second line, empty or not: the trends and the since-date land after
  // the totals, and a row whose tiles had none yet was 29px short until they did.
  const tile = (label, v, sub) => { const [n, u] = EP(v); return <StatTile label={label} value={n} unit={u} accent={CC.pv} loading={v == null} sub={sub || NBSP} />; };
  const trend = (k, min, word) => periodTrend(cmp, k, 'pv', min, word);
  const kwp = cfg.systemKwp;
  const [nowN, nowU] = fmtPowerParts(a.pvNow);

  // ---- the day on the chart ----
  const pick = useDayPicker(earliest, plantToday); // the plant's date, as the totals and bars use
  const { view, dim, day, points, dayWord } = useShownDay(pick, today, refreshKey);
  // A past day with most of 06:00–18:00 missing and no solar in what is there is a logging gap
  const daytime = points.slice(72, 216);
  const gapDay = !view.isToday && daytime.length > 0 && !points.some(p => p.pv != null && p.pv > 20)
    && daytime.filter(p => p.pv == null).length > daytime.length / 2;
  const noReadings = dayProblem(view, day, points) || (day && gapDay ? 'Readings are missing for most of this day.' : null);
  const peakOf = (pts) => {
    let pk = null;
    (pts || []).forEach(p => { if (p.pv != null && (!pk || p.pv > pk.pv)) pk = p; });
    return pk && pk.pv > 20 ? pk : null;
  };
  const peak = peakOf(points);
  // the Today tile always shows today's peak, whichever day the chart is on, so the tiles
  // keep their height and a scroll to the chart lands where it aimed
  const todayPeak = peakOf(today && !today.approx ? today.points : null);
  const split = React.useMemo(() => solarSplit(points), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  const splitTotal = split.home + split.batt;
  // A destination is shown only once it holds something: a 0.0 kWh column would be a
  // zero-width segment under a full-width label, and "the battery got none of it" is said
  // better by its absence than by a zero.
  const dests = [['Battery', split.batt, CC.batt, hasBatt], ['Home', split.home, CC.load, true]]
    .filter(d => d[3] && d[1] >= 0.05);
  const destPct = (v) => v / splitTotal * 100;
  // The percentages were a permanent column until 2026-09-19; the bar says the same thing,
  // so they moved to the bar's hover title rather than being printed twice. The label row
  // below is aria-hidden, so the bar's own label has to carry the kWh as well as the
  // shares, or a screen reader hears the proportions and never the figures.
  const destTitle = dests.map(d => d[0] + ' ' + Math.round(destPct(d[1])) + '%').join(', ');
  const destLabel = dests.map(d => d[0] + ' ' + fmtKwh(d[1]) + ', ' + Math.round(destPct(d[1])) + '%').join('; ');
  // No money on this card. It answers one question — where the day's sun went — and the rows
  // sum to the day's solar. Est. saved is (load - import) x rate, which is the electricity the
  // house USED and did not buy; it cannot divide into a generation split, so beside these rows
  // it reads as a third unexplained number. It lives on Live, where Home and Imported sit on
  // the same strip and the subtraction is on screen, and on the Grid tab, which spells today's
  // sum out in a sentence. Rejected here on 2026-09-19 after trying it three ways.

  // ---- battery full ----
  const cap = cfg.battCapacity;
  const updated = snap.updated instanceof Date ? snap.updated : new Date();
  // Can the house run a big appliance on solar right now? Only once the battery is full
  // does solar the house doesn't use go spare, so the answer hangs on when it fills.
  let spare = null;
  if (hasBatt) {
    const lost = sells ? 'be sold to the grid' : 'go to waste';
    const soc = Math.round(a.battSoc);
    // charging from the sun: the panels cover the house and most of what the battery takes
    const fromSun = a.battState === 'charging' && a.battPower > 50 && a.pvNow >= a.loadNow + a.battPower * 0.8 && !(a.gridPower > 100);
    const charging = a.battState === 'charging' && a.battPower > 300;
    // Past 17:00 at the plant there is little sun left to fill a battery or run appliances on,
    // wherever the plant is; saying "later" is safer than naming a time after dark.
    const late = (d) => window.plantHour(tz, d) >= 17;
    if (a.battSoc >= 99 && !charging && a.pvNow > a.loadNow + 200 && !late(updated)) {
      spare = { go: true, head: 'Go ahead now', note: 'The battery is full and the panels are making more than the house is using. The extra would ' + lost + '.' };
    } else if (fromSun && cap) {
      const eta = new Date(updated.getTime() + ((100 - a.battSoc) / 100 * cap) / (a.battPower / 1000) * 3600000);
      const at = window.fmtPlantTime(eta, tz);
      spare = plantDateStr(tz, eta) === plantDateStr(tz, updated) && !late(eta)
        ? { head: <>Wait until about <span className="mono">{at}</span></>, estimate: true, note: 'The battery is still charging (' + soc + '%). Once it is full, they can run on solar that would otherwise ' + lost + '.' }
        : { head: 'Not on spare solar today', estimate: true, note: 'The battery is charging (' + soc + '%), but at this rate it won’t be full while there’s still good sun.' };
    } else if (fromSun) {
      spare = { head: 'Wait until the battery is full', note: 'It is charging (' + soc + '%). Set your battery size to see what time that will be.', link: true };
    } else {
      spare = { head: 'Not right now', note: 'The panels aren’t making more than the house and battery can use.' };
    }
  }

  // ---- strings ----
  // some firmware leaves a string's readings empty; read those as zero rather than crash
  const invs = snap.inverters.map(inv => ({ ...inv, strings: inv.strings.map(s => ({ ...s, v: Number(s.v) || 0, i: Number(s.i) || 0, p: Number(s.p) || 0 })) }));
  const strings = invs.flatMap(inv => inv.strings);
  const active = strings.filter(s => s.p >= 5).map(s => s.p);
  const maxP = Math.max(0, ...active);
  let lead = null;
  if (strings.length && !active.length) lead = 'No string is making power right now.';
  else if (active.length > 1) {
    const spread = (maxP - Math.min(...active)) / maxP * 100;
    lead = spread <= 10
      ? 'The strings making power are within ' + Math.max(1, Math.ceil(spread)) + '% of each other.'
      : 'The strings making power range from ' + fmtPower(Math.min(...active)) + ' to ' + fmtPower(maxP) + '.';
  }
  const anyDead = strings.some(s => s.v < 1.5 && s.p < 5);

  // ---- last 30 days ----
  const [daily, loadDaily] = useDaily(refreshKey);
  const bars = daily ? daily.filter(r => r.date) : [];
  const pastBars = bars.filter(r => r.date !== plantToday);
  const best = pastBars.length ? pastBars.reduce((b, r) => ((r.pv || 0) > (b.pv || 0) ? r : b)) : null;
  const openDay = (d) => { pick.setDate(d); scrollToDay('solar-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="SOLAR NOW" value={nowN} unit={nowU} accent={CC.pv}
          sub={kwp > 0 ? <><b>{Math.round(a.pvNow / 10 / kwp)}%</b> of your {kwp} kW of panels</>
            : <button type="button" className="mini-link" onClick={() => onOpenSettings('plant')}>Set panel capacity</button>} />
        {tile('TODAY', a.pvToday, todayPeak ? <>Peak <b>{fmtPower(todayPeak.pv)}</b> at <b>{HM(todayPeak.t)}</b></> : null)}
        {tile('THIS WEEK', tot.week, trend('week', 2, 'last week'))}
        {tile('THIS MONTH', tot.month, trend('month', 3, 'last month'))}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="solar-day">
        <SectionTitle right={day && !noReadings && (view.isToday ? null : <>Made <b>{fmtKwh(day.totals.pv)}</b>{peak && <>, peak <b>{fmtPower(peak.pv)}</b> at <b>{HM(peak.t)}</b></>}</>)}>
          {titled('GENERATION', dayWord)}
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest} />
        {!day ? <window.Skeleton className="chart-skel" h="auto" r={12} />
          : <div {...dim}><DayLineChart points={noReadings ? [] : points} field="pv" color={CC.pv} label="Solar" crop empty={noReadings || (view.isToday ? 'No solar yet today.' : 'No solar on this day.')} /></div>}
      </Card>

      <Card>
        <SectionTitle right={best ? <>Best <b>{fmtKwh(best.pv)}</b> on {shortDate(best.date)}</> : null}>
          {titled('GENERATION', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <window.Skeleton className="bars-skel" h="auto" r={10} />
          : bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
          : <DaysBars rows={bars} field="pv" color={CC.pv} rgb="61,220,132" word="Solar" label="Solar per day for the last 30 days"
              today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />}
      </Card>

      <div className="solar-row">
        <Card>
          <SectionTitle>
            {titled('WHERE IT WENT', dayWord)}
            <window.InfoDot text={'An estimate from 5-minute readings: solar is counted to the house first, then to the battery. Anything sold to the grid is on the Grid tab.'} />
          </SectionTitle>
          {!day ? <window.Skeleton h={64} r={10} />
            : noReadings ? <div className="solar-note" {...dim}>{noReadings}</div>
            : splitTotal < 0.05 ? <div className="solar-note" {...dim}>{view.isToday ? 'No solar yet today.' : 'No solar on this day.'}</div>
            : <div {...dim}>
                <div className="solar-split" role="img" title={destTitle} aria-label={destLabel}>
                  {dests.map(([l, v, c]) => <i key={l} style={{ width: destPct(v) + '%', background: c }} />)}
                </div>
                <div className="solar-dest" aria-hidden="true">
                  {dests.map(([l, v, c]) => {
                    const [n, u] = EP(v);
                    return (
                      <div className="sd" key={l} style={{ width: destPct(v) + '%' }}>
                        <div className="sd-v mono" style={{ color: c }}>{n}<s>{u}</s></div>
                        <div className="sd-k">{l}</div>
                      </div>
                    );
                  })}
                </div>
              </div>}
        </Card>

        {spare && (
          <Card>
            <SectionTitle>
              GEYSER, POOL PUMP, WASHING
              {spare.estimate && <window.InfoDot text="The time comes from the battery’s charge now and how fast it is charging. Charging slows as the battery nears full, so it can take a little longer." />}
            </SectionTitle>
            <div className="solar-verdict" style={{ color: spare.go ? CC.pv : 'var(--text)' }}>{spare.head}</div>
            <p className="solar-spare-note">{spare.note}</p>
            {spare.link && <button type="button" className="mini-link" onClick={() => onOpenSettings('battery')}>Set battery size</button>}
          </Card>
        )}
      </div>

      {strings.length > 0 && (
        <Card>
          <SectionTitle>PANELS</SectionTitle>
          {lead && <p className="solar-lead">{lead}</p>}
          <div className="solar-invs">
            {invs.filter(inv => inv.strings.length).map(inv => (
              <div className="solar-inv" key={inv.sn}>
                <div className="solar-inv-head"><span className="solar-inv-name">{inv.alias}</span><span className="solar-inv-today">{fmtKwh(inv.pvToday)} today</span></div>
                <div className="solar-strings">
                  {inv.strings.map(s => {
                    const dead = s.v < 1.5 && s.p < 5, idle = s.p < 5;
                    return (
                      <div className={'solar-string' + (idle ? ' idle' : '') + (dead ? ' warn' : '')} key={s.no}>
                        <div className="solar-string-top">
                          <span className="solar-string-name">String {s.no} {dead ? <Badge tone="warn" dot>check</Badge> : idle ? <Badge tone="neutral">idle</Badge> : <Badge tone="ok" dot>active</Badge>}</span>
                          <span className="solar-string-kw">{fmtPower(s.p)}</span>
                        </div>
                        {!idle && <div className="meter sm"><div className="meter-fill" style={{ width: (s.p / maxP * 100) + '%', background: CC.pv }} /></div>}
                        <div className="solar-string-sub">{s.v.toFixed(1)} V · {s.i.toFixed(1)} A</div>
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
          {anyDead && a.pvNow > 500 && <div className="hint-line">A string at 0 V while others make power is worth a look: shade, a tripped breaker or a failed string.</div>}
        </Card>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- BATTERY
// Built like Solar: what came out of the battery (today, week, month, year, lifetime) beside
// its charge now, a day's charge against the reserve, the last 30 days, how the battery
// did overnight, how long it would carry the house if the grid went, and each pack.

// "13 h 10 m", "45 m": spoken, not decimal hours, and never broken across a line
function fmtHrs(h) {
  let hh = Math.floor(h), mm = Math.round((h - hh) * 60);
  if (mm === 60) { hh++; mm = 0; }
  return (hh > 0 ? hh + ' h ' + mm + ' m' : mm + ' m').replace(/ /g, NBSP);
}

// Two figures under a split bar, as Solar's Where it went draws them. Each part is
// [label, share, colour, value]; the value is kWh, or already-formatted text.
function SplitBar({ parts, title, aria }) {
  const tot = parts.reduce((s, p) => s + p[1], 0);
  const pct = (v) => v / tot * 100;
  return (
    <>
      <div className="solar-split" role="img" title={title} aria-label={aria}>
        {parts.map(([l, v, c]) => <i key={l} style={{ width: pct(v) + '%', background: c }} />)}
      </div>
      <div className="solar-dest" aria-hidden="true">
        {parts.map(([l, v, c, shown]) => {
          const [n, u] = typeof shown === 'string' ? [shown, ''] : window.fmtEnergyParts(shown == null ? v : shown);
          return (
            <div className="sd" key={l} style={{ width: pct(v) + '%' }}>
              <div className="sd-v mono" style={{ color: c }}>{n}{u && <s>{u}</s>}</div>
              <div className="sd-k">{l}</div>
            </div>
          );
        })}
      </div>
    </>
  );
}

// How the battery did over a night, from 17:00 on the day before to 07:00: how long the
// battery ran the house and how long the grid did (any 5 minutes that drew more than 50 W
// from it, which includes the grid charging the battery), the first time the charge reached
// the reserve, and the lowest charge. null when too little of the night was logged to say.
const NIGHT_FROM = 17 * 60, NIGHT_TO = 7 * 60;
function nightOf(before, after, reserve) {
  const pts = [...(before || []).filter(p => p.t >= NIGHT_FROM), ...(after || []).filter(p => p.t < NIGHT_TO)];
  const read = pts.filter(p => p.soc != null && p.load != null);
  if (read.length < 12 || read.length < pts.length / 2) return null;
  let gridMin = 0, battMin = 0, gridToBatt = 0;
  read.forEach(p => {
    if (p.grid != null && p.grid > 50) {
      gridMin += 5;
      if (p.batt != null && p.batt < 0) gridToBatt += Math.min(-p.batt, p.grid) * 5 / 60 / 1000; // day series: − = charging
    } else battMin += 5;
  });
  return {
    gridMin, battMin, gridToBatt,
    hit: read.find(p => p.soc <= reserve + 1) || null,
    low: read.reduce((b, p) => (p.soc < b.soc ? p : b)),
    done: (after || []).some(p => p.t >= NIGHT_TO - 5 && p.soc != null),
  };
}

// Six tiles, the day's chart, the month's bars and the pair of cards under them.
function BatterySkeleton() {
  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        {['CHARGE NOW', 'TODAY', 'THIS WEEK', 'THIS MONTH', 'THIS YEAR', 'LIFETIME'].map(l => <StatTile key={l} label={l} loading sub={NBSP} />)}
      </div>
      <Card>
        <SectionTitle>{titled('CHARGE', 'today')}</SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle>{titled('OUT OF THE BATTERY', 'last 30 days')}</SectionTitle>
        <window.Skeleton className="bars-skel" h="auto" r={10} />
      </Card>
      <div className="solar-row">
        <Card>
          <SectionTitle>{titled('OVERNIGHT', 'last night')}</SectionTitle>
          <window.Skeleton h={64} r={10} />
        </Card>
        <Card>
          <SectionTitle>IF THE GRID GOES OFF</SectionTitle>
          <window.Skeleton h={90} r={10} />
        </Card>
      </div>
    </div>
  );
}

function BatteryTab(props) {
  if ((props.snap.features || {}).hasBattery === false) {
    return (
      <div className="stack">
        <Card>
          <SectionTitle>BATTERY</SectionTitle>
          <div className="field-note" style={{ marginTop: 0 }}>This plant has no battery — the inverter reports no pack. If one has just been fitted, set Battery to Yes under Settings → Plant.</div>
        </Card>
      </div>
    );
  }
  return <BatteryBody {...props} />;
}

function BatteryBody({ snap, settings, energy, onNeedEnergy, today, refreshKey, onOpenSettings }) {
  const a = snap.aggregate;
  const cfg = snap.config || {};
  const feat = snap.features || {};
  const tz = cfg.timezone;
  const plantToday = plantDateStr(tz);
  const hasGrid = feat.hasGrid !== false;
  const reserve = cfg.reserve ?? 20;
  const cap = cfg.battCapacity ?? 0;
  const updated = snap.updated instanceof Date ? snap.updated : new Date();
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);
  const [earliest, setEarliest] = React.useState(null);
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);

  // ---- totals: what came out of the battery ----
  const tot = periodTotals('dischg', a.battDischgToday, energy, plantToday);
  const EP = window.fmtEnergyParts;
  const tile = (label, v, sub) => { const [n, u] = EP(v); return <StatTile label={label} value={n} unit={u} accent={CC.batt} loading={v == null} sub={sub || NBSP} />; };
  const soc = Math.round(a.battSoc);
  let nowSub;
  if (a.battState === 'charging' && a.battPower > 50) {
    const eta = cap > 0 ? new Date(updated.getTime() + ((100 - a.battSoc) / 100 * cap) / (a.battPower / 1000) * 3600000) : null;
    const sameDay = eta && plantDateStr(tz, eta) === plantDateStr(tz, updated);
    nowSub = <>Charging at <b>{fmtPower(a.battPower)}</b>{sameDay && <>, full at about <b>{window.fmtPlantTime(eta, tz)}</b></>}</>;
  } else if (a.battState === 'discharging' && a.battPower > 50) {
    nowSub = <>Giving out <b>{fmtPower(a.battPower)}</b></>;
  } else {
    nowSub = a.battSoc <= reserve + 1 ? <>Resting at the <b>{reserve}%</b> reserve</> : 'Resting';
  }
  const cycles = cap > 0 && tot.lifetime > 0 ? Math.round(tot.lifetime / cap) : null;

  // ---- the day on the chart ----
  const pick = useDayPicker(earliest, plantToday);
  const { view, dim, day, points, dayWord } = useShownDay(pick, today, refreshKey);
  const noReadings = dayProblem(view, day, points);
  const socs = points.filter(p => p.soc != null);
  const low = socs.length ? socs.reduce((b, p) => (p.soc < b.soc ? p : b)) : null;
  const full = socs.find(p => p.soc >= 98); // 98, as the Live banner counts full

  // ---- overnight: the night into the day on the chart ----
  const [before, setBefore] = React.useState(null); // { date, points }
  const prevDate = window.shiftDate(view.date || plantToday, -1);
  React.useEffect(() => {
    let alive = true;
    window.fetchDay(prevDate)
      .then(r => { if (alive) setBefore({ date: prevDate, points: r.points || [] }); })
      .catch(() => { if (alive) setBefore({ date: prevDate, points: [] }); });
    return () => { alive = false; };
  }, [prevDate, refreshKey]);
  const night = before && before.date === prevDate && day ? nightOf(before.points, points, reserve) : null;
  const nightLoading = !day || !before || before.date !== prevDate;
  const nightWord = view.isToday ? 'last night' : 'into ' + dayWord;
  let nightCard = null;
  if (night) {
    const at = (p) => HM(p.t);
    const d = (m) => fmtHrs(m / 60);
    const lowest = <>Lowest <b>{night.low.soc}%</b> at <b>{at(night.low)}</b>.</>;
    nightCard = {
      parts: [['Battery', night.battMin, CC.batt, d(night.battMin)], [hasGrid ? 'Grid' : 'Other', night.gridMin, CC.grid, d(night.gridMin)]].filter(p => p[1] > 0),
      note: !night.gridMin
        ? <>The battery ran the house {night.done ? 'all night' : 'so far'}. {lowest}</>
        : <>{night.hit ? <>The battery reached the {reserve}% reserve at <b>{at(night.hit)}</b>. </> : null}The grid ran the house for {d(night.gridMin)}{night.gridToBatt >= 0.3 ? <> and put {fmtKwh(night.gridToBatt)} into the battery</> : null}.{!night.hit ? <> {lowest}</> : null}</>,
    };
  }

  // ---- if the grid goes off ----
  // Hours down to the reserve at what the house usually draws between 18:00 and 06:00,
  // from the same hourly profile Live uses. Not at the battery's draw right now: at noon the
  // sun covers the house and that would read as days.
  const [hourly, setHourly] = React.useState(null);
  React.useEffect(() => { if (hasGrid) window.fetchHourly().then(setHourly).catch(() => {}); }, [refreshKey, hasGrid]);
  const nightHours = ((hourly && hourly.hours) || []).filter(h => (Number(h.hour) >= 18 || Number(h.hour) < 6) && h.load_w != null);
  const nightKw = nightHours.length >= 6 ? nightHours.reduce((s, h) => s + Number(h.load_w), 0) / nightHours.length / 1000 : null;
  const usable = cap > 0 ? Math.max(0, (a.battSoc - reserve) / 100 * cap) : null;
  let offCard = null;
  if (hasGrid) {
    if (!(cap > 0)) offCard = { head: 'Needs your battery size', link: true };
    else if (a.gridPresent === false) {
      offCard = a.battState === 'discharging' && a.battPower > 50
        ? { head: <>The grid is off: about <span className="mono">{fmtHrs(usable / (a.battPower / 1000))}</span> left</>, note: 'Down to the ' + reserve + '% reserve at the ' + fmtPower(a.battPower) + ' the battery is giving out now.' }
        : { head: 'The grid is off now', note: 'The battery is at ' + soc + '%.' };
    }
    else if (usable < 0.1) offCard = { head: 'Not long', note: 'The battery is at the ' + reserve + '% reserve.' };
    else if (nightKw > 0.05) offCard = { head: <>About <span className="mono">{fmtHrs(usable / nightKw)}</span></>, note: 'From ' + soc + '% down to the ' + reserve + '% reserve, at the ' + nightKw.toFixed(1) + ' kW the house usually uses at night. Longer while the sun is up.' };
    else if (hourly) offCard = { head: 'Not known yet', note: 'It needs a few nights of readings first.' };
  }

  // ---- last 30 days ----
  const [daily, loadDaily] = useDaily(refreshKey);
  const bars = daily ? daily.filter(r => r.date) : [];
  const pastBars = bars.filter(r => r.date !== plantToday);
  const most = pastBars.length ? pastBars.reduce((b, r) => ((r.dischg || 0) > (b.dischg || 0) ? r : b)) : null;
  const openDay = (d) => { pick.setDate(d); scrollToDay('battery-day'); };

  // ---- packs ----
  const shared = feat.banks === 'shared';
  const withBatt = snap.inverters.filter(i => i.numberOfBatteries > 0 || i.battSoc > 0);
  // One shared pack: every inverter reads the same BMS, so count it once.
  const banks = shared ? Math.min(1, withBatt.length) : withBatt.length;
  const modules = shared ? Math.max(0, ...withBatt.map(i => i.numberOfBatteries || 0)) : withBatt.reduce((n, i) => n + (i.numberOfBatteries || 0), 0);

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="CHARGE NOW" value={soc} unit="%" accent={CC.batt} sub={nowSub} />
        {tile('TODAY', a.battDischgToday, <>Out of the battery. In: <b>{fmtKwh(a.battChgToday)}</b></>)}
        {tile('THIS WEEK', tot.week)}
        {tile('THIS MONTH', tot.month)}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, cycles ? <>About <b>{cycles}</b> full cycles</> : lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="battery-day">
        <SectionTitle right={day && !noReadings && !view.isToday && low ? <>Low <b>{low.soc}%</b> at <b>{HM(low.t)}</b>{full ? <>, full at <b>{HM(full.t)}</b></> : ', never full'}</> : null}>
          {titled('CHARGE', dayWord)}
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest} />
        {!day ? <window.Skeleton className="chart-skel" h="auto" r={12} />
          : <div {...dim}><DayLineChart points={noReadings ? [] : points} field="soc" color={CC.batt} label="Charge" pct reserve={reserve}
              empty={noReadings || 'No charge readings for this day.'} /></div>}
      </Card>

      <Card>
        <SectionTitle right={most && most.dischg > 0 ? <>Most <b>{fmtKwh(most.dischg)}</b> on {shortDate(most.date)}</> : null}>
          {titled('OUT OF THE BATTERY', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <window.Skeleton className="bars-skel" h="auto" r={10} />
          : bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
          : <DaysBars rows={bars} field="dischg" color={CC.batt} rgb="167,139,250" word="Out" label="Energy out of the battery per day for the last 30 days"
              today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />}
      </Card>

      <div className="solar-row">
        <Card>
          <SectionTitle>
            {titled('OVERNIGHT', nightWord)}
            <window.InfoDot text={'From 17:00 to 07:00, in 5-minute readings. Any five minutes that drew from the grid count as the grid’s.'} />
          </SectionTitle>
          {nightLoading ? <window.Skeleton h={64} r={10} />
            : !nightCard ? <div className="solar-note" {...dim}>Readings are missing for most of that night.</div>
            : <div {...dim}>
                <SplitBar parts={nightCard.parts} title={nightCard.parts.map(p => p[0] + ' ' + p[3]).join(', ')} aria={nightCard.parts.map(p => p[0] + ' ' + p[3]).join('; ')} />
                <p className="solar-spare-note">{nightCard.note}</p>
              </div>}
        </Card>

        {offCard && (
          <Card>
            <SectionTitle>
              IF THE GRID GOES OFF
              <window.InfoDot text="The charge above the reserve, divided by the house’s usual use at night. It lasts longer if the inverter cuts some circuits in an outage." />
            </SectionTitle>
            <div className="solar-verdict">{offCard.head}</div>
            {offCard.note && <p className="solar-spare-note">{offCard.note}</p>}
            {offCard.link && <button type="button" className="mini-link" onClick={() => onOpenSettings('battery')}>Set battery size</button>}
          </Card>
        )}
      </div>

      <Card>
        <SectionTitle right={<span className="dim">{banks} {banks === 1 ? 'pack' : 'packs'} · {modules} {modules === 1 ? 'battery' : 'batteries'} · {shared ? 'one pack shared by ' + snap.inverters.length + ' inverters' : 'one pack per inverter'}</span>}>PACKS</SectionTitle>
        <div className="duo">
          {snap.inverters.map(inv => {
            const t = cleanTemp(inv.battTemp);
            return (
              <div className="mini-panel" key={inv.sn}>
                <div className="mp-head"><span className="mono">{inv.alias}</span><span className="dim mono">{inv.numberOfBatteries} × pack · {inv.battCap} Ah</span></div>
                <div className="mp-grid">
                  <Metric label="Power" value={fmtPower(battShown(inv.battOut, settings.battPositive))} accent={CC.batt} />
                  <Metric label="Charge" value={inv.battSoc} unit="%" accent={CC.batt} />
                  <Metric label="Voltage" value={inv.battVolt.toFixed(1)} unit=" V" />
                  <Metric label="Temp" value={t != null ? inv.battTemp.toFixed(1) : 'bad sensor'} unit={t != null ? ' °C' : ''} accent={t == null ? CC.load : null} />
                </div>
                {inv.bank2 && (
                  <div className="mp-grid" style={{ marginTop: 8 }} title="Second battery pack, as the inverter reports it">
                    <Metric label="Pack 2 power" value={fmtPower(Math.abs(inv.bank2.power || 0))} accent={CC.batt} />
                    <Metric label="Bank 2 charge" value={inv.bank2.soc} unit="%" accent={CC.batt} />
                    <Metric label="Bank 2 voltage" value={(inv.bank2.voltage || 0).toFixed(1)} unit=" V" />
                    <Metric label="Bank 2 temp" value={cleanTemp(inv.bank2.temperature) != null ? inv.bank2.temperature.toFixed(1) : '—'} unit={cleanTemp(inv.bank2.temperature) != null ? ' °C' : ''} />
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </Card>
    </div>
  );
}

// ---------------------------------------------------------------- GRID
// Built like Solar: what was bought (now, today, week, month, year, lifetime), a day's
// import, the last 30 days, what the house ran on and what the grid cost, whether the supply
// is there now, and the day's voltage and frequency.

// A connected plant is assumed until the snapshot says otherwise.
function GridSkeleton() {
  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        {['GRID NOW', 'TODAY', 'THIS WEEK', 'THIS MONTH', 'THIS YEAR', 'LIFETIME'].map(l => <StatTile key={l} label={l} loading sub={NBSP} />)}
      </div>
      <Card>
        <SectionTitle>{titled('BOUGHT FROM THE GRID', 'today')}</SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle>{titled('BOUGHT FROM THE GRID', 'last 30 days')}</SectionTitle>
        <window.Skeleton className="bars-skel" h="auto" r={10} />
      </Card>
      <div className="solar-row">
        <Card>
          <SectionTitle>{titled('WHAT THE HOUSE RAN ON', 'today')}</SectionTitle>
          <window.Skeleton h={64} r={10} />
        </Card>
        <Card>
          <SectionTitle>SUPPLY</SectionTitle>
          <window.Skeleton h={90} r={10} />
        </Card>
      </div>
    </div>
  );
}

function GridTab(props) {
  const a = props.snap.aggregate;
  if ((props.snap.features || {}).hasGrid === false) {
    const selfSuff = 100;
    return (
      <div className="stack">
        <div className="trio">
          <StatTile label="GRID" value="Off-grid" unit="" accent={CC.grid} sub="no utility connection" />
          <StatTile label="SELF-SUFFICIENCY" value={selfSuff} unit="%" accent={CC.soc} bar={selfSuff} sub="everything from solar and battery" />
          <StatTile label="USED TODAY" value={a.loadToday} unit=" kWh" accent={CC.load} sub="covered without a grid" />
        </div>
        <Card>
          <SectionTitle>OFF-GRID</SectionTitle>
          <div className="field-note" style={{ marginTop: 0 }}>The inverter reports no mains voltage and no import, so this tab has nothing to bill. If a grid connection is added later, set Grid to Connected under Settings → Plant.</div>
        </Card>
      </div>
    );
  }
  return <GridBody {...props} />;
}

// What a day's house load ran on, from its 5-minute points, with the same allocation as
// Solar's Where it went: solar to the house first, then the battery, and the grid for the
// rest. Import beyond that went into the battery.
function houseSplit(points) {
  let sun = 0, batt = 0, grid = 0, load = 0, imp = 0, exp = 0;
  const kwh = 5 / 60 / 1000;
  points.forEach(p => {
    if (p.grid != null) { if (p.grid > 0) imp += p.grid * kwh; else exp += -p.grid * kwh; }
    if (p.pv == null || p.load == null) return;
    const l = Math.max(0, p.load), s = Math.min(Math.max(0, p.pv), l);
    const b = Math.min(l - s, p.batt != null && p.batt > 0 ? p.batt : 0); // day series: + = discharging
    sun += s * kwh; batt += b * kwh; grid += (l - s - b) * kwh; load += l * kwh;
  });
  return { sun, batt, grid, load, imp, exp };
}

function GridBody({ snap, energy, onNeedEnergy, today, refreshKey, onOpenSettings }) {
  const a = snap.aggregate;
  const cfg = snap.config || {};
  const tz = cfg.timezone;
  const plantToday = plantDateStr(tz);
  const rate = cfg.tariffImport ?? 0;
  const rateExp = cfg.tariffExport ?? 0;
  const sells = rateExp > 0; // same rule as the Overview tile: only plants paid for export
  const hasBatt = (snap.features || {}).hasBattery !== false;
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);
  const [cmp, setCmp] = React.useState(null);
  const [earliest, setEarliest] = React.useState(null);
  React.useEffect(() => { window.fetchCompare().then(setCmp).catch(() => {}); }, [refreshKey]);
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);

  // ---- totals: what was bought ----
  // Today is the logger's own integral, as Live's Imported tile uses: one inverter's CT on a
  // two-inverter plant reads nothing, so the inverters' own counters undercount.
  const tot = periodTotals('imp', a.gridFromToday, energy, plantToday);
  const EP = window.fmtEnergyParts;
  const tile = (label, v, sub) => { const [n, u] = EP(v); return <StatTile label={label} value={n} unit={u} accent={CC.grid} loading={v == null} sub={sub || NBSP} />; };
  const trend = (k, min, word) => periodTrend(cmp, k, 'imp', min, word, true);
  // Every grid-tied inverter leaks a little backflow, so a plant not paid for export only
  // counts as sending power out above 100 W.
  const exporting = a.gridPower < (sells ? -5 : -100);
  const [nowN, nowU] = fmtPowerParts(Math.abs(a.gridPower));
  // Presence is mains voltage, not usage: nothing is bought on a sunny afternoon with the
  // grid live, and a blackout reads 0 W too.
  const nowSub = a.gridPresent === false ? <span style={{ color: CC.load }}>The grid is off</span>
    : exporting ? (sells ? 'Selling' : 'Sending to the grid')
    : a.gridPower > 5 ? 'Buying' : 'Not buying';
  const importPeak = (pts) => {
    let pk = null;
    (pts || []).forEach(p => { if (p.grid != null && p.grid > 50 && (!pk || p.grid > pk.grid)) pk = p; });
    return pk;
  };
  const todayPeak = importPeak(today && !today.approx ? today.points : null);

  // ---- the day on the chart ----
  const pick = useDayPicker(earliest, plantToday);
  const { view, dim, day, points, dayWord } = useShownDay(pick, today, refreshKey);
  const noReadings = dayProblem(view, day, points);
  // export is negative in the day series; this line is what was bought
  const bought = React.useMemo(() => points.map(p => ({ t: p.t, imp: p.grid == null ? null : Math.max(0, p.grid) })), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  const peak = importPeak(points);
  const split = React.useMemo(() => houseSplit(points), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  const parts = [['Solar', split.sun, CC.pv, true], ['Battery', split.batt, CC.batt, hasBatt], ['Grid', split.grid, CC.grid, true]]
    .filter(p => p[3] && p[1] >= 0.05).map(p => p.slice(0, 3));
  const intoBatt = hasBatt ? split.imp - split.grid : 0;
  const noRate = !(rate > 0);
  const money = window.fmtRandSmart; // whole rand, as the Live overview shows money

  // ---- supply now ----
  // One figure per phase each online inverter senses. A dead leg reads a few volts, not 0,
  // so anything under 100 V is "off" (the same test as the grid-down alert).
  const online = snap.inverters.filter(i => i.status === 'online');
  const legs = online.map(inv => ({ inv, v: inv.gridVolts.length ? inv.gridVolts : inv.gridVolt != null ? [inv.gridVolt] : [] })).filter(l => l.v.length);
  const all = legs.flatMap(l => l.v);
  const live = all.filter(v => v > 100).length, dead = all.length - live;
  // The plant's grid-present flag votes on L1 alone, so L1 down with L2 and L3 live reads as
  // a blackout there. Where this inverter shows a live leg, say part of it is off instead.
  let supply;
  if (a.gridPresent == null && !all.length) supply = { head: 'Can’t tell', note: 'The inverter doesn’t report mains voltage.' };
  else if (live > 0 && dead > 0) supply = { head: 'Part of the supply is off', off: true };
  else if (a.gridPresent === false || (all.length && live === 0)) supply = { head: 'The grid is off', off: true };
  else supply = { head: 'The grid is on' };
  if (!supply.note && all.length) {
    const volts = (vs) => <span className="mono">{vs.map(v => (v > 100 ? Math.round(v) : 'off')).join(' / ')} V</span>;
    const same = legs.length > 1 && legs.every(l => l.v.length === 1 && Math.round(l.v[0]) === Math.round(legs[0].v[0]));
    supply.note = live === 0 ? 'No mains voltage at the inverter.'
      : legs.length === 1 ? <>Mains reads {volts(legs[0].v)}{all.length === 3 ? ' on the three phases' : ''}.</>
      : same ? <>Mains reads {volts(legs[0].v)} at {legs.length === 2 ? 'both' : 'each'} inverter{legs.length === 2 ? 's' : ''}.</>
      : <>Mains reads {legs.map((l, i) => <React.Fragment key={l.inv.sn}>{i ? ', ' : ''}{volts(l.v)} at {l.inv.alias}</React.Fragment>)}.</>;
  }

  // ---- last 30 days ----
  const [daily, loadDaily] = useDaily(refreshKey);
  const bars = daily ? daily.filter(r => r.date) : [];
  const pastBars = bars.filter(r => r.date !== plantToday);
  const most = pastBars.length ? pastBars.reduce((b, r) => ((r.imp || 0) > (b.imp || 0) ? r : b)) : null;
  const openDay = (d) => { pick.setDate(d); scrollToDay('grid-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="GRID NOW" value={nowN} unit={nowU} accent={CC.grid} sub={nowSub} />
        {tile('TODAY', a.gridFromToday, sells ? <>Sold <b>{fmtKwh(a.gridToToday)}</b></> : todayPeak ? <>Peak <b>{fmtPower(todayPeak.grid)}</b> at <b>{HM(todayPeak.t)}</b></> : null)}
        {tile('THIS WEEK', tot.week, trend('week', 2, 'last week'))}
        {tile('THIS MONTH', tot.month, trend('month', 3, 'last month'))}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="grid-day">
        <SectionTitle right={day && !noReadings && !view.isToday ? <>Bought <b>{fmtKwh(split.imp)}</b>{peak && <>, most at <b>{HM(peak.t)}</b></>}</> : null}>
          {titled('BOUGHT FROM THE GRID', dayWord)}
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest} />
        {!day ? <window.Skeleton className="chart-skel" h="auto" r={12} />
          : <div {...dim}><DayLineChart points={noReadings ? [] : bought} field="imp" color={CC.grid} label="Bought"
              empty={noReadings || 'No grid readings for this day.'} /></div>}
      </Card>

      <Card>
        <SectionTitle right={most && most.imp > 0 ? <>Most <b>{fmtKwh(most.imp)}</b> on {shortDate(most.date)}</> : null}>
          {titled('BOUGHT FROM THE GRID', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <window.Skeleton className="bars-skel" h="auto" r={10} />
          : bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
          : <DaysBars rows={bars} field="imp" color={CC.grid} rgb="250,204,21" word="Bought" label="Energy bought from the grid per day for the last 30 days"
              today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />}
      </Card>

      <div className="solar-row">
        <Card>
          <SectionTitle>
            {titled('WHAT THE HOUSE RAN ON', dayWord)}
            <window.InfoDot text={'An estimate from 5-minute readings: solar counts first, then the battery, then the grid.'} />
          </SectionTitle>
          {!day ? <window.Skeleton h={64} r={10} />
            : noReadings ? <div className="solar-note" {...dim}>{noReadings}</div>
            : split.load < 0.05 ? <div className="solar-note" {...dim}>No use recorded on this day.</div>
            : <div {...dim}>
                <SplitBar parts={parts} title={parts.map(p => p[0] + ' ' + Math.round(p[1] / split.load * 100) + '%').join(', ')}
                  aria={parts.map(p => p[0] + ' ' + fmtKwh(p[1])).join('; ')} />
                {noRate
                  ? <p className="solar-spare-note"><button type="button" className="mini-link" onClick={() => onOpenSettings('tariff')}>Set your electricity rate</button> to see what the grid cost.</p>
                  : <p className="solar-spare-note">
                      {split.imp < 0.05 ? 'Bought nothing from the grid.' : <>Paid about <b style={{ color: 'var(--text)' }}>{money(split.imp * rate)}</b> for {fmtKwh(split.imp)}.</>}
                      {' '}The {fmtKwh(split.load)} the house used would have cost {money(split.load * rate)} from the grid alone.
                      {intoBatt >= 0.3 ? <> {fmtKwh(intoBatt)} of what was bought went into the battery.</> : null}
                      {sells && split.exp >= 0.05 ? <> Sold {fmtKwh(split.exp)} for {money(split.exp * rateExp)}.</> : null}
                      {' '}<button type="button" className="mini-link" onClick={() => onOpenSettings('tariff')}>Edit rate</button>
                    </p>}
              </div>}
        </Card>

        <Card>
          <SectionTitle>SUPPLY</SectionTitle>
          <div className="solar-verdict" style={{ color: supply.off ? CC.load : 'var(--text)' }}>{supply.head}</div>
          {supply.note && <p className="solar-spare-note">{supply.note}</p>}
        </Card>
      </div>

      {/* The supply over the picked day: voltage at each inverter's AC terminal and the grid's
          frequency, from SunSynk's history (two months back). A blackout shows as a shaded
          band — the terminal keeps reading the inverter's own 230 V then, so only the 0 Hz
          grid frequency gives it away. */}
      <Card className="chart-card">
        <SectionTitle>{titled('SUPPLY', dayWord)}</SectionTitle>
        <window.InverterHistoryChart kind="ac" refreshKey={refreshKey} dayPick={pick} />
      </Card>
    </div>
  );
}

// ---------------------------------------------------------------- INVERTERS
// One inverter card, not two: how many there are is the snapshot's to say.
function InvertersSkeleton() {
  return (
    <div className="stack">
      <SectionTitle>INVERTERS</SectionTitle>
      <Card className="chart-card">
        <SectionTitle>TEMPERATURE · DAY</SectionTitle>
        <DayChartSkeleton legend />
      </Card>
      <div className="duo"><window.Skeleton h={277} r={12} /></div>
    </div>
  );
}

function InvertersTab({ snap, settings, refreshKey }) {
  const feat = snap.features || {};
  const hasBatt = feat.hasBattery !== false, hasGrid = feat.hasGrid !== false;
  return (
    <div className="stack">
      <SectionTitle right={<span className="dim">{snap.inverters.length} units · {snap.plant.name}</span>}>INVERTERS</SectionTitle>
      {/* inverter temperatures over a day (SunSynk history; nothing live reports them) */}
      <Card className="chart-card">
        <SectionTitle>TEMPERATURE · DAY</SectionTitle>
        <window.InverterHistoryChart kind="temp" refreshKey={refreshKey} />
      </Card>
      {/* off-grid: the inverter's own output voltage and frequency live here, not on Grid */}
      {!hasGrid && (
        <Card className="chart-card">
          <SectionTitle>OUTPUT · DAY</SectionTitle>
          <window.InverterHistoryChart kind="output" refreshKey={refreshKey} />
        </Card>
      )}
      <div className="duo">
        {snap.inverters.map(inv => {
          const t = cleanTemp(inv.battTemp);
          return (
            <Card key={inv.sn} className="inv-card">
              <div className="inv-head">
                <div>
                  <div className="inv-sn">{inv.sn}</div>
                  <div className="inv-meta mono dim">{inv.model} · firmware {inv.soft} · {inv.commissioned}</div>
                </div>
                <Badge tone={inv.status === 'online' ? 'ok' : 'warn'} dot>{inv.status}</Badge>
              </div>
              <div className="inv-grid">
                <Metric label="Solar" value={fmtPower(inv.pvNow)} accent={CC.pv} />
                <Metric label="Output" value={fmtPower(inv.output)} />
                {hasBatt && <Metric label="Battery" value={fmtPower(battShown(inv.battOut, settings.battPositive))} accent={CC.batt} />}
                {hasBatt && <Metric label="Charge" value={inv.battSoc} unit="%" accent={CC.batt} />}
                {hasGrid && <Metric label={inv.grid < -5 ? 'Grid (export)' : 'Grid'} value={fmtPower(Math.abs(inv.grid))} accent={CC.grid} />}
                <Metric label="Home" value={fmtPower(inv.load)} accent={CC.load} />
                {hasBatt && <Metric label="Batt temp" value={t != null ? inv.battTemp.toFixed(1) : 'bad sensor'} unit={t != null ? ' °C' : ''} accent={t == null ? CC.load : null} />}
                <Metric label="Today PV" value={fmtKwh(inv.pvToday)} accent={CC.pv} />
              </div>
              {hasBatt && t == null && <div className="inv-warn">⚠ Battery temp sensor reading invalid (≤ −50 °C) — filtered.</div>}
            </Card>
          );
        })}
      </div>
    </div>
  );
}

// The shape to hold while the first snapshot is on its way. Trends and Settings never wait
// on one — App draws those for real — so they have no skeleton here.
function TabSkeleton({ tab }) {
  return tab === 'solar' ? <SolarSkeleton />
    : tab === 'battery' ? <BatterySkeleton />
    : tab === 'grid' ? <GridSkeleton />
    : tab === 'inverters' ? <InvertersSkeleton />
    : <LiveSkeleton />;
}

// ---------------------------------------------------------------- SETTINGS
// One column of sections with a sticky jump list beside it on wide screens. Sections
// are separated by rules, not cards, so the long plant form and the short account
// block sit in one rhythm instead of a lopsided grid.

const SETTINGS_SECTIONS = [
  ['tariff', 'Tariff'], ['plant', 'Plant'], ['battery', 'Battery'],
  ['display', 'Display'], ['connection', 'Logins'], ['account', 'Account'],
];

// Inline "are you sure" for a destructive row. Sits under the row it belongs to, in
// the same inset box the add-login form uses, so the question stays in the page
// instead of a browser dialog. Focus lands on Cancel, so a second Enter from the button
// that opened it cannot fire the deletion; Escape closes it the way a dialog would.
function ConfirmCard({ title, text, action, onConfirm, onCancel }) {
  return (
    <div className="conn-form confirm-card" role="alertdialog" aria-label={action}
         onKeyDown={(e) => { if (e.key === 'Escape') onCancel(); }}>
      {title && <div className="confirm-title">{title}</div>}
      <div className="confirm-text">{text}</div>
      <div className="conn-form-actions">
        <button type="button" className="danger-btn" onClick={onConfirm}>{action}</button>
        <button type="button" className="ghost-btn" onClick={onCancel} autoFocus>Cancel</button>
      </div>
    </div>
  );
}

// Which settings section is showing. Sections stay mounted and hide themselves, so
// the plant form keeps its unsaved edits while you look at another section.
const SettingsActive = React.createContext('tariff');
// { id, done } when a section should flash once on arrival (e.g. from "Set your rate")
const SettingsFlash = React.createContext(null);

function SettingsSection({ id, title, note, right, children }) {
  const active = React.useContext(SettingsActive);
  const flash = React.useContext(SettingsFlash);
  const flashing = flash && flash.id === id;
  return (
    <section id={'settings-' + id} className={'sset' + (flashing ? ' sset-flash' : '')} role="tabpanel" hidden={active !== id}
             onAnimationEnd={flashing ? (e) => { if (e.target === e.currentTarget) flash.done(); } : undefined}>
      <div className="sset-head">
        <h2 className="sset-title">{title}</h2>
        {right && <div className="sset-right">{right}</div>}
      </div>
      {note && <p className="sset-note">{note}</p>}
      <div className="sset-body">{children}</div>
    </section>
  );
}

// The signed-in user's SunSynk logins: one row each with its plants, a reconnect in
// place when the token has died, and a remove. Adding or removing a login changes
// which plants the app can see, so the app reloads its plant list afterwards; when
// the last login goes there is nothing left to show and the page reloads onto the
// Connect screen.
function SunSynkConnectionSection({ onChanged }) {
  const { useState } = React;
  const { loading, accounts, error, refresh } = window.useLinkStatus();
  const [busy, setBusy] = useState(null);
  const [err, setErr] = useState(null);
  const [mode, setMode] = useState(null); // null | 'add' | account_id being reconnected
  const live = accounts.filter(a => a.status !== 'disabled');
  // A failed read with nothing listed says nothing about the logins; "No login connected"
  // would be a guess. Try again re-reads.
  const unread = !!error && !live.length;
  const [checking, setChecking] = useState(false);
  const retry = async () => { setChecking(true); setErr(null); await refresh(); setChecking(false); };
  // "read 2 min ago": freshness is what a login row is for, not the calendar date
  const ago = (iso) => {
    const s = (Date.now() - new Date(iso).getTime()) / 1000;
    if (s < 90) return 'just now';
    const m = Math.round(s / 60); if (m < 90) return m + ' min ago';
    const h = Math.round(m / 60); if (h < 36) return h + ' h ago';
    return Math.round(h / 24) + ' days ago';
  };
  // Waits for the fresh list, so the form's "Connecting…" holds until the login is listed.
  const changed = async () => {
    const readError = await refresh();
    setMode(null); onChanged && onChanged();
    if (readError) setErr('Connected. Reload the page to see it here.');
  };
  // Removing asks once, inline under the row, in the app's own language rather than a
  // browser dialog. 'confirming' holds the account_id whose card is open.
  const [confirming, setConfirming] = useState(null);
  const [leaving, setLeaving] = useState(null); // account_id folding away after a remove
  const remove = async (acc) => {
    const last = live.length === 1;
    setConfirming(null);
    setBusy(acc.account_id); setErr(null);
    try {
      await window.disconnectSunsynk(acc.account_id);
      if (last) { location.reload(); return; }
      setBusy(null); setLeaving(acc.account_id);
      // The row stays folded until the fresh list drops it; clearing it first popped it back.
      // If that read fails the old list stays, so the row stays folded rather than showing
      // a login that is gone. Not changed(): an Add form open meanwhile keeps its fields.
      const [readError] = await Promise.all([refresh(), new Promise(r => setTimeout(r, 240))]); // matches .conn-row.leaving
      onChanged && onChanged();
      if (readError) setErr('Removed. Reload the page to update this list.'); else setLeaving(null);
    } catch (e) { setErr(e.message); setBusy(null); setLeaving(null); }
  };
  const n = live.length;
  const title = <>SunSynk logins{!loading && n > 0 && <span className="sset-count">{n}</span>}</>;
  return (
    <SettingsSection id="connection" title={title} note="The SunSynk logins the app reads your plants through.">
      {loading ? (
        // same height as a row, so the section does not jump when the logins land
        <div className="conn-row"><div className="conn-text"><div className="conn-user dim">Loading…</div><div className="conn-meta">&nbsp;</div></div></div>
      ) : unread ? (
        <div className="conn-row">
          <div className="conn-text"><div className="conn-user">Couldn’t load your logins</div><div className="conn-meta">&nbsp;</div></div>
          <div className="conn-actions"><button type="button" className="ghost-btn" onClick={retry} disabled={checking} aria-busy={checking}>{checking ? 'Checking…' : 'Try again'}</button></div>
        </div>
      ) : !live.length ? (
        <div className="field-note">No login connected.</div>
      ) : live.map(acc => {
        const ok = acc.status === 'active';
        // Green only while the poller is actually reaching it: the header pill calls
        // 15 minutes without a reading "offline", so a login goes amber at the same age.
        const stale = ok && acc.last_ok_at && (Date.now() - new Date(acc.last_ok_at).getTime()) > 900_000;
        const word = !ok ? 'Sign-in expired' : stale ? 'Stale' : 'Connected';
        const plants = acc.plants || [];
        return (
          <div key={acc.account_id} className={'conn-row' + (leaving === acc.account_id ? ' leaving' : '')}>
            <div className="conn-text">
              {/* Line 1: the login and the plants it brings. Line 2: is it working, and
                  when it was added. */}
              <div className="conn-user">
                <span className="mono">{acc.sunsynk_username}</span>
                {plants.length > 0 && <span className="conn-plants"> · {plants.map(p => p.plant_name || 'Plant ' + p.plant_id).join(', ')}</span>}
              </div>
              <div className="conn-meta">
                <span className={'conn-status' + (ok && !stale ? ' ok' : ' warn')}>{word}</span>
                {acc.last_ok_at ? ' · read ' + ago(acc.last_ok_at) : ''}
              </div>
              {!plants.length && <div className="conn-meta">No plant shared with this login. Ask your installer to share it in SunSynk Connect.</div>}
            </div>
            <div className="conn-actions">
              {!ok && mode !== acc.account_id && <button type="button" className="save-btn" onClick={() => { setErr(null); setMode(acc.account_id); }}>Reconnect</button>}
              <button type="button" className="ghost-btn" onClick={() => { setErr(null); setConfirming(confirming === acc.account_id ? null : acc.account_id); }} disabled={busy === acc.account_id}>
                {busy === acc.account_id ? 'Removing…' : 'Remove'}
              </button>
            </div>
            {/* the reconnect form and the remove card sit under the whole row, full width */}
            {mode === acc.account_id && (
              <window.LinkForm compact relink initialUsername={acc.sunsynk_username} onLinked={changed} onCancel={() => setMode(null)} />
            )}
            {confirming === acc.account_id && (
              <ConfirmCard
                title={<>Remove <b>{acc.sunsynk_username}</b>?</>}
                text={'History goes too, unless someone else shares the plant.' + (live.length === 1 ? ' Your only login, so the app returns to the Connect screen.' : '')}
                action="Remove login" onConfirm={() => remove(acc)} onCancel={() => setConfirming(null)} />
            )}
          </div>
        );
      })}
      {!loading && !unread && (mode === 'add'
        ? <div className="conn-row conn-add-row"><div className="conn-text">
            <div className="conn-user">Add login</div>
            {/* Cancel re-reads too: a login with no plant yet is saved but not listed. */}
            <window.LinkForm compact onLinked={changed} onCancel={() => { setMode(null); refresh(); }} />
          </div></div>
        : <div className="conn-add">
            <button type="button" className="save-btn" onClick={() => { setErr(null); setMode('add'); }}>
              <span aria-hidden="true">+</span> Add login
            </button>
          </div>)}
      {err && <div className="field-note" style={{ color: 'var(--load)' }}>{err}</div>}
    </SettingsSection>
  );
}

// Per-plant numbers live in plant_config and are the user's to edit. Timezone and
// currency arrive from SunSynk at link time; the rest are theirs. The roof is not asked
// for: the planned best-day line (BEST_DAY_CURVE.md) would learn from the plant's readings.
// One form, three sections, one save bar.
const PLANT_SECTION_IDS = ['tariff', 'plant', 'battery'];
// Pick one of a few, each with a line on what it means. Native radios underneath, so the
// group takes arrow keys and reads as one question; the tile is only their dress.
function ChoiceTiles({ name, labelledBy, value, options, onChange }) {
  return (
    <div className="choice-tiles" role="radiogroup" aria-labelledby={labelledBy} style={{ '--cols': options.length }}>
      {options.map(o => (
        <label key={o.label} className={'choice-tile' + (o.value === value ? ' on' : '')}>
          <input type="radio" name={name} checked={o.value === value} onChange={() => onChange(o.value)} />
          <span className="choice-text"><span className="conn-user">{o.label}</span><span className="conn-meta">{o.hint}</span></span>
        </label>
      ))}
    </div>
  );
}

function PlantSections({ me, plantId, onSaved, onOpenSection }) {
  const { useState, useEffect } = React;
  const activeSection = React.useContext(SettingsActive);
  const plant = (me?.plants || []).find(p => p.id === plantId) || (me?.plants || [])[0];
  const cfg = plant?.config || {};
  const [f, setF] = useState(cfg);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  // Panel capacity as one Total or By panel. Kept out of f: flipping it alone is not an unsaved
  // change. A plant with nothing set opens on By panel: a household counts panels, it does not
  // know its kW, and SunSynk's figure is no longer seeded (0054).
  const savedList = Array.isArray(cfg?.panel_groups) && cfg.panel_groups.length > 0;
  const capModeOf = (c) => Array.isArray(c?.panel_groups) && c.panel_groups.length ? 'panels'
    : c?.system_kwp == null ? 'panels' : 'total';
  const [capMode, setCapMode] = useState(capModeOf(cfg));
  const [capEditing, setCapEditing] = useState(null);   // 'total' or the row index typed in and not yet left
  const listRef = React.useRef(null);
  useEffect(() => { setF(plant?.config || {}); setCapMode(capModeOf(plant?.config)); }, [plant?.id, JSON.stringify(plant?.config || {})]);
  const set = (k, v) => setF(x => ({ ...x, [k]: v }));
  const num = (v) => v === '' || v == null ? null : Number(v);
  // By panel rows hold what is typed. A row with both boxes empty is skipped; any other needs
  // whole numbers in the database's range (panel_kwp, 0053), or Save stays off.
  const whole = (v, lo, hi) => v !== '' && v != null && Number.isInteger(Number(v)) && Number(v) >= lo && Number(v) <= hi;
  const panelRows = f.panel_groups?.length ? f.panel_groups : [{ count: '', watts: '' }];
  const filled = (r) => (r.count ?? '') !== '' || (r.watts ?? '') !== '';
  const filledRows = panelRows.filter(filled);
  const typedRows = filledRows.map(r => ({ count: Number(r.count), watts: Number(r.watts) }));
  const rowOk = (r) => whole(r.count, 1, 2000) && whole(r.watts, 50, 1000);
  const panelWatts = filledRows.filter(rowOk).reduce((s, r) => s + r.count * r.watts, 0);
  const setRow = (i, k, v) => { setCapEditing(i); set('panel_groups', panelRows.map((r, j) => j === i ? { ...r, [k]: v } : r)); };
  // after Add or Remove, focus lands on a row's panel count rather than dropping to the page
  const focusRow = (i) => setTimeout(() => listRef.current?.querySelectorAll('.panel-row')[i]?.querySelector('input')?.focus());
  // Numbers are compared as numbers, not as typed: 12.60 over a stored 12.6, or a figure
  // typed and taken back out, is not an unsaved change.
  const savedKwp = cfg.system_kwp ?? null;
  // untouched, a stored total is kept whatever it is
  const totalOk = num(f.system_kwp) === savedKwp || (f.system_kwp ?? '') === '' || Number(f.system_kwp) > 0;
  const capBad = capMode === 'total' ? !totalOk : !filledRows.every(rowOk);
  // Capacity counts as changed only as the switch shows it: the Total box, or the filled rows.
  // Blank rows and edits left behind in the other mode are not a change, so an empty By panel
  // never saves over a stored Total. Against a saved list, though, the switch itself is the
  // change: Total on screen means one figure and no list, even at the same kW, and emptying
  // the rows means no capacity at all.
  const capDirty = capMode === 'total' ? num(f.system_kwp) !== savedKwp || savedList
    : filledRows.length ? JSON.stringify(typedRows) !== JSON.stringify(cfg.panel_groups)
    : savedList;
  // The other boxes read the same way: what was typed counts as a change only if the number
  // changed. No `...rest` here: every .jsx is transpiled into the one global scope, and Babel's
  // rest helper keeps its key list in a shared `_excluded`, so a rest pattern in this file
  // silently rewrites what Card (components.jsx) strips from its own props.
  const sansCap = (x) => {
    const o = { ...x };
    delete o.system_kwp; delete o.panel_groups;
    ['tariff_import', 'battery_kwh', 'battery_reserve_pct'].forEach(k => { o[k] = num(o[k]); });
    return o;
  };
  const dirty = capDirty || JSON.stringify(sansCap(f)) !== JSON.stringify(sansCap(cfg));
  // A box turns red, with one line saying what to enter, once focus leaves a row typed in (or
  // Save is pressed), so a number part-way typed never flashes an error. Clicking back into a
  // red box keeps it red until it is changed.
  const capBlur = (e) => { if (!e.currentTarget.contains(e.relatedTarget)) setCapEditing(null); };
  const rowShown = (r, i) => i !== capEditing && filled(r);
  const badRow = panelRows.find((r, i) => rowShown(r, i) && !rowOk(r));
  const boxMsg = (v, empty, fraction, range) => (v ?? '') === '' ? empty : Number.isInteger(Number(v)) ? range : fraction;
  const capErr = capMode === 'total' ? (capEditing !== 'total' && !totalOk ? 'Enter more than 0 kW.' : null)
    : !badRow ? null
    : !whole(badRow.count, 1, 2000) ? boxMsg(badRow.count, 'Enter the number of panels.', 'Enter a whole number of panels.', 'Enter 1 to 2000 panels.')
    : boxMsg(badRow.watts, 'Enter the watts per panel.', 'Enter a whole number of watts.', 'Enter 50 to 1000 W.');

  // South Africa only, for now: no feed-in rate, currency or timezone to set. Those
  // columns keep what SunSynk reported at link time and are never sent from here.
  const save = async () => {
    if (!plant) return;
    // A capacity box still wrong: Save stays pressable (the bar is shared with Tariff and Battery)
    // and instead opens Plant with the message showing and focus on the box to fix.
    if (capBad) {
      setCapEditing(null);
      if (activeSection !== 'plant') onOpenSection && onOpenSection('plant');
      setTimeout(() => document.querySelector('#settings-plant input[aria-invalid="true"]')?.focus());
      return;
    }
    setBusy(true); setMsg(null);
    try {
      // Total clears the list; By panel sends the list and its total, which the database checks
      // against the list (whole watts over 1000 is already to 3 dp)
      const patch = {
        ...(!capDirty ? {} : capMode === 'total' ? { system_kwp: num(f.system_kwp), panel_groups: null }
          : filledRows.length ? { system_kwp: panelWatts / 1000, panel_groups: typedRows }
          : { system_kwp: null, panel_groups: null }),
        tariff_import: num(f.tariff_import) ?? 0,
        battery_kwh: num(f.battery_kwh),
        // untouched, a stored reserve outside the slider's range is kept; edited, it is held to 5..50 even if the box was never left
        battery_reserve_pct: num(f.battery_reserve_pct) === (cfg.battery_reserve_pct ?? null) ? (cfg.battery_reserve_pct ?? 20)
          : Math.min(50, Math.max(5, Math.round(num(f.battery_reserve_pct) ?? cfg.battery_reserve_pct ?? 20))),
        battery_banks: f.battery_banks || 'per-inverter',
        // Detected answers go out only when the owner touched them. Detection can rewrite them
        // while this page is open, and sending the stale copy back would read to the triggers as
        // the owner's choice (0041, 0042). The triggers also mark a choice as the owner's only
        // when its value changes, so confirming what detection found says so outright.
        ...(f.batt_positive_means !== cfg.batt_positive_means || f.batt_sign_source !== cfg.batt_sign_source
          ? { batt_positive_means: f.batt_positive_means ?? null, ...(f.batt_sign_source === 'user' ? { batt_sign_source: 'user' } : {}) } : {}),
        ...(f.has_battery !== cfg.has_battery || f.has_grid !== cfg.has_grid || f.features_source !== cfg.features_source
          ? { has_battery: f.has_battery ?? null, has_grid: f.has_grid ?? null, ...(f.features_source === 'user' ? { features_source: 'user' } : {}) } : {}),
      };
      await window.savePlantConfig(plant.id, patch);
      setMsg('Saved.'); onSaved && onSaved();
    } catch (e) { setMsg(e.message); }
    finally { setBusy(false); }
  };

  if (!plant) return <SettingsSection id="plant" title="Plant"><div className="field-note">No plant connected yet.</div></SettingsSection>;
  const sym = window.moneySymbol ? window.moneySymbol() : (f.currency || '');
  // Battery and grid show Auto until the owner pins an answer. The database pins both flags
  // as soon as either is chosen (0042), so a pick can take the other question off Auto too.
  const featureValue = (k) => f.features_source === 'user' && f[k] != null ? f[k] : 'auto';
  // Auto hands both back, as the trigger does: to what detection found when the saved row was
  // never pinned (so an already-selected Auto changes nothing), else to detection itself
  const pickFeature = (k, v) => setF(x => v !== 'auto' ? { ...x, [k]: v, features_source: 'user' }
    : cfg.features_source === 'user' ? { ...x, has_battery: null, has_grid: null, features_source: 'default' }
    : { ...x, has_battery: cfg.has_battery, has_grid: cfg.has_grid, features_source: cfg.features_source });
  // what Auto knows comes from the saved row, never from an unsaved pick
  const featureAutoHint = (k, yes, no) => cfg.features_source === 'detected' ? (cfg[k] ? yes : no)
    : cfg.features_source === 'user' ? 'Reads it from the inverter.' : 'Still checking.';
  // where the reserve slider sits: the box while it holds a number, else the saved value
  const reserve = Math.min(50, Math.max(5, num(f.battery_reserve_pct) ?? cfg.battery_reserve_pct ?? 20));
  return (
    <>
      {/* A unit is a kWh: it is what a South African bill calls one, so the rate is per unit */}
      <SettingsSection id="tariff" title="Tariff" note="What you pay for electricity, per unit (kWh).">
        <div className="conn-row sset-row">
          <label className="conn-text" htmlFor="tariff-import">
            <span className="conn-user">Electricity rate</span>
            <span className="conn-meta">{f.tariff_import > 0 ? 'Used to work out what solar saved.' : 'Savings show as zero until this is set.'}</span>
          </label>
          <div className="conn-actions">
            <div className="unit-input wide">
              <input id="tariff-import" className="input mono" type="number" inputMode="decimal" step="0.01" min="0" placeholder="3.40" aria-describedby="tariff-import-unit"
                     value={f.tariff_import ?? ''} onChange={e => set('tariff_import', e.target.value)} />
              <span id="tariff-import-unit" className="unit">{sym}/unit</span>
            </div>
          </div>
        </div>
      </SettingsSection>

      <SettingsSection id="plant" title="Plant"
        note="What this plant has: a battery, a grid connection and panels. Auto reads the first two from the inverter, and any choice applies to both.">
        <div className="conn-row sset-row">
          <div className="conn-text"><span id="plant-batt-q" className="conn-user">Does this plant have a battery?</span></div>
          <ChoiceTiles name="plant-batt" labelledBy="plant-batt-q" value={featureValue('has_battery')} onChange={v => pickFeature('has_battery', v)}
            options={[{ value: 'auto', label: 'Auto', hint: featureAutoHint('has_battery', 'Found a battery.', 'Found no battery.') },
                      { value: true, label: 'Yes', hint: 'Batteries are connected.' },
                      { value: false, label: 'No', hint: 'No batteries connected.' }]} />
        </div>
        <div className="conn-row sset-row">
          <div className="conn-text"><span id="plant-grid-q" className="conn-user">Is it connected to the grid?</span></div>
          <ChoiceTiles name="plant-grid" labelledBy="plant-grid-q" value={featureValue('has_grid')} onChange={v => pickFeature('has_grid', v)}
            options={[{ value: 'auto', label: 'Auto', hint: featureAutoHint('has_grid', 'Found a grid connection.', 'Found no grid connection.') },
                      { value: true, label: 'Connected', hint: 'Wired to the utility.' },
                      { value: false, label: 'Off-grid', hint: 'No utility connection.' }]} />
        </div>
        <div className="conn-row sset-row">
          <div className="conn-text">
            <span id="plant-kwp-q" className="conn-user">Panel capacity</span>
            <span className="conn-meta">What all the panels can make in full sun.</span>
          </div>
          {/* The switch belongs to what it switches, so it sits over the boxes on the left
              rather than alone at the far edge of a wide card. */}
          <div className="cap-switch">
            <Segmented size="sm" value={capMode} onChange={setCapMode}
              options={[{ value: 'total', label: 'Total' }, { value: 'panels', label: 'By panel' }]} />
          </div>
          {capMode === 'total' ? (
            <div className="cap-body cap-total" onBlur={capBlur}>
              <div className="unit-input">
                <input className="input mono" type="number" inputMode="decimal" step="0.01" min="0" placeholder="12.6" aria-labelledby="plant-kwp-q plant-kwp-unit"
                       aria-invalid={!!capErr} aria-describedby={capErr ? 'cap-err' : undefined} value={f.system_kwp ?? ''}
                       onChange={e => { setCapEditing('total'); set('system_kwp', e.target.value); }} />
                <span id="plant-kwp-unit" className="unit">kW</span>
              </div>
              {capErr && <p id="cap-err" className="cap-err" role="alert">{capErr}</p>}
            </div>
          ) : (
            <div className="cap-body">
              {/* the block is as wide as the rows, so the total's rule runs under them */}
              <div className="panel-block">
              <div className="panel-list" ref={listRef}>
                {panelRows.map((r, i) => {
                  const countBad = rowShown(r, i) && !whole(r.count, 1, 2000), wattsBad = rowShown(r, i) && !whole(r.watts, 50, 1000);
                  return (
                    <div key={i} className="panel-row" onBlur={capBlur}>
                      <div className="unit-input panel-count">
                        <input className="input mono" type="number" inputMode="numeric" min="1" max="2000" step="1" placeholder="20" aria-label={'Panels, row ' + (i + 1)}
                               aria-invalid={countBad} aria-describedby={countBad ? 'cap-err' : undefined} value={r.count ?? ''} onChange={e => setRow(i, 'count', e.target.value)} />
                        <span className="unit" aria-hidden="true">panels</span>
                      </div>
                      <span className="panel-times" aria-hidden="true">×</span>
                      <div className="unit-input panel-watts">
                        <input className="input mono" type="number" inputMode="numeric" min="50" max="1000" step="1" placeholder="450" aria-label={'Watts per panel, row ' + (i + 1)}
                               aria-invalid={wattsBad} aria-describedby={wattsBad ? 'cap-err' : undefined} value={r.watts ?? ''} onChange={e => setRow(i, 'watts', e.target.value)} />
                        <span className="unit" aria-hidden="true">W</span>
                      </div>
                      {/* a lone empty row has nothing to remove; hidden, not gone, so the columns keep their width */}
                      <button type="button" className="panel-del" aria-label={'Remove row ' + (i + 1)} title="Remove"
                              style={panelRows.length === 1 && !filled(r) ? { visibility: 'hidden' } : undefined}
                              onClick={() => { setCapEditing(null); set('panel_groups', panelRows.filter((_, j) => j !== i)); focusRow(Math.max(0, Math.min(i, panelRows.length - 2))); }}><TrashIcon /></button>
                    </div>
                  );
                })}
              </div>
              {/* always there, so an error arriving on blur never moves the button being clicked */}
              <p id="cap-err" className="cap-err" aria-live="polite">{capErr}</p>
              <button type="button" className="panel-add" onClick={() => { set('panel_groups', [...panelRows, { count: '', watts: '' }]); focusRow(panelRows.length); }}>Add panels</button>
              {/* not "Total": that word is the other way of entering it, on the switch above */}
              <div className={'panel-sum' + (panelWatts > 0 ? '' : ' empty')}><span>Comes to</span><span className="mono">{+(panelWatts / 1000).toFixed(3)} kW</span></div>
              </div>
            </div>
          )}
        </div>
      </SettingsSection>

      <SettingsSection id="battery" title="Battery" note="How big the battery is, and how the inverter reports it.">
        {/* rows like Logins and Account: name and hint on the left, control on the right, a rule between */}
        <div className="conn-row sset-row">
          <label className="conn-text" htmlFor="batt-kwh">
            <span className="conn-user">Capacity</span>
            <span className="conn-meta">Every battery added together.</span>
          </label>
          <div className="conn-actions">
            <div className="unit-input">
              <input id="batt-kwh" className="input mono" type="number" inputMode="decimal" step="0.1" min="0" placeholder="26.5" aria-describedby="batt-kwh-unit"
                     value={f.battery_kwh ?? ''} onChange={e => set('battery_kwh', e.target.value)} />
              <span id="batt-kwh-unit" className="unit">kWh</span>
            </div>
          </div>
        </div>
        <div className="conn-row sset-row">
          <label className="conn-text" htmlFor="batt-reserve">
            <span className="conn-user">Reserve</span>
            <span className="conn-meta">Discharging stops at this level.</span>
          </label>
          {/* type in the box or drag; an edited box settles into 5 to 50 when it loses focus */}
          <div className="conn-actions">
            <div className="unit-input">
              <input id="batt-reserve" className="input mono" type="number" inputMode="numeric" min="5" max="50" step="1" aria-describedby="batt-reserve-unit"
                     value={f.battery_reserve_pct ?? ''} onChange={e => set('battery_reserve_pct', e.target.value)}
                     onBlur={e => {
                       if (num(f.battery_reserve_pct) === (cfg.battery_reserve_pct ?? null)) return;   // untouched: keep a stored value outside the range
                       const v = Math.round(Number(e.target.value));
                       set('battery_reserve_pct', e.target.value === '' || isNaN(v) ? (cfg.battery_reserve_pct ?? 20) : Math.min(50, Math.max(5, v)));
                     }} />
              <span id="batt-reserve-unit" className="unit">%</span>
            </div>
          </div>
          <div className="reserve-slider">
            <input className="range" type="range" min="5" max="50" step="1" aria-label="Reserve slider"
                   style={{ '--fill': ((reserve - 5) / 45 * 100) + '%' }}
                   value={reserve} onChange={e => set('battery_reserve_pct', Number(e.target.value))} />
            <div className="reserve-scale" aria-hidden="true"><span>5%</span><span>50%</span></div>
          </div>
        </div>
        {/* battery_banks: 'shared' means every inverter reads the same batteries, so charge counts once */}
        <div className="conn-row sset-row">
          <div className="conn-text"><span id="batt-banks-q" className="conn-user">Do the inverters share batteries?</span></div>
          <ChoiceTiles name="batt-banks" labelledBy="batt-banks-q" value={f.battery_banks || 'per-inverter'} onChange={v => set('battery_banks', v)}
            options={[{ value: 'shared', label: 'Shared', hint: 'Every inverter reads the same batteries.' },
                      { value: 'per-inverter', label: 'Separate', hint: 'Each inverter has its own batteries.' }]} />
        </div>
        <div className="conn-row sset-row">
          <div className="conn-text">
            <span id="batt-sign-q" className="conn-user">Positive battery number</span>
            <span className="conn-meta">Change only if a draining battery shows as charging.</span>
          </div>
          <ChoiceTiles name="batt-sign" labelledBy="batt-sign-q" value={f.batt_sign_source === 'user' ? (f.batt_positive_means || '') : ''}
            // Auto on a plant that was never pinned puts back what detection found, so tapping
            // an already-selected Auto changes nothing; Auto on a pinned plant clears the pin
            onChange={v => setF(x => ({ ...x, ...(v ? { batt_positive_means: v, batt_sign_source: 'user' }
              : cfg.batt_sign_source === 'user' ? { batt_positive_means: null, batt_sign_source: 'default' }
              : { batt_positive_means: cfg.batt_positive_means, batt_sign_source: cfg.batt_sign_source }) }))}
            // what Auto knows comes from the saved row; a pinned answer says nothing about detection
            options={[{ value: '', label: 'Auto', hint: cfg.batt_sign_source === 'detected' && cfg.batt_positive_means ? 'Found: positive means ' + cfg.batt_positive_means + '.'
                        : cfg.batt_sign_source === 'user' ? 'Reads it from the inverter.' : 'Still checking.' },
                      { value: 'charging', label: 'Charging', hint: 'Positive means the battery is charging.' },
                      { value: 'discharging', label: 'Discharging', hint: "Positive means it's powering the house." }]} />
        </div>
      </SettingsSection>

      {(dirty || msg) && (
        <div className={'save-bar' + (dirty ? ' dirty' : '')} hidden={!PLANT_SECTION_IDS.includes(activeSection)}>
          <span className="save-text">{dirty ? 'Unsaved changes' : msg}</span>
          {dirty && <button type="button" className="ghost-btn" onClick={() => { setF(cfg); setCapMode(capModeOf(cfg)); setMsg(null); }} disabled={busy}>Discard</button>}
          {dirty && <button type="button" className="save-btn" onClick={save} disabled={busy}>{busy ? 'Saving…' : 'Save'}</button>}
        </div>
      )}
    </>
  );
}

function AccountSection() {
  const { useState, useEffect } = React;
  const [busy, setBusy] = useState(false);
  const [email, setEmail] = useState(null);
  useEffect(() => { window.sb.auth.getSession().then(({ data }) => setEmail(data?.session?.user?.email || null)).catch(() => {}); }, []);
  const [err, setErr] = useState(null);
  const [confirming, setConfirming] = useState(false);
  const del = async () => {
    setConfirming(false);
    setBusy(true); setErr(null);
    try { await window.deleteAccount(); await window.sb.auth.signOut(); location.href = './'; }
    catch (e) { setErr(e.message); setBusy(false); }
  };
  return (
    <SettingsSection id="account" title="Account" note="Sign out of this device, or delete your account.">
      <div className="conn-row">
        <div className="conn-text">
          <div className="conn-user mono">{email || 'this account'}</div>
          <div className="conn-meta">Signing out keeps your logins and history.</div>
        </div>
        <div className="conn-actions"><window.SignOutButton className="ghost-btn" /></div>
      </div>
      <div className="conn-row">
        <div className="conn-text">
          <div className="conn-user">Delete account</div>
          <div className="conn-meta">Removes your logins and settings. History goes too, unless someone else shares the plant.</div>
        </div>
        <div className="conn-actions"><button type="button" className="ghost-btn" onClick={() => { setErr(null); setConfirming(c => !c); }} disabled={busy}>{busy ? 'Deleting…' : 'Delete account'}</button></div>
        {confirming && (
          <ConfirmCard title={<>Delete <b>{email || 'this account'}</b>?</>} text="It cannot be undone."
            action="Delete account" onConfirm={del} onCancel={() => setConfirming(false)} />
        )}
      </div>
      {err && <div className="field-note" style={{ color: 'var(--load)' }}>{err}</div>}
    </SettingsSection>
  );
}

function SettingsTab({ settings, setSettings, config, me, plantId, onPlantConfigSaved, flash, onFlashed }) {
  const { useState, useEffect } = React;
  const set = (patch) => setSettings(s => ({ ...s, ...patch }));
  // One section at a time. ?s= in the URL wins on load, then the last one opened,
  // then Tariff. Read like ?tab= is: on mount only, never written back to the URL.
  // 'synsynk.settings' is the display-prefs blob; this key must stay separate.
  const ids = SETTINGS_SECTIONS.map(([id]) => id);
  const [active, setActive] = useState(() => {
    const want = new URLSearchParams(location.search).get('s') || localStorage.getItem('synsynk.section');
    return ids.includes(want) ? want : 'tariff';
  });
  const open = (id) => {
    setActive(id);
    localStorage.setItem('synsynk.section', id);
    window.scrollTo({ top: 0 });
  };
  return (
    <SettingsActive.Provider value={active}><SettingsFlash.Provider value={flash ? { id: flash, done: onFlashed } : null}>
    <div className="settings">
      <nav className="settings-nav" role="tablist" aria-label="Settings sections">
        {SETTINGS_SECTIONS.map(([id, label]) => (
          <button key={id} type="button" role="tab" aria-selected={active === id} className={active === id ? 'active' : ''} onClick={() => open(id)}>{label}</button>
        ))}
      </nav>
      <div className="settings-body">
        <PlantSections me={me} plantId={plantId} onSaved={onPlantConfigSaved} onOpenSection={open} />

        <SettingsSection id="display" title="Display" note="Saved to your account, so every device looks the same.">
          {/* reads like the toggle rows below: name, hint, then the control */}
          <div className="field sset-choice">
            <span className="toggle-text">
              <span id="batt-power-q" className="toggle-label">Battery power</span>
            </span>
            <ChoiceTiles name="batt-power" labelledBy="batt-power-q" value={settings.battPositive} onChange={v => set({ battPositive: v })}
              options={[{ value: 'discharge', label: '+ powering the house', hint: 'Discharging reads as a positive number.' },
                        { value: 'charge', label: '+ charging', hint: 'Charging reads as a positive number.' }]} />
          </div>
          <div className="field" style={{ marginBottom: 0 }}>
            <label>Extra tabs</label>
            {[['solar', 'Solar', 'Generation and PV strings'], ['battery', 'Battery', 'Charge, temperature and per-inverter packs'], ['grid', 'Grid', 'Import, quality and savings'], ['inverters', 'Inverters', 'Each unit in detail']].map(([k, l, h]) => (
              <Toggle key={k} label={l} hint={h} checked={settings.tabs[k]} onChange={v => set({ tabs: { ...settings.tabs, [k]: v } })} />
            ))}
          </div>
        </SettingsSection>

        <SunSynkConnectionSection onChanged={onPlantConfigSaved} />
        <AccountSection />
        {/* under the card, not inside it */}
        <div className="app-version mono">{window.APP_VERSION}</div>
      </div>
    </div>
    </SettingsFlash.Provider></SettingsActive.Provider>
  );
}

Object.assign(window, { LiveTab, SolarTab, BatteryTab, GridTab, InvertersTab, SettingsTab, MiniStat, FsEnterIcon, BalanceSkeleton, TabSkeleton });
