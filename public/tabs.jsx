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
          <MiniStat loading label="Made" />
          <MiniStat loading label="Home" />
          <MiniStat loading label="Independence" bar={0} />
          <MiniStat loading label="Imported" sub={' '} />
          <MiniStat loading label="Est. saved" sub={' '} />
        </div>
      </div>
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

function LiveTab({ snap, today, energy, onNeedEnergy, refreshKey, onOpenSettings }) {
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
  // A silent plant's last figures aren't now: no projection from them, and Today's tiles show a dash.
  const ps = window.plantStatus(snap, Date.now());
  const silent = ps.status === 'offline';
  let battEta = null, battInfo = null;
  if (!hasBatt || silent) { /* nothing to estimate */ }
  else if (!cap) { battInfo = 'Set pack size'; } // a link on the flow's battery node
  // Under 200 W the battery is only trickling and a time would read in days, so it gives none.
  else if (a.battState === 'discharging' && a.battPower >= 200) {
    const hrs = availKwh / (a.battPower / 1000);
    battEta = <span className="batt-eta"><span className="bel">≈ <b>{fmtDur(hrs)}</b> until {RESERVE}% reserve</span><span className="bel sub">~{fmtEta(hrs)}</span></span>;
    battInfo = `${fmtDur(hrs)} to empty`;
  } else if (a.battState === 'charging' && a.battPower >= 200) {
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
  // Both layouts are HTML at screen sizes, so on a wall the diagram is zoomed to fill the
  // room under the sentence (SOLAR-39). It is measured at zoom 1 and set back in the same
  // task, so the observer sees one settled size and cannot feed itself.
  React.useEffect(() => {
    const wrap = flowRef.current;
    if (!wall || !wrap) return;
    const card = wrap.querySelector('.flow-card');
    const fit = () => {
      const m = wrap.querySelector('.mflow, .pflow'), n = wrap.querySelector('.flow-narrative');
      if (!m || !n) return;
      wrap.style.setProperty('--wall-zoom', '1');
      const room = card.clientHeight - n.offsetHeight - parseFloat(getComputedStyle(n).marginBottom);
      if (!m.offsetWidth || !m.offsetHeight) return;
      const z = Math.min(card.clientWidth / m.offsetWidth, room / m.offsetHeight);
      if (z > 0) wrap.style.setProperty('--wall-zoom', z.toFixed(3));
    };
    const ro = new ResizeObserver(fit);
    [card, wrap.querySelector('.flow-narrative'), wrap.querySelector('.mflow, .pflow')].forEach(el => el && ro.observe(el));
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
  if (period === 'today' && silent) { pPv = pLoad = pImp = pExp = null; }
  else if (period === 'today') { pPv = a.pvToday; pLoad = a.loadToday; pImp = hasGrid ? a.gridFromToday : 0; pExp = hasGrid ? a.gridToToday : 0; }
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
  const periodWord = { today: 'today', week: 'this week', month: 'this month', year: 'this year', lifetime: 'lifetime' }[period];
  // trend vs the same elapsed slice of the previous period. Today's is yesterday up to
  // the same time (0077), so it is fair from the first minute and shows all day.
  // "current" = the live value shown in the tile (pPv/pLoad/…) so the arrow stays
  // consistent with the number AND moves on every refresh; "previous" comes from
  // the compare endpoint (same elapsed slice of the prior period).
  // The compare endpoint pairs each finished day of the current slice with its
  // counterpart in the previous period and sums only the pairs where both days have a
  // record (0037). So for Week/Month/Year the current side must be that paired sum
  // too, not the live tile total, or a plant logging since mid-year would compare a
  // full slice against a few matched days. Today joins that sum as one more pair when
  // its counterpart has a reading at the same time (`now`, 0078): today's live figures
  // on this side, the counterpart up to the same time on the other.
  const rawRow = (cmp && cmp[period]) ? cmp[period] : null;
  const plus = (x, y) => ({ pv: x.pv + y.pv, load: x.load + y.load, imp: x.imp + y.imp });
  const liveToday = { pv: a.pvToday || 0, load: a.loadToday || 0, imp: hasGrid ? (a.gridFromToday || 0) : 0 };
  // today is in the slice either way; it counts as compared only with a counterpart
  const cmpRow = (!rawRow || period === 'today') ? rawRow : {
    cur: rawRow.now ? plus(rawRow.cur, liveToday) : rawRow.cur,
    prev: rawRow.now ? plus(rawRow.prev, rawRow.now) : rawRow.prev,
    days: (rawRow.days || 0) + (rawRow.now ? 1 : 0),
    span: (rawRow.span || 0) + 1,
  };
  const cmpDays = cmpRow ? (cmpRow.days || 0) : 0;
  // one compared day is enough: the arrow should always show (Brynne, 2026-10-06)
  const prev = (cmpRow && cmpDays >= 1) ? cmpRow.prev : null;
  const useLive = period === 'today';
  const cPv = useLive ? pPv : (cmpRow ? cmpRow.cur.pv : null);
  const cLoad = useLive ? pLoad : (cmpRow ? cmpRow.cur.load : null);
  const cImp = useLive ? pImp : (cmpRow ? cmpRow.cur.imp : null);
  const suff = (load, imp) => Math.max(0, Math.min(100, ((load - imp) / load) * 100));
  // unrounded on both sides; the tile's pSuff is rounded for display
  const cSuff = useLive ? ((pLoad != null && pLoad > 0) ? suff(pLoad, pImp) : null) : ((cmpRow && cmpRow.cur.load > 0) ? suff(cmpRow.cur.load, cmpRow.cur.imp) : null);
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
    // nothing logged on the other side: no arrow at all, not even a "0%"
    if (c == null || p == null || !prevHasData) return null;
    // Zero then zero is no change. Zero then something has no meaningful percentage,
    // so hand the badge Infinity and let it fall back to the absolute kWh change.
    if (p === 0) return c === 0 ? 0 : Infinity;
    return ((c - p) / p) * 100;
  };
  const tGen = prev ? pct(cPv, prev.pv) : null;
  const tCon = prev ? pct(cLoad, prev.load) : null;
  const tImp = prev ? pct(cImp, prev.imp) : null;
  // absolute kWh change, the hybrid fallback when a % would explode off a tiny baseline
  const dGen = prev ? (cPv - prev.pv) : null;
  const dCon = prev ? (cLoad - prev.load) : null;
  const dImp = prev ? (cImp - prev.imp) : null;
  const prevSuff = (prev && prev.load > 0) ? suff(prev.load, prev.imp) : null;
  const tSuff = (cSuff != null && prevSuff != null) ? (cSuff - prevSuff) : null;
  // "vs last year, 40 of 120 days compared" — say when the arrow rests on a subset
  const cmpBase = { today: 'vs yesterday at this time', week: 'vs last week', month: 'vs last month', year: 'vs last year' }[period];
  // nothing logged on the other side: no arrows, and no note about them either
  const partial = !!(cmpBase && cmpRow && !useLive && prevHasData && cmpDays < (cmpRow.span || 0));
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
          <window.PowerFlow agg={a} inverters={snap.inverters.filter(i => i.status === 'online').length} battInfo={battInfo} onBattInfo={hasBatt && !cap && !wall ? () => onOpenSettings('battery') : undefined} typicalSoc={typicalSoc} typicalHour={typicalHour} features={feat} wall={wall} silentSince={silent ? readAgo(ps.last.getTime(), Date.now()) : null} />
        </Card>
      </div>

      <Card className="chart-card">
        <window.HistoryView today={today} refreshKey={refreshKey} silent={silent} />
      </Card>

      <div className="overview-section">
        <div className="overview-head">
          <SectionTitle>OVERVIEW · <span style={{ color: 'var(--text)' }}>{periodWord}</span></SectionTitle>
          <Segmented size="sm"
            options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]}
            value={period} onChange={setPeriod} />
        </div>
        {/* On a phone there is no hover, so a thin comparison base is said on screen. */}
        {partial && <div className="cmp-note">Arrows compare the {cmpDays} of {cmpRow.span} days with readings on both sides.</div>}
        <div className="today-strip">
          <MiniStat loading={pending} label="Made" value={window.fmtEnergySmart(pPv)} color={CC.pv} trend={tGen} trendDelta={dGen} trendTitle={cmpWord} />
          <MiniStat loading={pending} label="Home" value={window.fmtEnergySmart(pLoad)} color={CC.load} trend={tCon} trendDelta={dCon} trendInvert trendTitle={cmpWord}
            info="What your home used, across all inverters." />
          <MiniStat loading={pending} label="Independence" value={pSuff != null ? pSuff + '%' : '—'} color={CC.soc} bar={pSuff || 0} trend={tSuff} trendTitle={cmpWord}
            info="How much of what your home used didn’t come from the grid." />
          {showExport && <MiniStat loading={pending} label="Exported" value={window.fmtEnergySmart(pExp)} color={CC.grid}
            info="Sent to the grid, paid at your feed-in rate." />}
          {hasGrid && <MiniStat loading={pending} label="Imported" value={window.fmtEnergySmart(pImp)} color={CC.grid} trend={tImp} trendDelta={dImp} trendInvert trendTitle={cmpWord}
            sub={silent ? undefined : a.gridPresent == null ? (
              // No inverter has reported mains voltage yet; a blank here read as a
              // chip that failed to load.
              <span className="grid-state unknown"><span className="gs-dot" />Grid unknown</span>
            ) : (
              // Presence, not usage: mains voltage is there even when you draw nothing
              // from it, so this stays ON through a sunny self-powered afternoon.
              <span className={'grid-state ' + (a.gridPresent ? 'on' : 'off')}
                    title={a.gridPresent
                      ? 'The grid is live, even when you’re not using it.'
                      : 'No power from the grid.'}>
                <span className="gs-dot" />{a.gridPresent ? (a.phaseDown ? 'Phase down' : 'Grid on') : 'Grid off'}
              </span>
            )} />}
          {!hasGrid && <MiniStat loading={pending} label="Grid" value="Off" color={CC.grid}
            info="No grid connection. Everything the home uses comes from solar and the battery." />}
          <MiniStat loading={pending} label="Est. saved" color={CC.batt}
            value={(rate > 0 || rateExp > 0) && pSaved != null ? window.fmtRandSmart(pSaved) : '—'}
            trend={tSaved} trendDelta={dSaved} trendDeltaFmt={window.fmtRandSmart} trendTitle={cmpWord}
            // no rate yet: the line under the dash opens Settings on Tariff
            sub={!(rate > 0 || rateExp > 0) ? <button type="button" className="mini-link" onClick={() => onOpenSettings('tariff')}>Set your rate</button> : undefined}
            info={'What your home used that didn’t come from the grid, at your electricity rate' + (rateExp > 0 ? ', plus what you exported at your feed-in rate' : '') + '.'} />
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
// "14.2 kWh" → the number, then a smaller unit, so the figure reads first
function unitSplit(v) {
  const m = typeof v === 'string' && /^(.*?)\s?(kWh|MWh|GWh|kW|W|%)$/.exec(v);
  return m ? <>{m[1]}<span className={'mv-unit' + (m[2] === '%' ? ' pct' : '')}>{m[2]}</span></> : v;
}
function MiniStat({ label, value, color, sub, bar, info, trend, trendUnit, trendInvert, trendTitle, trendDelta, trendDeltaFmt, loading }) {
  return (
    <Card className="mini-stat">
      {/* the trend arrow sits on the label's line, top right, so it fits at every width */}
      <div className="mini-label">
        <span className="ml-text">{label}{info && <window.InfoDot text={info} />}</span>
        {!loading && <TrendBadge pct={trend} unit={trendUnit} invert={trendInvert} title={trendTitle} delta={trendDelta} deltaFmt={trendDeltaFmt} />}
      </div>
      {/* a shimmer beats an em-dash: switching to Week/Month refetches, and "—" reads as
          "no data" rather than "fetching" */}
      {loading
        ? <div className="mini-value"><window.Skeleton w="70%" h={31} /></div>
        : <div className="mini-value mono" style={{ color }}><span className="mv-num">{unitSplit(value)}</span></div>}
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
  let home = 0, batt = 0, grid = 0;
  const kwh = 5 / 60 / 1000;
  points.forEach(p => {
    if (p.pv == null || p.load == null) return;
    const pv = Math.max(0, p.pv), toHome = Math.min(pv, Math.max(0, p.load));
    const toBatt = Math.min(pv - toHome, p.batt != null && p.batt < 0 ? -p.batt : 0); // day series: − = charging
    // whatever solar is left that minute and went out of the meter (grid − = exporting)
    const toGrid = Math.min(pv - toHome - toBatt, p.grid != null && p.grid < 0 ? -p.grid : 0);
    home += toHome * kwh; batt += toBatt * kwh; grid += toGrid * kwh;
  });
  return { home, batt, grid };
}

// ---------------------------------------------------------------- PANELS
// Is every panel string doing its usual share? (SOLAR-51, mocked with all ten states first.)
// Each string's share of the solar is steady day to day, so a string well below its usual
// share by this time of day, on a day with real sun, is worth naming. Volts, amps and the old
// "check" badge (which lit on empty inputs floating near 1.5 V) are gone.
const PANELS_MIN_KWH = 2;      // below this today, nothing is judged yet
const PANELS_MIN_DAYS = 7;     // days of history before shares mean anything
const PANELS_LOW = 2 / 3;      // today's share under two thirds of usual is "less than usual"

function invName(inv) {
  return inv.alias && inv.alias !== inv.sn ? inv.alias : 'Inverter ' + inv.sn;
}

// The verdict from api_string_health plus the snapshot: which state, the alerts, and per
// inverter what its line says. Pure, so every state can be checked without a screen.
function panelsVerdict(h, snap, now) {
  const tz = (snap.config || {}).timezone;
  const hour = window.plantHour(tz, new Date(now));
  const night = (hour >= 18 || hour < 6) && !(snap.aggregate.pvNow > 20);
  const bySn = Object.fromEntries((h.inverters || []).map(i => [i.sn, i]));
  const used = (h.inverters || []).reduce((n, i) => n + i.strings.length, 0);
  // a silent inverter: offline, or its last reading 20 minutes old while the sun is up
  const silent = snap.inverters.filter(inv => inv.status === 'offline'
    || (!night && inv.readAt && now - inv.readAt > 20 * 60000));
  const alerts = [];
  let compared = 0, skipped = 0;
  const broken = {};
  if (used > 1 && h.historyDays >= PANELS_MIN_DAYS && h.todayKwh >= PANELS_MIN_KWH) {
    (h.inverters || []).forEach(hi => {
      const multi = hi.strings.length >= 2;
      if (!multi && hi.battFull) { skipped++; return; } // a full battery turns the panels down
      hi.strings.forEach(st => {
        const usual = multi ? st.usualInvShare : st.usualPlantShare;
        const today = multi ? st.todayInvShare : st.todayPlantShare;
        if (usual == null || usual < 0.02) return;
        compared++;
        const inv = snap.inverters.find(x => x.sn === hi.sn) || { sn: hi.sn };
        if (st.todayKwh < 0.05) {
          alerts.push({ kind: 'nothing', inv, no: st.no, usual, multi });
          broken[hi.sn] = (broken[hi.sn] || 0) + 1;
        } else if (today != null && today / usual < PANELS_LOW) {
          alerts.push({ kind: 'low', inv, no: st.no, usual, today, multi });
        }
      });
    });
  }
  let state;
  if (used === 0) state = 'none';
  else if (silent.length) state = 'silent';
  else if (used === 1) state = 'single';
  else if (h.historyDays < PANELS_MIN_DAYS) state = 'learning';
  else if (h.todayKwh < PANELS_MIN_KWH) state = night ? 'dull' : 'early';
  else if (alerts.length) state = 'alert';
  else if (!compared && skipped) state = 'unchecked';
  else state = night ? 'resting' : 'normal';
  const lines = snap.inverters.filter(inv => bySn[inv.sn]).map(inv => {
    const n = bySn[inv.sn].strings.length;
    const quiet = silent.includes(inv);
    return {
      sn: inv.sn, name: invName(inv), kwh: quiet ? null : inv.pvToday,
      sub: quiet ? (inv.readAt ? 'No readings since ' + (now - inv.readAt > 36 * 3600e3
          ? new Date(inv.readAt).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) + ', ' : '') + window.fmtTime(new Date(inv.readAt)) : 'No readings')
        : broken[inv.sn] ? (n - broken[inv.sn]) + ' of ' + n + ' strings working'
        : n + (n === 1 ? ' string' : ' strings'),
    };
  });
  return { state, alerts, lines, silent, night };
}

// One day of one reading as a line across the whole day: solar (which needs a reading over
// 20 W to count as made), grid power signed (+ bought, − exported), or the battery's charge
// on a fixed 0-100% scale with the reserve dashed.
// The reading under the pointer shows beside it. As on Live, dragging across the chart with
// a mouse totals the energy between the two times (`sums` names the + and − parts). Callers
// key it by date, so a new day starts with no range.
// `importScale` (Grid): the scale is set by what came in, at least 2 kW, and the side below
// zero is always a third of it, as on an import day; a bigger export is cut off at the bottom,
// and the hover and drag totals still give its real size (SOLAR-72).
function DayLineChart({ points, field, color, label, crop, pct, reserve, empty, sums, importScale }) {
  const [ref, width, height] = useChartSize([220, 300]);
  const [hover, setHover] = React.useState(null);
  const [sel, setSel] = React.useState(null);    // [i0, i1] the selected range
  const [drag, setDrag] = React.useState(null);  // the range while it is being dragged
  const dragRef = React.useRef(null);
  const mobile = width < 560;
  const v = i => points[i][field];
  const has = [];
  points.forEach((p, i) => { if (p[field] != null && (!crop || p[field] > 20)) has.push(i); });
  const hp = hover != null && points[hover] && v(hover) != null ? hover : null;
  let body = null, tip = null;
  if (has.length > 1) {
    const i0 = 0, i1 = points.length - 1;
    const m = { l: mobile ? 32 : 38, r: 12, t: 24, b: 30 };
    const innerW = Math.max(40, width - m.l - m.r), innerH = height - m.t - m.b;
    let dmin = 0, dmax = 0;
    for (let i = i0; i <= i1; i++) { const val = v(i); if (val != null) { dmax = Math.max(dmax, val); dmin = Math.min(dmin, val); } }
    const { lo, hi, ticks } = pct ? { lo: 0, hi: 100, ticks: [0, 25, 50, 75, 100] }
      : importScale ? (() => {
          const up = niceScale(0, Math.max(2000, dmax), 3);
          const step = up.ticks[1] - up.ticks[0];
          const down = step * Math.max(1, Math.round(up.hi / 3 / step));
          const t = [];
          for (let v = -down; v <= up.hi + step / 2; v += step) t.push(Math.round(v));
          return { lo: -down, hi: up.hi, ticks: t };
        })()
      : niceScale(dmin, dmax, 4);
    const clipId = 'dlc-' + field;
    // the x axis is the whole day, 00:00 to 24:00, so today's line stops at the last reading
    // rather than stretching to fill the width
    const t0 = 0, t1 = 1440;
    const x = i => m.l + ((points[i].t - t0) / Math.max(5, t1 - t0)) * innerW;
    const y = val => m.t + innerH - ((val - lo) / (hi - lo)) * innerH;
    // runs of readings; a missing bucket breaks the line
    const runs = [];
    for (let i = i0; i <= i1; i++) {
      if (v(i) == null) { runs.push(null); continue; }
      if (!runs.length || runs[runs.length - 1] == null) runs.push([]);
      runs[runs.length - 1].push(i);
    }
    const gaps = gapRuns(i0, i1, i => v(i) == null);
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
    // drag-to-range is a mouse interaction, as on Live; a tap on a phone just reads a point
    const canRange = !!sums && !mobile;
    const onDown = e => {
      const i = idxAt(e.clientX, e.currentTarget);
      if (!canRange || e.pointerType !== 'mouse') { setHover(i); return; }
      dragRef.current = { i0: i, i1: i }; setSel(null); setHover(null); setDrag({ i0: i, i1: i });
    };
    const onMove = e => {
      const i = idxAt(e.clientX, e.currentTarget);
      if (dragRef.current) { dragRef.current = { ...dragRef.current, i1: i }; setDrag({ ...dragRef.current }); } else setHover(i);
    };
    const onUp = () => {
      const d = dragRef.current; if (!d) return;
      dragRef.current = null; setDrag(null);
      const a = Math.min(d.i0, d.i1), b = Math.max(d.i0, d.i1);
      setSel(b - a >= 1 ? [a, b] : null);
    };
    const band = drag ? [Math.min(drag.i0, drag.i1), Math.max(drag.i0, drag.i1)] : sel;
    body = (
      <svg width={width} height={height} className="chart-svg" role="img" aria-label={label + ' over the day'} style={{ cursor: 'crosshair' }}
        onPointerMove={onMove} onPointerDown={onDown} onPointerUp={onUp}
        onPointerLeave={() => { setHover(null); onUp(); }}>
        <defs><GapHatch /></defs>
        {gaps.map(([a, b]) => <rect key={'gap' + a} x={x(a)} y={m.t} width={x(b) - x(a)} height={innerH} fill="url(#gaphatch)" />)}
        {ticks.map((t, k) => (
          <g key={k}>
            <line x1={m.l} x2={m.l + innerW} y1={y(t)} y2={y(t)} stroke={t === 0 ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.05)'} />
            <text x={m.l - 8} y={y(t) + 3} textAnchor="end" className="ax">{pct ? t : +(t / 1000).toFixed(1)}</text>
          </g>
        ))}
        <text x={m.l - 8} y={m.t - 10} textAnchor="end" className="ax" fillOpacity="0.55">{pct ? '%' : 'kW'}</text>
        {xt.map(t => <text key={t} x={xt5(t)} y={m.t + innerH + 20} textAnchor={t === t1 ? 'end' : t === t0 ? 'start' : 'middle'} className="ax">{HM(t)}</text>)}
        {reserve != null && (
          <g>
            <line x1={m.l} x2={m.l + innerW} y1={y(reserve)} y2={y(reserve)} stroke={color} strokeOpacity="0.55" strokeDasharray="4 4" />
            <text x={m.l + innerW - 4} y={y(reserve) - 6} textAnchor="end" className="ax">reserve {reserve}%</text>
          </g>
        )}
        {band && (
          <g>
            <rect x={x(band[0])} y={m.t} width={Math.max(1, x(band[1]) - x(band[0]))} height={innerH} fill="rgba(255,255,255,0.07)" stroke="rgba(255,255,255,0.4)" strokeDasharray="3 3" />
            <text x={Math.max(m.l + 16, x(band[0]))} y={m.t - 6} textAnchor="middle" className="ax" fillOpacity="0.9">{HM(points[band[0]].t)}</text>
            {band[1] > band[0] && x(band[1]) - x(band[0]) >= 78 && <text x={Math.min(m.l + innerW - 16, x(band[1]))} y={m.t - 6} textAnchor="middle" className="ax" fillOpacity="0.9">{HM(points[band[1]].t)}</text>}
          </g>
        )}
        <clipPath id={clipId}><rect x={m.l} y={m.t - 2} width={innerW} height={innerH + 4} /></clipPath>
        <g clipPath={'url(#' + clipId + ')'}>
          <path d={area} fill={color} fillOpacity="0.14" />
          <path d={line} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" />
        </g>
        {hp != null && !band && (
          <g>
            <line x1={x(hp)} x2={x(hp)} y1={m.t} y2={m.t + innerH} stroke="rgba(255,255,255,0.25)" />
            <circle cx={x(hp)} cy={Math.max(m.t, Math.min(m.t + innerH, y(v(hp))))} r="3" fill={color} stroke="#0b0e12" strokeWidth="1.5" />
          </g>
        )}
      </svg>
    );
    if (sel) {
      // energy between the two times: ∫ power dt, + and − kept apart
      const [a, b] = sel;
      let pos = 0, neg = 0;
      for (let i = a; i <= b; i++) {
        const val = v(i); if (val == null) continue;
        const nx = points[i + 1], dt = (nx && nx.t > points[i].t ? nx.t - points[i].t : 5) / 60;
        if (val > 0) pos += val / 1000 * dt; else neg += -val / 1000 * dt;
      }
      const mins = points[b].t - points[a].t;
      const dur = mins >= 60 ? `${Math.floor(mins / 60)}h ${String(mins % 60).padStart(2, '0')}m` : `${mins}m`;
      tip = (
        <div className="chart-range">
          <div className="cr-head"><span className="tip-time">{HM(points[a].t)} – {HM(points[b].t)} · {dur}</span><button className="cr-x" onClick={() => setSel(null)} aria-label="Clear">×</button></div>
          <div className="tip-row"><span className="tip-dot" style={{ background: color }} /><span className="tip-l">{sums[0]}</span><span className="tip-v mono">{pos.toFixed(2)} kWh</span></div>
          {sums[1] && <div className="tip-row"><span className="tip-dot" style={{ background: color }} /><span className="tip-l">{sums[1]}</span><span className="tip-v mono">{neg.toFixed(2)} kWh</span></div>}
        </div>
      );
    } else if (hp != null && !drag) {
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

// The day with the most `field` in `rows`. Today is still running, so it counts only once
// it has already passed every finished day: its total can only grow, so it is the record.
function bestDay(rows, field, today) {
  const past = rows.filter(r => r.date !== today);
  const best = past.length ? past.reduce((b, r) => ((r[field] || 0) > (b[field] || 0) ? r : b)) : null;
  const now = rows.find(r => r.date === today);
  return now && (now[field] || 0) > (best ? best[field] || 0 : 0) ? now : best;
}

// One reading per day for the last 30 days (solar made, grid bought, battery gave out).
// The biggest day is solid (today too, once it has passed the rest); the bar under the
// pointer brightens and shows its date and total; clicking one opens that day in the chart
// above, whose day is outlined here.
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
  const best = bestDay(rows, field, today);
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
              fill={r === best ? color : isToday ? fill(0.16) : hover === i ? fill(0.7) : fill(0.38)}
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
// A plant that has gone silent isn't collecting today's readings: it has none.
function dayProblem(view, day, points, silent) {
  if (!day) return null;
  if (day.failed) return 'Couldn’t load this day.';
  if (day.approx || !points.length) return view.isToday && !silent ? 'Collecting today’s first readings.' : view.isToday ? 'No readings today.' : 'No readings for this day.';
  return null;
}

// A tab's bars, with today's taking the live total its TODAY tile shows: the bars load once
// a visit, the tile every minute, so today's bar would otherwise freeze where it opened.
function withLiveToday(daily, today, field, live) {
  return (daily || []).filter(r => r.date).map(r => (r.date === today && live != null ? { ...r, [field]: live } : r));
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
  // "▲ 12% vs last month"; a jump the badge shows as kWh reads "▲ 14 kWh more than last month"
  const asKwh = !Number.isFinite(pct) || Math.abs(pct) >= 200;
  const words = asKwh ? (c > p ? ' more than ' : ' less than ') + word : ' vs ' + word;
  return <><TrendBadge pct={pct} delta={c - p} invert={invert} title={'vs ' + word + ', ' + r.days + ' matched days'} />{words}</>;
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
        <SectionTitle>{titled('SOLAR', 'today')}</SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle>{titled('SOLAR', 'last 30 days')}</SectionTitle>
        <window.Skeleton className="bars-skel" h="auto" r={10} />
      </Card>
      <div className="solar-row">
        <window.Skeleton className="wiw" h={150} r={16} />
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
  const hasGrid = feat.hasGrid !== false;
  const hasBatt = feat.hasBattery !== false;
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

  // ---- last 30 days (also the day totals Where it went scales to) ----
  const [daily, loadDaily] = useDaily(refreshKey);

  // ---- the day on the chart ----
  const pick = useDayPicker(earliest, plantToday); // the plant's date, as the totals and bars use
  const { view, dim, day, points, dayWord } = useShownDay(pick, today, refreshKey);
  // A past day with most of 06:00–18:00 missing and no solar in what is there is a logging gap
  const daytime = points.slice(72, 216);
  const gapDay = !view.isToday && daytime.length > 0 && !points.some(p => p.pv != null && p.pv > 20)
    && daytime.filter(p => p.pv == null).length > daytime.length / 2;
  // A silent plant's last figures aren't now: a dash and when they were read.
  const ps = window.plantStatus(snap, Date.now());
  const silent = ps.status === 'offline';
  const noReadings = dayProblem(view, day, points, silent) || (day && gapDay ? 'Readings are missing for most of this day.' : null);
  const peakOf = (pts) => {
    let pk = null;
    (pts || []).forEach(p => { if (p.pv != null && (!pk || p.pv > pk.pv)) pk = p; });
    return pk && pk.pv > 20 ? pk : null;
  };
  const peak = peakOf(points);
  // the Today tile always shows today's peak, whichever day the chart is on, so the tiles
  // keep their height and a scroll to the chart lands where it aimed
  const todayPeak = peakOf(today && !today.approx ? today.points : null);
  const est = React.useMemo(() => solarSplit(points), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  // The day's solar as the tiles and bars show it (SunSynk's own counter). The 5-minute
  // readings give the shares; scaling them to this total makes the card add up to the TODAY
  // tile. Tested 30 Sep–5 Oct: the readings land within ~1 kWh of it once the grid is
  // counted, so the scale moves each part about 2% at most (SOLAR-49).
  const estTotal = est.home + est.batt + est.grid;
  const dayRow = !view.isToday && (daily || []).find(r => r.date === pick.date);
  const madeKwh = view.isToday ? a.pvToday : (dayRow && dayRow.pv != null ? dayRow.pv : day && day.totals && day.totals.pv);
  const k = madeKwh > 0 && estTotal > 0 ? madeKwh / estTotal : 1;
  // Round each part to the 0.1 kWh shown, then give any rounding gap to the largest part, so the
  // three figures on screen add up to the total exactly (16.4, not 6.8 + 8.9 + 0.8 = 16.5).
  const tenths = (v) => Math.round(v * 10) / 10;
  const split = { home: tenths(est.home * k), batt: tenths(est.batt * k), grid: tenths(est.grid * k) };
  const big = ['home', 'batt', 'grid'].reduce((m, x) => (split[x] > split[m] ? x : m), 'home');
  split[big] = tenths(split[big] + tenths(est.home * k + est.batt * k + est.grid * k) - (split.home + split.batt + split.grid));
  const splitTotal = split.home + split.batt + split.grid;
  // A destination is shown only once it holds something: a 0.0 kWh column would be a
  // zero-width segment under a full-width label, and "the battery got none of it" is said
  // better by its absence than by a zero.
  const dests = [['Home', split.home, CC.load, true], ['Battery', split.batt, CC.batt, hasBatt], ['Grid', split.grid, CC.grid, hasGrid]]
    .filter(d => d[3] && d[1] >= 0.05);
  const destPct = (v) => v / splitTotal * 100;
  // The percentages were a permanent column until 2026-09-19; the bar says the same thing,
  // so they moved to the bar's hover title rather than being printed twice. The label row
  // below is aria-hidden, so the bar's own label has to carry the kWh as well as the
  // shares, or a screen reader hears the proportions and never the figures.
  const destTitle = dests.map(d => d[0] + ' ' + Math.round(destPct(d[1])) + '%').join(', ');
  const destLabel = dests.map(d => d[0] + ' ' + fmtKwh(d[1]) + ', ' + Math.round(destPct(d[1])) + '%').join('; ');
  // No money on this card. It answers one question — where the day's sun went — and the parts
  // sum to the day's solar, grid included (left out until SOLAR-49, so they didn't). Est. saved is (load - import) x rate, which is the electricity the
  // house USED and did not buy; it cannot divide into a generation split, so beside these rows
  // it reads as a third unexplained number. It lives on Live, where Home and Imported sit on
  // the same strip and the subtraction is on screen, and on the Grid tab, which spells today's
  // sum out in a sentence. Rejected here on 2026-09-19 after trying it three ways.

  // ---- last 30 days ----
  const bars = withLiveToday(daily, plantToday, 'pv', a.pvToday);
  const best = bestDay(bars, 'pv', plantToday);
  const openDay = (d) => { pick.setDate(d); scrollToDay('solar-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="SOLAR NOW" value={silent ? '—' : nowN} unit={silent ? '' : nowU} accent={CC.pv}
          sub={silent ? 'Last reading ' + readAgo(ps.last.getTime(), Date.now()) : kwp > 0 ? <><b>{Math.round(a.pvNow / 10 / kwp)}%</b> of your {kwp} kW of panels</>
            : <button type="button" className="mini-link" onClick={() => onOpenSettings('plant')}>Set panel capacity</button>} />
        {tile('TODAY', a.pvToday, todayPeak ? <>Peak <b>{fmtPower(todayPeak.pv)}</b> at <b>{HM(todayPeak.t)}</b></> : null)}
        {tile('THIS WEEK', tot.week, trend('week', 2, 'last week'))}
        {tile('THIS MONTH', tot.month, trend('month', 3, 'last month'))}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="solar-day">
        <SectionTitle right={day && !noReadings && !view.isToday && peak ? <>Peak <b>{fmtPower(peak.pv)}</b> at <b>{HM(peak.t)}</b></> : null}>
          {titled('SOLAR', dayWord)}
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest} />
        {!day ? <window.Skeleton className="chart-skel" h="auto" r={12} />
          : <div {...dim}><DayLineChart key={pick.date} points={noReadings ? [] : points} field="pv" color={CC.pv} label="Solar" crop sums={['Made']} empty={noReadings || (view.isToday ? 'No solar yet today.' : 'No solar on this day.')} /></div>}
      </Card>

      <Card>
        <SectionTitle right={best ? <>Best <b>{fmtKwh(best.pv)}</b> on {shortDate(best.date)}</> : null}>
          {titled('SOLAR', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <window.Skeleton className="bars-skel" h="auto" r={10} />
          : bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
          : <DaysBars rows={bars} field="pv" color={CC.pv} rgb="61,220,132" word="Solar" label="Solar per day for the last 30 days"
              today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />}
      </Card>

      {/* Where it went: a plain card like the rest of the page (SOLAR-74). The day's solar in the
          header, the share bar, and each part's kWh with its name under it, in its own colour. */}
      <div className="solar-row">
        <Card className="wiw" {...dim}>
          <SectionTitle right={day && !noReadings && splitTotal >= 0.05 ? <>Made <b>{fmtKwh(splitTotal)}</b></> : null}>
            {titled('WHERE IT WENT', dayWord)}
            <window.InfoDot text={'Solar counts to the house first, then the battery, then the grid.'} />
          </SectionTitle>
          {!day ? <window.Skeleton h={62} r={8} />
            : noReadings || splitTotal < 0.05 ? <div className="solar-note">{noReadings || (view.isToday ? 'No solar yet today.' : 'No solar on this day.')}</div>
            : <>
              <div className="fbox-bar" role="img" title={destTitle} aria-label={destLabel}>
                {dests.map(([l, v, c]) => <i key={l} style={{ flexGrow: v, background: c }} />)}
              </div>
              <div className="wiw-figs" aria-hidden="true">
                {dests.map(([l, v, c]) => {
                  const [n, u] = EP(v);
                  return <div key={l}><b style={{ color: c }}>{n}<span className="u">{u}</span></b><span>{l}</span></div>;
                })}
              </div>
            </>}
        </Card>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- GRID
// Built like Solar: what was bought (now, today, week, month, year, lifetime), the day's grid
// power both ways, and the last 30 days. The supply's voltage and frequency moved to
// Equipment (SOLAR-71).

// A connected plant is assumed until the snapshot says otherwise.
function GridSkeleton() {
  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        {['GRID NOW', 'TODAY', 'THIS WEEK', 'THIS MONTH', 'THIS YEAR', 'LIFETIME'].map(l => <StatTile key={l} label={l} loading sub={NBSP} />)}
      </div>
      <Card>
        <SectionTitle>{titled('GRID', 'today')}</SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle>{titled('IMPORTED', 'last 30 days')}</SectionTitle>
        <window.Skeleton className="bars-skel" h="auto" r={10} />
      </Card>
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
          <StatTile label="GRID" value="Off" unit="" accent={CC.grid} sub="Not connected" />
          <StatTile label="INDEPENDENCE" value={selfSuff} unit="%" accent={CC.soc} bar={selfSuff} sub={NBSP} />
          <StatTile label="USED TODAY" value={window.fmtEnergyParts(a.loadToday)[0]} unit={' ' + window.fmtEnergyParts(a.loadToday)[1]} accent={CC.load} sub={NBSP} />
        </div>
        <Card>
          <SectionTitle>OFF-GRID</SectionTitle>
          <div className="field-note" style={{ marginTop: 0 }}>No grid for a day or more. Figures come back when the inverter sees the grid again.</div>
        </Card>
      </div>
    );
  }
  return <GridBody {...props} />;
}

function GridBody({ snap, energy, onNeedEnergy, today, refreshKey, onOpenSettings }) {
  const a = snap.aggregate;
  const cfg = snap.config || {};
  const tz = cfg.timezone;
  const plantToday = plantDateStr(tz);
  const sells = (cfg.tariffExport ?? 0) > 0; // same rule as the Overview tile: only plants paid for export
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
  // signed as the chart is: + bought, − exported (a small backflow reads 0)
  const [nowN, nowU] = fmtPowerParts(exporting || a.gridPower > 5 ? a.gridPower : 0);
  // Presence is mains voltage, not usage: nothing is bought on a sunny afternoon with the
  // grid live, and a blackout reads 0 W too.
  const nowSub = a.gridPresent === false ? <span style={{ color: CC.load }}>The grid is off</span>
    : exporting ? 'Exporting'
    : a.gridPower > 5 ? 'Importing' : 'Not importing';
  const importPeak = (pts) => {
    let pk = null;
    (pts || []).forEach(p => { if (p.grid != null && p.grid > 50 && (!pk || p.grid > pk.grid)) pk = p; });
    return pk;
  };
  const todayPeak = importPeak(today && !today.approx ? today.points : null);
  // A silent plant's last figures aren't now: a dash and when they were read.
  const ps = window.plantStatus(snap, Date.now());
  const silent = ps.status === 'offline';

  // ---- the day on the chart: grid power signed, + bought and − exported ----
  const pick = useDayPicker(earliest, plantToday);
  const { view, dim, day, points, dayWord } = useShownDay(pick, today, refreshKey);
  const noReadings = dayProblem(view, day, points, silent);
  const peak = importPeak(points);
  const flows = React.useMemo(() => {
    let imp = 0, exp = 0;
    points.forEach(p => { if (p.grid != null) { if (p.grid > 0) imp += p.grid * 5 / 60 / 1000; else exp += -p.grid * 5 / 60 / 1000; } });
    return { imp, exp };
  }, [day]); // eslint-disable-line react-hooks/exhaustive-deps

  // ---- last 30 days ----
  const [daily, loadDaily] = useDaily(refreshKey);
  const bars = withLiveToday(daily, plantToday, 'imp', a.gridFromToday);
  const most = bestDay(bars, 'imp', plantToday);
  const openDay = (d) => { pick.setDate(d); scrollToDay('grid-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="GRID NOW" value={silent ? '—' : nowN} unit={silent ? '' : nowU} accent={CC.grid} sub={silent ? 'Last reading ' + readAgo(ps.last.getTime(), Date.now()) : nowSub} />
        {tile('TODAY', a.gridFromToday, sells ? <>Exported <b>{fmtKwh(a.gridToToday)}</b></> : todayPeak ? <>Peak <b>{fmtPower(todayPeak.grid)}</b> at <b>{HM(todayPeak.t)}</b></> : null)}
        {tile('THIS WEEK', tot.week, trend('week', 2, 'last week'))}
        {tile('THIS MONTH', tot.month, trend('month', 3, 'last month'))}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="grid-day">
        <SectionTitle right={day && !noReadings && !view.isToday ? <>Imported <b>{fmtKwh(flows.imp)}</b>{flows.exp >= 0.05 && <>, exported <b>{fmtKwh(flows.exp)}</b></>}</> : null}>
          {titled('GRID', dayWord)}
          <window.InfoDot text={'Above the line is power imported from the grid; below it is power exported.'} />
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest} />
        {!day ? <window.Skeleton className="chart-skel" h="auto" r={12} />
          : <div {...dim}><DayLineChart key={pick.date} points={noReadings ? [] : points} field="grid" color={CC.grid} label="Grid"
              sums={['Imported', 'Exported']} importScale empty={noReadings || 'No grid readings for this day.'} /></div>}
      </Card>

      <Card>
        <SectionTitle right={most && most.imp > 0 ? <>Most <b>{fmtKwh(most.imp)}</b> on {shortDate(most.date)}</> : null}>
          {titled('IMPORTED', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <window.Skeleton className="bars-skel" h="auto" r={10} />
          : bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
          : <DaysBars rows={bars} field="imp" color={CC.grid} rgb="250,204,21" word="Imported" label="Energy imported from the grid per day for the last 30 days"
              today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />}
      </Card>
    </div>
  );
}

// ---------------------------------------------------------------- EQUIPMENT
// The page id stays `inverters` so saved links and preferences keep working; it reads
// "Equipment" (SOLAR-52). Built for a home user (SOLAR-73, SOLAR-75): one headline says
// whether anything needs a look and a coral-edged card per problem says what to do. Under
// it, Simple (a tile each for panels, battery and inverters: one figure, one word) or
// Detailed (each panel string against its usual, the battery against its reserve, a tile
// per inverter, spec sheets and the two day charts). The choice is the viewer's, kept.

function InvertersSkeleton() {
  return (
    <div className="stack">
      <SectionTitle>EQUIPMENT</SectionTitle>
      <window.Skeleton h={56} r={12} />
      <div className="eq-tiles">
        <window.Skeleton h={120} r={16} />
        <window.Skeleton h={120} r={16} />
        <window.Skeleton h={120} r={16} />
      </div>
    </div>
  );
}

// How long ago a reading was, the way the cards say it.
const readAgo = (t, now) => now - t > 36 * 3600e3
  ? new Date(t).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) + ', ' + window.fmtTime(new Date(t))
  : window.fmtTime(new Date(t));
const kwh1 = (x) => (Math.round(x * 10) / 10).toFixed(1);
const EQ_FOLD = 6; // strings shown per inverter before "Show all"

// Everything both views read: who is quiet, the problems, the battery's checks and today's
// solar as it may be shown. Pure, so every state can be checked without a screen.
function equipmentState(snap, health, now) {
  const feat = snap.features || {};
  const a = snap.aggregate;
  const tz = (snap.config || {}).timezone;
  const hasBatt = feat.hasBattery !== false, hasGrid = feat.hasGrid !== false;
  const invs = snap.inverters;
  // an inverter offline, or quiet for 30 minutes (one here uploads every 5)
  const quiet = invs.filter(inv => inv.status === 'offline' || (inv.readAt && now - inv.readAt > 30 * 60000));
  const allQuiet = quiet.length > 0 && quiet.length === invs.length;
  const reads = invs.map(i => i.readAt).filter(Boolean);
  const lastAt = reads.length ? Math.max(...reads) : null;
  const since = t => t ? 'Since ' + readAgo(t, now) : '';
  const verdict = health && !allQuiet ? panelsVerdict(health, snap, now) : null;
  const hour = window.plantHour(tz, new Date(now));
  const night = verdict ? verdict.night : (hour >= 18 || hour < 6) && !(a.pvNow > 20);

  const issues = [];
  // The whole plant gone quiet is one problem, not one per inverter. With the grid down at
  // the last reading the router has likely lost power too, so that comes first.
  if (allQuiet) {
    const check = invs.length === 1 ? 'check the inverter is on and its Wi-Fi dongle shows a light.' : 'check the inverters are on and each Wi-Fi dongle shows a light.';
    issues.push({ title: 'Nothing is reporting', since: since(lastAt),
      todo: hasGrid && a.gridPresent === false
        ? 'The grid was off at the last reading, so your Wi-Fi may be off too. If the power is back, ' + check
        : check[0].toUpperCase() + check.slice(1) });
  } else {
    quiet.forEach(inv => issues.push({ title: invName(inv) + ' isn’t reporting', since: since(inv.readAt), todo: 'Check it is on and its Wi-Fi dongle shows a light.' }));
  }
  if (verdict && verdict.state === 'alert') verdict.alerts.forEach(x => issues.push({
    string: x.kind,
    title: invName(x.inv) + ', string ' + x.no + (x.kind === 'nothing' ? ' made nothing today' : ' is making less than usual'),
    todo: x.kind === 'nothing' ? 'Check its breaker or isolator.' : 'Check for shade, dirt or a tripped breaker.' }));
  // Battery checks read only inverters still reporting; a stale reading proves nothing.
  const withBatt = invs.filter(i => i.numberOfBatteries > 0 || i.battSoc > 0);
  const liveBatt = withBatt.filter(i => !quiet.includes(i));
  const battStale = hasBatt && withBatt.length > 0 && !liveBatt.length;
  const battAt = battStale ? Math.max(0, ...withBatt.map(i => i.readAt || 0)) || null : null;
  const temps = liveBatt.map(i => cleanTemp(i.battTemp)).filter(t => t != null);
  const battTemp = temps.length ? Math.max(...temps) : null;
  const badSensor = hasBatt && liveBatt.some(i => cleanTemp(i.battTemp) == null);
  const hot = hasBatt && battTemp != null && battTemp > 45;
  if (badSensor) issues.push({ title: 'A battery temperature sensor isn’t reading', todo: 'Mention it at the battery’s next service.' });
  if (hot) issues.push({ title: 'The battery is hot, ' + Math.round(battTemp) + ' °C', todo: 'Make sure air can move around it.' });

  // Today's solar: as of the last reading when the plant is quiet, none when that was another day.
  const oldDay = allQuiet && (!lastAt || plantDateStr(tz, new Date(lastAt)) !== plantDateStr(tz, new Date(now)));
  const pvParts = oldDay ? ['—', ''] : window.fmtEnergyParts(a.pvToday);
  const pvSub = oldDay ? 'No readings today' : allQuiet ? 'today, by ' + window.fmtTime(new Date(lastAt)) : night ? 'made today' : 'so far today';

  return { a, tz, hasBatt, hasGrid, invs, quiet, allQuiet, lastAt, verdict, night, issues,
    withBatt, battStale, battAt, battTemp, badSensor, hot, shared: feat.banks === 'shared', pvParts, pvSub };
}

// Simple names no strings: every string problem folds into one card about the panels.
function simpleIssues(issues) {
  const strs = issues.filter(x => x.string);
  if (!strs.length) return issues;
  const nothing = strs.every(x => x.string === 'nothing');
  const one = { title: nothing ? 'Some panels made nothing today' : 'Some panels are making less than usual',
    todo: nothing ? 'Check the breaker or isolator for your panels.' : 'Check for shade, dirt or a tripped breaker.', since: nothing ? '' : 'Today' };
  let placed = false;
  return issues.flatMap(x => !x.string ? [x] : placed ? [] : (placed = true, [one]));
}

function EqTile({ label, state, value, unit, sub, color, stale, word }) {
  return (
    <section className={'card eq-tile' + (stale ? ' stale' : '')} aria-label={label}>
      <div className="eq-tile-fig">
        <div className={'eq-fig' + (word ? ' word' : ' mono')} style={{ color }}>{value}{unit && <span className="u">{unit}</span>}</div>
        {sub && <div className="eq-fig-sub">{sub}</div>}
      </div>
      <div className="eq-tile-text">
        <span className="eq-tile-label">{label}</span>
        <span className={'eq-tile-state ' + state[0]}><i className={'eq-dot sm ' + state[0]} />{state[1]}</span>
      </div>
    </section>
  );
}

function EquipmentSimple({ st, now }) {
  const { a, verdict } = st;
  const last = t => t ? 'Last reading ' + readAgo(t, now) : 'Not reporting';
  const alerts = verdict && verdict.state === 'alert' ? verdict.alerts : [];
  const pvState = st.allQuiet ? ['stale', last(st.lastAt)]
    : st.quiet.length ? ['stale', 'Not all reporting']
    : alerts.length ? ['warn', 'Needs a look']
    : st.night ? ['ok', 'Resting for the night']
    : ['ok', 'Working'];
  const battState = st.battStale ? ['stale', last(st.battAt)]
    : st.hot || st.badSensor ? ['warn', 'Needs a look']
    : ['ok', a.battOut > 5 ? 'Powering the house' : a.battOut < -5 ? 'Charging' : 'Resting'];
  const n = st.invs.length, live = n - st.quiet.length;
  const invState = !st.quiet.length ? ['ok', 'Working']
    : st.allQuiet ? ['stale', last(st.lastAt)]
    : ['warn', 'Needs a look'];
  const invValue = !st.quiet.length ? (n === 1 ? 'On' : 'All on') : n === 1 ? '—' : live + ' of ' + n;
  const invSub = st.quiet.length ? (n === 1 ? 'not reporting' : 'reporting') : n === 2 ? st.invs.map(invName).join(' and ') : n > 2 ? n + ' inverters' : '';
  return (
    <div className="eq-tiles">
      <EqTile label="Solar panels" state={pvState} value={st.pvParts[0]} unit={st.pvParts[1]} sub={st.pvSub} color={CC.pv} stale={st.allQuiet} />
      {st.hasBatt && <EqTile label="Battery" state={battState} value={a.battSoc} unit="%" sub="charged" color={CC.batt} stale={st.battStale} />}
      <EqTile label={n === 1 ? 'Inverter' : 'Inverters'} state={invState} value={invValue} sub={invSub} word
        color={!st.quiet.length ? CC.pv : st.allQuiet ? 'var(--dim)' : 'var(--warn)'} />
    </div>
  );
}

// Panels in detail: one bar per string, grouped under its inverter, with a mark where it
// usually is by this time. The mark shows only where panelsVerdict really compared.
function EqPanelsCard({ st, snap, health, now }) {
  const [open, setOpen] = React.useState({}); // inverters whose long string list is unfolded
  const v = st.verdict;
  const hi = v && health ? health.inverters || [] : [];
  const compared = v && (v.state === 'normal' || v.state === 'alert' || v.state === 'resting');
  const groups = st.allQuiet || (v && (v.state === 'single' || v.state === 'none')) ? []
    : snap.inverters.filter(inv => st.quiet.includes(inv) || hi.some(h => h.sn === inv.sn)).map(inv => {
      if (st.quiet.includes(inv)) return { inv, quiet: true, rows: [] };
      const h = hi.find(x => x.sn === inv.sn);
      const multi = h.strings.length >= 2;
      const invKwh = h.strings.reduce((n, s) => n + (s.todayKwh || 0), 0);
      const rows = h.strings.map(s => {
        const share = multi ? s.usualInvShare : s.usualPlantShare;
        const usual = compared && share != null && share >= 0.02 && (multi || !h.battFull) ? share * (multi ? invKwh : health.todayKwh) : null;
        return { no: s.no, kwh: s.todayKwh || 0, usual, alert: v.alerts.find(x => x.inv.sn === inv.sn && x.no === s.no) };
      });
      return { inv, rows, kwh: invKwh };
    });
  let max = 0;
  groups.forEach(g => g.rows.forEach(r => { max = Math.max(max, r.kwh, r.usual || 0); }));
  const pct = x => (max > 0 ? Math.min(100, x / max * 100) : 0) + '%';
  const anyMark = groups.some(g => g.rows.some(r => r.usual != null));
  const toGo = PANELS_MIN_DAYS - ((health && health.historyDays) || 0);
  const note = v && {
    single: 'One string, nothing to compare it with.',
    learning: 'Checks start in ' + toGo + (toGo === 1 ? ' day.' : ' days.'),
    early: 'Checked once the panels have made ' + PANELS_MIN_KWH + ' kWh today.',
    dull: 'Not enough sun today to check.',
    unchecked: 'Battery full, panels turned down. Not checked today.',
  }[v.state];
  return (
    <Card className="eq-card">
      <SectionTitle>SOLAR PANELS</SectionTitle>
      <div className={'eq-big mono' + (st.allQuiet ? ' stale' : '')} style={{ color: CC.pv }}>{st.pvParts[0]}{st.pvParts[1] && <span className="u">{st.pvParts[1]}</span>}</div>
      <div className="eq-big-sub">{st.pvSub}</div>
      {groups.length > 0 && (
        <div className="eq-groups">
          {groups.map(g => {
            const folded = g.rows.length > EQ_FOLD && !open[g.inv.sn];
            return (
              <div className="eq-group" key={g.inv.sn}>
                {(groups.length > 1 || g.quiet) && (
                  <div className="eq-group-head">
                    <span>{invName(g.inv)}</span>
                    <span className={'mono' + (g.quiet ? ' warn' : '')}>{g.quiet ? (g.inv.readAt ? 'Not reporting since ' + readAgo(g.inv.readAt, now) : 'Not reporting') : fmtKwh(g.kwh)}</span>
                  </div>
                )}
                {(folded ? g.rows.slice(0, EQ_FOLD) : g.rows).map(r => (
                  <div className={'eq-string' + (r.alert ? ' weak' : '')} key={r.no}>
                    <span className="eq-string-name">String {r.no}</span>
                    <span className="eq-bar"><i style={{ width: pct(r.kwh) }} />{r.usual != null && <b style={{ left: pct(r.usual) }} />}</span>
                    <span className="eq-string-kwh mono">{kwh1(r.kwh)}</span>
                    {r.alert && <span className="eq-string-why">{r.alert.kind === 'nothing' ? 'Made nothing today' : 'Usually ' + kwh1(r.usual) + ' kWh by now'}</span>}
                  </div>
                ))}
                {folded && <button type="button" className="mini-link eq-fold" onClick={() => setOpen(o => Object.assign({}, o, { [g.inv.sn]: true }))}>Show all {g.rows.length} strings</button>}
              </div>
            );
          })}
        </div>
      )}
      {anyMark && <div className="eq-legend"><b />usual by now</div>}
      {note && <div className="eq-note">{note}</div>}
    </Card>
  );
}

// The battery against its reserve, then what it is doing and what it holds. Temperature
// shows only when it is worth a look.
function EqBatteryCard({ st, snap, now }) {
  const { a } = st;
  const cfg = snap.config || {};
  const reserve = cfg.reserve ?? 20;
  const cap = cfg.battCapacity;
  const rows = [];
  if (st.battStale) rows.push(['Last reading', st.battAt ? readAgo(st.battAt, now) : '—']);
  else {
    rows.push(['Now', a.battOut > 5 ? 'Powering the house at ' + fmtPower(a.battOut) : a.battOut < -5 ? 'Charging at ' + fmtPower(-a.battOut) : 'Resting']);
    if (cap > 0) rows.push(['Stored', kwh1(a.battSoc * cap / 100) + ' of ' + fmtKwh(cap)]);
    if (st.badSensor) rows.push(['Temperature', 'Sensor not reading', true]);
    else if (st.battTemp != null && (st.battTemp > 45 || st.battTemp < 5)) rows.push(['Temperature', Math.round(st.battTemp) + ' °C, ' + (st.battTemp > 45 ? 'hot' : 'cold'), st.battTemp > 45]);
  }
  const packs = st.shared ? Math.min(1, st.withBatt.length) : st.withBatt.length;
  const modules = st.shared ? Math.max(0, ...st.withBatt.map(i => i.numberOfBatteries || 0)) : st.withBatt.reduce((n, i) => n + (i.numberOfBatteries || 0), 0);
  const soc = Math.max(0, Math.min(100, a.battSoc || 0));
  return (
    <Card className="eq-card">
      <SectionTitle>BATTERY</SectionTitle>
      <div className={'eq-big mono' + (st.battStale ? ' stale' : '')} style={{ color: CC.batt }}>{a.battSoc}<span className="u">%</span></div>
      <div className={'eq-meter' + (st.battStale ? ' stale' : '')}><i style={{ width: soc + '%', background: CC.batt }} /><b style={{ left: reserve + '%' }} /></div>
      <div className="eq-meter-scale"><span style={reserve > 60 ? { right: (100 - reserve) + '%' } : { left: reserve + '%' }}>{reserve}% reserve</span></div>
      <dl className="eq-rows">
        {rows.map(([l, val, warn]) => <div key={l}><dt>{l}</dt><dd className={warn ? 'warn' : ''}>{val}</dd></div>)}
      </dl>
      <div className="eq-foot">{packs} {packs === 1 ? 'pack' : 'packs'} · {modules} {modules === 1 ? 'battery' : 'batteries'}</div>
    </Card>
  );
}

function EqInvertersCard({ st, now }) {
  return (
    <Card className="eq-card">
      <SectionTitle>{st.invs.length === 1 ? 'INVERTER' : 'INVERTERS'}</SectionTitle>
      <div className={'eq-inv-tiles' + (st.invs.length === 1 ? ' one' : '')}>
        {st.invs.map(inv => {
          const down = st.quiet.includes(inv);
          const [n, u] = down ? ['—', ''] : fmtPowerParts(inv.pvNow);
          return (
            <div className={'eq-inv' + (down ? ' down' : '')} key={inv.sn}>
              <div className="eq-inv-name">{invName(inv)}</div>
              <div className={'eq-inv-state' + (down ? ' warn' : '')}><i className={'eq-dot sm ' + (down ? 'warn' : 'ok')} />{down ? 'Not reporting' : 'On'}</div>
              <div className="eq-inv-now mono" style={{ color: down ? 'var(--dim)' : CC.pv }}>{n}{u && <span className="u">{u}</span>}</div>
              <div className="eq-inv-cap">solar now</div>
              <div className="eq-inv-today"><span>Today</span><span className="mono">{fmtKwh(inv.pvToday)}</span></div>
              <div className="eq-inv-foot">{down ? (inv.readAt ? 'Since ' + readAgo(inv.readAt, now) : NBSP) : inv.readAt ? 'Last reading ' + window.fmtAgo(new Date(inv.readAt), now) : NBSP}</div>
            </div>
          );
        })}
      </div>
    </Card>
  );
}

// One plain sheet per inverter: what it is, and its battery pack as the inverter reads it.
// A shared pack shows once, under the first inverter that reads it.
function EqSpecCard({ inv, st, now }) {
  const down = st.quiet.includes(inv);
  const rows = [
    ['Model', inv.model], ['Serial number', inv.sn], ['Firmware', inv.soft],
    ['Last reading', inv.readAt ? readAgo(inv.readAt, now) : '—'],
  ];
  const packs = [];
  const reads = inv.numberOfBatteries > 0 || inv.battSoc > 0;
  if (st.hasBatt && reads && (!st.shared || inv === st.withBatt[0])) {
    const label = st.shared ? 'Battery pack, shared' : inv.bank2 ? 'Battery pack 1' : 'Battery pack';
    packs.push({ label, soc: inv.battSoc, v: inv.battVolt, t: cleanTemp(inv.battTemp), n: inv.numberOfBatteries });
    if (inv.bank2) packs.push({ label: 'Battery pack 2', soc: inv.bank2.soc, v: inv.bank2.voltage, t: cleanTemp(inv.bank2.temperature), n: null });
  }
  return (
    <Card className="eq-spec">
      <div className="eq-spec-head">
        <span>{invName(inv)}</span>
        <span className={'eq-inv-state' + (down ? ' warn' : '')}><i className={'eq-dot sm ' + (down ? 'warn' : 'ok')} />{down ? 'Not reporting' : 'On'}</span>
      </div>
      <dl className="eq-spec-rows">
        {rows.map(([l, val]) => <div key={l}><dt>{l}</dt><dd className="mono">{val}</dd></div>)}
      </dl>
      {packs.map(p => (
        <div key={p.label}>
          <div className="eq-label eq-pack-label">{p.label}</div>
          <div className="eq-pack">
            <div><b className="mono">{p.soc}%</b><span>Charge</span></div>
            <div><b className="mono">{p.v != null ? p.v.toFixed(1) + ' V' : '—'}</b><span>Voltage</span></div>
            <div><b className="mono">{p.t != null ? Math.round(p.t) + ' °C' : '—'}</b><span>{p.t != null ? 'Temperature' : 'Sensor not reading'}</span></div>
            {p.n != null && <div><b className="mono">{p.n}</b><span>{p.n === 1 ? 'Battery' : 'Batteries'}</span></div>}
          </div>
        </div>
      ))}
    </Card>
  );
}

function EquipmentDetailed({ st, snap, health, now, refreshKey }) {
  return (
    <>
      <div className={'eq-cards' + (st.hasBatt ? '' : ' two')}>
        <EqPanelsCard st={st} snap={snap} health={health} now={now} />
        {st.hasBatt && <EqBatteryCard st={st} snap={snap} now={now} />}
        <EqInvertersCard st={st} now={now} />
      </div>
      <div className="eq-specs">
        {snap.inverters.map(inv => <EqSpecCard key={inv.sn} inv={inv} st={st} now={now} />)}
      </div>
      {/* inverter temperatures over a day (SunSynk history; nothing live reports them) */}
      <Card className="chart-card">
        <SectionTitle>TEMPERATURE</SectionTitle>
        <window.InverterHistoryChart kind="temp" refreshKey={refreshKey} />
      </Card>
      {/* The supply over a day: voltage at each inverter's AC terminal and the grid's frequency,
          from SunSynk's history (two months back). A blackout shows as a shaded band; the
          terminal keeps reading the inverter's own 230 V then, so only the 0 Hz gives it away.
          Off-grid, the inverter's own output takes its place. */}
      <Card className="chart-card">
        <SectionTitle>{st.hasGrid ? 'GRID SUPPLY' : 'OUTPUT'}</SectionTitle>
        <window.InverterHistoryChart kind={st.hasGrid ? 'ac' : 'output'} refreshKey={refreshKey} />
      </Card>
    </>
  );
}

function InvertersTab({ snap, refreshKey }) {
  const now = window.useNow(15000);
  // Panels: today's share of each string against its usual share by this time (0076). Asked on
  // open, on refresh and every 10 minutes; the shares move slowly.
  const [health, setHealth] = React.useState(null);
  React.useEffect(() => {
    const load = () => window.fetchStringHealth().then(setHealth).catch(() => setHealth(false));
    load();
    const t = setInterval(load, 600000);
    return () => clearInterval(t);
  }, [refreshKey]);
  // Simple or Detailed is this viewer's own choice, kept across visits
  const [view, setView] = React.useState(() => { try { return localStorage.getItem('synsynk.eqView') === 'detailed' ? 'detailed' : 'simple'; } catch (e) { return 'simple'; } });
  const pickView = (v) => { setView(v); try { localStorage.setItem('synsynk.eqView', v); } catch (e) {} };

  const st = equipmentState(snap, health, now);
  const simple = view === 'simple';
  const issues = simple ? simpleIssues(st.issues) : st.issues;
  const n = issues.length;
  const head = n === 0 ? 'Everything is working' : n === 1 ? '1 thing needs a look' : n + ' things need a look';

  return (
    <div className="stack eq-tab">
      <div className="eq-top">
        <span className="eq-label">Equipment</span>
        <Segmented size="sm" value={view} onChange={pickView} options={[{ value: 'simple', label: 'Simple' }, { value: 'detailed', label: 'Detailed' }]} />
      </div>

      {/* the one place that says whether things are OK */}
      <section className="eq-status" aria-label="Status">
        <div className="eq-head"><i className={'eq-dot ' + (n ? 'warn' : 'ok')} />{head}</div>
        {n === 0 && st.lastAt && <div className="eq-head-sub">Last reading {window.fmtAgo(new Date(st.lastAt), now)}</div>}
      </section>
      {n > 0 && (
        <div className="eq-problems">
          {issues.map(x => (
            <div className="eq-problem" key={x.title}>
              <div className="eq-problem-head"><b>{x.title}</b>{x.since && <span className="mono">{x.since}</span>}</div>
              <p>{x.todo}</p>
            </div>
          ))}
        </div>
      )}

      {simple ? <EquipmentSimple st={st} now={now} />
        : <EquipmentDetailed st={st} snap={snap} health={health} now={now} refreshKey={refreshKey} />}
    </div>
  );
}

// The shape to hold while the first snapshot is on its way. Trends and Settings never wait
// on one — App draws those for real — so they have no skeleton here.
function TabSkeleton({ tab }) {
  return tab === 'solar' ? <SolarSkeleton />
    : tab === 'grid' ? <GridSkeleton />
    : tab === 'inverters' ? <InvertersSkeleton />
    : <LiveSkeleton />;
}

// ---------------------------------------------------------------- SETTINGS / ACCOUNT
// Settings is the plant on screen (Plant, Battery, Tariff) and Account is the person
// (SunSynk logins, Pages, Delete account), each one scrolling page (SOLAR-13). A section
// is a title and note on the left with its card on the right; stacked on a phone.

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

// { id, done } when a section should flash once on arrival (e.g. from "Set your rate");
// it scrolls itself into view first.
const SettingsFlash = React.createContext(null);

function SettingsSection({ id, title, note, children }) {
  const flash = React.useContext(SettingsFlash);
  const flashing = flash && flash.id === id;
  const ref = React.useRef(null);
  React.useEffect(() => { if (flashing) ref.current?.scrollIntoView({ block: 'start' }); }, [flashing]);
  return (
    <section id={'settings-' + id} className="sec" ref={ref} aria-labelledby={'settings-' + id + '-t'}>
      <div className="sec-intro">
        <h2 id={'settings-' + id + '-t'} className="sset-title">{title}</h2>
        {note && <p className="sset-note">{note}</p>}
      </div>
      <div className={'sset' + (flashing ? ' sset-flash' : '')}
           onAnimationEnd={flashing ? (e) => { if (e.target === e.currentTarget) flash.done(); } : undefined}>
        <div className="sset-body">{children}</div>
      </div>
    </section>
  );
}

// The signed-in user's SunSynk logins: one row each with its plants, a reconnect in
// place when the token has died, and a remove. Adding or removing a login changes
// which plants the app can see, so the app reloads its plant list afterwards; when
// the last login goes there is nothing left to show and the page reloads onto the
// Connect screen.
// `links` is the gate's own list (LinkGate), already read before the page opened, so the
// section draws at once and its changes reach the rest of the app (SOLAR-96).
function SunSynkConnectionSection({ onChanged, links }) {
  const { useState } = React;
  const { accounts, error, refresh } = links;
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
  const title = <>SunSynk logins{n > 0 && <span className="sset-count">{n}</span>}</>;
  return (
    <SettingsSection id="connection" title={title}>
      {unread ? (
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
      {!unread && (mode === 'add'
        ? <div className="conn-row conn-add-row"><div className="conn-text">
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
// One form, three sections, one floating save bar.
function PlantSections({ me, plantId, onSaved, onDirty, switchBlocked }) {
  const { useState, useEffect } = React;
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
  // App holds the plant still while there are unsaved changes; a switch asked for meanwhile
  // says so in the save bar until the changes are saved or discarded.
  useEffect(() => { onDirty && onDirty(dirty); }, [dirty]);
  useEffect(() => () => onDirty && onDirty(false), []);
  const [blocked, setBlocked] = useState(false);
  useEffect(() => { if (switchBlocked && dirty) setBlocked(true); }, [switchBlocked]);
  useEffect(() => { if (!dirty) setBlocked(false); }, [dirty]);
  // A box turns red, with one line saying what to enter, once focus leaves a row typed in (or
  // Save is pressed), so a number part-way typed never flashes an error. Clicking back into a
  // red box keeps it red until it is changed.
  const capBlur = (e) => { if (!e.currentTarget.contains(e.relatedTarget)) setCapEditing(null); };
  const rowShown = (r, i) => i !== capEditing && filled(r);
  const badRow = panelRows.find((r, i) => rowShown(r, i) && !rowOk(r));
  const boxMsg = (v, empty, fraction, range) => (v ?? '') === '' ? empty : Number.isInteger(Number(v)) ? range : fraction;
  const capKw = capMode === 'total' ? (num(f.system_kwp) || 0) : panelWatts / 1000;
  const capErr = capMode === 'total' ? (capEditing !== 'total' && !totalOk ? 'Enter more than 0 kW.' : null)
    : !badRow ? null
    : !whole(badRow.count, 1, 2000) ? boxMsg(badRow.count, 'Enter the number of panels.', 'Enter a whole number of panels.', 'Enter 1 to 2000 panels.')
    : boxMsg(badRow.watts, 'Enter the watts per panel.', 'Enter a whole number of watts.', 'Enter 50 to 1000 W.');

  // South Africa only, for now: no feed-in rate, currency or timezone to set. Those
  // columns keep what SunSynk reported at link time and are never sent from here.
  const save = async () => {
    if (!plant) return;
    // A capacity box still wrong: Save stays pressable (the bar is shared with Tariff and Battery)
    // and instead shows the message and puts focus on the box to fix.
    if (capBad) {
      setCapEditing(null);
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
        // untouched, a stored reserve outside 5..50 is kept; edited, it is held to 5..50 even if the box was never left
        battery_reserve_pct: num(f.battery_reserve_pct) === (cfg.battery_reserve_pct ?? null) ? (cfg.battery_reserve_pct ?? 20)
          : Math.min(50, Math.max(5, Math.round(num(f.battery_reserve_pct) ?? cfg.battery_reserve_pct ?? 20))),
      };
      await window.savePlantConfig(plant.id, patch);
      setMsg('Saved.'); onSaved && onSaved();
    } catch (e) { setMsg(e.message); }
    finally { setBusy(false); }
  };

  if (!plant) return <SettingsSection id="plant" title="Plant"><div className="field-note">No plant connected yet.</div></SettingsSection>;
  const sym = window.moneySymbol ? window.moneySymbol() : (f.currency || '');
  return (
    <>
      {/* A unit is a kWh: it is what a South African bill calls one, so the rate is per unit */}
      <SettingsSection id="tariff" title="Tariff">
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

      <SettingsSection id="battery" title="Battery">
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
          {/* an edited box settles into 5 to 50 when it loses focus */}
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
        </div>
      </SettingsSection>

      <SettingsSection id="plant" title="Plant">
        <div className="conn-row sset-row">
          <div className="conn-text cap-text">
            {/* the answer sits on the label's line in both modes and at every width, so it reads before the boxes */}
            <span className="cap-head"><span id="plant-kwp-q" className="conn-user">Solar panels</span>
              <span className={'cap-kw mono' + (capKw > 0 ? '' : ' empty')} aria-live="polite">{capKw > 0 ? +capKw.toFixed(2) + ' kW' : '— kW'}</span></span>
            <span className="conn-meta">What they make in full sun.</span>
          </div>
          {/* The switch belongs to what it switches, so it sits over the boxes on the left
              rather than alone at the far edge of a wide card. */}
          <div className="cap-switch">
            <Segmented size="sm" value={capMode} onChange={setCapMode}
              options={[{ value: 'panels', label: 'Panels' }, { value: 'total', label: 'Total kW' }]} />
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
              <div className="panel-list" ref={listRef}>
                {panelRows.map((r, i) => {
                  const countBad = rowShown(r, i) && !whole(r.count, 1, 2000), wattsBad = rowShown(r, i) && !whole(r.watts, 50, 1000);
                  return (
                    <div key={i} className="panel-row" onBlur={capBlur}>
                      <div className="unit-input panel-count">
                        <input className="input mono" type="number" inputMode="numeric" min="1" max="2000" step="1" placeholder="20" aria-label={'Panels, row ' + (i + 1)}
                               aria-invalid={countBad} aria-describedby={countBad ? 'cap-err' : undefined} value={r.count ?? ''} onChange={e => setRow(i, 'count', e.target.value)} />
                      </div>
                      <span className="panel-of" aria-hidden="true">panels of</span>
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
              <button type="button" className="panel-add" onClick={() => { set('panel_groups', [...panelRows, { count: '', watts: '' }]); focusRow(panelRows.length); }}>Add another panel size</button>
            </div>
          )}
        </div>
      </SettingsSection>

      {(dirty || msg) && (
        <div className={'save-bar' + (dirty ? ' dirty' : '')} role="status">
          <span className="save-text">{!dirty ? msg : blocked ? 'Save or discard before switching plant.' : 'Unsaved changes'}</span>
          {dirty && <button type="button" className="ghost-btn" onClick={() => { setF(cfg); setCapMode(capModeOf(cfg)); setMsg(null); }} disabled={busy}>Discard</button>}
          {dirty && <button type="button" className="save-btn" onClick={save} disabled={busy}>{busy ? 'Saving…' : 'Save'}</button>}
        </div>
      )}
    </>
  );
}

function DeleteAccountSection({ email }) {
  const { useState } = React;
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [confirming, setConfirming] = useState(false);
  const del = async () => {
    setConfirming(false);
    setBusy(true); setErr(null);
    try { await window.deleteAccount(); await window.sb.auth.signOut(); location.href = './'; }
    catch (e) { setErr(e.message); setBusy(false); }
  };
  return (
    <SettingsSection id="delete" title="Delete account" note="Removes your logins and settings. History goes too, unless someone else shares the plant.">
      <div className="conn-row">
        <div className="conn-text">
          <div className="conn-user">Delete <span className="mono">{email || 'this account'}</span></div>
          <div className="conn-meta">It cannot be undone.</div>
        </div>
        <div className="conn-actions"><button type="button" className="danger-btn" onClick={() => { setErr(null); setConfirming(c => !c); }} disabled={busy || confirming}>{busy ? 'Deleting…' : 'Delete account'}</button></div>
        {confirming && (
          <ConfirmCard title={<>Delete <b>{email || 'this account'}</b>?</>} text="It cannot be undone."
            action="Delete account" onConfirm={del} onCancel={() => setConfirming(false)} />
        )}
      </div>
      {err && <div className="field-note" style={{ color: 'var(--load)' }}>{err}</div>}
    </SettingsSection>
  );
}

// Settings: the plant on screen.
function SettingsTab({ me, plantId, onPlantConfigSaved, flash, onFlashed, onDirty, switchBlocked }) {
  const plant = (me?.plants || []).find(p => p.id === plantId);
  return (
    <SettingsFlash.Provider value={flash ? { id: flash, done: onFlashed } : null}>
      <div className="settings-page">
        <div className="page-head">
          <h1>Settings</h1>
          {plant && <p>For {plant.name || 'Plant ' + plant.id}. Shared with everyone who sees it.</p>}
        </div>
        <PlantSections me={me} plantId={plantId} onSaved={onPlantConfigSaved} onDirty={onDirty} switchBlocked={switchBlocked} />
      </div>
    </SettingsFlash.Provider>
  );
}

// Account: the person. Sign out is in the account menu only.
function AccountTab({ onPlantConfigSaved, links, flash, onFlashed }) {
  const { useState, useEffect } = React;
  const [email, setEmail] = useState(null);
  useEffect(() => { window.sb.auth.getSession().then(({ data }) => setEmail(data?.session?.user?.email || null)).catch(() => {}); }, []);
  return (
    <SettingsFlash.Provider value={flash ? { id: flash, done: onFlashed } : null}>
      <div className="settings-page">
        <div className="page-head">
          <h1>Account</h1>
          {email && <p className="mono">{email}</p>}
        </div>
        <SunSynkConnectionSection onChanged={onPlantConfigSaved} links={links} />
        <DeleteAccountSection email={email} />
        <div className="app-version mono">{window.APP_VERSION}</div>
      </div>
    </SettingsFlash.Provider>
  );
}

Object.assign(window, { LiveTab, SolarTab, GridTab, InvertersTab, SettingsTab, AccountTab, MiniStat, FsEnterIcon, TabSkeleton });
