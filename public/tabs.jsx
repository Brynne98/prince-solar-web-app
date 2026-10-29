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
      {legend && <div className="legend-row" aria-hidden="true"><span className="legend-chip" style={{ visibility: 'hidden' }}>{NBSP}</span></div>}
      <PlotSkeleton heights={[220, 300]} />
    </>
  );
}

// A plot area before it can be drawn, at the height useChartSize gives the real chart at this
// card's width (DayLineChart 220/300, DaysBars 170/220). The breakpoint is the card's own
// width, so a CSS rule on the window's width got it wrong at 375px (SOLAR-221).
function PlotSkeleton({ heights, r = 12 }) {
  const [ref, , height] = useChartSize(heights);
  return <div ref={ref}><window.Skeleton h={height} r={r} /></div>;
}

// A tile's second line, held open while the words for it are still coming: a plain space
// collapses to a zero-height line box, and the tile lands 17px short of the real one.
const NBSP = '\u00a0';
// A card title's right-hand figure ("Best 51.0 kWh on 2 Oct"), held open until it arrives: its
// bold figure is in the mono face, which sets the line 1.5px taller than the title alone, and
// on a phone the figure takes a line of its own under the title.
const RIGHT_HOLD = <b>{NBSP}</b>;

// Where it went / came from, before the day lands: the share bar, then a figure and a label
// per part, each at the height of the real one (SOLAR-221).
function WiwBodySkeleton() {
  return (
    <>
      <window.Skeleton className="fbox-bar" h={5} r={3} />
      <div className="wiw-figs" aria-hidden="true">
        {[0, 1, 2].map(i => <div key={i}><b><window.Skeleton w="60%" h="1em" r={6} style={{ display: 'inline-block', verticalAlign: 'top' }} /></b><span>{NBSP}</span></div>)}
      </div>
    </>
  );
}
// The card's total ("Made 21.3 kWh"), unseen, at a typical width: on a phone the title and the
// total share a line only when both fit, so the held space has to be as wide as the real one.
const wiwHold = (word) => <span style={{ visibility: 'hidden' }}>{word} <b>0.0 kWh</b></span>;
function WiwSkeleton({ title, word, info }) {
  return (
    <div className="solar-row">
      <Card className="wiw">
        <SectionTitle right={wiwHold(word)}>{titled(title, 'today')}<window.InfoDot text={info} /></SectionTitle>
        <WiwBodySkeleton />
      </Card>
    </div>
  );
}

// A readout whose number hasn't arrived. The label is static and draws for real.
function skelVal(w) {
  return <window.Skeleton w={w} h={19} r={5} style={{ display: 'inline-block', verticalAlign: 'top', marginTop: 3 }} />;
}

function LiveSkeleton() {
  return (
    <div className="live-grid">
      <div className="overview-section">
        <div className="overview-head">
          <div className="section-title">OVERVIEW</div>
          <window.Segmented size="sm" value="today" onChange={() => {}}
            options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]} />
        </div>
        {/* The real tiles in loading mode, with the same meter and second line the live
            ones carry, so the row lands at the same height. */}
        <div className="today-strip">
          <MiniStat loading label="Made" />
          <MiniStat loading label="Home" />
          <MiniStat loading label="Independence" bar={0} />
          {/* the grid chip's box sets its line 0.5px taller than plain text */}
          <MiniStat loading label="Imported" sub={<span className="grid-state" style={{ visibility: 'hidden' }}><span className="gs-dot" />{NBSP}</span>} />
          <MiniStat loading label="Saved" sub={NBSP} />
        </div>
      </div>
      <div className="card flow-card">
        <SectionTitle right={<button className="flow-fs-btn" disabled><FsEnterIcon /><span>Fullscreen</span></button>}>POWER FLOW</SectionTitle>
        {/* the summary sentence opens the card, one line of its height */}
        <div className="flow-narrative narr-hold"><window.Skeleton w={300} h={12} r={6} style={{ maxWidth: '80%' }} /><window.Skeleton className="narr-2" w={180} h={12} r={6} style={{ maxWidth: '50%' }} /></div>
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
    window.fetchHourly(undefined, refreshKey).then((d) => { if (alive) setHourly(d); }).catch(() => {});
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
  const availKwh = cap && a.battSoc != null ? Math.max(0, (a.battSoc - RESERVE) / 100 * cap) : null;
  const headroomKwh = cap && a.battSoc != null ? Math.max(0, (100 - a.battSoc) / 100 * cap) : null;
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
  else if (!cap) { battInfo = 'Add battery size to see this'; } // a link on the flow's battery node
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
  const cmp = useCompare(refreshKey, snap);
  // Free after its week (SOLAR-242): Today stays; the month's figures blur, the rest is a faint shape
  const over = window.useFreeOver();

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
    <>
    {over && hasGrid && <GridOffPrompt hasBatt={hasBatt} tz={tz} />}
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
          <SectionTitle>OVERVIEW</SectionTitle>
          <Segmented size="sm"
            options={[{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }]}
            value={period} onChange={setPeriod} />
        </div>
        {over && period !== 'today' && period !== 'month' ? <window.HistoryLock where={'overview_' + period} /> : <>
        {/* On a phone there is no hover, so a thin comparison base is said on screen. */}
        {partial && !over && <div className="cmp-note">Arrows compare the {cmpDays} of {cmpRow.span} days with readings on both sides.</div>}
        <div className={'today-strip' + (over && period === 'month' ? ' blurred' : '')}>
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
          <MiniStat loading={pending} label="Saved" color={CC.batt}
            value={(rate > 0 || rateExp > 0) && pSaved != null ? window.fmtRandSmart(pSaved) : '—'}
            trend={tSaved} trendDelta={dSaved} trendDeltaFmt={window.fmtRandSmart} trendTitle={cmpWord}
            // no rate yet: the line under the dash opens Settings on Tariff
            sub={!(rate > 0 || rateExp > 0) ? <button type="button" className="mini-link" onClick={() => onOpenSettings('tariff')}>Add your rate to see this</button>
              : over && period === 'month' ? <button type="button" className="lock-btn" onClick={() => window.openPlans('month_saved')}><window.LockIcon />See it</button> : undefined}
            info={'An estimate: what your home used that didn’t come from the grid, at your electricity rate' + (rateExp > 0 ? ', plus what you exported at your feed-in rate' : '') + '.'} />
        </div>
        </>}
      </div>

    </div>
    </>
  );
}

// Free after its week, once the grid has come back (SOLAR-242): how long it was off and
// what carried the house, then the plans. Once per outage on this device; × puts it away.
function GridOffPrompt({ hasBatt, tz }) {
  const [span, setSpan] = React.useState(null);
  const [seen, setSeen] = React.useState(() => { try { return localStorage.getItem('ps.gridOffSeen'); } catch (e) { return null; } });
  React.useEffect(() => {
    let alive = true;
    window.sb.rpc('api_grid_off_recent', { p_plant: window.CURRENT_PLANT }).then(({ data }) => { if (alive) setSpan(data || null); });
    return () => { alive = false; };
  }, [window.CURRENT_PLANT]);
  if (!span || !span.endedAt || seen === span.endedAt) return null;
  const from = new Date(span.startedAt), to = new Date(span.endedAt);
  const mins = (to - from) / 60000;
  const dur = mins < 90 ? Math.max(1, Math.round(mins)) + ' min' : Math.round(mins / 60) + ' h';
  const h = window.plantHour(tz, from), today = plantDateStr(tz);
  const when = (h >= 18 || h < 6) && window.plantHour(tz, to) < 12 && plantDateStr(tz, to) === today ? 'last night'
    : plantDateStr(tz, to) === today ? 'today' : 'yesterday';
  const close = () => { try { localStorage.setItem('ps.gridOffSeen', span.endedAt); } catch (e) {} setSeen(span.endedAt); };
  return (
    <div className="notice grid-off-prompt" role="status">
      <p><b>Grid was off {dur} {when}.</b>{hasBatt && ' Your battery carried the house.'}</p>
      <button type="button" className="mini-link" onClick={() => { close(); window.openPlans('grid_off'); }}>See how it held up →</button>
      <button type="button" className="fs-x" aria-label="Close" onClick={close}><Icon id="close" /></button>
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
        ? <div className="mini-value mono" style={{ position: 'relative' }}>{NBSP}<window.Skeleton w="70%" h="auto" style={{ position: 'absolute', top: 0, bottom: 0, left: 0 }} /></div>
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
      // A full battery turns the panels down, so "less than usual" means nothing that day;
      // "made nothing" still does (healthy strings made 4.6 kWh or more on full days).
      const full = !multi && hi.battFull;
      if (full) skipped++;
      hi.strings.forEach(st => {
        const usual = multi ? st.usualInvShare : st.usualPlantShare;
        const today = multi ? st.todayInvShare : st.todayPlantShare;
        if (usual == null || usual < 0.02) return;
        if (!full) compared++;
        const inv = snap.inverters.find(x => x.sn === hi.sn) || { sn: hi.sn };
        if (st.todayKwh < 0.05) {
          alerts.push({ kind: 'nothing', inv, no: st.no, usual, multi });
          broken[hi.sn] = (broken[hi.sn] || 0) + 1;
        } else if (!full && today != null && today / usual < PANELS_LOW) {
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

// One day of one reading as a line across the whole day: solar (drawn at 0 W too, SOLAR-179),
// grid power signed (+ bought, − exported), or the battery's charge
// on a fixed 0-100% scale with the reserve dashed.
// The reading under the pointer shows beside it. As on Live, dragging across the chart with
// a mouse totals the energy between the two times (`sums` names the + and − parts). Callers
// key it by date, so a new day starts with no range.
// `importScale` (Grid): the scale is set by what came in, at least 2 kW, and the side below
// zero is always a third of it, as on an import day; a bigger export is cut off at the bottom,
// and the hover and drag totals still give its real size (SOLAR-72).
// `outages` (Grid): runs of 5-minute buckets the grid was down, shaded as on Equipment's supply chart.
function DayLineChart({ points, field, color, label, pct, reserve, empty, sums, importScale, outages }) {
  const [ref, width, height] = useChartSize([220, 300]);
  const [hover, setHover] = React.useState(null);
  const [sel, setSel] = React.useState(null);    // [i0, i1] the selected range
  const [drag, setDrag] = React.useState(null);  // the range while it is being dragged
  const dragRef = React.useRef(null);
  const mobile = width < 560;
  const v = i => points[i][field];
  const has = [];
  points.forEach((p, i) => { if (p[field] != null) has.push(i); });
  const hp = hover != null && points[hover] && v(hover) != null ? hover : null;
  let body = null, tip = null;
  if (has.length) {
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
        {(outages || []).map(([a, b]) => (
          <rect key={'o' + a} x={xt5(Math.max(t0, a * 5 - 2.5))} y={m.t} width={Math.max(2, xt5(Math.min(t1, b * 5 + 2.5)) - xt5(Math.max(t0, a * 5 - 2.5)))} height={innerH} fill={window.COLORS.load} fillOpacity="0.18" />
        ))}
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
          {outages && <OutageTipRow span={outageAt(outages, Math.round(points[hp].t / 5))} what="Grid" />}
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
// Free after its week (SOLAR-242): the 30 days are a faint shape and a lock
function DaysBars(props) {
  return window.useFreeOver() ? <window.HistoryLock where={'days_' + props.field} /> : <DaysBarsChart {...props} />;
}
function DaysBarsChart({ rows, field, color, rgb, word, label, today, selected, earliest, onPick }) {
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

// Period-over-period totals for the trend arrows. "Yesterday up to now" moves with the
// clock, so it is asked again with each new snapshot, not only on refreshKey; the shared
// 5-minute cache keeps that to one request per 5 minutes (SOLAR-148).
function useCompare(refreshKey, snap) {
  const [cmp, setCmp] = React.useState(null);
  React.useEffect(() => { window.fetchCompare(refreshKey).then(setCmp).catch(() => {}); }, [refreshKey, snap]);
  return cmp;
}

// The last 30 days of plant totals, for a tab's bars: null loading, false failed.
function useDaily(refreshKey) {
  const [daily, setDaily] = React.useState(null);
  const load = React.useCallback(() => {
    setDaily(null);
    window.fetchTrendDaily(30, refreshKey).then(setDaily).catch(() => setDaily(false));
  }, [refreshKey]);
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
  // Without a panel size the line is "Set panel capacity", one line: the tab remembers which.
  const noKwp = (() => { try { return localStorage.getItem('synsynk.kwpSet') === '0'; } catch (e) { return false; } })();
  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        {/* "30% of your 15.9 kW of panels" runs to two lines on a phone, so Solar now
            holds two there; the rest hold one. */}
        {['SOLAR NOW', 'TODAY', 'THIS WEEK', 'THIS MONTH', 'THIS YEAR', 'LIFETIME']
          .map(l => <StatTile key={l} label={l} loading sub={l === 'SOLAR NOW' && !noKwp ? <span className="sub-hold-2">{NBSP}</span> : NBSP} />)}
      </div>
      <Card>
        <SectionTitle>{titled('SOLAR', 'today')}</SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle right={RIGHT_HOLD}>{titled('SOLAR', 'last 30 days')}</SectionTitle>
        <PlotSkeleton heights={[170, 220]} r={10} />
      </Card>
      <WiwSkeleton title="WHERE IT WENT" word="Made" info="Solar counts to the house first, then the battery, then the grid." />
    </div>
  );
}

function SolarTab({ snap, energy, onNeedEnergy, today, refreshKey, onOpenSettings, alertDay }) {
  const a = snap.aggregate;
  const cfg = snap.config || {};
  const feat = snap.features || {};
  const tz = cfg.timezone;
  const plantToday = plantDateStr(tz);
  const hasGrid = feat.hasGrid !== false;
  const hasBatt = feat.hasBattery !== false;
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);

  // ---- totals ----
  const cmp = useCompare(refreshKey, snap);
  const [earliest, setEarliest] = React.useState(null);
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);
  const tot = periodTotals('pv', a.pvToday, energy, plantToday);
  const EP = window.fmtEnergyParts;
  // Every tile keeps its second line, empty or not: the trends and the since-date land after
  // the totals, and a row whose tiles had none yet was 29px short until they did.
  // Free after its week (SOLAR-242): every total but Today is a faint shape and a lock
  const over = window.useFreeOver();
  const tile = (label, v, sub) => { const [n, u] = EP(v); return <StatTile label={label} value={n} unit={u} accent={CC.pv} loading={v == null} sub={sub || NBSP} locked={over && label !== 'TODAY' ? 'solar_totals' : null} />; };
  const trend = (k, min, word) => periodTrend(cmp, k, 'pv', min, word);
  const kwp = cfg.systemKwp;
  React.useEffect(() => { try { localStorage.setItem('synsynk.kwpSet', kwp > 0 ? '1' : '0'); } catch (e) {} }, [kwp]);
  const [nowN, nowU] = fmtPowerParts(a.pvNow);

  // ---- last 30 days (also the day totals Where it went scales to) ----
  const [daily, loadDaily] = useDaily(refreshKey);

  // ---- the day on the chart ----
  const pick = useDayPicker(earliest, plantToday, alertDay); // the plant's date, as the totals and bars use
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
  const best = over ? null : bestDay(bars, 'pv', plantToday);
  const openDay = (d) => { pick.setDate(d); scrollToDay('solar-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="SOLAR NOW" value={silent ? '—' : nowN} unit={silent ? '' : nowU} accent={CC.pv}
          sub={silent ? 'Last reading ' + readAgo(ps.last.getTime(), Date.now()) : kwp > 0 ? (over ? <window.Locked where="panel_pct" label="Keep your insights"><b>{Math.round(a.pvNow / 10 / kwp)}%</b> of your {kwp} kW</window.Locked>
              : <><b>{Math.round(a.pvNow / 10 / kwp)}%</b> of your {kwp} kW of panels</>)
            : <button type="button" className="mini-link" onClick={() => onOpenSettings('plant')}>Add your panels to see this</button>} />
        {tile('TODAY', a.pvToday, todayPeak ? <>Peak <b>{fmtPower(todayPeak.pv)}</b> at <b>{HM(todayPeak.t)}</b></> : null)}
        {tile('THIS WEEK', tot.week, trend('week', 2, 'last week'))}
        {tile('THIS MONTH', tot.month, trend('month', 3, 'last month'))}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="solar-day">
        <SectionTitle right={day && !noReadings && !view.isToday && peak ? <>Peak <b>{fmtPower(peak.pv)}</b> at <b>{HM(peak.t)}</b></> : !pick.isToday ? RIGHT_HOLD : null}>
          {titled('SOLAR', dayWord)}
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest} />
        {!day ? <PlotSkeleton heights={[220, 300]} />
          : <div {...dim}><DayLineChart key={pick.date} points={noReadings ? [] : points} field="pv" color={CC.pv} label="Solar" sums={['Made']} empty={noReadings || (view.isToday ? 'No solar yet today.' : 'No solar on this day.')} /></div>}
      </Card>

      <Card>
        <SectionTitle right={best ? <>Best <b>{fmtKwh(best.pv)}</b> on {shortDate(best.date)}</> : RIGHT_HOLD}>
          {titled('SOLAR', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <PlotSkeleton heights={[170, 220]} r={10} />
          : !over && bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
          : <DaysBars rows={bars} field="pv" color={CC.pv} rgb="61,220,132" word="Solar" label="Solar per day for the last 30 days"
              today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />}
      </Card>

      {/* Where it went: a plain card like the rest of the page (SOLAR-74). The day's solar in the
          header, the share bar, and each part's kWh with its name under it, in its own colour. */}
      <div className="solar-row">
        <Card className="wiw" {...dim}>
          <SectionTitle right={day && !noReadings && splitTotal >= 0.05 ? <>Made <b>{fmtKwh(splitTotal)}</b></> : !day ? wiwHold('Made') : null}>
            {titled('WHERE IT WENT', dayWord)}
            <window.InfoDot text={'Solar counts to the house first, then the battery, then the grid.'} />
          </SectionTitle>
          {!day ? <WiwBodySkeleton />
            : noReadings || splitTotal < 0.05 ? <div className="solar-note">{noReadings || (view.isToday ? 'No solar yet today.' : 'No solar on this day.')}</div>
            : <>
              <div className="fbox-bar" role="img" title={destTitle} aria-label={destLabel}>
                {dests.map(([l, v, c]) => <i key={l} style={{ flexGrow: destPct(v), background: c }} />)}
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

// ---------------------------------------------------------------- HOME
// Built like Solar, for what the house used (SOLAR-151): now, today, week, month, year,
// lifetime, the day's home power, the last 30 days, and where the day's use came from.

function HomeSkeleton() {
  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        {/* "40% from solar right now" runs to two lines on a phone, as Solar's first tile does */}
        {['HOME NOW', 'TODAY', 'THIS WEEK', 'THIS MONTH', 'THIS YEAR', 'LIFETIME']
          .map(l => <StatTile key={l} label={l} loading sub={l === 'HOME NOW' ? <span className="sub-hold-2">{NBSP}</span> : NBSP} />)}
      </div>
      <Card>
        <SectionTitle>{titled('HOME', 'today')}</SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle right={RIGHT_HOLD}>{titled('HOME', 'last 30 days')}</SectionTitle>
        <PlotSkeleton heights={[170, 220]} r={10} />
      </Card>
      <WiwSkeleton title="WHERE IT CAME FROM" word="Used" info="The house uses solar first, then the battery, then the grid." />
    </div>
  );
}

// Where a day's home use came from, from its 5-minute points: solar first, then the
// battery, and the grid for the rest. Day series: battery + = discharging.
function homeSplit(points) {
  let solar = 0, batt = 0, grid = 0;
  const kwh = 5 / 60 / 1000;
  points.forEach(p => {
    if (p.load == null || p.load <= 0) return;
    const fromSolar = Math.min(p.load, Math.max(0, p.pv || 0));
    const fromBatt = Math.min(p.load - fromSolar, p.batt != null && p.batt > 0 ? p.batt : 0);
    solar += fromSolar * kwh; batt += fromBatt * kwh; grid += (p.load - fromSolar - fromBatt) * kwh;
  });
  return { solar, batt, grid };
}

function HomeTab({ snap, energy, onNeedEnergy, today, refreshKey }) {
  const a = snap.aggregate;
  const cfg = snap.config || {};
  const feat = snap.features || {};
  const plantToday = plantDateStr(cfg.timezone);
  const hasGrid = feat.hasGrid !== false;
  const hasBatt = feat.hasBattery !== false;
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);

  // ---- totals ----
  const cmp = useCompare(refreshKey, snap);
  const [earliest, setEarliest] = React.useState(null);
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);
  const tot = periodTotals('load', a.loadToday, energy, plantToday);
  const EP = window.fmtEnergyParts;
  // Free after its week (SOLAR-242): every total but Today is a faint shape and a lock
  const over = window.useFreeOver();
  const tile = (label, v, sub) => { const [n, u] = EP(v); return <StatTile label={label} value={n} unit={u} accent={CC.load} loading={v == null} sub={sub || NBSP} locked={over && label !== 'TODAY' ? 'home_totals' : null} />; };
  // less used is better, as on Grid
  const trend = (k, min, word) => periodTrend(cmp, k, 'load', min, word, true);
  const [nowN, nowU] = fmtPowerParts(a.loadNow);
  const ps = window.plantStatus(snap, Date.now());
  const silent = ps.status === 'offline';
  const solarNow = a.loadNow > 50 ? Math.round(Math.min(a.loadNow, Math.max(0, a.pvNow || 0)) / a.loadNow * 100) : null;
  const peakOf = (pts) => {
    let pk = null;
    (pts || []).forEach(p => { if (p.load != null && (!pk || p.load > pk.load)) pk = p; });
    return pk && pk.load > 20 ? pk : null;
  };
  const todayPeak = peakOf(today && !today.approx ? today.points : null);

  // ---- the day on the chart ----
  const [daily, loadDaily] = useDaily(refreshKey);
  const pick = useDayPicker(earliest, plantToday);
  const { view, dim, day, points, dayWord } = useShownDay(pick, today, refreshKey);
  const noReadings = dayProblem(view, day, points, silent);
  const peak = peakOf(points);

  // ---- where it came from: shares from the readings, scaled to the day's counter as Solar does ----
  const est = React.useMemo(() => homeSplit(points), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  const estTotal = est.solar + est.batt + est.grid;
  const dayRow = !view.isToday && (daily || []).find(r => r.date === pick.date);
  const usedKwh = view.isToday ? a.loadToday : (dayRow && dayRow.load != null ? dayRow.load : day && day.totals && day.totals.load);
  const k = usedKwh > 0 && estTotal > 0 ? usedKwh / estTotal : 1;
  const tenths = (v) => Math.round(v * 10) / 10;
  const split = { solar: tenths(est.solar * k), batt: tenths(est.batt * k), grid: tenths(est.grid * k) };
  const big = ['solar', 'batt', 'grid'].reduce((m, x) => (split[x] > split[m] ? x : m), 'solar');
  split[big] = tenths(split[big] + tenths(estTotal * k) - (split.solar + split.batt + split.grid));
  const splitTotal = split.solar + split.batt + split.grid;
  const srcs = [['Solar', split.solar, CC.pv, true], ['Battery', split.batt, CC.batt, hasBatt], ['Grid', split.grid, CC.grid, hasGrid]]
    .filter(d => d[3] && d[1] >= 0.05);
  const srcPct = (v) => v / splitTotal * 100;
  const srcTitle = srcs.map(d => d[0] + ' ' + Math.round(srcPct(d[1])) + '%').join(', ');
  const srcLabel = srcs.map(d => d[0] + ' ' + fmtKwh(d[1]) + ', ' + Math.round(srcPct(d[1])) + '%').join('; ');

  // ---- last 30 days ----
  const bars = withLiveToday(daily, plantToday, 'load', a.loadToday);
  const most = over ? null : bestDay(bars, 'load', plantToday);
  const openDay = (d) => { pick.setDate(d); scrollToDay('home-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="HOME NOW" value={silent ? '—' : nowN} unit={silent ? '' : nowU} accent={CC.load}
          sub={silent ? 'Last reading ' + readAgo(ps.last.getTime(), Date.now()) : solarNow != null ? <><b>{solarNow}%</b> from solar right now</> : NBSP} />
        {tile('TODAY', a.loadToday, todayPeak ? <>Peak <b>{fmtPower(todayPeak.load)}</b> at <b>{HM(todayPeak.t)}</b></> : null)}
        {tile('THIS WEEK', tot.week, trend('week', 2, 'last week'))}
        {tile('THIS MONTH', tot.month, trend('month', 3, 'last month'))}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="home-day">
        <SectionTitle right={day && !noReadings && !view.isToday && peak ? <>Peak <b>{fmtPower(peak.load)}</b> at <b>{HM(peak.t)}</b></> : !pick.isToday ? RIGHT_HOLD : null}>
          {titled('HOME', dayWord)}
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest} />
        {!day ? <PlotSkeleton heights={[220, 300]} />
          : <div {...dim}><DayLineChart key={pick.date} points={noReadings ? [] : points} field="load" color={CC.load} label="Home" sums={['Used']} empty={noReadings || 'No home readings for this day.'} /></div>}
      </Card>

      <Card>
        <SectionTitle right={most && most.load > 0 ? <>Most <b>{fmtKwh(most.load)}</b> on {shortDate(most.date)}</> : RIGHT_HOLD}>
          {titled('HOME', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <PlotSkeleton heights={[170, 220]} r={10} />
          : !over && bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
          : <DaysBars rows={bars} field="load" color={CC.load} rgb="248,113,113" word="Used" label="Home use per day for the last 30 days"
              today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />}
      </Card>

      <div className="solar-row">
        <Card className="wiw" {...dim}>
          <SectionTitle right={day && !noReadings && splitTotal >= 0.05 ? <>Used <b>{fmtKwh(splitTotal)}</b></> : !day ? wiwHold('Used') : null}>
            {titled('WHERE IT CAME FROM', dayWord)}
            <window.InfoDot text={'The house uses solar first, then the battery, then the grid.'} />
          </SectionTitle>
          {!day ? <WiwBodySkeleton />
            : noReadings || splitTotal < 0.05 ? <div className="solar-note">{noReadings || 'No home readings for this day.'}</div>
            : <>
              <div className="fbox-bar" role="img" title={srcTitle} aria-label={srcLabel}>
                {srcs.map(([l, v, c]) => <i key={l} style={{ flexGrow: srcPct(v), background: c }} />)}
              </div>
              <div className="wiw-figs" aria-hidden="true">
                {srcs.map(([l, v, c]) => {
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
        <SectionTitle right={NBSP}>{titled('GRID', 'today')}<window.InfoDot text={'Above the line is power imported from the grid; below it is power exported.'} /></SectionTitle>
        <DayChartSkeleton />
      </Card>
      <Card>
        <SectionTitle right={RIGHT_HOLD}>{titled('IMPORTED', 'last 30 days')}</SectionTitle>
        <PlotSkeleton heights={[170, 220]} r={10} />
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

function GridBody({ snap, energy, onNeedEnergy, today, refreshKey, onOpenSettings, alertDay }) {
  const a = snap.aggregate;
  const cfg = snap.config || {};
  const tz = cfg.timezone;
  const plantToday = plantDateStr(tz);
  const sells = (cfg.tariffExport ?? 0) > 0; // same rule as the Overview tile: only plants paid for export
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);
  const cmp = useCompare(refreshKey, snap);
  const [earliest, setEarliest] = React.useState(null);
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);

  // ---- totals: what was bought ----
  // Today is the logger's own integral, as Live's Imported tile uses: one inverter's CT on a
  // two-inverter plant reads nothing, so the inverters' own counters undercount.
  const tot = periodTotals('imp', a.gridFromToday, energy, plantToday);
  const EP = window.fmtEnergyParts;
  // Free after its week (SOLAR-242): every total but Today is a faint shape and a lock
  const over = window.useFreeOver();
  const tile = (label, v, sub) => { const [n, u] = EP(v); return <StatTile label={label} value={n} unit={u} accent={CC.grid} loading={v == null} sub={sub || NBSP} locked={over && label !== 'TODAY' ? 'grid_totals' : null} />; };
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
  const pick = useDayPicker(earliest, plantToday, alertDay);
  const { view, dim, day, points, dayWord } = useShownDay(pick, today, refreshKey);
  const noReadings = dayProblem(view, day, points, silent);
  const peak = importPeak(points);
  // grid-down runs for the day, from the same history Equipment's supply chart shades
  const [outages, setOutages] = React.useState([]);
  React.useEffect(() => {
    let alive = true;
    setOutages([]);
    window.fetchInverterHistory(pick.date, refreshKey)
      .then(r => { if (alive) setOutages(outageRuns(r || [], ['gmin', 'gmax'], DAY_LAST)); })
      .catch(() => {});
    return () => { alive = false; };
  }, [pick.date, refreshKey]);
  const outageMin = outageMinutes(outages);
  const flows = React.useMemo(() => {
    let imp = 0, exp = 0;
    points.forEach(p => { if (p.grid != null) { if (p.grid > 0) imp += p.grid * 5 / 60 / 1000; else exp += -p.grid * 5 / 60 / 1000; } });
    return { imp, exp };
  }, [day]); // eslint-disable-line react-hooks/exhaustive-deps

  // ---- last 30 days ----
  const [daily, loadDaily] = useDaily(refreshKey);
  const bars = withLiveToday(daily, plantToday, 'imp', a.gridFromToday);
  const most = over ? null : bestDay(bars, 'imp', plantToday);
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
        {/* the right line is always there (blank today) so the date bar under it never shifts on a phone */}
        <SectionTitle right={day && !noReadings && !view.isToday ? <>Imported <b>{fmtKwh(flows.imp)}</b>{flows.exp >= 0.05 && <>, exported <b>{fmtKwh(flows.exp)}</b></>}</> : NBSP}>
          {titled('GRID', dayWord)}
          <window.InfoDot text={'Above the line is power imported from the grid; below it is power exported.'} />
        </SectionTitle>
        <DateBar pick={pick} earliest={earliest}>
          <OutagePill mins={outageMin} what="Grid" />
        </DateBar>
        {!day ? <PlotSkeleton heights={[220, 300]} />
          : <div {...dim}><DayLineChart key={pick.date} points={noReadings ? [] : points} field="grid" color={CC.grid} label="Grid"
              sums={['Imported', 'Exported']} importScale outages={outages} empty={noReadings || 'No grid readings for this day.'} /></div>}
      </Card>

      <Card>
        <SectionTitle right={most && most.imp > 0 ? <>Most <b>{fmtKwh(most.imp)}</b> on {shortDate(most.date)}</> : RIGHT_HOLD}>
          {titled('IMPORTED', 'last 30 days')}
        </SectionTitle>
        {daily === false
          ? <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={loadDaily}>Try again</button></div>
          : !daily ? <PlotSkeleton heights={[170, 220]} r={10} />
          : !over && bars.length < 2 ? <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>
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

// The page as InvertersTab draws it with nothing wrong, in the view this viewer last chose,
// built from the same classes so each piece lands at the real one's height (SOLAR-221).
// Problem cards are left out: most visits have none. Detailed holds one inverter with two
// strings; a plant with more grows into them.
function InvertersSkeleton() {
  const detailed = (() => { try { return localStorage.getItem('synsynk.eqView') === 'detailed'; } catch (e) { return false; } })();
  // a line of text whose words haven't come: a shimmer, and the line's own height held by a space
  const line = (w, h = 10) => <><window.Skeleton w={w} h={h} r={5} style={{ display: 'inline-block', verticalAlign: 'middle', maxWidth: '70%' }} />{NBSP}</>;
  const fig = <window.Skeleton w={80} h="1em" r={6} />;
  const tile = (label, word) => (
    <section className="card eq-tile" aria-label={label}>
      <div className="eq-tile-fig"><div className={'eq-fig' + (word ? ' word' : ' mono')}>{fig}</div><div className="eq-fig-sub">{line(60)}</div></div>
      <div className="eq-tile-text">
        <span className="eq-tile-label">{label}</span>
        <span className="eq-tile-state"><i className="eq-dot sm" />{line(90)}</span>
      </div>
    </section>
  );
  const rows = (n) => <dl className="eq-rows">{Array.from({ length: n }, (_, i) => <div key={i}><dt>{line(60)}</dt><dd>{line(110)}</dd></div>)}</dl>;
  return (
    <div className="stack eq-tab">
      <div className="eq-top">
        <span className="eq-label">Equipment</span>
        <Segmented size="sm" value={detailed ? 'detailed' : 'simple'} onChange={() => {}} options={[{ value: 'simple', label: 'Simple' }, { value: 'detailed', label: 'Detailed' }]} />
      </div>
      <section className="eq-status" aria-label="Status">
        <div className="eq-head"><i className="eq-dot" />{line(240, 20)}</div>
        <div className="eq-head-sub">{line(150)}</div>
      </section>
      {!detailed ? (
        <div className="eq-tiles">{tile('Solar panels')}{tile('Battery')}{tile('Inverter', true)}</div>
      ) : (
        <>
          <div className="eq-cards">
            <Card className="eq-card">
              <SectionTitle>SOLAR PANELS</SectionTitle>
              <div className="eq-big mono">{fig}</div>
              <div className="eq-big-sub">{line(140)}</div>
              <div className="eq-groups"><div className="eq-group">
                {[1, 2].map(no => <div className="eq-string" key={no}><span className="eq-string-name">String {no}</span><span className="eq-bar" /><span className="eq-string-kwh mono">{NBSP}</span></div>)}
              </div></div>
            </Card>
            <Card className="eq-card">
              <SectionTitle>BATTERY</SectionTitle>
              <div className="eq-big mono">{fig}</div>
              <div className="eq-meter" />
              <div className="eq-meter-scale"><span>{NBSP}</span></div>
              {rows(2)}
              <div className="eq-foot">{line(120)}</div>
            </Card>
            <Card className="eq-card">
              <SectionTitle>INVERTER</SectionTitle>
              <div className="eq-inv-tiles one"><div className="eq-inv">
                <div className="eq-inv-name">{line(90)}</div>
                <div className="eq-inv-state"><i className="eq-dot sm" />{line(30)}</div>
                <div className="eq-inv-now mono">{fig}</div>
                <div className="eq-inv-cap">solar now</div>
                <div className="eq-inv-today"><span>Today</span><span className="mono">{line(50)}</span></div>
                <div className="eq-inv-foot">{line(110)}</div>
              </div></div>
            </Card>
          </div>
          <div className="eq-specs">
            <Card className="eq-spec">
              <div className="eq-spec-head"><span>{line(90)}</span></div>
              <dl className="eq-spec-rows">
                {['Model', 'Serial number', 'Firmware', 'Last reading'].map(l => <div key={l}><dt>{l}</dt><dd className="mono">{line(100)}</dd></div>)}
              </dl>
              <div>
                <div className="eq-label eq-pack-label">Battery pack</div>
                <div className="eq-pack">
                  {['Charge', 'Voltage', 'Temperature', 'Batteries'].map(l => <div key={l}><b className="mono">{line(40, 14)}</b><span>{l}</span></div>)}
                </div>
              </div>
            </Card>
          </div>
          <Card className="chart-card"><SectionTitle>TEMPERATURE</SectionTitle><DayChartSkeleton legend /></Card>
          <Card className="chart-card"><SectionTitle>GRID SUPPLY</SectionTitle><DayChartSkeleton legend /></Card>
        </>
      )}
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
  // A battery answer that came back empty is stored as unknown (SOLAR-231): it says
  // nothing about the sensor this minute.
  const readBatt = liveBatt.filter(i => i.battSoc != null);
  const temps = readBatt.map(i => cleanTemp(i.battTemp)).filter(t => t != null);
  const battTemp = temps.length ? Math.max(...temps) : null;
  // A shared pack has one sensor; the slaves on it read -100 for good (SOLAR-229), so
  // it is judged only when every inverter on it answered.
  const badSensor = hasBatt && readBatt.length > 0 && (feat.banks === 'shared'
    ? readBatt.length === liveBatt.length && battTemp == null
    : readBatt.some(i => cleanTemp(i.battTemp) == null));
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
      {st.hasBatt && <EqTile label="Battery" state={battState} value={a.battSoc ?? '—'} unit={a.battSoc != null ? '%' : null} sub="charged" color={CC.batt} stale={st.battStale} />}
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
    if (cap > 0 && a.battSoc != null) rows.push(['Stored', kwh1(a.battSoc * cap / 100) + ' of ' + fmtKwh(cap)]);
    if (st.badSensor) rows.push(['Temperature', 'Sensor not reading', true]);
    else if (st.battTemp != null && (st.battTemp > 45 || st.battTemp < 5)) rows.push(['Temperature', Math.round(st.battTemp) + ' °C, ' + (st.battTemp > 45 ? 'hot' : 'cold'), st.battTemp > 45]);
  }
  const packs = st.shared ? Math.min(1, st.withBatt.length) : st.withBatt.length;
  const modules = st.shared ? Math.max(0, ...st.withBatt.map(i => i.numberOfBatteries || 0)) : st.withBatt.reduce((n, i) => n + (i.numberOfBatteries || 0), 0);
  const soc = Math.max(0, Math.min(100, a.battSoc || 0));
  return (
    <Card className="eq-card">
      <SectionTitle>BATTERY</SectionTitle>
      <div className={'eq-big mono' + (st.battStale ? ' stale' : '')} style={{ color: CC.batt }}>{a.battSoc ?? '—'}{a.battSoc != null && <span className="u">%</span>}</div>
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
  // under the inverter that reads its sensor: the slaves on a shared pack read -100.
  // One whose answer came back empty this minute is likely it, so it keeps the pack.
  const packInv = st.withBatt.find(i => cleanTemp(i.battTemp) != null) || st.withBatt.find(i => i.battSoc == null) || st.withBatt[0];
  if (st.hasBatt && reads && (!st.shared || inv === packInv)) {
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
            <div><b className="mono">{p.soc != null ? p.soc + '%' : '—'}</b><span>Charge</span></div>
            <div><b className="mono">{p.v != null ? p.v.toFixed(1) + ' V' : '—'}</b><span>Voltage</span></div>
            <div><b className="mono">{p.t != null ? Math.round(p.t) + ' °C' : '—'}</b><span>{p.t != null || p.soc == null ? 'Temperature' : 'Sensor not reading'}</span></div>
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
    const t = setInterval(() => { if (document.visibilityState === 'visible') load(); }, 600000);
    // off screen it skips; back on screen it catches up
    const back = () => { if (document.visibilityState === 'visible') load(); };
    document.addEventListener('visibilitychange', back);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', back); };
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
    : tab === 'home' ? <HomeSkeleton />
    : tab === 'grid' ? <GridSkeleton />
    : tab === 'inverters' ? <InvertersSkeleton />
    : <LiveSkeleton />;
}

// ---------------------------------------------------------------- SETTINGS / ACCOUNT
// Account, Billing and Plant, each one scrolling page in the Settings area (SOLAR-250,
// SettingsArea below). A section is its title and note over a full-width card.

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
        <button type="button" className="ghost-btn" onClick={onCancel} autoFocus>Cancel</button>
        <button type="button" className="danger-btn" onClick={onConfirm}>{action}</button>
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
  // A reload on #id scrolls back to it without the flash (SOLAR-165).
  React.useEffect(() => { if (flashing || location.hash === '#' + id) ref.current?.scrollIntoView({ block: 'start' }); }, [flashing]);
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

// The plan (SOLAR-208), on Billing since SOLAR-250: what it is, its price and renewal, then
// Adjust plan (a page of its own) and Cancel plan. Downgrade, cancel and a monthly/yearly
// switch wait for the billing date; going up is an upgrade and charges now
// (window.startUpgrade). Plants go first, then the plan: a downgrade the plants don't fit
// is refused, and the toast points at the logins on Plant.
const PLAN_NAME = { free: 'Free', home: 'Home', family: 'Family' };
const PLAN_RANK = { free: 0, home: 1, family: 2 };
const longDay = (d) => new Date(d + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
// Books a change for the billing date, or undoes one. True once booked.
async function bookPlan(b, plan, period, reload) {
  const { error } = await window.sb.rpc('api_billing_change', { p_plan: plan, p_period: period ?? null });
  if (error) {
    window.toast(/remove plants first/.test(error.message)
      ? `${PLAN_NAME[plan]} covers ${plan === 'family' ? '3 plants' : 'one plant'}. Remove SunSynk logins on Billing until that many are left, then try again.`
      : 'Couldn’t change your plan. Try again.', { error: true });
    return false;
  }
  await reload();
  window.track(plan === b.plan ? 'plan_change_undone' : 'downgrade_done', { plan, period: period ?? b.period });
  return true;
}
// A change booked for the billing date: what it says, and the button that undoes it.
function bookedChange(b) {
  const { billDay } = window.billingFmt;
  if (b.plan === 'free' || b.comped || !(b.nextPlan || b.nextPeriod)) return null;
  return b.nextPlan === 'free' ? [`Ends on ${billDay(b.nextDate)}, then you’re on Free.`, `Keep ${PLAN_NAME[b.plan]}`]
    : b.nextPlan ? [`Moves to ${PLAN_NAME[b.nextPlan]} on ${billDay(b.nextDate)}.`, `Keep ${PLAN_NAME[b.plan]}`]
    : [`Switches to ${b.nextPeriod} on ${billDay(b.nextDate)}.`, `Stay ${b.period}`];
}
const cancelText = (b) => `It runs until ${window.billingFmt.billDay(b.nextDate)}. After that you’re on Free: we keep only the last 24 hours of readings. Alerts stay on; reports stop.`;

function PlanSection({ billing, reload, onAdjust, collecting }) {
  const { useState } = React;
  const [busy, setBusy] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const kind = !billing ? null : billing.comped ? 'comped' : billing.plan !== 'free' ? 'paid' : 'free';
  React.useEffect(() => { if (kind) try { localStorage.setItem('synsynk.planKind', kind); } catch (e) {} }, [kind]);
  // Its outline while the plan loads, from the last plan seen on this device, so the
  // sections below don't jump down (SOLAR-221).
  if (!billing) {
    const last = (() => { try { return localStorage.getItem('synsynk.planKind'); } catch (e) { return null; } })() || 'free';
    return (
      <SettingsSection id="plan" title="Plan">
        <div className="plan-now" aria-hidden="true">
          <window.Skeleton w={84} h={11} r={5} />
          <window.Skeleton w={130} h={20} r={6} style={{ marginTop: 9 }} />
          <window.Skeleton w={280} h={12} r={5} style={{ marginTop: 9, maxWidth: '100%' }} />
        </div>
        {last !== 'comped' && (
          <div className="plan-acts" aria-hidden="true">
            <window.Skeleton w={112} h={34} r={9} />{last === 'paid' && <window.Skeleton w={112} h={34} r={9} />}
          </div>
        )}
      </SettingsSection>
    );
  }
  const { rand, billDay, perUnit } = window.billingFmt;
  const b = billing;
  const paid = b.plan !== 'free' && !b.comped;
  const booked = bookedChange(b);
  const ending = paid && b.nextPlan === 'free';
  const [word, tone] = b.state === 'past_due' ? ['Payment failed', 'warn'] : ending ? ['Ends ' + billDay(b.nextDate), 'warn'] : ['Active', 'ok'];
  const line = b.comped ? 'Free of charge. Every plant, full history.'
    : paid ? <><span className="mono">{rand(b.price)}</span> {perUnit(b.period)} for {collecting === 1 ? '1 plant' : (collecting || 'your') + ' plants'}. {ending ? 'Ends' : 'Renews'} on {longDay(b.nextDate)}.</>
    : '1 plant and the last 24 hours. No card needed.';
  const run = async (fn) => { setBusy(true); await fn(); setBusy(false); };
  return (
    <SettingsSection id="plan" title="Plan">
      <div className="plan-now">
        <div className="plan-lbl">Current plan</div>
        <div className="plan-name">{PLAN_NAME[b.plan]} <span className={'conn-status ' + tone}>{word}</span></div>
        <div className="conn-meta">{line}</div>
      </div>
      {b.state === 'past_due' && (
        <div className="plan-booked plan-alert">
          <span className="conn-status warn">Payment didn’t go through</span>
          <button type="button" className="save-btn" onClick={() => window.settlePayment()}>Pay with another card</button>
        </div>
      )}
      {booked && (
        <div className="plan-booked plan-alert">
          <span className="conn-status warn">{booked[0]}</span>
          <button type="button" className="ghost-btn" disabled={busy} onClick={() => run(() => bookPlan(b, b.plan, b.period, reload))}>{booked[1]}</button>
        </div>
      )}
      {!b.comped && (
        <div className="plan-acts">
          <button type="button" className={paid ? 'ghost-btn' : 'save-btn'} onClick={onAdjust}>Adjust plan</button>
          {paid && !ending && <button type="button" className="danger-btn" disabled={busy || cancelling} onClick={() => setCancelling(true)}>Cancel plan</button>}
        </div>
      )}
      {cancelling && (
        <ConfirmCard title={<>Cancel {PLAN_NAME[b.plan]}?</>} text={cancelText(b)} action="Cancel plan"
          onConfirm={() => { setCancelling(false); run(() => bookPlan(b, 'free', null, reload)); }} onCancel={() => setCancelling(false)} />
      )}
    </SettingsSection>
  );
}

// Adjust plan (SOLAR-250): a page of its own, back to Billing. Free, Home and Family side by
// side with a monthly/yearly switch. A paid plan's period changes on its billing date, so in
// the other period only its own card offers the switch. Family is priced per inverter past
// the 3rd plant, as before (the per-plant price is SOLAR-249).
const PLAN_TAG = { free: 'See your solar today', home: 'One house, every day kept', family: 'Up to 3 plants' };
function AdjustPlanPage({ billing, reload, onBack, paused, added }) {
  const { useState, useEffect } = React;
  const b = billing;
  const paid = !!b && b.plan !== 'free' && !b.comped;
  const [view, setView] = useState(paid ? b.period : 'monthly');
  const [busy, setBusy] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  // Family's real charge (the saved card pays it at once): on an upgrade from Home, or when
  // paused plants add inverters to it.
  const [quote, setQuote] = useState(null);
  const period = paid ? b.period : view;
  const quoted = !!b && !b.comped && (b.plan !== 'family' || added > 0);
  useEffect(() => { window.track('plan_page_shown', { plan: b?.plan }); }, []);
  useEffect(() => {
    if (!quoted) return;
    let alive = true;
    setQuote(null);
    window.sb.rpc('api_billing_quote', { p_plan: 'family', p_period: period, p_added: added })
      .then(({ data, error }) => alive && !error && setQuote(data));
    return () => { alive = false; };
  }, [quoted, period, added]);
  const back = <button type="button" className="back-link" onClick={onBack}><span aria-hidden="true">←</span> Billing</button>;
  if (!b) return (
    <div className="settings-page">
      {back}
      <div className="page-head"><h1>Pick your plan</h1></div>
      <div className="plan-grid plan-cards" aria-hidden="true">{[0, 1, 2].map(i => <window.Skeleton key={i} h={260} r={14} />)}</div>
    </div>
  );
  const { rand, billDay, perUnit } = window.billingFmt;
  const unit = perUnit(view);
  const prices = b.prices?.[view] || {};
  const sameView = !paid || view === b.period;
  const price = (p) => p === 'free' ? 0 : p === b.plan && sameView ? b.price
    : p === 'family' && quote && period === view ? quote.nextCharge : prices[p];
  const run = async (fn) => { setBusy(true); await fn(); setBusy(false); };
  const names = paused.length > 1 ? paused.slice(0, -1).join(', ') + ' and ' + paused[paused.length - 1] : paused[0];
  const booked = bookedChange(b);
  // The line under a price
  const note = (p) => {
    if (p === b.plan && sameView) return paid ? (booked ? 'Changes ' : 'Renews ') + billDay(b.nextDate) : 'No card needed';
    if (p === 'family' && paid && quote && sameView && quote.dueNow !== quote.nextCharge) return `${rand(quote.dueNow)} today, then from ${billDay(quote.nextDate)}`;
    if (p === 'family' && b.plan === 'home' && price('family') > price('home')) return `${rand(price('family') - price('home'))} more than Home`;
    return ' ';
  };
  const action = (p) => {
    if (p === b.plan) {
      if (!sameView) return b.nextPeriod === view ? <div className="plan-cur">From {billDay(b.nextDate)}</div>
        : <button type="button" className="ghost-btn" disabled={busy} onClick={() => run(() => bookPlan(b, b.plan, view, reload))}>Switch on {billDay(b.nextDate)}</button>;
      if (p === 'family' && added > 0) return <button type="button" className="save-btn" disabled={!quote} onClick={() => window.startUpgrade('family', period, added)}>Add paused plants</button>;
      return <div className="plan-cur">Your plan</div>;
    }
    if (!sameView) return null; // a paid plan changes plan in its own period
    if (PLAN_RANK[p] > PLAN_RANK[b.plan]) {
      return <button type="button" className="save-btn" disabled={paid && p === 'family' && !quote}
                     onClick={() => window.startUpgrade(p, period, p === 'family' ? added : 0, !paid)}>Upgrade</button>;
    }
    if (b.nextPlan === p) return <div className="plan-cur">From {billDay(b.nextDate)}</div>;
    return <button type="button" className="ghost-btn" disabled={busy || cancelling}
                   onClick={() => (p === 'free' ? setCancelling(true) : run(() => bookPlan(b, p, null, reload)))}>Downgrade</button>;
  };
  const gives = {
    free: [null, ['1 plant', 'The last 24 hours', 'Alerts']],
    home: ['Free', ['Full history', 'Reports by email']],
    family: ['Home', ['Up to 3 plants', `More plants: ${rand(prices.extra ?? 0)} ${unit} per inverter`]],
  };
  return (
    <div className="settings-page">
      {back}
      <div className="page-head">
        <h1>Pick your plan</h1>
        <p>{paid ? `Moving up starts today. Moving down waits for ${billDay(b.nextDate)}.` : 'Moving up starts today. Cancel any time.'}</p>
        {paused.length > 0 && <p className="plan-ctx">{names} {paused.length > 1 ? 'are' : 'is'} paused, not on your plan.</p>}
      </div>
      {b.comped ? <p className="field-note">Your plan is free of charge: every plant, full history.</p> : <>
        <div className="segmented seg-sm plan-period" role="group" aria-label="Billing">
          {['monthly', 'yearly'].map(p => (
            <button type="button" key={p} className={'seg-btn' + (view === p ? ' active' : '')} aria-pressed={view === p}
                    onClick={() => setView(p)}>{p === 'monthly' ? 'Monthly' : 'Yearly, save 16%'}</button>
          ))}
        </div>
        {!sameView && <p className="field-note">Your plan changes to {view} on {billDay(b.nextDate)}, its billing date.</p>}
        <div className="plan-grid plan-cards">
          {['free', 'home', 'family'].map(p => (
            <div key={p} className={'pw-plan' + (p === b.plan ? ' plan-mine' : '') + (p === 'free' ? ' plan-free' : '')}>
              <div className="pw-name">{PLAN_NAME[p]}</div>
              <div className="plan-tagline">{PLAN_TAG[p]}</div>
              <div className="pw-price"><b>{rand(price(p) ?? 0)}</b>{p !== 'free' && ' ' + unit}</div>
              <div className="plan-note">{note(p)}</div>
              {action(p)}
              <ul className="pw-gives plan-gives">
                {gives[p][0] && <li className="plan-also">Everything in {gives[p][0]}, and</li>}
                {gives[p][1].map(g => <li key={g}>{g}</li>)}
              </ul>
            </div>
          ))}
        </div>
        {cancelling && (
          <ConfirmCard title={<>Cancel {PLAN_NAME[b.plan]}?</>} text={cancelText(b)} action="Cancel plan"
            onConfirm={() => { setCancelling(false); run(() => bookPlan(b, 'free', null, reload)); }} onCancel={() => setCancelling(false)} />
        )}
        <p className="field-note plan-foot">Paid by card through Paystack. Cancel any time.</p>
      </>}
    </div>
  );
}

// The saved card and the money taken (SOLAR-238). Change card opens Paystack's card
// page for R1, which goes back once the card is saved.
function PaymentsSection({ billing }) {
  const { useState } = React;
  const [busy, setBusy] = useState(false);
  const b = billing;
  if (!b || b.comped || (b.plan === 'free' && !b.card && !(b.payments || []).length)) return null;
  const { rand } = window.billingFmt;
  const c = b.card;
  const day = (d) => new Date(d + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
  const what = { start: '', upgrade: 'upgrade', renewal: '', settle: 'paid late' };
  return (
    <SettingsSection id="payments" title="Payment" note={b.plan !== 'free' ? 'Paystack charges your card on your billing date.' : null}>
      {c ? (
        <div className="conn-row">
          <span className="pay-card" aria-hidden="true">{c.brand === 'mastercard' ? 'MC' : (c.brand || 'card').toUpperCase().slice(0, 4)}</span>
          <div className="conn-text">
            <div className="conn-user">{c.name} ending <span className="mono">{c.last4}</span></div>
            <div className="conn-meta">Expires {String(c.expMonth).padStart(2, '0')}/{String(c.expYear).slice(-2)}</div>
          </div>
          {/* past due: Pay with another card in Plan changes it and pays */}
          {b.plan !== 'free' && b.state !== 'past_due' && (
            <div className="conn-actions">
              <button type="button" className="ghost-btn" disabled={busy} aria-busy={busy}
                      onClick={async () => { setBusy(true); await window.changeCard(); setBusy(false); }}>{busy ? 'Opening…' : 'Update'}</button>
            </div>
          )}
        </div>
      ) : <div className="field-note">No card saved.</div>}
      {(b.payments || []).length > 0 && (
        <div className="pay-list">
          {b.payments.map(p => (
            <div key={p.at} className="pay-row">
              <span>{day(p.date)}</span>
              <span className="pay-what">{PLAN_NAME[p.plan]}, {p.period}{what[p.kind] ? ', ' + what[p.kind] : ''}</span>
              <span className="mono pay-amt">{rand(p.amount)}</span>
            </div>
          ))}
        </div>
      )}
    </SettingsSection>
  );
}

// Billing's Plants: the signed-in user's SunSynk logins, each with its plants and their state, one row each with its plants, a reconnect in
// place when the token has died, and a remove. Adding or removing a login changes
// which plants the app can see, so the app reloads its plant list afterwards; when
// the last login goes there is nothing left to show and the app turns to its empty pages.
// `links` is the gate's own list (LinkGate), already read before the page opened, so the
// section draws at once and its changes reach the rest of the app (SOLAR-96).
// Plant states (paused, deleted) and their buttons are on Billing since SOLAR-250.
function SunSynkConnectionSection({ onChanged, links, billing, reloadBilling, onCollect }) {
  const { useState } = React;
  const { accounts, error, refresh } = links;
  const [busy, setBusy] = useState(null);
  const fail = (text) => window.toast(text, { error: true }); // SOLAR-166
  const [mode, setMode] = useState(null); // null | 'add' | account_id being reconnected
  const live = accounts.filter(a => a.status !== 'disabled');
  // A failed read with nothing listed says nothing about the logins; "No login connected"
  // would be a guess. Try again re-reads.
  const unread = !!error && !live.length;
  const [checking, setChecking] = useState(false);
  const retry = async () => { setChecking(true); await refresh(); setChecking(false); };
  // "read 2 min ago": freshness is what a login row is for, not the calendar date
  const ago = (iso) => {
    const s = (Date.now() - new Date(iso).getTime()) / 1000;
    if (s < 90) return 'just now';
    const m = Math.round(s / 60); if (m < 90) return m + ' min ago';
    const h = Math.round(m / 60); if (h < 36) return h + ' h ago';
    return Math.round(h / 24) + ' days ago';
  };
  // Waits for the fresh list, so the form's "Connecting…" holds until the login is listed.
  const changed = async (linked) => {
    const adding = mode === 'add';
    const readError = await refresh();
    setMode(null); onChanged && onChanged(linked);
    if (readError) { fail('Connected. Reload the page to see it here.'); return; }
    const paused = new Set((linked?.paused || []).map(Number));
    const on = (linked?.plants || []).filter(p => !paused.has(Number(p.id)));
    const off = (linked?.plants || []).filter(p => paused.has(Number(p.id)));
    window.toast(adding ? 'Login added.' + plantsLine(on, 'now in your plant list') + plantsLine(off, 'paused, not on your plan') : 'Login reconnected.');
  };
  // " Plant 495944 is now in your plant list." for one plant, "… and … are …" for more
  const plantsLine = (plants, what) => {
    const names = (plants || []).map(p => p.name || p.plant_name || 'Plant ' + (p.id ?? p.plant_id));
    if (!names.length) return '';
    const list = names.length > 1 ? names.slice(0, -1).join(', ') + ' and ' + names[names.length - 1] : names[0];
    return ' ' + list + (names.length > 1 ? ' are ' : ' is ') + what + '.';
  };
  // Removing asks once, inline under the row, in the app's own language rather than a
  // browser dialog. 'confirming' holds the account_id whose card is open.
  const [confirming, setConfirming] = useState(null);
  const [leaving, setLeaving] = useState(null); // account_id folding away after a remove
  const paidPlan = billing && billing.plan !== 'free' && !billing.comped; // never billed: remove at once
  const { billDay } = window.billingFmt;
  // On a paid plan a login's plants stay until the billing date, then go (0113).
  const remove = async (acc) => {
    const last = live.length === 1;
    setConfirming(null);
    setBusy(acc.account_id);
    try {
      const { data: res, error } = await window.sb.rpc('api_link_remove', { p_account: acc.account_id });
      if (error) throw error;
      if (res?.result === 'booked') {
        await Promise.all([refresh(), reloadBilling && reloadBilling()]);
        setBusy(null);
        window.toast(`Login stays until ${billDay(res.on)}, then it’s deleted.`);
        return;
      }
      window.track('login_remove_done');
      // The last login: re-reading the list leaves no plant, so the app turns to its empty
      // pages in place. A reload here blanked the screen first (SOLAR-98).
      const gone = 'Login removed.' + plantsLine(acc.plants, 'no longer in your plant list');
      if (last) { await refresh(); window.toast(gone); return; }
      setBusy(null); setLeaving(acc.account_id);
      // The row stays folded until the fresh list drops it; clearing it first popped it back.
      // If that read fails the old list stays, so the row stays folded rather than showing
      // a login that is gone. Not changed(): an Add form open meanwhile keeps its fields.
      const [readError] = await Promise.all([refresh(), new Promise(r => setTimeout(r, 240))]); // matches .conn-row.leaving
      onChanged && onChanged();
      if (readError) fail('Removed. Reload the page to update this list.'); else { setLeaving(null); window.toast(gone); }
    } catch (e) { fail('Couldn’t remove the login. Try again.'); setBusy(null); setLeaving(null); }
  };
  // Each plant once, with its state (SOLAR-208): paused (not on the plan), deleted on the
  // billing date, collecting while any login that sees it works, else stopped.
  const plantOk = {};
  live.forEach(a => (a.plants || []).forEach(p => { plantOk[p.plant_id] = plantOk[p.plant_id] || a.status === 'active'; }));
  const state = (p) => p.paused ? 'paused' : p.remove_on ? 'going' : plantOk[p.plant_id] ? 'on' : 'off';
  const allPlants = [...new Map(live.flatMap(a => a.plants || []).map(p => [p.plant_id, p])).values()];
  const keep = async (p) => {
    setBusy('keep:' + p.plant_id);
    const { error } = await window.sb.rpc('api_billing_keep', { p_plant: p.plant_id });
    if (error) fail(/needed for your plan change/.test(error.message) ? 'Your plan change needs this removed. Undo the change in Plan first.' : 'Couldn’t keep it. Try again.');
    await Promise.all([refresh(), reloadBilling && reloadBilling()]);
    setBusy(null);
  };
  const plantRow = (p) => {
    const s = state(p);
    const [word, tone] = { on: ['Collecting', 'ok'], off: ['Stopped', 'warn'], paused: ['Paused', 'warn'], going: ['Deleted ' + billDay(p.remove_on), 'bad'] }[s];
    const n = Number(p.inverters) || 0;
    return (
      <div key={p.plant_id} className="login-plant">
        <div className="conn-text">
          <div className="conn-user">{p.plant_name || 'Plant ' + p.plant_id}</div>
          <div className="conn-meta">{s === 'paused' ? 'Not on your plan. Its readings aren’t saved.' : n ? n + (n === 1 ? ' inverter' : ' inverters') : '\u00a0'}</div>
        </div>
        <span className={'conn-status plant-state ' + tone}>{word}</span>
        {s === 'paused' && onCollect && <button type="button" className="save-btn" onClick={onCollect}>Collect</button>}
        {s === 'going' && <button type="button" className="ghost-btn" disabled={busy === 'keep:' + p.plant_id} onClick={() => keep(p)}>Keep</button>}
      </div>
    );
  };
  const title = <>Plants{allPlants.length > 0 && <span className="sset-count">{allPlants.filter(p => state(p) === 'on').length} of {allPlants.length} collecting</span>}</>;
  return (
    <SettingsSection id="connection" title={title} note="Each SunSynk login and the plants it brings.">
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
        const word = !ok ? 'Sign-in expired' : stale ? 'Not updating' : 'Connected';
        const plants = acc.plants || [];
        return (
          <div key={acc.account_id} className={'conn-row' + (leaving === acc.account_id ? ' leaving' : '')}>
            <div className="conn-text">
              {/* Line 1: the login. Line 2: is it working, and the last reading when that
                  is the news. Its plants are listed under it. */}
              <div className="conn-user"><span className="mono">{acc.sunsynk_username}</span></div>
              <div className="conn-meta">
                <span className={'conn-status' + (ok && !stale ? ' ok' : ' warn')}>{word}</span>
                {(!ok || stale) && acc.last_ok_at ? ' · last reading ' + ago(acc.last_ok_at) : ''}
              </div>
            </div>
            <div className="conn-actions">
              {!ok && mode !== acc.account_id && <button type="button" className="save-btn" onClick={() => setMode(acc.account_id)}>Reconnect</button>}
              <button type="button" className="ghost-btn" onClick={() => setConfirming(confirming === acc.account_id ? null : acc.account_id)} disabled={busy === acc.account_id}>
                {busy === acc.account_id ? 'Removing…' : 'Remove'}
              </button>
            </div>
            <div className="login-plants">
              {plants.length ? plants.map(plantRow) : <div className="conn-meta">No plant shared with this login.</div>}
            </div>
            {/* the reconnect form and the remove card sit under the whole row, full width */}
            {mode === acc.account_id && (
              <window.LinkForm compact relink initialUsername={acc.sunsynk_username} onLinked={changed} onCancel={() => setMode(null)} />
            )}
            {confirming === acc.account_id && (
              <ConfirmCard
                title={<>Remove <b>{acc.sunsynk_username}</b>?</>}
                text={paidPlan && plants.length
                  ? `It stays until ${billDay(billing.nextDate)}, then it’s deleted with its history, unless another account shares it.`
                  : 'This plant’s history is deleted too, unless another account shares it.' + (live.length === 1 ? ' It’s your only login. Your pages stay empty until you add one.' : '')}
                action="Remove login" onConfirm={() => remove(acc)} onCancel={() => setConfirming(null)} />
            )}
          </div>
        );
      })}
      {!unread && (mode === 'add'
        ? <div className="conn-row conn-add-row"><div className="conn-text">
            {/* Cancel re-reads too: a login with no plant yet is saved but not listed. */}
            <window.LinkForm compact hasPlant={live.some(a => (a.plants || []).length > 0)} onLinked={changed} onCancel={() => { setMode(null); refresh(); }} />
          </div></div>
        : <div className="conn-add">
            <button type="button" className="save-btn" onClick={() => setMode('add')}>
              Add SunSynk login
            </button>
          </div>)}
    </SettingsSection>
  );
}

// Per-plant numbers live in plant_config and are the user's to edit. Timezone and
// currency arrive from SunSynk at link time; the rest are theirs. The roof is not asked
// for: the planned best-day line (BEST_DAY_CURVE.md) would learn from the plant's readings.
// One form, three sections, one floating save bar. The fields are First steps' own
// (StepField, SumBox in app.jsx, SOLAR-170), so a value is entered the same way in both.
const SYSTEM_NOTE = 'Sizes the charts and the battery’s time left.';
function PlantSections({ me, plantId, onSaved, onDirty, switchBlocked }) {
  const { useState, useEffect } = React;
  const plant = (me?.plants || []).find(p => p.id === plantId) || (me?.plants || [])[0];
  const cfg = plant?.config || {};
  // The battery keeps only its kWh, so it opens on Total; panels open on By size when rows
  // are saved (panel_groups), else on Total.
  const fromCfg = (c) => {
    const groups = Array.isArray(c?.panel_groups) && c.panel_groups.length ? c.panel_groups : null;
    return {
      rate: c?.tariff_import > 0 ? String(c.tariff_import) : '',
      res: String(c?.battery_reserve_pct ?? 20),
      bMode: 'total', bTot: c?.battery_kwh > 0 ? String(c.battery_kwh) : '', bRows: window.rowsFrom(null),
      pMode: groups ? 'rows' : 'total', pTot: !groups && c?.system_kwp > 0 ? String(c.system_kwp) : '', pRows: window.rowsFrom(groups),
    };
  };
  const [f, setF] = useState(() => fromCfg(cfg));
  const [busy, setBusy] = useState(false);
  const [tried, setTried] = useState(false);   // Save pressed with a box still wrong: its line shows
  useEffect(() => { setF(fromCfg(plant?.config)); setTried(false); }, [plant?.id, JSON.stringify(plant?.config || {})]);
  const set = (k) => (v) => setF(x => ({ ...x, [k]: v }));
  const n = window.stepNum;
  const whole = (x, lo, hi) => Number.isInteger(n(x)) && n(x) >= lo && n(x) <= hi;
  const batt = window.sumOf('size', f.bMode, f.bTot, f.bRows);
  const pan = window.sumOf('panels', f.pMode, f.pTot, f.pRows);
  // An empty rate is 0 (savings show as zero). A stored reserve outside 5..50, left alone, is kept.
  const rateOk = f.rate === '' || n(f.rate) >= 0;
  const resOk = whole(f.res, 5, 50) || n(f.res) === (cfg.battery_reserve_pct ?? 20);
  // What Save sends: the way on screen for battery and panels, empty meaning none
  const patch = {
    tariff_import: f.rate === '' ? 0 : n(f.rate),
    battery_kwh: batt.empty ? null : +batt.value.toFixed(3),
    battery_reserve_pct: n(f.res),
    ...(pan.empty ? { system_kwp: null, panel_groups: null }
      : f.pMode === 'total' ? { system_kwp: pan.value, panel_groups: null }
      : { system_kwp: pan.value, panel_groups: pan.filled.map(r => ({ count: n(r.c), watts: n(r.e) })) }),
  };
  const bad = { rate: !rateOk, res: !resOk, batt: !batt.ok, pan: !pan.ok };
  // Numbers are compared as numbers, not as typed: 12.60 over a stored 12.6 is not a change.
  // Switching Total and By size alone is not a change unless what would be saved differs.
  const groupsOf = (g) => JSON.stringify(Array.isArray(g) && g.length ? g.map(x => ({ count: Number(x.count), watts: Number(x.watts) })) : null);
  const dirty = Object.values(bad).some(Boolean)
    || patch.tariff_import !== (cfg.tariff_import ?? 0) || patch.battery_kwh !== (cfg.battery_kwh ?? null)
    || patch.battery_reserve_pct !== (cfg.battery_reserve_pct ?? 20) || patch.system_kwp !== (cfg.system_kwp ?? null)
    || groupsOf(patch.panel_groups) !== groupsOf(cfg.panel_groups);
  // App holds the plant still while there are unsaved changes; a switch asked for meanwhile
  // says so in the save bar until the changes are saved or discarded.
  useEffect(() => { onDirty && onDirty(dirty); }, [dirty]);
  useEffect(() => () => onDirty && onDirty(false), []);
  const [blocked, setBlocked] = useState(false);
  useEffect(() => { if (switchBlocked && dirty) setBlocked(true); }, [switchBlocked]);
  useEffect(() => { if (!dirty) setBlocked(false); }, [dirty]);

  // South Africa only, for now: no feed-in rate, currency or timezone to set. Those
  // columns keep what SunSynk reported at link time and are never sent from here.
  const save = async () => {
    if (!plant) return;
    // A box still wrong: Save stays pressable (the bar is shared) and instead shows each
    // wrong box's line and puts focus on the first
    if (Object.values(bad).some(Boolean)) {
      setTried(true);
      setTimeout(() => document.querySelector('.settings-page .fs-in.bad input, .settings-page .sset-err')?.closest('.sset-row')?.querySelector('input')?.focus());
      return;
    }
    // The toast names what changed, read before the reload replaces cfg
    const num = (x) => String(+x.toFixed(2));
    const said = [];
    if (patch.tariff_import !== (cfg.tariff_import ?? 0)) said.push('rate R' + patch.tariff_import.toFixed(2) + ' a unit');
    if (patch.battery_reserve_pct !== (cfg.battery_reserve_pct ?? 20)) said.push('reserve ' + patch.battery_reserve_pct + '%');
    if (patch.battery_kwh !== (cfg.battery_kwh ?? null)) said.push(patch.battery_kwh == null ? 'no battery size' : 'battery ' + num(patch.battery_kwh) + ' kWh');
    if (patch.system_kwp !== (cfg.system_kwp ?? null) || groupsOf(patch.panel_groups) !== groupsOf(cfg.panel_groups))
      said.push(patch.system_kwp == null ? 'no panel size' : 'panels ' + num(patch.system_kwp) + ' kW');
    setBusy(true);
    // Failed: the bar keeps the edits, the red toast says so
    // A reserve set here is confirmed for First steps too (SOLAR-247)
    const send = patch.battery_reserve_pct !== (cfg.battery_reserve_pct ?? 20) ? { ...patch, battery_reserve_confirmed: true } : patch;
    try { await window.savePlantConfig(plant.id, send); }
    catch (e) { window.toast('Couldn’t save. Try again.', { error: true }); setBusy(false); return; }
    setTried(false);
    // Saving… holds until the reload closes the bar, so the toast takes its place
    await Promise.resolve(onSaved && onSaved()).catch(() => {});
    window.toast(said.length ? 'Saved: ' + said.join(', ') + '.' : 'Saved.');
    setBusy(false);
  };

  // The plant list is still on its way: the section with its words, and a shimmer in
  // each box's place at its size, so nothing moves when the values land (SOLAR-221).
  if (!me) {
    const row = (label, meta, sum) => (
      <div className="conn-row sset-row">
        <div className="conn-text"><span className="conn-user">{label}</span><span className="conn-meta">{meta}</span></div>
        {sum
          ? <div className="sset-sum"><div className="fs-sum">
              {/* the Total / By size switch is words only, so it draws for real, locked */}
              <div className="fs-sumhead"><div className="fs-seg"><button type="button" className="on" disabled>Total</button><button type="button" disabled>By size</button></div><b className="fs-val mono">{NBSP}</b></div>
              <window.Skeleton className="fs-in" w="" h={41} r={9} />
            </div></div>
          : <div className="conn-actions sset-one"><window.Skeleton className="fs-in" w="" h={41} r={9} /></div>}
      </div>
    );
    return (
      <SettingsSection id="system" title="Your system" note={SYSTEM_NOTE}>
        {row('Solar panels', 'What they make in full sun.', true)}
        {row('Battery capacity', 'All batteries together.', true)}
        {row('Battery reserve', 'The battery stops powering your home at this charge.')}
        {row('Electricity rate', 'Savings show as zero until this is set.')}
      </SettingsSection>
    );
  }
  if (!plant) return <SettingsSection id="system" title="Your system"><div className="field-note">No plant connected yet.</div></SettingsSection>;
  const sym = window.moneySymbol ? window.moneySymbol() : (cfg.currency || '');
  const err = (on, text) => on && tried ? <p className="sset-err" role="alert">{text}</p> : null;
  return (
    <>
      {/* One section since SOLAR-250: panels, battery, reserve, rate */}
      <SettingsSection id="system" title="Your system" note={SYSTEM_NOTE}>
        <div className="conn-row sset-row">
          <div className="conn-text">
            <span className="conn-user">Solar panels</span>
            <span className="conn-meta">What they make in full sun.</span>
          </div>
          <div className="sset-sum">
            <window.SumBox kind="panels" mode={f.pMode} onMode={set('pMode')} tot={f.pTot} onTot={set('pTot')} rows={f.pRows} onRows={set('pRows')} label="Solar panels" />
            {err(bad.pan, f.pMode === 'total' ? 'Enter more than 0 kW.' : 'Enter whole panels and 50 to 1000 W each.')}
          </div>
        </div>
        <div className="conn-row sset-row">
          <div className="conn-text">
            <span className="conn-user">Battery capacity</span>
            <span className="conn-meta">All batteries together.</span>
          </div>
          <div className="sset-sum">
            <window.SumBox kind="size" mode={f.bMode} onMode={set('bMode')} tot={f.bTot} onTot={set('bTot')} rows={f.bRows} onRows={set('bRows')} label="Battery size" />
            {err(bad.batt, f.bMode === 'total' ? 'Enter more than 0 kWh.' : 'Enter whole batteries and the kWh of one.')}
          </div>
        </div>
        <div className="conn-row sset-row">
          <div className="conn-text">
            <span className="conn-user">Battery reserve</span>
            <span className="conn-meta">The battery stops powering your home at this charge.</span>
          </div>
          <div className="conn-actions sset-one">
            <window.StepField value={f.res} onChange={set('res')} label="Reserve" unit="%" inputMode="numeric" ph="20" invalid={tried && bad.res} />
            {err(bad.res, 'Enter 5 to 50.')}
          </div>
        </div>
        {/* A unit is a kWh: it is what a South African bill calls one, so the rate is per unit */}
        <div className="conn-row sset-row">
          <div className="conn-text">
            <span className="conn-user">Electricity rate</span>
            <span className="conn-meta">{n(f.rate) > 0 ? 'Used to work out what solar saved.' : 'Savings show as zero until this is set.'}</span>
          </div>
          <div className="conn-actions sset-one">
            <window.StepField value={f.rate} onChange={set('rate')} label="Electricity rate" pre={sym} unit="/unit" inputMode="decimal" ph="3.40" invalid={tried && bad.rate} />
            {err(bad.rate, 'Enter a price, like 3.40.')}
          </div>
        </div>
      </SettingsSection>

      {dirty && (
        <div className="save-bar dirty" role="status">
          <span className="save-text">{blocked ? 'Save or discard before switching plant.' : 'Unsaved changes'}</span>
          <button type="button" className="ghost-btn" onClick={() => { setF(fromCfg(cfg)); setTried(false); }} disabled={busy}>Discard</button>
          <button type="button" className="save-btn" onClick={save} disabled={busy}>{busy ? 'Saving…' : 'Save'}</button>
        </div>
      )}
    </>
  );
}

// Change password (SOLAR-155), for a user with an email login; Google-only users have no
// password, so the section doesn't show. The current password is checked by signing in
// with it, which also gives the fresh session Supabase wants before a password change.
// Saving signs out every other device, so whoever had the old password is out.
// "Reset password" in the password-changed email (?reset=1) arrives with it already open.
function PasswordRow({ email }) {
  const { useState, useEffect } = React;
  // Account mounts again once the plant list arrives, so the ask is only peeked here and
  // cleared when the form closes.
  const [open, setOpen] = useState(() => window.resetAsked());
  const [cur, setCur] = useState('');
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [bad, setBad] = useState({});
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (open) document.getElementById('pw-current')?.focus(); }, [open]);

  const close = () => { window.takeResetAsk(); setOpen(false); setCur(''); setPw(''); setPw2(''); setBad({}); };
  const flag = (problems) => { setBad(problems); setTimeout(() => document.getElementById(Object.keys(problems)[0])?.focus()); };
  const edited = (...ids) => setBad(b => {
    if (!ids.some(id => b[id])) return b;
    const next = { ...b };
    ids.forEach(id => delete next[id]);
    return next;
  });
  const check = () => {
    const out = {};
    if (!cur) out['pw-current'] = 'Enter your password';
    // Matches the minimum set in Supabase (Auth → Email) and supabase/config.toml.
    if (!pw) out['pw-new'] = 'Choose a password';
    else if (pw.length < 8) out['pw-new'] = 'Use at least 8 characters';
    // No "same as current" check here: matching boxes don't mean the current one is
    // right. Supabase answers in order: wrong current password, then same_password.
    if (!pw2) out['pw-confirm'] = 'Confirm your password';
    else if (pw !== pw2) out['pw-confirm'] = 'Passwords don’t match';
    return out;
  };

  const submit = async (e) => {
    e.preventDefault();
    const problems = check();
    if (Object.keys(problems).length) return flag(problems);
    setBusy(true); setBad({});
    try {
      const { error: wrong } = await window.sb.auth.signInWithPassword({ email, password: cur });
      if (wrong?.code === 'invalid_credentials') return flag({ 'pw-current': 'Wrong password' });
      if (wrong) throw wrong;
      const { error } = await window.sb.auth.updateUser({ password: pw });
      if (error) throw error;
      window.track('password_change_done');
      const { error: others } = await window.sb.auth.signOut({ scope: 'others' }).catch(ex => ({ error: ex }));
      close();
      window.toast(others ? 'Password changed. Other devices are still signed in.' : 'Password changed. Other devices signed out.');
    } catch (ex) {
      const x = window.explainAuthError(ex);
      if (x.field) flag({ 'pw-new': x.text });
      else window.toast(x.text, { error: true });
    } finally {
      setBusy(false);
    }
  };

  const label = (id, text, hint) => (
    <label htmlFor={id}>{text}{bad[id] ? <span className="link-bad" id={id + '-err'}>{bad[id]}</span> : hint && <span>{hint}</span>}</label>
  );
  const field = (id, text, value, set, autoComplete, hint, also = []) => (
    <div className={'field' + (id === 'pw-confirm' ? ' link-last' : '')}>
      {label(id, text, hint)}
      <window.LinkPassword id={id} autoComplete={autoComplete} value={value}
                           onChange={(v) => { set(v); edited(id, ...also); }} invalid={window.invalidProps(id, bad[id])} />
    </div>
  );
  return (
      <div className="conn-row" id="settings-password">
        <div className="conn-text"><div className="conn-user">Change password</div><div className="conn-meta">Signs out your other devices.</div></div>
        {!open && <div className="conn-actions"><button type="button" className="ghost-btn" onClick={() => setOpen(true)}>Change</button></div>}
        {open && (
          <form className="conn-form link-form" onSubmit={submit} noValidate aria-busy={busy}>
            {/* The email, unseen, so a password manager knows which login to update. */}
            <input type="email" autoComplete="username" value={email || ''} readOnly hidden />
            {field('pw-current', 'Current password', cur, setCur, 'current-password')}
            {field('pw-new', 'New password', pw, setPw, 'new-password', '8+ characters', ['pw-confirm'])}
            {field('pw-confirm', 'Confirm password', pw2, setPw2, 'new-password')}
            <div className="conn-form-actions">
              <button type="button" className="ghost-btn" onClick={close} disabled={busy}>Cancel</button>
              <button type="submit" className="save-btn" disabled={busy} aria-busy={busy}>{busy ? 'Saving…' : 'Save password'}</button>
            </div>
          </form>
        )}
      </div>
  );
}

// The plant's readings for any range of days as one CSV (SOLAR-191). api_export
// builds the file; a year at most. Full history (paid) once plans exist: SOLAR-104.
function DownloadSection() {
  const { useState } = React;
  const over = window.useFreeOver(); // Free after its week (SOLAR-242): the button is a lock
  const today = window.localDateStr(new Date());
  const weekAgo = window.localDateStr(new Date(Date.now() - 6 * 86400000));
  const [from, setFrom] = useState(weekAgo);
  const [to, setTo] = useState(today);
  const [bad, setBad] = useState(null);
  const [busy, setBusy] = useState(false);
  const days = (a, b) => Math.round((new Date(b) - new Date(a)) / 86400000);

  const submit = async () => {
    if (!from || !to) return setBad('Pick both dates.');
    if (to < from) return setBad('Pick a To date after From.');
    if (days(from, to) > 365) return setBad('Pick a year or less.');
    setBad(null); setBusy(true);
    try {
      const { data, error } = await window.sb.rpc('api_export', { p_from: from, p_to: to, p_plant: window.CURRENT_PLANT });
      if (error) throw error;
      if (!data || data.indexOf('\n') === data.length - 1) { window.toast('No readings for those days.', { error: true }); return; }
      const a = document.createElement('a');
      a.href = URL.createObjectURL(new Blob([data], { type: 'text/csv' }));
      a.download = `prince-solar-${from}-to-${to}.csv`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      // agg_minute holds the last 31 days; older days come from agg_5m.
      const minuteFrom = window.localDateStr(new Date(Date.now() - 30 * 86400000));
      const resolution = from >= minuteFrom ? 'minute' : to < minuteFrom ? '5min' : 'mixed';
      window.track('data_download_done', { days: days(from, to) + 1, resolution });
    } catch (ex) {
      window.toast('Couldn’t download. Try again.', { error: true });
    } finally {
      setBusy(false);
    }
  };

  // From, To and Download on one line; on a phone they stack.
  const field = (id, text, value, set) => (
    <div className="dl-field">
      <label htmlFor={id} className="conn-meta">{text}</label>
      <div className={'fs-in' + (bad ? ' bad' : '')}>
        <input id={id} type="date" value={value} max={today}
               onChange={(e) => { set(e.target.value); setBad(null); }} {...window.invalidProps(id, bad, 'dl-err')} />
      </div>
    </div>
  );
  return (
    <SettingsSection id="download" title="Your data" note="A CSV file. Every minute for the last 31 days, every 5 minutes before that.">
      <div className="dl-row">
        {field('dl-from', 'From', from, setFrom)}
        {field('dl-to', 'To', to, setTo)}
        {over ? <button type="button" className="ghost-btn lock-cta" onClick={() => window.openPlans('csv')}><window.LockIcon />Download</button>
          : <button type="button" className="save-btn" onClick={submit} disabled={busy} aria-busy={busy}>{busy ? 'Preparing…' : 'Download'}</button>}
      </div>
      {bad && <p className="sset-err" id="dl-err" role="alert">{bad}</p>}
    </SettingsSection>
  );
}

// Delete account is off while a paid plan runs: cancel it on Billing first (SOLAR-250).
// A plan already cancelled (it ends on its billing date) doesn't block it.
function DeleteAccountRow({ email, billing, onBilling }) {
  const { useState } = React;
  const blocked = !!billing && billing.plan !== 'free' && !billing.comped && billing.nextPlan !== 'free';
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const del = async () => {
    setConfirming(false);
    setBusy(true);
    // The account is gone; signing out here is what moves the screen to sign-in, once.
    // No reload after it: that blanked the page and drew sign-in again (SOLAR-98).
    try { await window.deleteAccount(); await window.signOutHere(); }
    catch (e) { window.toast('Couldn’t delete the account. Try again.', { error: true }); setBusy(false); }
  };
  return (
    <div className="conn-row" id="settings-delete">
      <div className="conn-text">
        <div className="conn-user">Delete account</div>
        <div className="conn-meta">Deletes your logins, settings and email choices.</div>
      </div>
      <div className="conn-actions"><button type="button" className="danger-btn" onClick={() => setConfirming(c => !c)} disabled={blocked || busy || confirming}>{busy ? 'Deleting…' : 'Delete'}</button></div>
      {blocked && (
        <div className="set-warn">
          <span>Cancel your <b>{PLAN_NAME[billing.plan]} plan</b> before you delete your account.</span>
          <button type="button" className="text-link" onClick={onBilling}>Go to Billing</button>
        </div>
      )}
      {confirming && (
        <ConfirmCard title={<>Delete <b>{email || 'this account'}</b>?</>} text="Your plants’ history goes too, unless another account shares them. It cannot be undone."
          action="Delete account" onConfirm={del} onCancel={() => setConfirming(false)} />
      )}
    </div>
  );
}

// Settings: the plant on screen.
// The First steps card once hidden (SOLAR-170): here only while it has steps left.
function FirstStepsSection({ me, plantId, onSaved }) {
  const [busy, setBusy] = React.useState(false);
  const fs = window.firstSteps(me, plantId);
  if (!fs || !fs.mine.hidden || !fs.left.length) return null;
  // Done, the card is back on screen; failed, the red toast says so
  const show = () => {
    setBusy(true);
    window.saveFirstSteps(me, plantId, { hidden: false }).then(onSaved)
      .catch(() => window.toast('Couldn’t show First steps. Try again.', { error: true })).finally(() => setBusy(false));
  };
  return (
    <SettingsSection id="steps" title="First steps">
      <div className="conn-row sset-row">
        <div className="conn-text">
          <span className="conn-user">Finish setup</span>
          <span className="conn-meta">{fs.left.length === 1 ? '1 step left.' : fs.left.length + ' steps left.'}</span>
        </div>
        <div className="conn-actions"><button type="button" className="ghost-btn" onClick={show} disabled={busy}>Show</button></div>
      </div>
    </SettingsSection>
  );
}

// Report and alert emails (SOLAR-158), in two groups that open to one switch per email
// (SOLAR-164). A group's switch is on while any email in it is on, and sets them all.
// A tap saves at once and flips back if the save fails. "SunSynk disconnected" and
// account emails have no switch. The footer of every report and alert email opens this
// (section=notifications).
const EMAIL_GROUPS = [
  { id: 'reports', label: 'Reports', rows: [
    ['weekly', 'Weekly', 'Last week, on Mondays.'],
    ['monthly', 'Monthly', 'Last month, on the 1st.'],
    ['yearly', 'Yearly', 'Last year, on 1 January.']] },
  { id: 'alerts', label: 'Alerts', when: 'Sent when it happens', rows: [
    ['grid', 'Grid', 'The grid goes off, and when it’s back.'],
    ['battery', 'Battery', 'Over 40 °C, or charging unevenly. Once a day while it lasts.'],
    ['panels', 'Panels', 'A string stops while the others make power. Once a day while it lasts.'],
    ['readings', 'Readings', 'No readings for 15 min, and when they’re back.'],
    ['sunsynk', 'SunSynk', 'SunSynk stops answering, and when it’s back.']] },
];
// "All 3 on", "Weekly and Monthly on", "4 of 5 on. Sent when it happens", "Off".
function emailGroupSummary(g, prefs) {
  const on = g.rows.filter(([k]) => !prefs || prefs[k]).map(([, label]) => label);
  if (!on.length) return 'Off';
  const names = on.length === g.rows.length ? 'All ' + on.length
    : on.length > 2 ? on.length + ' of ' + g.rows.length : on.join(' and ');
  return names + ' on' + (g.when ? '. ' + g.when : '');
}
function NotificationsSection({ userId }) {
  const { useState, useEffect } = React;
  const [prefs, setPrefs] = useState(null);
  const [failed, setFailed] = useState(false);
  const [open, setOpen] = useState({});
  // Pop-ups on this browser (SOLAR-244): its state, then the five alert switches once on.
  const [push, setPush] = useState(null); // on | off | blocked | ios | none | asking
  const [pushPrefs, setPushPrefs] = useState(null);
  const load = () => {
    setFailed(false);
    window.fetchEmailPrefs(userId).then(setPrefs).catch(() => setFailed(true));
    window.fetchPushPrefs(userId).then(setPushPrefs).catch(() => {});
  };
  useEffect(() => { if (userId) load(); }, [userId]);
  useEffect(() => { window.pushState().then(setPush).catch(() => setPush('off')); }, []);
  // A save that works shows nothing more than the switch; one that fails names what it was
  // (the email, or the group a group switch set) in the red toast (SOLAR-166).
  const saver = (set, save) => async (kind, on, name) => {
    set(p => ({ ...p, [kind]: on }));
    try { await save(userId, kind, on); }
    catch {
      set(p => ({ ...p, [kind]: !on }));
      window.toast('Couldn’t save ' + (name || EMAIL_GROUPS.flatMap(g => g.rows).find(([k]) => k === kind)[1]) + '. Try again.', { error: true });
    }
  };
  const flip = saver(setPrefs, window.saveEmailPref);
  const flipPush = saver(setPushPrefs, window.savePushPref);
  const togglePush = async () => {
    const was = push;
    setPush('asking');
    try { setPush(await (was === 'on' ? window.pushTurnOff() : window.pushTurnOn())); }
    catch { setPush(was); window.toast('Couldn’t turn pop-ups ' + (was === 'on' ? 'off' : 'on') + '. Try again.', { error: true }); }
  };
  // One group: a row that opens its switches, and a switch for all of them. Each switch
  // saves through its own flip, so a group is its switches' saves, one per kind.
  const group = (g, p, flipOne, key) => {
    const anyOn = !p || g.rows.some(([kind]) => p[kind]);
    return (
      <div className="notif-group" key={key}>
        <div className="notif-head">
          <button type="button" className="notif-open" aria-expanded={!!open[key]} aria-controls={'notif-' + key}
                  onClick={() => setOpen(o => ({ ...o, [key]: !o[key] }))}>
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true"><path d="M6 3.5 10.5 8 6 12.5" /></svg>
            <span className="toggle-text">
              <span className="notif-label">{g.label}</span>
              <span className="toggle-hint">{emailGroupSummary(g, p)}</span>
            </span>
          </button>
          <button type="button" className={'switch' + (anyOn ? ' on' : '')} role="switch" aria-checked={anyOn} aria-label={g.label}
                  onClick={() => p && g.rows.forEach(([kind]) => { if (p[kind] === anyOn) flipOne(kind, !anyOn, g.label); })}><span className="knob" /></button>
        </div>
        <div id={'notif-' + key} className="field notif-rows" role="group" aria-label={g.label} hidden={!open[key]}>
          {g.rows.map(([kind, label, hint]) => (
            <Toggle key={kind} label={label} hint={hint} checked={!p || p[kind]}
                    onChange={(on) => p && flipOne(kind, on)} />
          ))}
        </div>
      </div>
    );
  };
  const alerts = EMAIL_GROUPS.find(g => g.id === 'alerts');
  // All emails (SOLAR-250): one switch over both groups, on while any email is on
  const every = EMAIL_GROUPS.flatMap(g => g.rows);
  const onCount = prefs ? every.filter(([k]) => prefs[k]).length : every.length;
  const allOn = onCount > 0;
  return (
    <SettingsSection id="notifications" title="Notifications" note="Account emails always go out.">
      {failed ? (
        <div className="conn-row">
          <div className="conn-text"><div className="conn-user">Couldn’t load your email settings</div></div>
          <div className="conn-actions"><button type="button" className="ghost-btn" onClick={load}>Try again</button></div>
        </div>
      ) : <>
        <div className="notif-sub">Email</div>
        <div className="notif-head notif-all">
          <span className="toggle-text">
            <span className="notif-label">All emails</span>
            <span className="toggle-hint">{onCount === every.length ? 'All ' + onCount + ' on' : onCount ? onCount + ' of ' + every.length + ' on' : 'Off'}</span>
          </span>
          <button type="button" className={'switch' + (allOn ? ' on' : '')} role="switch" aria-checked={allOn} aria-label="All emails"
                  onClick={() => prefs && every.forEach(([kind]) => { if (prefs[kind] === allOn) flip(kind, !allOn, 'All emails'); })}><span className="knob" /></button>
        </div>
        {EMAIL_GROUPS.map(g => group(g, prefs, flip, g.id))}
      </>}
      {push && push !== 'none' && (
        <div className={'notif-push ' + push}>
          <div className="notif-sub">On this browser</div>
          <Toggle label="Pop-up alerts" hint="The same alerts, shown on this device even when the app is closed."
                  checked={push === 'on'} onChange={() => push !== 'asking' && push !== 'ios' && togglePush()} />
          {push === 'blocked' && (
            <p className="notif-note warn">Your browser blocked pop-ups for this site. Allow notifications for {location.host} in the browser’s site settings, then turn this on again.</p>
          )}
          {push === 'ios' && (
            <p className="notif-note">On iPhone, pop-ups work only from the Home Screen. In Safari, tap <b>Share</b>, then <b>Add to Home Screen</b>, and open the app from there. Needs iOS 16.4 or later.</p>
          )}
          {push === 'on' && group({ ...alerts, when: null }, pushPrefs, flipPush, 'push')}
        </div>
      )}
    </SettingsSection>
  );
}

// ---------------------------------------------------------------- SETTINGS AREA
// One area, three pages (SOLAR-250): Account (the person), Billing (the plan, plants and
// card) and Plant (the plant on screen). A side menu on a desktop. On a phone 'prefs' is
// that menu as a list you tap into, and each page has a back link to it; on a desktop
// 'prefs' shows Account. Adjust plan ('plans') is a page under Billing. The plan is read
// once here: Billing shows it, Account's Delete and Plant's Remove login need it.
const SETTINGS_NAV = [['account', 'Account'], ['billing', 'Billing'], ['settings', 'System']];
function SettingsArea({ page, onPage, me, plantId, plantSlot, onPlantConfigSaved, links, flash, onFlashed, onDirty, switchBlocked }) {
  const { useState, useEffect } = React;
  const [user, setUser] = useState(null);
  useEffect(() => { window.sb.auth.getSession().then(({ data }) => setUser(data?.session?.user || null)).catch(() => {}); }, []);
  const [billing, setBilling] = useState(null);
  const reloadBilling = () => window.sb.rpc('api_billing_status').then(({ data }) => { if (data) setBilling(data); return data; });
  // Back from a payment: billingReturn checks it (a paid one reloads the page).
  useEffect(() => { reloadBilling().then(b => window.billingReturn(b)).then(r => r === 'card' && reloadBilling()); }, []);
  // Every plant on the logins once (a plant can be on two). Collecting the paused ones adds
  // the inverters of those past the 3rd plant to Family, active plants counted first.
  const live = (links?.accounts || []).filter(a => a.status !== 'disabled');
  const plants = [...new Map(live.flatMap(a => a.plants || []).map(p => [p.plant_id, p])).values()];
  const paused = plants.filter(p => p.paused);
  const activeTotal = plants.length - paused.length;
  const added = paused.reduce((sum, p, i) => sum + (activeTotal + i + 1 > 3 ? Number(p.inverters) || 0 : 0), 0);
  const dot = { billing: billing?.state === 'past_due' || paused.length > 0, settings: live.some(a => a.status === 'needs_relink') };
  const shown = page === 'prefs' ? 'account' : page === 'plans' ? 'billing' : page;
  return (
    <SettingsFlash.Provider value={flash ? { id: flash, done: onFlashed } : null}>
      <div className={'set-area' + (page === 'prefs' ? ' set-list' : '')}>
        <nav className="set-nav" aria-label="Settings">
          <h1 className="set-nav-title">Settings</h1>
          {SETTINGS_NAV.map(([id, label]) => (
            <button key={id} type="button" aria-current={shown === id ? 'page' : undefined} onClick={() => onPage(id)}>
              <span>{label}</span>
              {dot[id] && <span className="dot" aria-label={id === 'billing' ? 'Needs you' : 'A login needs reconnecting'} />}
              <svg className="set-chev" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true"><path d="M6 3.5 10.5 8 6 12.5" /></svg>
            </button>
          ))}
        </nav>
        <div className="set-main">
          {page !== 'plans' && <button type="button" className="back-link set-back" onClick={() => onPage('prefs')}><span aria-hidden="true">←</span> Settings</button>}
          {shown === 'account' && <AccountPage user={user} billing={billing} onBilling={() => onPage('billing')} />}
          {page === 'billing' && <BillingPage billing={billing} reload={reloadBilling} links={links} onPage={onPage} collecting={activeTotal} onSaved={onPlantConfigSaved} />}
          {page === 'plans' && <AdjustPlanPage billing={billing} reload={reloadBilling} onBack={() => onPage('billing')}
                                               paused={paused.map(p => p.plant_name || 'Plant ' + p.plant_id)} added={added} />}
          {page === 'settings' && (plantSlot || (
            <PlantPage me={me} plantId={plantId} onSaved={onPlantConfigSaved} onDirty={onDirty}
                       switchBlocked={switchBlocked} links={links} />
          ))}
        </div>
      </div>
    </SettingsFlash.Provider>
  );
}

// Account: the person. Email and sign-in method, emails, then the account's actions.
function AccountPage({ user, billing, onBilling }) {
  const email = user?.email || null;
  const providers = user?.app_metadata?.providers || [];
  const method = providers.includes('google') ? (providers.includes('email') ? 'Google or password' : 'Google') : 'password';
  return (
    <div className="settings-page">
      <div className="page-head">
        <h1>Account</h1>
        <p>{email ? <>{email}<span className="set-method"> · Signs in with {method}</span></> : '\u00a0'}</p>{/* its line held while the session loads */}
      </div>
      <NotificationsSection userId={user?.id} />
      <SettingsSection id="actions" title="Account actions">
        {email && providers.includes('email') && <PasswordRow email={email} />}
        <div className="conn-row">
          <div className="conn-text"><div className="conn-user">Sign out</div><div className="conn-meta">On this device.</div></div>
          <div className="conn-actions"><window.SignOutButton className="ghost-btn" /></div>
        </div>
        <DeleteAccountRow email={email} billing={billing} onBilling={onBilling} />
      </SettingsSection>
      <div className="app-version mono">
        {window.APP_VERSION} · <a href="terms.html" target="_blank" rel="noopener">Terms</a> · <a href="privacy.html" target="_blank" rel="noopener">Privacy</a>
      </div>
    </div>
  );
}

// Billing holds the plants and the logins they come from (moved from Plant, SOLAR-250).
function BillingPage({ billing, reload, links, onPage, collecting, onSaved }) {
  return (
    <div className="settings-page">
      <div className="page-head"><h1>Billing</h1><p>Paid by card through Paystack.</p></div>
      <PlanSection billing={billing} reload={reload} onAdjust={() => onPage('plans')} collecting={collecting} />
      {links && <SunSynkConnectionSection onChanged={onSaved} links={links} billing={billing} reloadBilling={reload} onCollect={() => onPage('plans')} />}
      <PaymentsSection billing={billing} />
    </div>
  );
}

// Plant: the plant on screen (picked in the header). Its system and its readings as a file.
function PlantPage({ me, plantId, onSaved, onDirty, switchBlocked, links }) {
  return (
    <div className="settings-page">
      <div className="page-head"><h1>System</h1><p>Changes apply to everyone on this plant.</p></div>
      <PlantSections me={me} plantId={plantId} onSaved={onSaved} onDirty={onDirty} switchBlocked={switchBlocked} />
      {links?.accounts?.length > 0 && <DownloadSection />}
      <FirstStepsSection me={me} plantId={plantId} onSaved={onSaved} />
    </div>
  );
}

Object.assign(window, { LiveTab, SolarTab, HomeTab, GridTab, InvertersTab, SettingsArea, MiniStat, FsEnterIcon, TabSkeleton });
