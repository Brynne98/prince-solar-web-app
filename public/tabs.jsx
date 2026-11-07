// ============================================================================
// tabs.jsx — the individual views. Live / Solar / Battery / Grid / Inverters / Settings
// (History lives in chart.jsx as <HistoryView/>)
// Week/Month/Year aggregates come from the live `energy` cache owned by <App>;
// `onNeedEnergy(period)` asks App to lazily fetch a period it hasn't loaded yet.
// ============================================================================
const { Card, StatTile, Segmented, Toggle, SectionTitle,
  fmtPower, fmtPowerParts, battShown, fmtKwh, fmtRand, cleanTemp, COLORS: CC } = window;

const FsEnterIcon = () => <svg className="ico ico-sm" viewBox="0 0 16 16" aria-hidden="true"><path d="M2 6V2h4M14 6V2h-4M2 10v4h4M14 10v4h-4" /></svg>;
const TrashIcon = () => <svg className="ico ico-sm" viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 4.5h11M6.5 4.5v-2h3v2M4 4.5l.6 9h6.8l.6-9M6.75 7v4M9.25 7v4" /></svg>;
const FsExitIcon = () => <svg className="ico ico-sm" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 2v4H2M10 2v4h4M6 14v-4H2M10 14v-4h4" /></svg>;

// The Overview's periods, for its switch and its loading copy alike.
const PERIODS = [{ value: 'today', label: 'Today' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' }, { value: 'year', label: 'Year' }, { value: 'lifetime', label: 'Lifetime' }];
// What each Overview card is, for its (?) here and in the loading row alike.
const OV_INFO = {
  made: 'What your panels made, across all inverters.',
  home: 'What your home used, across all inverters.',
  suff: 'How much of what your home used didn’t come from the grid.',
  exp: 'Sent to the grid, paid at your feed-in rate.',
  imp: 'What you bought from the grid.',
  grid: 'No grid connection. Everything the home uses comes from solar and the battery.',
  saved: 'An estimate: what your home used that didn’t come from the grid, at your electricity rate.',
};

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
    <div className="pie-wrap" aria-hidden="true">
      <svg className="pie" viewBox="0 0 150 150"><circle className="pie-track" cx="75" cy="75" r="61" /></svg>
      <div className="pie-figs">
        {[0, 1].map(i => <div key={i}><span>{NBSP}</span><b><window.Skeleton w="4.5em" h="1em" r={6} style={{ display: 'inline-block', verticalAlign: 'top' }} /></b></div>)}
      </div>
    </div>
  );
}
function WiwSkeleton({ title, info }) {
  return (
    <Card className="wiw">
      <SectionTitle>{titled(title, 'today')}<window.InfoDot text={info} /></SectionTitle>
      <WiwBodySkeleton />
    </Card>
  );
}

// A readout whose number hasn't arrived. The label is static and draws for real.
function skelVal(w) {
  return <window.Skeleton w={w} h={19} r={5} style={{ display: 'inline-block', verticalAlign: 'top', marginTop: 3 }} />;
}

// cfg: the plant's saved settings from api_me, so the row holds the cards LiveTab will draw
function LiveSkeleton({ cfg }) {
  const grid = cfg?.has_grid !== false;
  const exp = grid && cfg?.tariff_export > 0;
  return (
    <div className="live-grid">
      <div className="overview-section">
        <div className="overview-head">
          <div className="section-title">OVERVIEW</div>
          <window.Segmented size="sm" value="today" onChange={() => {}}
            options={PERIODS} />
        </div>
        {/* The real tiles in loading mode, with the same meter and second line the live
            ones carry, so the row lands at the same height. */}
        <div className="today-strip">
          <MiniStat loading label="Made" info={OV_INFO.made} />
          <MiniStat loading label="Home" info={OV_INFO.home} />
          <MiniStat loading label="Independence" info={OV_INFO.suff} bar={0} />
          {/* the grid chip's box sets its line 0.5px taller than plain text */}
          {grid ? <MiniStat loading label="Imported" info={OV_INFO.imp} sub={<span className="grid-state" style={{ visibility: 'hidden' }}><span className="gs-dot" />{NBSP}</span>} /> : <MiniStat loading label="Grid" info={OV_INFO.grid} />}
          {exp && <MiniStat loading label="Exported" info={OV_INFO.exp} />}
          <MiniStat loading label="Saved" info={OV_INFO.saved} sub={NBSP} />
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
  const fmtDur = (hrs) => window.fmtDuration(Math.round(hrs * 60));
  const fmtEta = (hrs) => {
    const d = new Date(snap.updated.getTime() + hrs * 3600000);
    return window.fmtPlantTime(d, tz) + ', ' + d.toLocaleDateString('en', { weekday: 'short', day: 'numeric', month: 'short', timeZone: tz || undefined });
  };
  // A silent plant's last figures aren't now: no projection from them. Today's tiles keep
  // the stored totals, as Solar's Today does; only live watts show a dash (SOLAR-348).
  const ps = window.plantStatus(snap, Date.now());
  // Old readings grey the page (.page.old, SOLAR-343). A dead login: live watts are dashes,
  // as on a silent plant; Today keeps today's figures (SOLAR-386).
  const cut = !!snap.loginCut;
  const silent = ps.status === 'offline' || cut;
  let battEta = null, battInfo = null;
  if (!hasBatt || silent || ps.faded) { /* nothing to estimate */ }
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
    // the cards above the flow are Today's (SOLAR-309)
    setWall(true); rememberWall(true); setPeriod('today');
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
    if (!armed || over) return; // Free after its week: no wall view (SOLAR-333)
    const resume = () => { cleanup(); enterWall(); };
    const cleanup = () => { window.removeEventListener('pointerdown', resume); window.removeEventListener('keydown', resume); };
    window.addEventListener('pointerdown', resume, { once: true });
    window.addEventListener('keydown', resume, { once: true });
    return cleanup;
  }, [over]);

  // ---- period-over-period trend arrows on the Overview cards ----
  const cmp = useCompare(refreshKey, snap);
  // Free after its week (SOLAR-242): Today stays; the month's figures blur, the rest is a faint shape
  const over = window.useFreeOver();

  // ---- period overview: Today / Week / Month / Year / Lifetime ----
  const [period, setPeriod] = React.useState('today');
  const isAgg = period === 'week' || period === 'month' || period === 'year' || period === 'lifetime';
  // Year and Lifetime total this month from its days, as on the Solar tab, so they need both
  const needs = !isAgg ? [] : period === 'year' || period === 'lifetime' ? [period, 'month'] : [period];
  React.useEffect(() => { needs.forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [period, energy]);
  const pending = needs.some(p => !energy[p]);
  // the Solar, Home and Grid tabs' totals: the days before today plus today's live figure
  const heavy = React.useMemo(() => {
    if (!isAgg || pending) return null;
    const plantToday = plantDateStr(tz);
    // a day with a missing figure totals NaN there; here it reads as "—", like no data
    const tot = (key, now) => { const v = periodTotals(key, now, energy, plantToday)[period]; return Number.isFinite(v) ? v : null; };
    return { pv: tot('pv', a.pvToday), load: tot('load', a.loadToday), imp: tot('imp', a.gridFromToday), exp: tot('exp', a.gridToToday) };
  }, [period, energy, pending, tz, a.pvToday, a.loadToday, a.gridFromToday, a.gridToToday]);
  const rate = snap.config?.tariffImport ?? 0;
  const rateExp = snap.config?.tariffExport ?? 0;
  let pPv, pLoad, pImp, pExp;
  if (period === 'today') { pPv = a.pvToday; pLoad = a.loadToday; pImp = hasGrid ? a.gridFromToday : 0; pExp = hasGrid ? a.gridToToday : 0; }
  else if (heavy) { pPv = heavy.pv; pLoad = heavy.load; pImp = hasGrid ? heavy.imp : 0; pExp = hasGrid ? heavy.exp : 0; }
  else { pPv = pLoad = pImp = pExp = null; } // aggregate period still loading
  // clamp to 0–100: import can exceed load when the grid charges the battery,
  // which would otherwise drive this negative (and break the bar).
  const pSuff = (pLoad != null && pLoad > 0 && pImp != null) ? Math.max(0, Math.min(100, Math.round(((pLoad - pImp) / pLoad) * 100))) : null;
  // avoided purchases at the import rate, plus anything sold at the feed-in rate
  const pSaved = (pLoad != null && pImp != null) ? Math.max(0, pLoad - pImp) * rate + (pExp || 0) * rateExp : null;
  // Show an Exported tile when this plant sells (a feed-in rate is set, or it has exported)
  // Only plants paid for export get an Exported tile. Every grid-tied inverter leaks a
  // few Wh of backflow, so a non-zero counter alone is not a sign the site sells.
  const showExport = hasGrid && rateExp > 0;
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
    return changePct(c, p);
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
  const cmpFrom = { today: 'yesterday at this time', week: 'last week', month: 'last month', year: 'last year' }[period];
  // nothing logged on the other side: no arrows, and no note about them either
  const partial = !!(cmpFrom && cmpRow && !useLive && prevHasData && cmpDays < (cmpRow.span || 0));
  // "from last year, over the 40 of 120 days with readings in both": the arrow's tip and the
  // (?) say the same sentence, with Change or No change in front (MiniStat)
  const cmpPhrase = cmpFrom && ('from ' + cmpFrom + (partial ? ', over the ' + cmpDays + ' of ' + cmpRow.span + ' days with readings in both' : ''));
  // Est. saved trend: avoided import at today's rate, both sides from the paired
  // compare rows (they carry no export). A plant paid for export gets no arrow, since
  // the tile's figure includes feed-in and the arrow could not.
  const avoided = (load, imp) => Math.max(0, load - imp) * rate;
  const cSaved = useLive ? (pLoad != null ? avoided(pLoad, pImp) : null) : (cmpRow ? avoided(cmpRow.cur.load, cmpRow.cur.imp) : null);
  const prevSaved = prev ? avoided(prev.load, prev.imp) : null;
  const moneyTrend = rate > 0 && !(rateExp > 0);
  const tSaved = moneyTrend ? pct(cSaved, prevSaved) : null;
  const dSaved = (moneyTrend && prev && cSaved != null) ? cSaved - prevSaved : null;

  // Overview's cards, drawn under the chart and, in fullscreen, above the flow (SOLAR-309)
  const strip = (
    <div className={'today-strip' + (over && period === 'month' ? ' blurred' : '')} data-today={period === 'today' || undefined}>
      <MiniStat loading={pending} label="Made" value={window.fmtEnergyParts(pPv)} color={CC.pv} trend={tGen} trendDelta={dGen} trendFrom={cmpPhrase}
        info={OV_INFO.made} />
      <MiniStat loading={pending} label="Home" value={window.fmtEnergyParts(pLoad)} color={CC.load} trend={tCon} trendDelta={dCon} trendInvert trendFrom={cmpPhrase}
        info={OV_INFO.home} />
      <MiniStat loading={pending} label="Independence" value={pSuff != null ? [pSuff, '%'] : '—'} color={CC.soc} bar={pSuff ?? undefined} trend={tSuff} trendFrom={cmpPhrase}
        info={OV_INFO.suff} />
      {hasGrid && <MiniStat loading={pending} label="Imported" value={window.fmtEnergyParts(pImp)} color={CC.grid} trend={tImp} trendDelta={dImp} trendInvert trendFrom={cmpPhrase}
        info={OV_INFO.imp}
        sub={silent ? undefined : a.gridPresent == null ? (
          // No inverter has reported mains voltage yet; a blank here read as a
          // chip that failed to load.
          <span className="grid-state unknown"><span className="gs-dot" />Grid unknown</span>
        ) : (
          // Presence, not usage: mains voltage is there even when you draw nothing
          // from it, so this stays ON through a sunny self-powered afternoon.
          <window.Tip className={'grid-state ' + (a.gridPresent ? 'on' : 'off')}
                text={a.gridPresent
                  ? 'The grid is live, even when you’re not using it.'
                  : 'No power from the grid.'}>
            <span className="gs-dot" />{a.gridPresent ? (a.phaseDown ? 'Phase down' : 'Grid on') : 'Grid off'}
          </window.Tip>
        )} />}
      {!hasGrid && <MiniStat loading={pending} label="Grid" value="Off" color={CC.grid}
        info={OV_INFO.grid} />}
      {/* after Imported, the order Power flow uses */}
      {showExport && <MiniStat loading={pending} label="Exported" value={window.fmtEnergyParts(pExp)} color={CC.grid}
        info={OV_INFO.exp} />}
      <MiniStat loading={pending} label="Saved" color="var(--money)"
        value={(rate > 0 || rateExp > 0) && pSaved != null ? window.fmtRandSmart(pSaved) : '—'}
        trend={tSaved} trendDelta={dSaved} trendDeltaFmt={window.fmtRandSmart} trendFrom={cmpPhrase}
        // no rate yet: the line under the dash opens Settings on Tariff
        sub={!(rate > 0 || rateExp > 0) ? <button type="button" className="mini-link" onClick={() => onOpenSettings('tariff')}>Add your rate to see this</button>
          : over && period === 'month' ? <button type="button" className="lock-btn" onClick={() => window.openPlans('month_saved')}><window.LockIcon />On paid plans</button> : undefined}
        info={rateExp > 0 ? OV_INFO.saved.slice(0, -1) + ', plus what you exported at your feed-in rate.' : OV_INFO.saved} />
    </div>
  );

  return (
    <>
    {over && hasGrid && <GridOffPrompt tz={tz} />}
    <div className="live-grid">
      <div className="overview-section">
        <div className="overview-head">
          <SectionTitle>OVERVIEW</SectionTitle>
          <Segmented size="sm"
            options={PERIODS}
            value={period} onChange={setPeriod} />
        </div>
        {over && period !== 'today' && period !== 'month' ? <window.HistoryLock where={'overview_' + period} /> : strip}
      </div>
      <div className={'flow-fs-wrap' + (wall ? ' wall' : '') + (wall && idle ? ' idle' : '')} ref={flowRef}>
        {wall && (
          // Exit on the left, so the status sits flush right whether Exit shows or hides
          <div className="wall-bar">
            <button className="flow-fs-btn wall-exit"
              onClick={() => { if (Date.now() - revealedAt.current > 400) exitWall(); }}>
              <FsExitIcon /><span>Exit</span>
            </button>
            <window.WallStatus snap={snap} />
          </div>
        )}
        {wall && strip}
        <Card className="flow-card">
          {!wall && <SectionTitle right={
            over ? <button className="flow-fs-btn" onClick={() => window.openPlans('wall')}><window.LockIcon /><span>Fullscreen</span></button>
            : <button className="flow-fs-btn" onClick={enterWall}>
              <FsEnterIcon /><span>Fullscreen</span>
            </button>
          }>POWER FLOW</SectionTitle>}
          <window.PowerFlow agg={a} inverters={snap.inverters.filter(i => i.status === 'online').length} battInfo={battInfo} onBattInfo={hasBatt && !cap && !wall ? () => onOpenSettings('battery') : undefined} typicalSoc={typicalSoc} typicalHour={typicalHour} features={feat} wall={wall} silentSince={silent ? window.readAgo(ps.last.getTime(), Date.now()) : null}
            pausedSince={!silent && ps.faded ? window.readAgo(ps.last.getTime(), Date.now()) : null} keepToday={cut} />
        </Card>
      </div>

      <Card className="chart-card">
        <window.HistoryView today={today} refreshKey={refreshKey} silent={silent} />
      </Card>


    </div>
    </>
  );
}

// Free after its week, once the grid has come back (SOLAR-242): how long it was off and
// what carried the house, then the plans. Once per outage on this device; × puts it away.
function GridOffPrompt({ tz }) {
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
  const dur = window.fmtDuration(Math.max(1, Math.round(mins)));
  const h = window.plantHour(tz, from), today = plantDateStr(tz);
  const when = (h >= 18 || h < 6) && window.plantHour(tz, to) < 12 && plantDateStr(tz, to) === today ? 'last night'
    : plantDateStr(tz, to) === today ? 'today' : 'yesterday';
  const close = () => { try { localStorage.setItem('ps.gridOffSeen', span.endedAt); } catch (e) {} setSeen(span.endedAt); };
  return (
    <div className="notice gridoff grid-off-prompt" role="status">
      <p><b>Grid was off {dur} {when}.</b></p>
      <button type="button" className="mini-link" onClick={() => { close(); window.openPlans('grid_off'); }}>See how it held up →</button>
      <button type="button" className="fs-x" aria-label="Close" onClick={close}><Icon id="close" /></button>
    </div>
  );
}
// tip: the whole sentence for the hover, when the caller has one (Overview's cards)
function TrendBadge({ pct, unit = '%', invert, title, tip, delta, deltaFmt }) {
  if (pct == null) return null;                       // only hide when there is no prior period
  const usable = Number.isFinite(delta);
  if (!Number.isFinite(pct) && !usable) return null;  // grew from zero and no kWh figure to show
  const mag = Math.abs(pct);
  if (mag < 0.05) return <window.Tip className="trend-badge flat" text={tip || (title || 'vs previous period') + ' — no change'}>0{unit}</window.Tip>; // dead flat: neutral, no arrow
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
  return <window.Tip className={'trend-badge ' + (good ? 'good' : 'bad')} text={tip || title || 'vs previous period'}>{up ? '▲' : '▼'} {label}</window.Tip>;
}
// value: text, or [number, unit] (fmtEnergyParts) for the number, then a smaller unit, so the figure reads first
const unitSplit = (v) => (Array.isArray(v) && v[1] ? <>{v[0]}<span className={'mv-unit' + (v[1] === '%' ? ' pct' : '')}>{v[1]}</span></> : Array.isArray(v) ? v[0] : v);
function MiniStat({ label, value, color, sub, bar, info, trend, trendUnit, trendInvert, trendFrom, trendDelta, trendDeltaFmt, loading }) {
  // the note joins the (?) only while TrendBadge draws a badge, and is its hover text too
  const arrow = !loading && trend != null && (Number.isFinite(trend) || Number.isFinite(trendDelta));
  const flat = Number.isFinite(trend) && Math.abs(trend) < 0.05;   // TrendBadge's "0%"
  const trendNote = trendFrom && (flat ? 'No change ' : 'Change ') + trendFrom + '.';
  return (
    <Card className="mini-stat">
      {/* the trend arrow sits on the label's line, top right, so it fits at every width */}
      <div className="mini-label">
        {/* the whole label opens the (?)'s bubble, so a phone, which has no room for the
            dot, still opens it with a tap (SOLAR-348) */}
        <window.Tip className="ml-text" text={info && (arrow && trendNote ? <>{info}<span className="ib-note">{trendNote}</span></> : info)}>
          {label}{info && <window.InfoDot bare />}</window.Tip>
        {!loading && <TrendBadge pct={trend} unit={trendUnit} invert={trendInvert} tip={trendNote} delta={trendDelta} deltaFmt={trendDeltaFmt} />}
      </div>
      {/* a shimmer beats an em-dash: switching to Week/Month refetches, and "—" reads as
          "no data" rather than "fetching" */}
      {loading
        ? <div className="mini-value mono" style={{ position: 'relative' }}>{NBSP}<window.Skeleton w="70%" h="auto" style={{ position: 'absolute', top: 0, bottom: 0, left: 0 }} /></div>
        : <div className="mini-value mono" style={{ color }}><span className="mv-num">{unitSplit(value)}</span></div>}
      {bar != null && !loading && <window.Meter small pct={bar} color={color} />}
      {bar != null && loading && <window.Skeleton h={5} r={4} style={{ marginTop: 8 }} />}
      {sub && <div className="mini-sub">{sub}</div>}
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
    ? window.dayText(earliest, { day: 'numeric', month: 'short', year: 'numeric' })
    : window.dayText(ym + '-01', { month: 'short', year: 'numeric' }));
}

// The day's flows from its 5-minute points, worked out once so Solar, Home and Grid show the
// same number for the same flow (SOLAR-332; each card used to scale its own estimate to its
// own counter, so solar to the house read 11.4 kWh on Solar and 14.5 on Home). Solar serves
// the house first, then the battery, then the grid; the house takes solar, then the battery,
// then the grid. Day series: battery + = discharging, grid + = imported. Each flow is capped
// by what was measured, so the parts come in under the counters by the inverter's losses.
function dayFlows(points) {
  const f = { pvHome: 0, pvBatt: 0, pvGrid: 0, battHome: 0, gridHome: 0, gridBatt: 0 };
  const kwh = 5 / 60 / 1000;
  points.forEach(p => {
    if (p.load == null) return;
    const pv = Math.max(0, p.pv || 0), load = Math.max(0, p.load);
    const chg = p.batt != null && p.batt < 0 ? -p.batt : 0, dis = p.batt != null && p.batt > 0 ? p.batt : 0;
    const imp = p.grid != null && p.grid > 0 ? p.grid : 0, exp = p.grid != null && p.grid < 0 ? -p.grid : 0;
    const pvHome = Math.min(pv, load);
    const pvBatt = Math.min(pv - pvHome, chg);
    const battHome = Math.min(load - pvHome, dis);
    const gridHome = Math.min(load - pvHome - battHome, imp);
    f.pvHome += pvHome * kwh; f.pvBatt += pvBatt * kwh;
    f.pvGrid += Math.min(pv - pvHome - pvBatt, exp) * kwh;
    f.battHome += battHome * kwh; f.gridHome += gridHome * kwh;
    f.gridBatt += Math.max(0, Math.min(imp - gridHome, chg - pvBatt)) * kwh;
  });
  // rounded to the 0.1 kWh shown, so a flow is the same figure wherever it appears
  Object.keys(f).forEach(k => { f[k] = Math.round(f[k] * 10) / 10; });
  return f;
}
const WIW_INFO = {
  solar: 'Solar goes to the house first, then the battery, then the grid. Worked out from readings every 5 minutes, so it can come in a little under Today.',
  home: 'The house uses solar first, then the battery, then the grid. Worked out from readings every 5 minutes, so it can come in a little under Today.',
  grid: 'Imported power goes to the house first, then the battery. Worked out from readings every 5 minutes, so it can come in a little under Today.',
};
// Where a day's energy went or came from (SOLAR-332): a hollow pie of its parts
// ([name, kWh, colour]) with their sum in the middle, and each part's kWh beside it.
// empty: the note for a day with nothing to share out; the ring stays, bare, so the card
// keeps its shape beside the 30 days instead of leaving a blank box (SOLAR-345).
function SharePie({ parts, word, empty, whole }) {
  // whole: [the day total the bar shows, the page's colour]. A day with that total but no
  // readings to split it still shows the total, as one ring with no parts beside it (SOLAR-387).
  const only = empty && whole && whole[0] >= 0.05 ? whole : null;
  if (empty) parts = only ? [['', only[0], only[1]]] : [];
  const total = parts.reduce((t, d) => t + d[1], 0);
  const R = 61, C = 2 * Math.PI * R, gap = parts.length > 1 ? 3 : 0;
  const [n, u] = window.fmtEnergyParts(total);
  let at = 0;
  return (
    <div className={'pie-wrap' + (only ? ' whole' : empty ? ' empty' : '')}>
      <svg className="pie" viewBox="0 0 150 150" role="img" aria-hidden={empty && !only ? 'true' : undefined} aria-label={word + ' ' + fmtKwh(total) + (only ? '' : ': ' + parts.map(d => d[0] + ' ' + fmtKwh(d[1])).join(', '))}>
        <circle className="pie-track" cx="75" cy="75" r={R} />
        {parts.map(([l, v, c]) => {
          const len = v / total * C;
          const arc = <circle key={l} cx="75" cy="75" r={R} stroke={c} strokeDasharray={Math.max(0, len - gap) + ' ' + C} strokeDashoffset={-at} transform="rotate(-90 75 75)" />;
          at += len;
          return arc;
        })}
        <text x="75" y="74" className="pie-num">{n}<tspan className="pie-u" dx="3">{u}</tspan></text>
        <text x="75" y="94" className="pie-word">{word}</text>
      </svg>
      {empty ? <div className="solar-note">{empty}</div> : <div className="pie-figs" aria-hidden="true">
        {parts.map(([l, v, c]) => {
          const [a, b] = window.fmtEnergyParts(v);
          return <div key={l}><span>{l}</span><b style={{ color: c }}>{a}<span className="u">{b}</span></b></div>;
        })}
      </div>}
    </div>
  );
}
// Solar, Home and Grid's last-30-days card body: why there are no bars yet, or the bars.
function DaysPanel({ daily, onRetry, over, rows, ...bars }) {
  if (daily === false) return <div className="solar-note">Couldn’t load. <button type="button" className="mini-link" onClick={onRetry}>Try again</button></div>;
  if (!daily) return <PlotSkeleton heights={[170, 220]} r={10} />;
  if (!over && rows.length < 2) return <div className="solar-note">{window.emptyText(window.PLANT_DAYS)}</div>;
  return <DaysBars rows={rows} {...bars} />;
}
// The total tiles of Solar, Home and Grid (now, today, week…): a kWh figure in the page's
// colour. locked: the lock's place on a plan past its free week; Today is never locked.
const totalTile = (accent, locked) => (label, v, sub) => {
  const [n, u] = window.fmtEnergyParts(v);
  return <StatTile label={label} value={n} unit={u} accent={accent} loading={v == null} sub={sub || NBSP} locked={locked && label !== 'TODAY' ? locked : null} />;
};

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
      sub: quiet ? (inv.readAt ? 'No readings since ' + window.readAgo(inv.readAt, now) : 'No readings')
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
    // a missing bucket breaks the line
    const gaps = gapRuns(i0, i1, i => v(i) == null);
    const yAt = i => v(i) == null ? null : y(v(i));
    const line = window.seriesPath(i0, i1, x, yAt);
    const area = window.seriesArea(i0, i1, x, yAt, y(0));
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
          <rect key={'o' + a} x={xt5(Math.max(t0, a * 5 - 2.5))} y={m.t} width={Math.max(2, xt5(Math.min(t1, b * 5 + 2.5)) - xt5(Math.max(t0, a * 5 - 2.5)))} height={innerH} fill="var(--bad)" fillOpacity="0.18" />
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
          <window.TipRow color={color} label={sums[0]}>{pos.toFixed(2)} kWh</window.TipRow>
          {sums[1] && <window.TipRow color={color} label={sums[1]}>{neg.toFixed(2)} kWh</window.TipRow>}
        </div>
      );
    } else if (hp != null && !drag) {
      tip = (
        <div className="chart-tip" style={{ left: tipLeftFor(x(hp), width, 168), top: 12 }}>
          <div className="tip-time">{HM(points[hp].t)}</div>
          <window.TipRow color={color} label={label}>{fmt(v(hp))}</window.TipRow>
          {outages && <OutageTipRow span={outageAt(outages, Math.round(points[hp].t / 5))} what="Grid" />}
        </div>
      );
    }
  }
  return (
    <div className="chart-area" ref={ref} style={{ position: 'relative', height }}>
      {body || <div className="chart-empty" style={{ height }}>{empty}</div>}
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
  const dateLabel = (r, opts) => window.dayText(r.date, opts || { day: 'numeric', month: 'short' });
  const fill = (a) => 'rgba(' + rgb + ',' + a + ')';
  // Axis labels: first day, the 1st of a month, last day. The 1st shows only when it has
  // 12 px clear of both ends, measured in pixels (.ax is 11.5 px mono, ~7 px a character),
  // so on a phone it never runs into "Today" (SOLAR-347).
  const textW = (s) => s.length * 7;
  const startX = m.l + slot / 2, endX = m.l + innerW - slot / 2;
  const startText = dateLabel(rows[0]);
  const endText = rows[rows.length - 1].date === today ? 'Today' : dateLabel(rows[rows.length - 1]);
  const midX = m.l + slot * firstOfMonth + slot / 2, midText = firstOfMonth > 0 ? dateLabel(rows[firstOfMonth]) : '';
  const showMid = firstOfMonth > 0
    && midX - textW(midText) / 2 >= startX + textW(startText) + 12
    && midX + textW(midText) / 2 <= endX - textW(endText) - 12;
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
              style={{ transition: 'fill var(--dur-fast) var(--ease-out)' }} />
          );
        })}
        <text x={startX} y={height - 6} textAnchor="start" className="ax">{startText}</text>
        {showMid && <text x={midX} y={height - 6} textAnchor="middle" className="ax">{midText}</text>}
        <text x={endX} y={height - 6} textAnchor="end" className="ax">{endText}</text>
      </svg>
      {h && (
        <div className="chart-tip" style={{ left: tipLeftFor(m.l + slot * hover + slot / 2, width, 168), top: 8 }}>
          <div className="tip-time">{window.dayText(h.date)}</div>
          <window.TipRow color={color} label={word}>{fmtKwh(h[field])}{h.date === today ? ' so far' : ''}</window.TipRow>
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
  // data-today: old readings grey today's day and leave history in colour (SOLAR-386)
  const dim = { 'aria-busy': !ready, 'data-today': view.isToday || undefined, style: { opacity: ready ? 1 : 0.45, transition: 'opacity var(--dur-fast) var(--ease-out)' } };
  const day = view.data;
  return { view, dim, day, points: (day && day.points) || [], dayWord: view.isToday ? 'today' : window.dayText(view.date) };
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
// The shown day's total as the 30-day bar has it: the inverter's own counter, or the
// live figure today. Undefined for a day outside the 30.
const dayTotal = (daily, today, date, field, live) => (withLiveToday(daily, today, field, live).find(r => r.date === date) || {})[field];
// Where it went sums 5-minute readings, and short bursts slip between them: 14 Oct read
// 0.05 kWh imported against the counter's 0.2 (SOLAR-387). Its parts ([name, kWh, colour,
// shown]) are scaled to the day total, so the round chart and the bar agree; with no split
// at all, the total goes to the first part. Rounded to 0.1, the rest to the largest part.
function toDayTotal(parts, total) {
  if (!(total > 0)) return parts;
  const on = parts.filter(d => d[3]);
  const sum = on.reduce((t, d) => t + d[1], 0);
  const out = parts.map(d => !d[3] ? d : [d[0], sum > 0 ? Math.round(d[1] * total / sum * 10) / 10 : d === on[0] ? total : 0, d[2], d[3]]);
  const big = out.filter(d => d[3]).reduce((m, d) => (!m || d[1] > m[1] ? d : m), null);
  if (big) big[1] = Math.round((big[1] + total - out.filter(d => d[3]).reduce((t, d) => t + d[1], 0)) * 10) / 10;
  return out;
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

// Change as a percentage. Zero then zero is no change; zero then something has no meaningful
// percentage, so it is Infinity and the badge falls back to the absolute kWh change.
const changePct = (c, p) => (p === 0 ? (c === 0 ? 0 : Infinity) : ((c - p) / p) * 100);

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
  const pct = changePct(c, p);
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
      <div className="solar-row">
        <WiwSkeleton title="WHERE IT WENT" info={WIW_INFO.solar} />
        <Card>
          <SectionTitle right={RIGHT_HOLD}>{titled('SOLAR', 'last 30 days')}</SectionTitle>
          <PlotSkeleton heights={[170, 220]} r={10} />
        </Card>
      </div>
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
  // Every tile keeps its second line, empty or not: the trends and the since-date land after
  // the totals, and a row whose tiles had none yet was 29px short until they did.
  // Free after its week (SOLAR-242): every total but Today is a faint shape and a lock
  const over = window.useFreeOver();
  const tile = totalTile(CC.pv, over && 'solar_totals');
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
  const silent = ps.status === 'offline' || !!snap.loginCut; // a dead login: dashes now (SOLAR-386)
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
  const flows = React.useMemo(() => dayFlows(points), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  // A destination is shown only once it holds something: a 0.0 kWh column would be a
  // zero-width segment under a full-width label, and "the battery got none of it" is said
  // better by its absence than by a zero.
  const shownTotal = dayTotal(daily, plantToday, pick.date, 'pv', a.pvToday);
  const dests = toDayTotal([['Home', flows.pvHome, CC.load, true], ['Battery', flows.pvBatt, CC.batt, hasBatt], ['Grid', flows.pvGrid, CC.grid, hasGrid]], shownTotal)
    .filter(d => d[3] && d[1] >= 0.05);
  const splitTotal = dests.reduce((t, d) => t + d[1], 0);
  // The percentages were a permanent column until 2026-09-19; the bar says the same thing,
  // so they moved to the bar's hover title rather than being printed twice.
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
          sub={silent ? 'Last reading ' + window.readAgo(ps.last.getTime(), Date.now()) : kwp > 0 ? (over ? <window.Locked where="panel_pct" label="Keep your insights"><b>{Math.round(a.pvNow / 10 / kwp)}%</b> of your {kwp} kW</window.Locked>
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

      {/* Where it went beside the 30 days, under the day it describes (SOLAR-332): a hollow
          pie of the day's solar with each part's kWh beside it, in its own colour. */}
      <div className="solar-row">
        <Card className="wiw" {...dim}>
          <SectionTitle>{titled('WHERE IT WENT', dayWord)}<window.InfoDot text={WIW_INFO.solar} /></SectionTitle>
          {!day ? <WiwBodySkeleton />
            : <SharePie parts={dests} word="Made" whole={[shownTotal, CC.pv]} empty={(noReadings || splitTotal < 0.05) && (noReadings || (view.isToday ? 'No solar yet today.' : 'No solar on this day.'))} />}
        </Card>
        <Card>
          <SectionTitle right={best ? <>Best <b>{fmtKwh(best.pv)}</b> on {window.dayText(best.date)}</> : RIGHT_HOLD}>
            {titled('SOLAR', 'last 30 days')}
          </SectionTitle>
          <DaysPanel daily={daily} onRetry={loadDaily} over={over} rows={bars} field="pv" color={CC.pv} rgb="61,220,132" word="Solar" label="Solar per day for the last 30 days"
            today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />
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
      <div className="solar-row">
        <WiwSkeleton title="WHERE IT CAME FROM" info={WIW_INFO.home} />
        <Card>
          <SectionTitle right={RIGHT_HOLD}>{titled('HOME', 'last 30 days')}</SectionTitle>
          <PlotSkeleton heights={[170, 220]} r={10} />
        </Card>
      </div>
    </div>
  );
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
  // Free after its week (SOLAR-242): every total but Today is a faint shape and a lock
  const over = window.useFreeOver();
  const tile = totalTile(CC.load, over && 'home_totals');
  // less used is better, as on Grid
  const trend = (k, min, word) => periodTrend(cmp, k, 'load', min, word, true);
  const [nowN, nowU] = fmtPowerParts(a.loadNow);
  const ps = window.plantStatus(snap, Date.now());
  const silent = ps.status === 'offline' || !!snap.loginCut; // a dead login: dashes now (SOLAR-386)
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

  // ---- where it came from: the same flows Solar and Grid show (SOLAR-332) ----
  const flows = React.useMemo(() => dayFlows(points), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  const shownTotal = dayTotal(daily, plantToday, pick.date, 'load', a.loadToday);
  const srcs = toDayTotal([['Solar', flows.pvHome, CC.pv, true], ['Battery', flows.battHome, CC.batt, hasBatt], ['Grid', flows.gridHome, CC.grid, hasGrid]], shownTotal)
    .filter(d => d[3] && d[1] >= 0.05);
  const splitTotal = srcs.reduce((t, d) => t + d[1], 0);

  // ---- last 30 days ----
  const bars = withLiveToday(daily, plantToday, 'load', a.loadToday);
  const most = over ? null : bestDay(bars, 'load', plantToday);
  const openDay = (d) => { pick.setDate(d); scrollToDay('home-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="HOME NOW" value={silent ? '—' : nowN} unit={silent ? '' : nowU} accent={CC.load}
          sub={silent ? 'Last reading ' + window.readAgo(ps.last.getTime(), Date.now()) : solarNow != null ? <><b>{solarNow}%</b> from solar right now</> : NBSP} />
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

      <div className="solar-row">
        <Card className="wiw" {...dim}>
          <SectionTitle>{titled('WHERE IT CAME FROM', dayWord)}<window.InfoDot text={WIW_INFO.home} /></SectionTitle>
          {!day ? <WiwBodySkeleton />
            : <SharePie parts={srcs} word="Used" whole={[shownTotal, CC.load]} empty={(noReadings || splitTotal < 0.05) && (noReadings || 'No home readings for this day.')} />}
        </Card>
        <Card>
          <SectionTitle right={most && most.load > 0 ? <>Most <b>{fmtKwh(most.load)}</b> on {window.dayText(most.date)}</> : RIGHT_HOLD}>
            {titled('HOME', 'last 30 days')}
          </SectionTitle>
          <DaysPanel daily={daily} onRetry={loadDaily} over={over} rows={bars} field="load" color={CC.load} rgb="248,113,113" word="Used" label="Home use per day for the last 30 days"
            today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />
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
      <div className="solar-row">
        <WiwSkeleton title="WHERE IT WENT" info={WIW_INFO.grid} />
        <Card>
          <SectionTitle right={RIGHT_HOLD}>{titled('GRID', 'last 30 days')}</SectionTitle>
          <PlotSkeleton heights={[170, 220]} r={10} />
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
          <StatTile label="GRID" value="Off" unit="" accent={CC.grid} sub="Not connected" />
          <StatTile label="INDEPENDENCE" value={selfSuff} unit="%" accent={CC.soc} bar={selfSuff} sub={NBSP} />
          <StatTile label="USED TODAY" value={window.fmtEnergyParts(a.loadToday)[0]} unit={' ' + window.fmtEnergyParts(a.loadToday)[1]} accent={CC.load} sub={NBSP} />
        </div>
        <Card>
          <SectionTitle>OFF-GRID</SectionTitle>
          <div className="field-note" style={{ marginTop: 0 }}>No grid for over a day. Figures return when it’s back.</div>
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
  const hasBatt = (snap.features || {}).hasBattery !== false;
  React.useEffect(() => { ['week', 'month', 'year', 'lifetime'].forEach(p => { if (!energy[p]) onNeedEnergy(p); }); }, [energy]);
  const cmp = useCompare(refreshKey, snap);
  const [earliest, setEarliest] = React.useState(null);
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);

  // ---- totals: what was bought ----
  // Today is the logger's own integral, as Live's Imported tile uses: one inverter's CT on a
  // two-inverter plant reads nothing, so the inverters' own counters undercount.
  const tot = periodTotals('imp', a.gridFromToday, energy, plantToday);
  // Free after its week (SOLAR-242): every total but Today is a faint shape and a lock
  const over = window.useFreeOver();
  const tile = totalTile(CC.grid, over && 'grid_totals');
  const trend = (k, min, word) => periodTrend(cmp, k, 'imp', min, word, true);
  // Every grid-tied inverter leaks a little backflow, so a plant not paid for export only
  // counts as sending power out above 100 W.
  const exporting = a.gridPower < (sells ? -5 : -100);
  // signed as the chart is: + bought, − exported (a small backflow reads 0)
  const [nowN, nowU] = fmtPowerParts(exporting || a.gridPower > 5 ? a.gridPower : 0);
  // Presence is mains voltage, not usage: nothing is bought on a sunny afternoon with the
  // grid live, and a blackout reads 0 W too.
  const nowSub = a.gridPresent === false ? <span style={{ color: 'var(--bad)' }}>The grid is off</span>
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
  const silent = ps.status === 'offline' || !!snap.loginCut; // a dead login: dashes now (SOLAR-386)

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
  // where the day's imports went: the same flows Solar and Home show (SOLAR-332)
  const flows = React.useMemo(() => dayFlows(points), [day]); // eslint-disable-line react-hooks/exhaustive-deps
  const [daily, loadDaily] = useDaily(refreshKey);
  const shownTotal = dayTotal(daily, plantToday, pick.date, 'imp', a.gridFromToday);
  const dests = toDayTotal([['Home', flows.gridHome, CC.load, true], ['Battery', flows.gridBatt, CC.batt, hasBatt]], shownTotal)
    .filter(d => d[3] && d[1] >= 0.05);
  const splitTotal = dests.reduce((t, d) => t + d[1], 0);

  // ---- last 30 days ----
  const bars = withLiveToday(daily, plantToday, 'imp', a.gridFromToday);
  const most = over ? null : bestDay(bars, 'imp', plantToday);
  const openDay = (d) => { pick.setDate(d); scrollToDay('grid-day'); };

  return (
    <div className="stack solar-tab">
      <div className="solar-stats">
        <StatTile label="GRID NOW" value={silent ? '—' : nowN} unit={silent ? '' : nowU} accent={CC.grid} sub={silent ? 'Last reading ' + window.readAgo(ps.last.getTime(), Date.now()) : nowSub} />
        {tile('TODAY', a.gridFromToday, sells ? <>Exported <b>{fmtKwh(a.gridToToday)}</b></> : todayPeak ? <>Peak <b>{fmtPower(todayPeak.grid)}</b> at <b>{HM(todayPeak.t)}</b></> : null)}
        {tile('THIS WEEK', tot.week, trend('week', 2, 'last week'))}
        {tile('THIS MONTH', tot.month, trend('month', 3, 'last month'))}
        {tile('THIS YEAR', tot.year)}
        {tile('LIFETIME', tot.lifetime, lifetimeSince(energy.lifetime, earliest, plantToday))}
      </div>

      <Card id="grid-day">
        {/* the right line is always there (blank today) so the date bar under it never shifts on a phone */}
        <SectionTitle right={day && !noReadings && !view.isToday && peak ? <>Peak <b>{fmtPower(peak.grid)}</b> at <b>{HM(peak.t)}</b></> : NBSP}>
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

      <div className="solar-row">
        <Card className="wiw" {...dim}>
          <SectionTitle>{titled('WHERE IT WENT', dayWord)}<window.InfoDot text={WIW_INFO.grid} /></SectionTitle>
          {!day ? <WiwBodySkeleton />
            : <SharePie parts={dests} word="Imported" whole={[shownTotal, CC.grid]} empty={(noReadings || splitTotal < 0.05) && (noReadings || (!points.some(p => p.grid != null) ? 'No grid readings for this day.' : view.isToday ? 'Nothing imported yet today.' : 'Nothing imported on this day.'))} />}
        </Card>
        <Card>
          <SectionTitle right={most && most.imp > 0 ? <>Most <b>{fmtKwh(most.imp)}</b> on {window.dayText(most.date)}</> : RIGHT_HOLD}>
            {titled('GRID', 'last 30 days')}
          </SectionTitle>
          <DaysPanel daily={daily} onRetry={loadDaily} over={over} rows={bars} field="imp" color={CC.grid} rgb="250,204,21" word="Imported" label="Energy imported from the grid per day for the last 30 days"
            today={plantToday} selected={pick.date} earliest={earliest} onPick={openDay} />
        </Card>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- EQUIPMENT
// The page id stays `inverters` so saved links and preferences keep working; it reads
// "Equipment" (SOLAR-52). Built for a home user (SOLAR-73, SOLAR-75): one headline says
// whether anything needs a look and a coral-edged card per problem says what to do. Under
// it, Simple (a tile each for panels, battery and inverters: one figure, one word) or
// Detailed (SOLAR-392: panels, battery, inverters and grid as cards with the inverters in
// columns, then the two day charts full width). The choice is the viewer's, kept.

// The page as InvertersTab draws it with nothing wrong, in the view this viewer last chose,
// built from the same classes so each piece lands at the real one's height (SOLAR-221).
// Problem cards are left out: most visits have none. Detailed holds one inverter with two
// strings; a plant with more grows into them.
function InvertersSkeleton() {
  const detailed = (() => { try { return localStorage.getItem('synsynk.eqView') === 'detailed'; } catch (e) { return false; } })();
  // a line of text whose words haven't come: a shimmer, and the line's own height held by a space
  const line = (w, h = 10) => <><window.SkelLine w={w} h={h} max="70%" />{NBSP}</>;
  const fig = <window.Skeleton w={80} h="1em" r={6} />;
  const tile = (label) => (
    <section className="card eq-tile" aria-label={label}>
      <span className="eq-tile-label">{label}</span>
      <span className="eq-tile-state"><i className="eq-dot sm" />{line(70)}</span>
      <div className="eq-fig mono">{fig}</div>
      <div className="eq-fig-sub">{line(120)}</div>
      <div className="eq-spark" />
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
        <div className="eq-tiles">{tile('Solar panels')}{tile('Battery')}{tile('Inverter')}{tile('Grid')}</div>
      ) : (
        <>
          <div className="eq-cards">
            <Card className="eq-card">
              <SectionTitle right={NBSP}>SOLAR PANELS</SectionTitle>
              <div className="eq-big mono">{fig}</div>
              <div className="eq-big-sub">{line(140)}</div>
              {rows(4)}
            </Card>
            <Card className="eq-card">
              <SectionTitle right={NBSP}>BATTERY</SectionTitle>
              <div className="eq-big mono">{fig}</div>
              <div className="eq-meter" />
              <div className="eq-meter-scale"><span>{NBSP}</span></div>
              {rows(4)}
            </Card>
          </div>
          <div className="eq-cards">
            <Card className="eq-card"><SectionTitle>INVERTER</SectionTitle>{rows(5)}</Card>
            <Card className="eq-card"><SectionTitle>GRID SUPPLY</SectionTitle>{rows(3)}</Card>
          </div>
          <Card className="chart-card"><SectionTitle>TEMPERATURE</SectionTitle><DayChartSkeleton legend /></Card>
          <Card className="chart-card"><SectionTitle>GRID SUPPLY</SectionTitle><DayChartSkeleton legend /></Card>
        </>
      )}
    </div>
  );
}

// Everything both views read: who is quiet, the problems, the battery's checks and today's
// solar as it may be shown. Pure, so every state can be checked without a screen.
// An inverter's last temperature today, from SunSynk's day history (SOLAR-393): no live
// reading reaches our key, and recover fetches the history every six hours, so each comes
// with its time. A DC sensor that never moves is absent (the parents' read 25 °C flat).
function invTemps(rows) {
  const out = {};
  (rows || []).forEach(r => {
    const pts = r.points || [];
    for (let i = pts.length - 1; i >= 0; i--) {
      const p = pts[i];
      if (p && p.ac != null) { out[r.sn] = { ac: p.ac, dc: r.dcFlat ? null : p.dc, at: i * 5 }; break; }
    }
  });
  return out;
}

function equipmentState(snap, health, now, invT = {}) {
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
  const since = t => t ? 'Since ' + window.readAgo(t, now) : '';
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
  invs.forEach(inv => {
    const t = invT[inv.sn];
    if (!t) return;
    const hot = t.ac > EQ_HOT_AC ? t.ac : t.dc != null && t.dc > EQ_HOT_DC ? t.dc : null;
    if (hot != null) issues.push({ title: invName(inv) + ' is hot, ' + Math.round(hot) + ' °C', since: 'At ' + HM(t.at),
      todo: 'Make sure air can move around it and it is out of direct sun.' });
  });
  if (badSensor) issues.push({ title: 'A battery temperature sensor isn’t reading', todo: 'Mention it at the battery’s next service.' });
  if (hot) issues.push({ title: 'The battery is hot, ' + Math.round(battTemp) + ' °C', todo: 'Make sure air can move around it.' });

  // Today's solar: as of the last reading when the plant is quiet, none when that was another day.
  const oldDay = allQuiet && (!lastAt || plantDateStr(tz, new Date(lastAt)) !== plantDateStr(tz, new Date(now)));
  const pvParts = oldDay ? ['—', ''] : window.fmtEnergyParts(a.pvToday);
  const pvSub = oldDay ? 'No readings today' : allQuiet ? 'today, by ' + window.fmtTime(new Date(lastAt)) : night ? 'made today' : 'so far today';

  return { a, tz, hasBatt, hasGrid, invs, quiet, allQuiet, lastAt, verdict, night, issues, invT,
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

// Simple (SOLAR-397): a tile per part, its figure, one line of what it is doing, and a small
// chart of today under it. Panels, battery and grid from our own minute readings; inverter
// heat from SunSynk's inverter history, which the poller fetches every ten minutes (SOLAR-398).

// A day sparkline: `vals` are [minute, value | null] pairs across 0 to 1440, drawn into a box
// that stretches with the tile. `stroke` is a colour or a heat gradient (`heat`).
function EqSpark({ vals, lo, hi, stroke, fill, heat, outages }) {
  const gid = React.useId().replace(/:/g, '');
  const W = 1440, H = 100;
  const ys = v => H - 4 - (Math.max(lo, Math.min(hi, v)) - lo) / (hi - lo) * (H - 8);
  const d = seriesPath(0, vals.length - 1, i => vals[i][0], i => vals[i][1] == null ? null : ys(vals[i][1]));
  const area = fill ? seriesArea(0, vals.length - 1, i => vals[i][0], i => vals[i][1] == null ? null : ys(vals[i][1]), H) : null;
  return (
    <div className="chart-area eq-spark" aria-hidden="true">
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" height="100%" preserveAspectRatio="none" style={{ display: 'block' }}>
        {heat && (
          <defs><linearGradient id={gid} gradientUnits="userSpaceOnUse" x1={0} x2={0} y1={ys(heat)} y2={ys(heat - 20)}>
            <stop offset="0" style={{ stopColor: 'var(--bad)' }} /><stop offset="0.5" style={{ stopColor: HEAT_WARM }} /><stop offset="1" style={{ stopColor: 'var(--muted)' }} />
          </linearGradient></defs>
        )}
        {(outages || []).map(([a, b], i) => <rect key={i} x={a * 5} y={0} width={Math.max(5, (b - a + 1) * 5)} height={H} fill="var(--bad)" fillOpacity="0.18" />)}
        {area && <path d={area} fill={fill} fillOpacity="0.15" stroke="none" />}
        <path d={d} fill="none" stroke={heat ? `url(#${gid})` : stroke} strokeWidth="1.5" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
      </svg>
    </div>
  );
}

function EqTile({ label, state, value, unit, sub, color, stale, spark }) {
  return (
    <section className={'card eq-tile' + (stale ? ' stale' : '')} aria-label={label} data-today>
      <span className="eq-tile-label">{label}</span>
      <span className={'eq-tile-state ' + state[0]}><i className={'eq-dot sm ' + state[0]} />{state[1]}</span>
      <div className="eq-fig mono" style={stale || !color ? undefined : { color }}>{value}{unit && <span className="u">{unit}</span>}</div>
      <div className="eq-fig-sub">{sub || NBSP}</div>
      {spark || <div className="eq-spark" />}
    </section>
  );
}

function EquipmentSimple({ st, now, today, hist, gridDay }) {
  const { a, verdict } = st;
  const last = t => t ? 'Last reading ' + window.readAgo(t, now) : 'Not reporting';
  const alerts = verdict && verdict.state === 'alert' ? verdict.alerts : [];
  const pts = (today && today.points) || [];
  const rows = (hist || []).filter(r => r.points && r.points.length);
  // ---- solar panels ----
  const pvState = st.allQuiet ? ['stale', last(st.lastAt)]
    : st.quiet.length ? ['stale', 'Not all reporting']
    : alerts.length ? ['warn', 'Needs a look']
    : st.night ? ['ok', 'Resting for the night']
    : ['ok', 'Working'];
  const pvVals = pts.map(p => [p.t, p.pv == null ? null : Math.max(0, p.pv)]);
  const pvMax = Math.max(500, ...pvVals.map(v => v[1] || 0));
  // ---- battery ----
  const battState = st.battStale ? ['stale', last(st.battAt)]
    : st.hot || st.badSensor ? ['warn', 'Needs a look']
    : ['ok', a.battOut > 5 ? 'Powering the house' : a.battOut < -5 ? 'Charging' : 'Resting'];
  const battSub = st.battStale ? null : [a.battOut > 5 ? fmtPower(a.battOut) + ' out' : a.battOut < -5 ? fmtPower(-a.battOut) + ' in' : null,
    st.battTemp != null ? Math.round(st.battTemp) + ' °C' : null].filter(Boolean).join(' · ');
  // ---- inverters: the warmest one now, and the warmest of them through the day ----
  const n = st.invs.length, live = n - st.quiet.length;
  const invState = !st.quiet.length ? ['ok', n === 1 ? 'On' : n === 2 ? 'Both on' : 'All on']
    : st.allQuiet ? ['stale', last(st.lastAt)]
    : ['warn', live + ' of ' + n + ' reporting'];
  const temps = Object.values(st.invT);
  const warm = temps.length ? temps.reduce((x, y) => (y.ac > x.ac ? y : x)) : null;
  const hot = temps.some(t => t.ac > EQ_HOT_AC || (t.dc != null && t.dc > EQ_HOT_DC));
  const out = st.invs.filter(i => !st.quiet.includes(i)).reduce((s, i) => s + (i.output || 0), 0);
  const heatVals = Array.from({ length: DAY_LAST + 1 }, (_, i) => {
    const vs = rows.map(r => r.points[i] && r.points[i].ac).filter(v => v != null);
    return [i * 5, vs.length ? Math.max(...vs) : null];
  });
  // ---- grid: voltage now, and any time off today, from our own minute readings (SOLAR-398) ----
  const liveInv = st.invs.filter(i => !st.quiet.includes(i));
  const volt = liveInv.map(i => i.gridVolt).find(v => v > 50) || null;
  const gb = (gridDay && gridDay.buckets) || [];
  const outages = [];
  gb.forEach(b => { const r = outages[outages.length - 1]; if (!b.off) return; if (r && r[1] === b.i - 1) r[1] = b.i; else outages.push([b.i, b.i]); });
  const offMin = gridDay ? Number(gridDay.offMinutes) || 0 : 0;
  const gridState = st.allQuiet || a.gridPresent == null ? ['stale', st.allQuiet ? last(st.lastAt) : 'Not known']
    : a.gridPresent ? ['ok', 'On'] : ['warn', 'Off'];
  const vVals = gb.map(b => [b.i * 5, b.v]);
  return (
    <div className="eq-tiles">
      <EqTile label="Solar panels" state={pvState} value={st.pvParts[0]} unit={st.pvParts[1]} color={CC.pv} stale={st.allQuiet}
        sub={st.allQuiet ? st.pvSub : st.pvSub + (a.pvNow > 0 ? ' · now ' + fmtPower(a.pvNow) : '')}
        spark={pvVals.length > 1 && <EqSpark vals={pvVals} lo={0} hi={pvMax} stroke={CC.pv} fill={CC.pv} />} />
      {st.hasBatt && <EqTile label="Battery" state={battState} value={a.battSoc ?? '—'} unit={a.battSoc != null ? '%' : null} color={CC.batt} stale={st.battStale}
        sub={battSub} spark={pts.some(p => p.soc != null) && <EqSpark vals={pts.map(p => [p.t, p.soc])} lo={0} hi={100} stroke={CC.batt} />} />}
      <EqTile label={n === 1 ? 'Inverter' : 'Inverters'} state={hot && !st.allQuiet ? ['warn', 'Running hot'] : invState}
        value={warm ? Math.round(warm.ac) : '—'} unit={warm ? ' °C' : null} stale={st.allQuiet}
        sub={[warm && (n > 1 ? 'warmest at ' : 'at ') + HM(warm.at), !st.allQuiet && fmtPower(out) + ' to the house'].filter(Boolean).join(' · ')}
        spark={heatVals.some(v => v[1] != null) && <EqSpark vals={heatVals} lo={30} hi={70} heat={EQ_HOT_AC} />} />
      {st.hasGrid && <EqTile label="Grid" state={gridState} value={volt ? Math.round(volt) : '—'} unit={volt ? ' V' : null} color={CC.grid} stale={st.allQuiet || !volt}
        sub={gb.length ? (offMin ? 'Off ' + window.fmtDuration(offMin) + ' today' : 'No outage today') : null}
        spark={vVals.some(v => v[1] != null) && <EqSpark vals={vVals} lo={215} hi={255} stroke={CC.grid} outages={outages} />} />}
    </div>
  );
}

// Detailed (SOLAR-392): a card per part, the inverters side by side in columns so they
// read across; what only an installer would want sits under "More detail". The two day
// charts run full width below.

// A table with a column per inverter. `rows`: [label, cells], one cell per inverter, each
// { v, sub, cls } or null for nothing there (an inverter without that string).
function EqTable({ invs, st, now, rows }) {
  const many = invs.length > 1;
  return (
    <div className="eq-table">
      <table>
        {many && (
          <thead><tr><th />{invs.map(inv => {
            const down = st.quiet.includes(inv); // its column reads dashes; the Inverters card says why
            return <th key={inv.sn} scope="col" className={down ? 'down' : undefined}>{invName(inv)}</th>;
          })}</tr></thead>
        )}
        <tbody>
          {rows.map(([label, cells]) => (
            <tr key={label}>
              <th scope="row">{label}</th>
              {cells.map((c, k) => (
                <td key={invs[k].sn} className={c && c.cls}>
                  {c ? <span className="mono">{c.v}</span> : null}
                  {c && c.sub && <span className="eq-sub">{c.sub}</span>}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// Rows an everyday look doesn't need, folded shut.
function EqMore({ rows }) {
  const shown = rows.filter(r => r[1] != null);
  if (!shown.length) return null;
  return (
    <details className="eq-more">
      <summary>More detail<Icon id="chevron" /></summary>
      <dl className="eq-rows">{shown.map(([l, val]) => <div key={l}><dt>{l}</dt><dd className="mono">{val}</dd></div>)}</dl>
    </details>
  );
}

const eqVolts = v => v != null && v > 0 ? Math.round(v) + ' V' : null;
const eqReadAt = (inv, now) => inv.readAt ? window.readAgo(inv.readAt, now) : '—';

// Solar panels: today's total, then each inverter's solar now, each string's yield with its
// live volts and amps, today and since installed. A string well below its usual share is red.
function EqPanelsCard({ st, snap, health, now }) {
  const v = st.verdict;
  const hi = (health && health.inverters) || [];
  const invs = snap.inverters;
  const down = inv => st.quiet.includes(inv);
  const nos = [...new Set(invs.flatMap(inv => {
    const h = hi.find(x => x.sn === inv.sn);
    return (h ? h.strings.map(s => s.no) : []).concat((inv.strings || []).map(s => s.no));
  }))].sort((x, y) => x - y);
  const compared = v && (v.state === 'normal' || v.state === 'alert' || v.state === 'resting');
  const stringCell = (inv, no) => {
    const h = hi.find(x => x.sn === inv.sn);
    const hs = h && h.strings.find(s => s.no === no);
    const live = (inv.strings || []).find(s => s.no === no);
    if (!hs && !live) return null;
    if (down(inv)) return { v: '—' };
    const kwh = hs ? hs.todayKwh || 0 : live.today;
    const sub = live && live.v > 0 ? Math.round(live.v) + ' V · ' + (live.i || 0).toFixed(1) + ' A' : null;
    const alert = v && v.state === 'alert' && v.alerts.find(x => x.inv.sn === inv.sn && x.no === no);
    if (!alert) return { v: fmtKwh(kwh), sub };
    const multi = h.strings.length >= 2;
    const share = multi ? hs.usualInvShare : hs.usualPlantShare;
    const usual = compared && share != null ? share * (multi ? h.strings.reduce((n, s) => n + (s.todayKwh || 0), 0) : health.todayKwh) : null;
    return { v: fmtKwh(kwh), cls: 'bad', sub: alert.kind === 'nothing' ? 'Made nothing today' : usual != null ? 'Usually ' + fmtKwh(usual) + ' by now' : 'Less than usual' };
  };
  const toGo = PANELS_MIN_DAYS - ((health && health.historyDays) || 0);
  const note = v && {
    learning: 'String checks start in ' + toGo + (toGo === 1 ? ' day.' : ' days.'),
    early: 'Strings are checked once the panels have made ' + PANELS_MIN_KWH + ' kWh today.',
    dull: 'Not enough sun today to check the strings.',
    unchecked: 'Battery full, panels turned down. Strings not checked today.',
  }[v.state];
  const rows = [
    ['Solar now', invs.map(inv => ({ v: down(inv) ? '—' : fmtPower(inv.pvNow) }))],
    ...nos.map(no => ['String ' + no, invs.map(inv => stringCell(inv, no))]),
    ['Today', invs.map(inv => down(inv) && st.pvParts[0] === '—' ? { v: '—' } : { v: fmtKwh(inv.pvToday), cls: 'pv' })],
    ['Since installed', invs.map(inv => ({ v: window.fmtEnergySmart(inv.pvTotal) }))],
  ];
  return (
    <Card className="eq-card">
      <SectionTitle right={st.allQuiet ? NBSP : <>Now <b>{fmtPower(st.a.pvNow)}</b></>}>SOLAR PANELS</SectionTitle>
      <div className={'eq-big mono' + (st.allQuiet ? ' stale' : '')} style={st.allQuiet ? undefined : { color: CC.pv }}>{st.pvParts[0]}{st.pvParts[1] && <span className="u">{st.pvParts[1]}</span>}</div>
      <div className="eq-big-sub">{st.pvSub}</div>
      <EqTable invs={invs} st={st} now={now} rows={rows} />
      {note && <div className="eq-note">{note}</div>}
    </Card>
  );
}

// The battery: charge against the reserve, then what it is doing, its voltage, current and
// temperature, and what went in and out. Each pack as the inverters read it is folded away.
function EqBatteryCard({ st, snap, now }) {
  const { a } = st;
  const cfg = snap.config || {};
  const reserve = cfg.reserve ?? 20;
  const cap = cfg.battCapacity;
  const rows = [];
  if (st.battStale) rows.push(['Last reading', st.battAt ? window.readAgo(st.battAt, now) : '—']);
  else {
    rows.push(['Now', a.battOut > 5 ? 'Powering the house at ' + fmtPower(a.battOut) : a.battOut < -5 ? 'Charging at ' + fmtPower(-a.battOut) : 'Resting']);
    if (cap > 0 && a.battSoc != null) rows.push(['Stored', window.fmtEnergyParts(a.battSoc * cap / 100)[0] + ' of ' + fmtKwh(cap)]);
    if (a.battVoltage > 0) rows.push(['Voltage · current', a.battVoltage.toFixed(1) + ' V · ' + Math.abs(a.battCurrent || 0).toFixed(1) + ' A']);
    if (st.badSensor) rows.push(['Temperature', 'Sensor not reading', true]);
    else if (st.battTemp != null) rows.push(['Temperature', Math.round(st.battTemp) + ' °C' + (st.battTemp > 45 ? ', hot' : st.battTemp < 5 ? ', cold' : ''), st.battTemp > 45]);
  }
  if (!st.battStale) rows.push(['In · out today', window.fmtEnergyParts(a.battChgToday)[0] + ' · ' + fmtKwh(a.battDischgToday)]);
  if (a.battChgTotal > 0) rows.push(['In · out since installed', window.fmtEnergySmart(a.battChgTotal) + ' · ' + window.fmtEnergySmart(a.battDischgTotal)]);
  const packs = st.shared ? Math.min(1, st.withBatt.length) : st.withBatt.length;
  const modules = st.shared ? Math.max(0, ...st.withBatt.map(i => i.numberOfBatteries || 0)) : st.withBatt.reduce((n, i) => n + (i.numberOfBatteries || 0), 0);
  // each pack under the inverter that reads its sensor: the slaves on a shared pack read -100.
  // One whose answer came back empty this minute is likely it, so it keeps the pack.
  const packInv = st.withBatt.find(i => cleanTemp(i.battTemp) != null) || st.withBatt.find(i => i.battSoc == null) || st.withBatt[0];
  const packLine = (soc, volt, t) => [soc != null ? soc + '%' : '—', volt != null ? volt.toFixed(1) + ' V' : '—', t != null ? Math.round(t) + ' °C' : '—'].join(' · ');
  const more = [];
  (st.shared ? [packInv].filter(Boolean) : st.withBatt).forEach((inv, k, all) => {
    const name = all.length > 1 ? invName(inv) + ', pack' : 'Pack';
    more.push([inv.bank2 ? name + ' 1' : name, packLine(inv.battSoc, inv.battVolt, cleanTemp(inv.battTemp))]);
    if (inv.bank2) more.push([name + ' 2', packLine(inv.bank2.soc, inv.bank2.voltage, cleanTemp(inv.bank2.temperature))]);
  });
  const ah = st.shared ? Math.max(0, ...st.withBatt.map(i => i.battCap || 0)) : st.withBatt.reduce((n, i) => n + (i.battCap || 0), 0);
  if (ah > 0) more.push(['Capacity', Math.round(ah) + ' Ah']);
  const soc = Math.max(0, Math.min(100, a.battSoc || 0));
  return (
    <Card className="eq-card">
      <SectionTitle right={<>{packs} {packs === 1 ? 'pack' : 'packs'} · {modules} {modules === 1 ? 'battery' : 'batteries'}</>}>BATTERY</SectionTitle>
      <div className={'eq-big mono' + (st.battStale ? ' stale' : '')} style={st.battStale ? undefined : { color: CC.batt }}>{a.battSoc ?? '—'}{a.battSoc != null && <span className="u">%</span>}</div>
      <div className={'eq-meter' + (st.battStale ? ' stale' : '')}><i style={{ width: soc + '%', background: CC.batt }} /><b style={{ left: reserve + '%' }} /></div>
      <div className="eq-meter-scale"><span style={reserve > 60 ? { right: (100 - reserve) + '%' } : { left: reserve + '%' }}>{reserve}% reserve</span></div>
      <dl className="eq-rows">
        {rows.map(([l, val, warn]) => <div key={l}><dt>{l}</dt><dd className={'mono' + (warn ? ' warn' : '')}>{val}</dd></div>)}
      </dl>
      <EqMore rows={more} />
    </Card>
  );
}

// The inverters side by side: on or not, what each sends to the house, model and firmware.
function EqInvertersCard({ st, now }) {
  const invs = st.invs;
  const down = inv => st.quiet.includes(inv);
  const rows = [
    ['State', invs.map(inv => down(inv) ? { v: 'Not reporting', cls: 'warn', sub: inv.readAt ? 'Since ' + window.readAgo(inv.readAt, now) : null }
      : { v: <><i className="eq-dot sm ok" />On</>, sub: 'Read ' + eqReadAt(inv, now) })],
    ['To the house now', invs.map(inv => ({ v: down(inv) ? '—' : fmtPower(inv.output) }))],
    ['Temperature', invs.map(inv => {
      const t = st.invT[inv.sn];
      if (!t) return { v: '—' };
      const hot = t.ac > EQ_HOT_AC || (t.dc != null && t.dc > EQ_HOT_DC);
      return { v: Math.round(t.ac) + ' °C', cls: hot ? 'bad' : undefined,
        sub: (t.dc != null ? 'DC side ' + Math.round(t.dc) + ' °C, ' : '') + 'at ' + HM(t.at) };
    })],
    ['Home use today', invs.map(inv => ({ v: down(inv) && st.pvParts[0] === '—' ? '—' : fmtKwh(inv.loadToday) }))],
    ['Model', invs.map(inv => ({ v: inv.model, cls: 'wrap' }))],
    ['Firmware', invs.map(inv => ({ v: inv.soft }))],
  ];
  // per inverter when there are several, so each row says whose it is
  const each = (label, f) => invs.map(inv => [invs.length > 1 ? invName(inv) + ', ' + label.toLowerCase() : label, f(inv)]);
  const more = [
    ...each('Serial number', inv => inv.sn),
    ...each('Wi-Fi dongle', inv => inv.gsn !== '—' ? inv.gsn : null),
    ...each('Screen firmware', inv => inv.hmi !== '—' ? inv.hmi : null),
    ...each('Output voltage', inv => down(inv) ? null : inv.phases.map(p => eqVolts(p.volt)).filter(Boolean).join(' · ') || null),
    ...each('Unused panel inputs', inv => inv.unusedInputs > 0 ? String(inv.unusedInputs) : null),
  ];
  return (
    <Card className="eq-card">
      <SectionTitle>{invs.length === 1 ? 'INVERTER' : 'INVERTERS'}</SectionTitle>
      <EqTable invs={invs} st={st} now={now} rows={rows} />
      <EqMore rows={more} />
    </Card>
  );
}

// The grid as each inverter sees it now; the day's story is the chart below.
function EqGridCard({ st }) {
  const { a } = st;
  const live = st.invs.filter(inv => !st.quiet.includes(inv));
  const volts = inv => inv.gridVolts.map(eqVolts).filter(Boolean).join(' · ') || eqVolts(inv.gridVolt) || '—';
  const rows = [['Grid', st.allQuiet || a.gridPresent == null ? '—' : a.gridPresent ? 'On' : 'Off', a.gridPresent === false]];
  if (live.length === 1) rows.push(['Voltage', volts(live[0])]);
  else live.forEach(inv => rows.push([invName(inv) + ', voltage', volts(inv)]));
  rows.push(['Frequency', !st.allQuiet && a.gridFreq > 0 ? a.gridFreq.toFixed(2) + ' Hz' : '—']);
  if (!st.allQuiet && a.gridPf > 0) rows.push(['Power factor', a.gridPf.toFixed(2)]);
  return (
    <Card className="eq-card">
      <SectionTitle>GRID SUPPLY</SectionTitle>
      <dl className="eq-rows">
        {rows.map(([l, val, bad]) => <div key={l}><dt>{l}</dt><dd className={'mono' + (bad ? ' bad' : '')}>{val}</dd></div>)}
      </dl>
    </Card>
  );
}

function EquipmentDetailed({ st, snap, health, now, refreshKey }) {
  return (
    <>
      <div className="eq-cards">
        <EqPanelsCard st={st} snap={snap} health={health} now={now} />
        {st.hasBatt && <EqBatteryCard st={st} snap={snap} now={now} />}
      </div>
      <div className="eq-cards">
        <EqInvertersCard st={st} now={now} />
        {st.hasGrid && <EqGridCard st={st} />}
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

function InvertersTab({ snap, today, refreshKey }) {
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
  // Today's temperatures: the same answer the Temperature chart asks for, shared, so no extra call
  const [hist, setHist] = React.useState(null);
  const [gridDay, setGridDay] = React.useState(null); // today's grid from our own readings (SOLAR-398)
  React.useEffect(() => {
    let alive = true;
    window.fetchInverterHistory(window.localDateStr(), refreshKey).then(r => { if (alive) setHist(r); }).catch(() => {});
    window.fetchGridToday().then(r => { if (alive) setGridDay(r); }).catch(() => {});
    return () => { alive = false; };
  }, [refreshKey]);
  // Simple or Detailed is this viewer's own choice, kept across visits
  const [view, setView] = React.useState(() => { try { return localStorage.getItem('synsynk.eqView') === 'detailed' ? 'detailed' : 'simple'; } catch (e) { return 'simple'; } });
  const pickView = (v) => { setView(v); try { localStorage.setItem('synsynk.eqView', v); } catch (e) {} };

  const temps = React.useMemo(() => invTemps(hist), [hist]);
  const st = equipmentState(snap, health, now, temps);
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

      {simple ? <EquipmentSimple st={st} now={now} today={today} hist={hist} gridDay={gridDay} />
        : <EquipmentDetailed st={st} snap={snap} health={health} now={now} refreshKey={refreshKey} />}
    </div>
  );
}

// The shape to hold while the first snapshot is on its way. Trends and Settings never wait
// on one — App draws those for real — so they have no skeleton here.
function TabSkeleton({ tab, cfg }) {
  return tab === 'solar' ? <SolarSkeleton />
    : tab === 'home' ? <HomeSkeleton />
    : tab === 'grid' ? <GridSkeleton />
    : tab === 'inverters' ? <InvertersSkeleton />
    : <LiveSkeleton cfg={cfg} />;
}

// ---------------------------------------------------------------- SETTINGS / ACCOUNT
// Account, Billing and Plant, each one scrolling page in the Settings area (SOLAR-250,
// SettingsArea below). A section is its title and note over a full-width card.

// Inline "are you sure" for a destructive row. Sits under the row it belongs to, in
// the same inset box the add-login form uses, so the question stays in the page
// instead of a browser dialog. Focus lands on Cancel, so a second Enter from the button
// that opened it cannot fire the deletion; Escape closes it the way a dialog would.
// preventScroll: autoFocus made the browser scroll Cancel into view, so the page jumped (SOLAR-258).
const focusNoScroll = (el) => el && el.focus({ preventScroll: true });
// busy: the change is on its way; the card stays, buttons off, until it lands (SOLAR-281).
// modal: over the page in a Dialog rather than in place under its row.
// danger: the action is red, as it undoes something; otherwise green. No action: Cancel alone.
// label names a modal one, the action's words by default.
// confirmDisabled: the action waits on a choice in the children (KeepPicker's plants).
function ConfirmCard({ title, text, children, action, onConfirm, onCancel, cancelLabel = 'Cancel', busy = false, modal = false, danger = true, label, confirmDisabled }) {
  const cancel = React.useRef(null);
  React.useEffect(() => focusNoScroll(cancel.current), []);
  const body = <>
    {title && <div className="confirm-title">{title}</div>}
    {text && <div className="confirm-text">{text}</div>}
    {children}
    <div className="conn-form-actions">
      <button type="button" className="ghost-btn" onClick={onCancel} ref={cancel} disabled={busy}>{cancelLabel}</button>
      {action && <window.BusyButton className={danger ? 'danger-btn' : 'save-btn'} onClick={onConfirm} busy={busy} disabled={confirmDisabled}>{action}</window.BusyButton>}
    </div>
  </>;
  if (modal) return <window.Dialog label={label || action} busy={busy} onClose={onCancel}>{body}</window.Dialog>;
  return (
    <div className="conn-form confirm-card" role="alertdialog" aria-label={action}
         onKeyDown={(e) => { if (e.key === 'Escape') onCancel(); }}>
      {body}
    </div>
  );
}

// { id, done } when a section should flash once on arrival (e.g. from "Set your rate");
// it scrolls itself into view first.
const SettingsFlash = React.createContext(null);

// bare: no card of its own; the children bring their own cards (Billing's logins).
// action: a button at the top right of the section's title (Billing's Add SunSynk login).
function SettingsSection({ id, title, note, bare, action, children }) {
  const flash = React.useContext(SettingsFlash);
  const flashing = flash && flash.id === id;
  const ref = React.useRef(null);
  // A reload on #id scrolls back to it without the flash (SOLAR-165). Only on arrival:
  // the flash ending must not scroll again, or the page jumps once the cards above load (SOLAR-275).
  const arrived = React.useRef(false);
  React.useEffect(() => {
    if (flashing || (!arrived.current && location.hash === '#' + id)) ref.current?.scrollIntoView({ block: 'start' });
    arrived.current = true;
  }, [flashing]);
  return (
    <section id={'settings-' + id} className="sec" ref={ref} aria-labelledby={'settings-' + id + '-t'}>
      <div className="sec-intro">
        <div>
          <h2 id={'settings-' + id + '-t'} className="sset-title">{title}</h2>
          {note && <p className="sset-note">{note}</p>}
        </div>
        {action}
      </div>
      <div className={(bare ? 'sset-cards' : 'sset') + (flashing ? ' sset-flash' : '')}
           onAnimationEnd={flashing ? (e) => { if (e.animationName === 'sset-flash') flash.done(); } : undefined}>
        {bare ? children : <div className="sset-body">{children}</div>}
      </div>
    </section>
  );
}

// One line of a Settings card: its name and a note under it at the left, its control at the
// right (action, in actionClass's box). lead: before the name (a card's logo). children: after
// the row's parts, such as the dialog its button opens. hidden: a loading outline.
function SettingRow({ label, note, action, actionClass = 'conn-actions', lead, id, className = '', hidden, children }) {
  return (
    <div className={'conn-row' + (className ? ' ' + className : '')} id={id} aria-hidden={hidden || undefined}>
      {lead}
      <div className="conn-text">
        <div className="conn-user">{label}</div>
        {note != null && note !== false && <div className="conn-meta">{note}</div>}
      </div>
      {action && <div className={actionClass}>{action}</div>}
      {children}
    </div>
  );
}

// A plant under its login: the name, then its switch or state (children). off: greyed, not collecting.
function PlantLine({ name, off, children }) {
  return (
    <div className={'login-plant' + (off ? ' off' : '')}>
      <div className="conn-user plant-nm">{name}</div>
      {children}
    </div>
  );
}

// The plan (SOLAR-208), on Billing since SOLAR-250: what it is, its price and renewal, then
// Adjust plan (a page of its own) and Cancel plan. Downgrade, cancel and a monthly/yearly
// switch wait for the billing date; going up is an upgrade and charges now
// (window.startUpgrade). A downgrade with more plants than the new plan covers first picks
// the plants it keeps (SOLAR-295): the others collect until the billing date, then stop.
const PLAN_RANK = { free: 0, home: 1, family: 2 };
// Since SOLAR-371: Home 2, Family 5. Extra plants are no longer sold; those already held still count.
const planRoom = (plan, extra) => (plan === 'family' ? 5 + (extra || 0) : plan === 'home' ? 2 : 1);
// The plants a downgrade picks from, under their logins as Billing lists them: collecting
// and not up for deletion, except those that stop on the billing date (drop), which can
// still be picked. A plant two logins share shows under the first.
const pickableLogins = (links) => {
  const seen = new Set();
  return (links?.accounts || []).filter(a => a.status !== 'disabled').map(a => ({ ...a,
    plants: (a.plants || []).filter(p => !p.paused && (!p.remove_on || p.drop) && !seen.has(p.plant_id) && seen.add(p.plant_id)) }))
    .filter(a => a.plants.length);
};
// Sends a change for the billing date, then reads the plan again. Failed: the toast says
// failed(error) and it re-reads anyway, as a change that ran out of time may still have landed.
// True once saved.
async function billingChange(rpc, args, reload, failed) {
  const { error } = await window.billingRpc(rpc, args);
  if (error) {
    reload();
    window.toast(failed(error), { error: true });
    return false;
  }
  await reload();
  return true;
}
// Books a change for the billing date, or undoes one. keep: the plants picked to stay
// (none: the first linked). True once booked.
async function bookPlan(b, plan, period, reload, keep) {
  const ok = await billingChange('api_billing_change', { p_plan: plan, p_period: period ?? null, p_keep: keep ?? null }, reload,
    () => 'Couldn’t change your plan. Try again.');
  if (ok) window.track(plan === b.plan ? 'plan_change_undone' : 'downgrade_done', { plan, period: period ?? b.period });
  return ok;
}
// A change booked for the billing date: what it says, and the button that undoes it.
function bookedChange(b) {
  const { billDay, rand, perUnit } = window.billingFmt;
  if (b.plan === 'free' || b.comped || !(b.nextPlan || b.nextPeriod || b.nextExtraPlants != null)) return null;
  // a paid switch to yearly (SOLAR-298): nothing to undo
  if (b.prepaidOn) return [`Switches to yearly on ${billDay(b.nextDate)}. Paid.`, null];
  // one sentence, as most billing pages put it: the plan, its plants and the price from the
  // billing date (nextAmount), as the booked change leaves it (SOLAR-367)
  const on = `On ${billDay(b.nextDate)} your plan changes to `;
  const then = `${rand(b.nextAmount)} ${perUnit(b.nextPeriod || b.period)}.`;
  const plants = (n) => (n === 1 ? '1 plant' : n + ' plants');
  return b.nextPlan === 'free' ? [on + 'Free, 1 plant.', `Keep ${PLAN_NAME[b.plan]}`]
    : b.nextPlan ? [on + `${PLAN_NAME[b.nextPlan]}, ${plants(planRoom(b.nextPlan, b.nextExtraPlants ?? b.extraPlants))}, ` + then, `Keep ${PLAN_NAME[b.plan]}`]
    : b.nextPeriod ? [on + `${b.nextPeriod}, ` + then, `Stay ${b.period}`]
    : [on + `${plants(planRoom(b.plan, b.nextExtraPlants))}, ` + then, `Keep ${plants(planRoom(b.plan, b.extraPlants))}`];
}
// Sets the extra plants from the billing date (SOLAR-264): fewer than held books a drop,
// as many as held undoes one. More is a payment (window.startUpgrade). True once saved.
async function bookExtras(b, count, reload, keep) {
  const ok = await billingChange('api_billing_extras', { p_count: count, p_keep: keep ?? null }, reload,
    (e) => /plan change/.test(e.message) ? 'Your plan changes on its billing date. Keep it first.' : 'Couldn’t change your extra plants. Try again.');
  if (ok) window.track('extra_plants_done', { count, change: count < b.extraPlants ? 'down' : 'undo' });
  return ok;
}
// Undo whatever is booked: the extras alone, or the plan and period.
const undoBooked = (b, reload) => (!b.nextPlan && !b.nextPeriod && b.nextExtraPlants != null
  ? bookExtras(b, b.extraPlants, reload) : bookPlan(b, b.plan, b.period, reload));
// A plan's price at list prices, with Family's extra plants (SOLAR-330).
const listPrice = (b, plan, period, extra = 0) => {
  const lp = b.listPrices?.[period] || {};
  return plan === 'free' ? 0 : plan === 'family' ? (lp.family ?? 0) + extra * (lp.extra ?? 0) : lp[plan];
};
const cancelText = (b) => {
  const { billDay, rand, perUnit, offerName } = window.billingFmt;
  const text = `It runs until ${billDay(b.nextDate)}. After that, on Free, readings are kept for 30 days, then only the last 24 hours. Alerts stay on; reports stop.`;
  // an offer goes with the plan: coming back costs the list price
  const list = b.offer?.held && listPrice(b, b.plan, b.period, b.extraPlants || 0);
  return list > b.price ? `${text} Your ${offerName(b.offer)} of ${rand(b.price)} ${perUnit(b.period)} goes too; ${PLAN_NAME[b.plan]} costs ${rand(list)} if you come back.` : text;
};

// A downgrade's pick (SOLAR-295): the plants the new plan keeps, each with the switch and
// under the login Billing shows it with. One on for Home and Free; Family's room for Family.
// Starts from the plants kept now: those not stopping, then link order.
function KeepPicker({ b, room, logins, title, text, action, cancelLabel = 'Cancel', danger = false, busy, onPick, onCancel }) {
  const { useState } = React;
  const { billDay } = window.billingFmt;
  const plants = logins.flatMap(a => a.plants);
  const [keep, setKeep] = useState(() => [...plants.filter(p => !p.drop), ...plants.filter(p => p.drop)].slice(0, room).map(p => p.plant_id));
  const one = room === 1;
  // only plants still listed: the list re-reads while this is open
  const picked = keep.filter(id => plants.some(p => p.plant_id === id));
  const toggle = (id) => setKeep(k => k.includes(id) ? k.filter(x => x !== id) : one ? [id] : picked.length < room ? [...picked, id] : k);
  return (
    <ConfirmCard modal title={title || (one ? 'Pick the plant to keep' : `Pick ${room} plants to keep`)} text={text} action={action}
      cancelLabel={cancelLabel} danger={danger} busy={busy} confirmDisabled={picked.length !== room}
      onConfirm={() => onPick(picked)} onCancel={onCancel}>
      <div className="login-list keep-picks">
        {logins.map(a => (
          <div key={a.account_id} className="login-grp">
            <div className="login-line"><span className="login-email">{a.sunsynk_username}</span></div>
            {a.plants.map(p => {
              const on = keep.includes(p.plant_id);
              const name = window.plantLabel(p);
              return (
                <PlantLine key={p.plant_id} name={name} off={!on}>
                  <window.Switch on={on} label={'Keep ' + name} disabled={busy || (!one && !on && picked.length >= room)} onChange={() => toggle(p.plant_id)} />
                </PlantLine>
              );
            })}
          </div>
        ))}
      </div>
      <div className="confirm-text keep-note">Others collect until {billDay(b.nextDate)}, then stop. Their history is deleted on {billDay(window.shiftDate(b.nextDate, 30))}.</div>
    </ConfirmCard>
  );
}

// Cancel plan, from Billing or Adjust plan: with more than one plant it first picks the one
// Free keeps. onConfirm(keep), keep undefined when there was nothing to pick.
function CancelPlanDialog({ b, logins, busy, onConfirm, onCancel }) {
  const title = <>Cancel {PLAN_NAME[b.plan]}?</>, keepLabel = 'Keep ' + PLAN_NAME[b.plan];
  return logins.flatMap(a => a.plants).length > 1
    ? <KeepPicker b={b} room={1} logins={logins} title={title} text={cancelText(b) + ' Pick the plant to keep.'}
        action="Cancel plan" danger cancelLabel={keepLabel} busy={busy} onPick={onConfirm} onCancel={onCancel} />
    : <ConfirmCard modal title={title} text={cancelText(b)} action="Cancel plan" cancelLabel={keepLabel}
        busy={busy} onConfirm={() => onConfirm()} onCancel={onCancel} />;
}

function PlanSection({ billing, reload, onAdjust, freeWeekEndsAt }) {
  const { useState } = React;
  const [busy, setBusy] = useState(false);
  const kind = !billing ? null : billing.comped ? 'comped' : billing.plan !== 'free' ? 'paid' : 'free';
  React.useEffect(() => { if (kind) try { localStorage.setItem('synsynk.planKind', kind); } catch (e) {} }, [kind]);
  // Its outline while the plan loads, from the last plan seen on this device, so the
  // sections below don't jump down (SOLAR-221). Free waits for api_me too (undefined until
  // it answers): its line depends on whether the free week is still on.
  if (!billing || (kind === 'free' && freeWeekEndsAt === undefined)) {
    const last = (() => { try { return localStorage.getItem('synsynk.planKind'); } catch (e) { return null; } })() || 'free';
    return (
      <SettingsSection id="plan" title="Plan" bare>
        <PlanCard title={<window.Skeleton w={130} h={20} r={6} />} hidden
          action={last !== 'comped' && <window.Skeleton w={112} h={34} r={9} />}>
          <window.Skeleton w={280} h={12} r={5} style={{ marginTop: 9, maxWidth: '100%' }} />
        </PlanCard>
      </SettingsSection>
    );
  }
  const { rand, perUnit } = window.billingFmt;
  const b = billing;
  const paid = b.plan !== 'free' && !b.comped;
  const booked = bookedChange(b);
  const ending = paid && b.nextPlan === 'free';
  // The free week (api_me, 0122): a Free account sees full history until it ends.
  const weekEnds = b.plan === 'free' && !b.comped && freeWeekEndsAt && Date.parse(freeWeekEndsAt) > Date.now()
    ? new Date(freeWeekEndsAt).toLocaleDateString('en-CA', { timeZone: 'Africa/Johannesburg' }) : null;
  // A word beside the name only when something is wrong; an active plan needs none.
  // an ending plan says so in the notice under it (SOLAR-364)
  const word = b.state === 'past_due' ? 'Payment failed' : null;
  const line = b.comped ? 'Free of charge. Every plant, full history.'
    : weekEnds ? `Free week until ${window.billingFmt.billDay(weekEnds)}.`
    : !paid ? '1 plant and the last 24 hours. No card needed.' : null;
  // the plants it collects, with any extra plants still held (SOLAR-371)
  const room = planRoom(b.plan, b.extraPlants);
  const run = async (fn, key = true) => { setBusy(key); try { await fn(); } finally { setBusy(false); } };
  return (
    <SettingsSection id="plan" title="Plan" bare>
      {/* the plan top left, its button top right; its price and renewal in the darker box under them */}
      <PlanCard title={<>{PLAN_NAME[b.plan]}{word && <span className="conn-status bad">{word}</span>}</>}
        action={!b.comped && <button type="button" className={paid ? 'ghost-btn' : 'save-btn'} onClick={onAdjust}>Adjust plan</button>}>
        {line && <div className="plan-line">{line}</div>}
        {paid && (
          <div className="pay-review-box">
            <div className="pay-review-ln"><span>{room === 1 ? '1 plant' : room + ' plants'}</span><b>{rand(b.price)} {perUnit(b.period)}</b></div>
            {/* past due and ending say their date below */}
            {b.state !== 'past_due' && !ending && <div className="pay-review-ln"><span>Renews</span><b>{window.dayText(b.nextDate, { day: 'numeric', month: 'short', year: 'numeric' })}</b></div>}
          </div>
        )}
        {paid && b.offer?.held && <div className="conn-meta pw-offer">{window.billingFmt.offerLine(b.offer, listPrice(b, b.plan, b.period, b.extraPlants || 0), b.period)}</div>}
        {b.state === 'past_due' && (
          <div className="plan-booked plan-alert">
            <span className="conn-status bad">Payment failed.{b.nextTry && <> Next try {window.billingFmt.billDay(b.nextTry)}.</>} Pay by {window.billingFmt.billDay(b.freeOn)} to keep {PLAN_NAME[b.plan]}.</span>
            <button type="button" className="save-btn" onClick={() => window.settlePayment()}>Pay with another card</button>
          </div>
        )}
        {booked && <BookedNotice booked={booked} busy={busy} onUndo={() => run(() => undoBooked(b, reload))} />}
      </PlanCard>
    </SettingsSection>
  );
}

// One card of Billing's Plan section: its title top left, its control top right, the rest under them.
// hidden: a loading outline.
function PlanCard({ title, action, hidden, children }) {
  return (
    <div className="sset" aria-hidden={hidden || undefined}>
      <div className="sset-body">
        <div className="plan-head">
          <div className="plan-name">{title}</div>
          {action && <div className="plan-acts">{action}</div>}
        </div>
        {children}
      </div>
    </div>
  );
}

// A change booked for the billing date, the undo a link in the notice, so the card keeps one
// button (SOLAR-283).
function BookedNotice({ booked, busy, onUndo }) {
  return (
    <div className="plan-booked plan-alert">
      <span className="conn-status warn">{booked[0]} {booked[1] && <button type="button" className="plan-undo" disabled={busy} aria-busy={busy} onClick={onUndo}>{booked[1]}</button>}</span>
    </div>
  );
}

// Which of Billing's lower sections showed last on this device, as Plan keeps its kind: while
// the plan loads they draw as outlines in their places rather than popping in under it.
const BILL_SHAPE = 'synsynk.billShape';
const billShape = () => { try { return JSON.parse(localStorage.getItem(BILL_SHAPE)) || {}; } catch (e) { return {}; } };
const shapeOf = (b) => ({
  pay: !b.comped && !(b.plan === 'free' && !b.card), card: !!b.card,
  payNote: b.plan !== 'free' && b.nextPlan !== 'free', update: b.plan !== 'free' && b.state !== 'past_due',
  inv: b.comped ? 0 : (b.payments || []).length,
  cancel: !(b.comped || b.plan === 'free' || b.nextPlan === 'free'),
});

// Cancellation, last on Billing as on most billing pages: a paid plan not already ending.
function CancelSection({ billing: b, reload, logins = [] }) {
  const { useState } = React;
  const [busy, setBusy] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  if (!b) return billShape().cancel ? (
    <SettingsSection id="cancel" title="Cancellation">
      <SettingRow hidden label="Cancel plan" action={<window.Skeleton w={112} h={34} r={9} />} />
    </SettingsSection>
  ) : null;
  if (b.comped || b.plan === 'free' || b.nextPlan === 'free') return null;
  return (
    <SettingsSection id="cancel" title="Cancellation">
      <SettingRow label="Cancel plan"
        action={<button type="button" className="danger-btn" disabled={busy || cancelling} onClick={() => setCancelling(true)}>Cancel</button>} />
      {cancelling && <CancelPlanDialog b={b} logins={logins} busy={busy} onCancel={() => setCancelling(false)}
        onConfirm={async (keep) => { setBusy(true); await bookPlan(b, 'free', null, reload, keep); setBusy(false); setCancelling(false); }} />}
    </SettingsSection>
  );
}

// Adjust plan (SOLAR-250): a page of its own, back to Billing. Free, Home and Family side by
// side with a monthly/yearly switch. A smaller plan in either period is booked for the
// billing date (SOLAR-364); a bigger one is paid today, in the plan's own period or, from
// monthly, yearly. No extra plants (SOLAR-371): more than Family's 5 is by email.
const PLAN_TAG = { free: 'See your solar today', home: 'One house, every day kept', family: 'More than one house' };
function AdjustPlanPage({ billing, reload, onBack, logins = [], forPlant = null }) {
  const plants = logins.flatMap(a => a.plants);
  const { useState, useEffect } = React;
  const b = billing;
  const paid = !!b && b.plan !== 'free' && !b.comped;
  const [view, setView] = useState(paid ? b.period : 'monthly');
  // Opened before the plan loaded (straight to the plans page): show the plan's own period.
  useEffect(() => { if (paid) setView(b.period); }, [paid, b?.period]);
  const [busy, setBusy] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  // A downgrade that needs a pick first (SOLAR-295): { plan, period }
  const [picking, setPicking] = useState(null);
  // Home monthly on the Yearly tab: Family yearly is paid now, from today (SOLAR-364)
  const across = paid && b.plan === 'home' && b.period === 'monthly' && view === 'yearly';
  const period = paid && !across ? b.period : view;
  useEffect(() => { window.track('plan_page_shown', { plan: b?.plan }); }, []);
  // It can't close while a change is saving, so the result is never lost from view.
  const close = () => { if (!busy) onBack(); };
  const pop = (body) => <window.Dialog size="wide" label="Pick your plan" onClose={close}>{body}</window.Dialog>;
  const back = (
    <button type="button" className="pop-x" aria-label="Close" disabled={busy} onClick={close}>
      <Icon id="close" />
    </button>
  );
  if (!b) return pop(
    <div className="settings-page plan-pop">
      {back}
      <div className="page-head"><h1>Pick your plan</h1></div>
      <div className="plan-grid plan-cards" aria-hidden="true">{[0, 1, 2].map(i => <window.Skeleton key={i} h={260} r={14} />)}</div>
    </div>
  );
  const { rand, billDay, perUnit, offerLine, offerCap, Was } = window.billingFmt;
  const unit = perUnit(view);
  const prices = b.prices?.[view] || {};
  const sameView = !paid || view === b.period;
  const price = (p) => p === 'free' ? 0 : p === b.plan && sameView ? b.price : prices[p];
  // its list price, with the extra plants still held on your own Family card
  const list = (p) => listPrice(b, p, view, p === b.plan && sameView ? b.extraPlants || 0 : 0);
  const run = async (fn, key = true) => { setBusy(key); try { await fn(); } finally { setBusy(false); } };
  const booked = bookedChange(b);
  // the plan's own card while a change is booked: when it ends or changes, in either period
  const ownDate = <div className="plan-cur">{b.nextPlan === 'free' ? 'Ends ' : 'Changes '}{billDay(b.nextDate)}</div>;
  // a smaller plan booked for the billing date in this period; Free has none
  const bookedHere = (p) => b.nextPlan === p && (p === 'free' || (b.nextPeriod || b.period) === view);
  // The line under a price: Family's says where more plants go
  const note = (p) => (p === 'family' ? <>More than 5 plants? <a className="mini-link" href="mailto:hello@princesolarhub.co.za" onClick={() => window.track('more_plants_email_done', { plan: b.plan, from: 'plans' })}>Email us</a>.</> : ' ');
  const action = (p) => {
    // a paid year changes nothing until it starts (SOLAR-298); a quiet line holds the button's row
    if (b.prepaidOn && !(p === b.plan && !sameView)) return <div className="plan-cur plan-wait">{p === b.plan ? 'Yearly from ' : 'After '}{billDay(b.nextDate)}</div>;
    if (p === b.plan && paid && b.nextPlan) return ownDate;
    if (p === b.plan) {
      if (!sameView) return b.nextPeriod === view ? <div className="plan-cur">From {billDay(b.nextDate)}</div>
        // monthly to yearly is paid now (SOLAR-298); yearly to monthly is booked
        : view === 'yearly' ? <button type="button" className="ghost-btn" onClick={() => window.startUpgrade(b.plan, 'yearly', false, null, null,
            { name: 'yearly_switch_done', props: { plan: b.plan } })}>Switch</button>
        : <button type="button" className="ghost-btn" disabled={!!busy} aria-busy={busy === 'switch'} onClick={() => run(() => bookPlan(b, b.plan, view, reload), 'switch')}>Switch</button>;
      // in the button's place, so the card for your plan has no empty row (SOLAR-303)
      return <div className="plan-cur">{paid ? (booked ? 'Changes ' : 'Renews ') + billDay(b.nextDate) : 'No card needed'}</div>;
    }
    // a bigger plan is bought in the plan's own period
    if (!sameView && !across && PLAN_RANK[p] > PLAN_RANK[b.plan]) return <div className="plan-cur plan-wait">Available {b.period}</div>;
    if (PLAN_RANK[p] > PLAN_RANK[b.plan]) return <button type="button" className="save-btn"
      onClick={() => (b.offer && window.track('offer_pick_done', { offer: b.offer.id, plan: p, period }), window.startUpgrade(p, period, !paid, null, forPlant ? [forPlant] : null))}>Upgrade</button>;
    if (bookedHere(p)) return <div className="plan-cur">From {billDay(b.nextDate)}</div>;
    // a smaller plan in either period, from the billing date (SOLAR-364)
    return <button type="button" className="ghost-btn" disabled={!!busy || cancelling} aria-busy={busy === 'down:' + p}
                   onClick={() => (p === 'free' ? setCancelling(true)
                     : plants.length > planRoom(p, b.nextExtraPlants ?? b.extraPlants) ? setPicking({ plan: p, period: view })
                     : run(() => bookPlan(b, p, view, reload), 'down:' + p))}>Downgrade</button>;
  };
  // The same four lines on every card, so the cards end level; false is a line the plan lacks
  const gives = {
    free: [['1 plant', true], ['The last 24 hours', true], ['Alerts', true], ['Reports by email', false]],
    home: [['2 plants', true], ['Full history', true], ['Alerts', true], ['Reports by email', true]],
    family: [['5 plants', true], ['Full history', true], ['Alerts', true], ['Reports by email', true]],
  };
  return pop(
    <div className="settings-page plan-pop">
      {back}
      <div className="page-head">
        <h1>Pick your plan</h1>
        {!b.comped && <p>{paid ? `Upgrades start today. Downgrades start on ${billDay(b.nextDate)}.` : 'Upgrades start today.'}</p>}
      </div>
      {b.comped ? <p className="field-note">Your plan is free of charge: every plant, full history.</p> : <>
        <Segmented size="sm" className="plan-period" label="Billing" value={view} onChange={setView}
                   options={[{ value: 'monthly', label: 'Monthly' }, { value: 'yearly', label: 'Yearly, 2 months free' }]} />
        {/* One paywall on every screen: three cards side by side, stacked on phones (SOLAR-303, SOLAR-304) */}
        <div className="plan-grid plan-cards">
          {['free', 'home', 'family'].map(p => (
            <div key={p} className={'pw-plan' + (p === b.plan ? ' plan-mine' : '')}>
              {p === b.plan && <div className="plan-band">Your plan</div>}
              <div className="pw-name">{PLAN_NAME[p]}</div>
              <div className="plan-tagline">{PLAN_TAG[p]}</div>
              <div className="pw-price"><Was list={list(p)} price={price(p) ?? 0} /><b>{rand(price(p) ?? 0, true)}</b>{p !== 'free' && ' ' + unit}
                {b.offer && list(p) > (price(p) ?? 0) && <span className="pw-billed pw-offer">{offerLine(b.offer, list(p), view)}</span>}</div>
              <div className="plan-note">{note(p)}</div>
              {action(p)}
              <ul className="pw-gives plan-gives">
                {gives[p].map(([g, has], i) => <li key={i} className={has ? undefined : 'plan-off'}>{g}</li>)}
              </ul>
            </div>
          ))}
        </div>
        <p className="plan-foot">{offerCap(b.offer) && offerCap(b.offer) + ' '}Prices in rand. Cancel any time.</p>
        {cancelling && <CancelPlanDialog b={b} logins={logins} busy={!!busy} onCancel={() => setCancelling(false)}
          onConfirm={(keep) => run(async () => { await bookPlan(b, 'free', null, reload, keep); setCancelling(false); })} />}
        {picking && (
          <KeepPicker b={b} room={planRoom(picking.plan)} logins={logins} busy={!!busy} action="Downgrade"
            onPick={(keep) => run(async () => { await bookPlan(b, picking.plan, picking.period, reload, keep); setPicking(null); })}
            onCancel={() => setPicking(null)} />
        )}
      </>}
    </div>
  );
}

// The brand's own mark, as card lists in other apps show it. Paystack takes Visa, Mastercard and
// Amex; anything else keeps the name in text.
function CardLogo({ brand }) {
  const b = (brand || '').toLowerCase();
  if (b === 'visa') return (
    <svg className="pay-card pay-logo" viewBox="0 0 46 30" aria-hidden="true">
      <rect width="46" height="30" rx="5" fill="#fff" />
      <text x="23" y="19.5" textAnchor="middle" fill="#1a1f71" fontFamily="Arial, sans-serif" fontSize="12.5" fontWeight="800" fontStyle="italic">VISA</text>
    </svg>
  );
  if (b === 'mastercard') return (
    <svg className="pay-card pay-logo" viewBox="0 0 46 30" aria-hidden="true">
      <rect width="46" height="30" rx="5" fill="#1c1c1c" />
      <circle cx="18.5" cy="15" r="8" fill="#eb001b" /><circle cx="27.5" cy="15" r="8" fill="#f79e1b" />
      <path d="M23 8.4a8 8 0 0 1 0 13.2 8 8 0 0 1 0-13.2z" fill="#ff5f00" />
    </svg>
  );
  if (b === 'american express' || b === 'amex') return (
    <svg className="pay-card pay-logo" viewBox="0 0 46 30" aria-hidden="true">
      <rect width="46" height="30" rx="5" fill="#016fd0" />
      <text x="23" y="19" textAnchor="middle" fill="#fff" fontFamily="Arial, sans-serif" fontSize="10" fontWeight="800" fontStyle="normal" letterSpacing=".5">AMEX</text>
    </svg>
  );
  return <span className="pay-card" aria-hidden="true">{(brand || 'card').toUpperCase().slice(0, 4)}</span>;
}

// The saved card and the money taken (SOLAR-238). Change card opens Paystack's card
// page for R1, which goes back once the card is saved.
function PaymentsSection({ billing }) {
  const { useState } = React;
  const [busy, setBusy] = useState(false);
  const b = billing;
  if (!b) {
    const s = billShape();
    return s.pay ? (
      <SettingsSection id="payments" title="Payment" note={s.payNote ? 'Your card pays for renewals and upgrades.' : null}>
        {s.card ? (
          <SettingRow hidden lead={<window.Skeleton w={46} h={30} r={5} style={{ flex: 'none' }} />}
            label={<window.SkelLine w={150} />} note={<window.SkelLine w={90} />} action={s.update && <window.Skeleton w={84} h={34} r={9} />} />
        ) : <div className="field-note" aria-hidden="true"><window.SkelLine w={110} /></div>}
      </SettingsSection>
    ) : null;
  }
  if (b.comped || (b.plan === 'free' && !b.card)) return null;
  const c = b.card;
  return (
    <SettingsSection id="payments" title="Payment" note={b.plan !== 'free' && b.nextPlan !== 'free' ? 'Your card pays for renewals and upgrades.' : null}>
      {c ? (
        // past due: Pay with another card in Plan changes it and pays
        <SettingRow lead={<CardLogo brand={c.brand} />} label={<>{c.name} •••• <span className="mono">{c.last4}</span></>}
          note={`Expires ${String(c.expMonth).padStart(2, '0')}/${String(c.expYear).slice(-2)}`}
          action={b.plan !== 'free' && b.state !== 'past_due' && (
            <window.BusyButton className="ghost-btn" busy={busy} busyText="Opening…"
                    onClick={async () => { setBusy(true); await window.changeCard(); setBusy(false); }}>Update</window.BusyButton>
          )} />
      ) : <div className="field-note">No card saved.</div>}
    </SettingsSection>
  );
}
// The last six card payments (api_billing_status lists paid ones only). No PDF yet (SOLAR-265).
function InvoicesSection({ billing: b }) {
  if (!b) {
    const n = billShape().inv || 0;
    return n > 0 ? (
      <SettingsSection id="invoices" title="Invoices">
        <table className="pay-table" aria-hidden="true">
          <thead><tr><th>Date</th><th>Plan</th><th>Total</th><th>Status</th></tr></thead>
          <tbody>
            {Array.from({ length: n }, (_, i) => (
              <tr key={i}><td>{<window.SkelLine w={80} />}</td><td className="pay-what">{<window.SkelLine w={140} />}</td><td>{<window.SkelLine w={56} />}</td><td>{<window.SkelLine w={32} />}</td></tr>
            ))}
          </tbody>
        </table>
      </SettingsSection>
    ) : null;
  }
  if (b.comped || !(b.payments || []).length) return null;
  const { rand } = window.billingFmt;
  const day = (d) => window.dayText(d, { day: 'numeric', month: 'short', year: 'numeric' });
  // What each payment was for (SOLAR-302). Extra plants bought on the same plan are an
  // 'upgrade' charge too, so the plan before it tells them apart from a real upgrade.
  const plants = (n) => `${n} extra ${n === 1 ? 'plant' : 'plants'}`;
  const what = (p) => {
    const extra = p.extra > 0 ? ', ' + plants(p.extra) : '';
    if (p.kind === 'start') return 'first payment' + extra;
    if (p.kind === 'renewal') return 'renewal' + extra;
    if (p.kind === 'settle') return 'paid late';
    if (p.kind === 'switch') return 'switched from monthly'; // the row already says yearly
    if (p.kind === 'upgrade' && p.added > 0) return (p.prev === p.plan ? '' : 'upgrade, ') + plants(p.added);
    return p.kind === 'upgrade' ? 'upgrade' : '';
  };
  return (
    <SettingsSection id="invoices" title="Invoices">
      <table className="pay-table">
        <thead><tr><th>Date</th><th>Plan</th><th>Total</th><th>Status</th></tr></thead>
        <tbody>
          {b.payments.map(p => {
            const line = `${PLAN_NAME[p.plan]}, ${p.period}${what(p) ? ', ' + what(p) : ''}`;
            return (
            <tr key={p.at}>
              {/* on a phone the Plan column drops and the plan goes under the date */}
              <td>{day(p.date)}<span className="pay-what-sub">{line}</span></td>
              <td className="pay-what">{line}</td>
              <td className="mono">{rand(p.amount)}</td>
              <td>Paid</td>
            </tr>
            );
          })}
        </tbody>
      </table>
    </SettingsSection>
  );
}

// Billing's Plants: the signed-in user's SunSynk logins, each with its plants and their state, one row each with its plants, a reconnect in
// place when the token has died, and a remove. Adding or removing a login changes
// which plants the app can see, so the app reloads its plant list afterwards; when
// the last login goes there is nothing left to show and the app turns to its empty pages.
// `links` is the gate's own list (LinkGate), already read before the page opened, so the
// section draws at once and its changes reach the rest of the app (SOLAR-96).
// Plant states (stopped, deleted) and their buttons are on Billing since SOLAR-250.
// A login's quiet actions: change its password, remove it (SOLAR-251). The header's menus
// (usePopover, MenuList in app.jsx) do the opening, closing and arrow keys.
function LoginMenu({ email, busy, onPassword, onRemove }) {
  const [open, setOpen, ref] = usePopover();
  const pick = (fn) => () => { setOpen(false); fn(); };
  return (
    <div className="login-more" ref={ref}>
      {/* a word, not three dots, so it reads as a button (SOLAR-285) */}
      <button type="button" className="login-manage" aria-haspopup="menu" aria-expanded={open} aria-label={'Manage ' + email}
              disabled={busy} aria-busy={busy} onClick={() => setOpen(o => !o)}>
        Manage
        <Icon id="chevron" />
      </button>
      {open && (
        <MenuList className="login-menu" label={email}>
          {onPassword && <button type="button" role="menuitem" onClick={pick(onPassword)}>Change password</button>}
          <button type="button" role="menuitem" className="menu-danger" onClick={pick(onRemove)}>Remove login</button>
        </MenuList>
      )}
    </div>
  );
}

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
  const ago = (iso) => window.fmtAgo(new Date(iso), Date.now());
  // Waits for the fresh list, so the form's "Connecting…" holds until the login is listed.
  const changed = async (linked) => {
    const wasAdding = mode === 'add';
    const readError = await refresh();
    setMode(null); onChanged && onChanged(linked);
    if (readError) { fail('Connected. Reload the page to see it here.'); return; }
    const paused = new Set((linked?.paused || []).map(Number));
    const on = (linked?.plants || []).filter(p => !paused.has(Number(p.id)));
    const off = (linked?.plants || []).filter(p => paused.has(Number(p.id)));
    window.toast(wasAdding ? 'Login added.' + plantsLine(on, 'now in your plant list') + plantsLine(off, 'stopped: your plan is full') : 'Login reconnected.');
  };
  // " Plant 495944 is now in your plant list." for one plant, "… and … are …" for more
  const plantsLine = (plants, what) => {
    const names = (plants || []).map(p => window.plantLabel(p));
    if (!names.length) return '';
    const list = names.length > 1 ? names.slice(0, -1).join(', ') + ' and ' + names[names.length - 1] : names[0];
    return ' ' + list + (names.length > 1 ? ' are ' : ' is ') + what + '.';
  };
  // Removing asks once, inline under the row, in the app's own language rather than a
  // browser dialog. 'confirming' holds the account_id whose card is open.
  const [confirming, setConfirming] = useState(null);
  const [leaving, setLeaving] = useState(null); // account_id folding away after a remove
  const { billDay } = window.billingFmt;
  // Remove login deletes the login and its plants now, on every plan (0139). The plan and
  // the room paid for don't change: that's billing's, not the login's.
  const removeText = (acc) => {
    const n = (acc.plants || []).length;
    return !n ? 'It has no plants.'
      : n === 1 ? 'This plant and its history will be deleted straight away, unless another account shares it.'
      : 'These plants and their history will be deleted straight away, unless another account shares them.';
  };
  // The plants that go, in the pay pop-up's darker box, a panel before each (SOLAR-368).
  const removeList = (acc) => !!acc.plants?.length && (
    <div className="remove-plants">
      {acc.plants.map(p => (
        <div key={p.plant_id} className="remove-plant"><Icon id="panel" />{window.plantLabel(p)}</div>
      ))}
    </div>
  );
  const remove = async (acc) => {
    const last = live.length === 1;
    setConfirming(null);
    setBusy(acc.account_id);
    try {
      const { error } = await window.sb.rpc('api_link_remove', { p_account: acc.account_id });
      if (error) throw error;
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
  // A stopped plant booked for deletion shows its date and Keep too, so the booking is never hidden.
  const state = (p) => p.remove_on ? 'going' : p.paused ? 'paused' : plantOk[p.plant_id] ? 'on' : 'off';
  const allPlants = [...new Map(live.flatMap(a => a.plants || []).map(p => [p.plant_id, p])).values()];
  const keep = async (p) => {
    setBusy('keep:' + p.plant_id);
    const { error } = await window.billingRpc('api_billing_keep', { p_plant: p.plant_id });
    if (error) fail('Couldn’t keep it. Try again.');
    await Promise.all([refresh(), reloadBilling && reloadBilling()]);
    setBusy(null);
  };
  // Stop and Start (SOLAR-251): the plan sets how many plants collect. Stopping deletes
  // the plant's readings, so it asks first; a full plan offers the upgrade instead.
  const [stopping, setStopping] = useState(null); // plant_id whose confirm card is open
  const [full, setFull] = useState(null);         // plant_id that found the plan full
  const stop = async (p) => {
    setStopping(null); setBusy('stop:' + p.plant_id);
    const { error } = await window.sb.rpc('api_plant_stop', { p_plant: p.plant_id });
    if (error) fail('Couldn’t stop it. Try again.');
    else { window.track('plant_stop_done'); onChanged && onChanged(); }
    await refresh();
    setBusy(null);
  };
  const start = async (p) => {
    setFull(null); setBusy('start:' + p.plant_id);
    const { error } = await window.sb.rpc('api_plant_start', { p_plant: p.plant_id });
    if (error && /no room/.test(error.message)) setFull(p.plant_id);
    else if (error) fail(/plan change/.test(error.message) ? `Your booked change has no room for it. Tap ${(billing && bookedChange(billing)?.[1]) || 'Keep'} in Plan first.` : 'Couldn’t start it. Try again.');
    else { window.track('plant_start_done'); onChanged && onChanged(); }
    await refresh();
    setBusy(null);
  };
  // One switch per plant. On means collecting. Turning it off asks first and stays on until
  // "Stop and delete"; a plant up for deletion on the billing date shows that and Keep instead.
  const plantRow = (p) => {
    const s = state(p);
    const name = window.plantLabel(p);
    const b = busy === 'stop:' + p.plant_id || busy === 'start:' + p.plant_id;
    const on = s === 'on' || s === 'off';
    // A stopped plant the move to Free booked comes back only by swapping it in: its switch,
    // not Keep, on Free (0131) and after paying again (0133).
    const swap = s === 'going' && p.paused && (!billing || billing.plan === 'free' || p.free_removal);
    const sw = <window.Switch on={on} label={'Collect ' + name} disabled={b} busy={b} onChange={() => on ? setStopping(p.plant_id) : start(p)} />;
    return (
      <PlantLine key={p.plant_id} name={name} off={!on}>
        {s === 'going' ? <>
          <span className="conn-status plant-state bad">Deleted {billDay(p.remove_on)}</span>
          {swap ? sw : <button type="button" className="ghost-btn" disabled={busy === 'keep:' + p.plant_id} onClick={() => keep(p)}>Keep</button>}
        </> : sw}
        {stopping === p.plant_id && (
          <ConfirmCard modal
            title={<>Stop collecting <b>{name}</b>?</>}
            text="Its history is deleted, unless another account shares it. Turn it on later and only the last 60 days come back."
            action="Stop and delete" onConfirm={() => stop(p)} onCancel={() => setStopping(null)} />
        )}
        {/* No room: the plans live on their own page, not in this list (SOLAR-264). Family is the
            biggest plan; more than its 5 plants is by email (SOLAR-371). */}
        {full === p.plant_id && (
          <ConfirmCard modal danger={false} label="Your plan is full" title="Your plan is full"
            text={billing?.plan === 'family' ? <>Turn another plant off first. More than 5 plants? <a className="mini-link" href="mailto:hello@princesolarhub.co.za" onClick={() => window.track('more_plants_email_done', { plan: 'family', from: 'plan_full' })}>Email us</a>.</> : 'Turn another plant off first, or upgrade.'}
            action={billing?.plan !== 'family' && onCollect && 'Upgrade'} onCancel={() => setFull(null)}
            onConfirm={() => { setFull(null); onCollect(p.plant_id); }} />
        )}
      </PlantLine>
    );
  };
  // Free collects one plant, Home 2, Family 5 plus any extras still held. With that taken, Add login
  // still opens the form: the server links the new plants stopped, and each one's switch offers
  // the upgrade (SOLAR-272). A stopped plant leaves room, as on the server (SOLAR-259).
  const collecting = allPlants.filter(p => !p.paused).length;
  const limit = billing && !billing.comped ? planRoom(billing.plan, billing.extraPlants) : null;
  const planFull = limit != null && collecting >= limit;
  // Plants on out of what the plan allows, so it shows the room left (SOLAR-285); none when
  // free of charge. A plant up for deletion still collects until its date.
  const title = <>Plants{limit != null && allPlants.length > 0 && <span className="sset-count">{allPlants.filter(p => !p.paused && ['on', 'going'].includes(state(p))).length} of {limit} on your plan</span>}</>;
  return (
    <SettingsSection id="connection" title={title}
      action={!unread && <button type="button" className="save-btn" onClick={() => { if (planFull) window.track('add_login_full_done', { plan: billing.plan }); setMode('add'); }}>Add login</button>}>
      {!unread && mode === 'add' && (
        // A form over the page (SOLAR-286). Cancel re-reads too: a login with no plant yet is saved but not listed.
        <window.LinkDialog title="Add login" note={planFull && 'Your plan is full, so new plants are added stopped.'}
          onLinked={changed} onCancel={() => { setMode(null); refresh(); }} />
      )}
      {unread ? (
        <SettingRow label="Couldn’t load your logins" note={NBSP}
          action={<window.BusyButton className="ghost-btn" onClick={retry} busy={checking} busyText="Checking…">Try again</window.BusyButton>} />
      ) : !live.length ? (
        <div className="field-note">No login connected.</div>
      ) : (
        // One full-width card, laid out as Notifications (SOLAR-377): each login a small grey
        // heading with Reconnect and Manage at its right, its plants under it, a switch each.
        // Its state shows only when it needs something.
        <>
          {live.map(acc => {
            const ok = acc.status === 'active';
            const plants = acc.plants || [];
            const at = acc.sunsynk_username.indexOf('@') + 1; // 0 when there is no @
            // Amber at the age the header pill calls offline (15 minutes without a reading). A login
            // with no plant is never read, so its age means nothing (SOLAR-285).
            const stale = ok && plants.length > 0 && acc.last_ok_at && (Date.now() - new Date(acc.last_ok_at).getTime()) > 900_000;
            return (
              <div key={acc.account_id} className={'login-grp plant-logins' +(leaving === acc.account_id ? ' leaving' : '')}>
                <div className="login-line">
                  <div className="login-who">
                    {/* a narrow card breaks a long email after the @, not mid-word */}
                    <span className="login-email">{at ? <>{acc.sunsynk_username.slice(0, at)}<wbr />{acc.sunsynk_username.slice(at)}</> : acc.sunsynk_username}</span>
                    {(!ok || stale) && <window.Tip className={'login-state ' + (ok ? 'warn' : 'bad')} text={acc.last_ok_at ? 'Last reading ' + ago(acc.last_ok_at) : null}>{!ok ? 'Sign-in expired' : 'Not updating'}</window.Tip>}
                  </div>
                  {!ok && mode !== acc.account_id && <button type="button" className="ghost-btn login-fix" onClick={() => setMode(acc.account_id)}>Reconnect</button>}
                  <LoginMenu email={acc.sunsynk_username} busy={busy === acc.account_id}
                    onPassword={ok ? () => setMode(acc.account_id) : null}
                    onRemove={() => setConfirming(acc.account_id)} />
                </div>
                {mode === acc.account_id && (
                  <window.LinkDialog title={ok ? 'Change SunSynk password' : 'Reconnect'} relink changing={ok}
                    initialUsername={acc.sunsynk_username} onLinked={changed} onCancel={() => setMode(null)} />
                )}
                {confirming === acc.account_id && (
                  <ConfirmCard modal
                    title={<>Remove <b>{acc.sunsynk_username}</b>?</>}
                    text={removeText(acc)}
                    action="Remove login" onConfirm={() => remove(acc)} onCancel={() => setConfirming(null)}>
                    {removeList(acc)}                  </ConfirmCard>
                )}
                {plants.length ? plants.map(plantRow) : <div className="conn-meta">No plant shared with this login.</div>}
              </div>
            );
          })}
        </>
      )}
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
    const t = window.cfgFields(c);
    return { rate: t.rate, res: t.reserve, bMode: 'total', bTot: t.size, bRows: window.rowsFrom(null),
      pMode: t.groups ? 'rows' : 'total', pTot: t.panels, pRows: window.rowsFrom(t.groups) };
  };
  const [f, setF] = useState(() => fromCfg(cfg));
  const [busy, setBusy] = useState(false);
  const [tried, setTried] = useState(false);   // Save pressed with a box still wrong: its line shows
  // Another plant, or its saved values changed: the boxes take them in this render, not in an
  // effect after it, which drew one frame of the old boxes as unsaved changes and flashed the save bar.
  const shownCfg = (plant?.id ?? '') + JSON.stringify(plant?.config || {});
  const [loaded, setLoaded] = useState(shownCfg);
  if (loaded !== shownCfg) { setLoaded(shownCfg); setF(fromCfg(plant?.config)); setTried(false); }
  const set = (k) => (v) => setF(x => ({ ...x, [k]: v }));
  const n = window.stepNum;
  const batt = window.sumOf('size', f.bMode, f.bTot, f.bRows);
  const pan = window.sumOf('panels', f.pMode, f.pTot, f.pRows);
  // An empty rate is 0 (savings show as zero). A stored reserve outside 0..50, left alone, is kept.
  const rateOk = f.rate === '' || n(f.rate) >= 0;
  // An empty reserve keeps what is stored (the 20 stand-in, until the owner sets one).
  const resOk = f.res === '' || window.wholeNum(f.res, 0, 50) || n(f.res) === (cfg.battery_reserve_pct ?? 20);
  // What Save sends: the way on screen for battery and panels, empty meaning none
  const patch = {
    tariff_import: f.rate === '' ? 0 : n(f.rate),
    battery_kwh: batt.empty ? null : +batt.value.toFixed(3),
    battery_reserve_pct: f.res === '' ? (cfg.battery_reserve_pct ?? 20) : n(f.res),
    ...window.panelsPatch(pan, f.pMode),
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
      <SettingRow className="sset-row" label={label} note={meta} actionClass={sum ? 'sset-sum' : 'conn-actions sset-one'}
        action={sum
          ? <div className="fs-sum">
              {/* the Total / By size switch is words only, so it draws for real, locked */}
              <div className="fs-sumhead"><Segmented size="sm" label="How to enter it" value="total" onChange={() => {}} options={window.SUM_MODES} disabled /><b className="fs-val mono">{NBSP}</b></div>
              <window.Skeleton className="fs-in" w="" h={41} r={9} />
            </div>
          : <window.Skeleton className="fs-in" w="" h={41} r={9} />} />
    );
    return (
      <SettingsSection id="system" title="Your system" note={SYSTEM_NOTE}>
        {row('Electricity rate', 'Savings show as zero until this is set.')}
        {row('Battery capacity', 'All batteries together.', true)}
        {row('Battery reserve', 'The battery stops powering your home at this charge.')}
        {row('Solar panels', 'What they make in full sun.', true)}
      </SettingsSection>
    );
  }
  if (!plant) return <SettingsSection id="system" title="Your system"><div className="field-note">No plant connected yet.</div></SettingsSection>;
  const sym = window.moneySymbol ? window.moneySymbol() : (cfg.currency || '');
  const err = (on, text) => on && tried ? <p className="sset-err" role="alert">{text}</p> : null;
  return (
    <>
      {/* One section since SOLAR-250, in First steps' order: rate, battery, reserve, panels */}
      <SettingsSection id="system" title="Your system" note={SYSTEM_NOTE}>
        {/* A unit is a kWh: it is what a South African bill calls one, so the rate is per unit */}
        <SettingRow className="sset-row" label="Electricity rate" actionClass="conn-actions sset-one"
          note={n(f.rate) > 0 ? 'Used to work out what solar saved.' : 'Savings show as zero until this is set.'}
          action={<>
            <window.StepField value={f.rate} onChange={set('rate')} label="Electricity rate" pre={sym} unit="/unit" inputMode="decimal" ph="3.40" invalid={tried && bad.rate} />
            {err(bad.rate, 'Enter a price, like 3.40.')}
          </>} />
        <SettingRow className="sset-row" label="Battery capacity" note="All batteries together." actionClass="sset-sum"
          action={<>
            <window.SumBox kind="size" mode={f.bMode} onMode={set('bMode')} tot={f.bTot} onTot={set('bTot')} rows={f.bRows} onRows={set('bRows')} label="Battery size" />
            {err(bad.batt, f.bMode === 'total' ? 'Enter more than 0 kWh.' : 'Enter whole batteries and the kWh of one.')}
          </>} />
        <SettingRow className="sset-row" label="Battery reserve" note="The battery stops powering your home at this charge." actionClass="conn-actions sset-one"
          action={<>
            <window.StepField value={f.res} onChange={set('res')} label="Reserve" unit="%" inputMode="numeric" ph="20" invalid={tried && bad.res} />
            {err(bad.res, 'Enter 0 to 50.')}
          </>} />
        <SettingRow className="sset-row" label="Solar panels" note="What they make in full sun." actionClass="sset-sum"
          action={<>
            <window.SumBox kind="panels" mode={f.pMode} onMode={set('pMode')} tot={f.pTot} onTot={set('pTot')} rows={f.pRows} onRows={set('pRows')} label="Solar panels" />
            {err(bad.pan, f.pMode === 'total' ? 'Enter more than 0 kW.' : 'Enter whole panels and 50 to 1000 W each.')}
          </>} />
      </SettingsSection>

      {dirty && (
        <div className="save-bar dirty" role="status">
          <span className="save-text">{blocked ? 'Save or discard before switching plant.' : 'Unsaved changes'}</span>
          <button type="button" className="ghost-btn" onClick={() => { setF(fromCfg(cfg)); setTried(false); }} disabled={busy}>Discard</button>
          <window.BusyButton className="save-btn" onClick={save} busy={busy} busyText="Saving…">Save</window.BusyButton>
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
  const { bad, setBad, flag, edited } = window.useFieldErrors();
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (open) document.getElementById('pw-current')?.focus(); }, [open]);

  const close = () => { window.takeResetAsk(); setOpen(false); setCur(''); setPw(''); setPw2(''); setBad({}); };
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

  const field = (id, text, value, set, autoComplete, hint, also = []) => (
    <div className={'field' + (id === 'pw-confirm' ? ' link-last' : '')}>
      <window.FieldLabel id={id} label={text} error={bad[id]} hint={hint} />
      <window.PasswordInput id={id} className="input" autoComplete={autoComplete} value={value}
                            onChange={(v) => { set(v); edited(id, ...also); }} aria={window.invalidProps(id, bad[id])} />
    </div>
  );
  return (
      <SettingRow id="settings-password" label="Change password" note="Signs out your other devices."
        action={<button type="button" className="ghost-btn" onClick={() => setOpen(true)}>Change</button>}>
        {open && (
          <window.Dialog keep busy={busy} label="Change password" onClose={close}>
          <div className="confirm-title">Change password</div>
          <div className="confirm-text">Signs out your other devices.</div>
          <form className="conn-form link-form" onSubmit={submit} noValidate aria-busy={busy}>
            {/* The email, unseen, so a password manager knows which login to update. */}
            <input type="email" autoComplete="username" value={email || ''} readOnly hidden />
            {field('pw-current', 'Current password', cur, setCur, 'current-password')}
            {field('pw-new', 'New password', pw, setPw, 'new-password', '8+ characters', ['pw-confirm'])}
            {field('pw-confirm', 'Confirm password', pw2, setPw2, 'new-password')}
            <div className="conn-form-actions">
              <button type="button" className="ghost-btn" onClick={close} disabled={busy}>Cancel</button>
              <window.BusyButton type="submit" className="save-btn" busy={busy} busyText="Saving…">Save password</window.BusyButton>
            </div>
          </form>
          </window.Dialog>
        )}
      </SettingRow>
  );
}

// One end of a range: a field-sized button reading "Fri 2 Oct" that opens the app's calendar.
function DayField({ id, value, todayStr, earliest, latest, bad, onPick }) {
  const [open, setOpen, ref] = usePopover();
  const close = React.useCallback(() => setOpen(false), []);
  return (
    <div className="pick" ref={ref}>
      <button type="button" id={id} className={'fs-in pick-btn' + (bad ? ' bad' : '')} aria-haspopup="dialog" aria-expanded={open}
              onClick={() => setOpen(o => !o)} {...window.invalidProps(id, bad, 'dl-err')}>
        <window.CalIcon /><span className="pick-val day-face">{window.dayFace(value, todayStr)}</span>
      </button>
      {open && <window.CalendarPop date={value} todayStr={todayStr} earliest={earliest} latest={latest} allDays onPick={onPick} onClose={close} />}
    </div>
  );
}

// A plant's readings for any range of days as one CSV (SOLAR-191). api_export
// builds the file; a year at most. Full history (paid) once plans exist: SOLAR-104.
// On Account, so it picks its own plant, starting on the one on screen; one plant, no picker.
function DownloadSection({ plants, plantId, ready }) {
  const { useState } = React;
  const over = window.useFreeOver(); // Free after its week (SOLAR-242): the button is a lock
  const today = window.localDateStr(new Date());
  const weekAgo = window.localDateStr(new Date(Date.now() - 6 * 86400000));
  // The plant on screen until one is picked; it's still loading when a reload opens Account.
  const [picked, setPlant] = useState(null);
  const plant = plants.some(p => p.id === picked) ? picked : plants.some(p => p.id === plantId) ? plantId : plants[0].id;
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
      const { data, error } = await window.sb.rpc('api_export', { p_from: from, p_to: to, p_plant: plant });
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

  // From, To and Download on one line; on a phone they stack. The two calendars keep the
  // range in order and a year at most; a day with no readings is still a fine end.
  const field = (id, text, value, set, earliest, latest) => (
    <div className="dl-field">
      <label htmlFor={id} className="conn-meta">{text}</label>
      <DayField id={id} value={value} todayStr={today} earliest={earliest} latest={latest} bad={bad}
                onPick={(k) => { set(k); setBad(null); }} />
    </div>
  );
  const yearTo = window.shiftDate(from, 365);
  return (
    <SettingsSection id="download" title="Your data" note="A CSV file. Every minute for the last 31 days, every 5 minutes before that.">
      <div className="dl-row">
        {plants.length > 1 && (
          <div className="dl-field">
            <label htmlFor="dl-plant" className="conn-meta">Plant</label>
            {/* which plant is on screen comes with api_me: until then the picker shimmers */}
            {!ready ? <window.Skeleton className="fs-in" w="" h={41} r={9} />
              : <PickMenu id="dl-plant" label="Plants" value={plant} onPick={setPlant}
                          options={plants.map(p => ({ value: p.id, label: window.plantLabel(p) }))} />}
          </div>
        )}
        {field('dl-from', 'From', from, setFrom, window.shiftDate(to, -365), to)}
        {field('dl-to', 'To', to, setTo, from, yearTo < today ? yearTo : today)}
        {/* the plan isn't known yet, so neither is the lock: the button's place shimmers */}
        {!ready ? <window.Skeleton w={104} h={41} r={9} style={{ flex: 'none' }} />
          : over ? <button type="button" className="ghost-btn lock-cta" onClick={() => window.openPlans('csv')}><window.LockIcon />Download</button>
          : <window.BusyButton className="save-btn" onClick={submit} busy={busy} busyText="Preparing…">Download</window.BusyButton>}
      </div>
      {bad && <p className="sset-err" id="dl-err" role="alert">{bad}</p>}
    </SettingsSection>
  );
}

// Delete account is off while a paid plan runs or a payment failed: cancel or pay on Billing
// first (SOLAR-250; the server refuses too, 0130). A plan already cancelled doesn't block it.
const DELETE_REFUSED = [
  [/owed/, 'Pay the failed payment on Billing first.'],
  [/payment is open/, 'A payment is still going through. Try again tomorrow.'],
  [/cancel your plan/, 'Cancel your plan first.', 'cancel'],
];
function DeleteAccountRow({ email, billing, onBilling }) {
  const { useState } = React;
  const owed = billing?.state === 'past_due';
  const blocked = !!billing && (owed || (billing.plan !== 'free' && !billing.comped && billing.nextPlan !== 'free'));
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const del = async () => {
    setConfirming(false);
    setBusy(true);
    // The account is gone; signing out here is what moves the screen to sign-in, once.
    // No reload after it: that blanked the page and drew sign-in again (SOLAR-98).
    try { await window.deleteAccount(); await window.signOutHere(); window.toast('Account deleted.'); }
    catch (e) {
      const why = DELETE_REFUSED.find(([re]) => re.test(e?.message || ''));
      // Refused on billing: what we showed was stale, so reload it (Cancellation only draws
      // for a paid plan), and link a running plan to where it is cancelled (SOLAR-361).
      if (why) window.dispatchEvent(new Event('ps-billing'));
      const toCancel = why?.[2] === 'cancel' && { label: 'Go to cancel plan', onClick: () => onBilling('cancel') };
      window.toast(why ? why[1] : 'Couldn’t delete the account. Try again.', { error: true, ...(toCancel && { action: toCancel }) });
      setBusy(false);
    }
  };
  return (
    <SettingRow id="settings-delete" label="Delete account" note="Deletes your logins, settings and email choices."
      action={<window.BusyButton className="danger-btn" onClick={() => setConfirming(c => !c)} busy={busy} busyText="Deleting…" disabled={confirming && !blocked}>Delete</window.BusyButton>}>
      {/* Tapping Delete on a blocked account shows why, in place of the confirm (SOLAR-274) */}
      {/* a plan to cancel or a payment to settle first: said in a pop-up when Delete is pressed (SOLAR-292) */}
      {blocked && confirming && (
        <ConfirmCard modal danger={false} label={owed ? 'Pay the failed payment first' : 'Cancel your plan first'}
          title={owed ? 'Pay the failed payment first' : 'Cancel your plan first'}
          text={owed ? 'Pay it in Billing, then you can delete your account.'
            : <>Your <b>{PLAN_NAME[billing.plan]}</b> plan is still running. Cancel it in Billing, then you can delete your account.</>}
          cancelLabel="Close" action={owed ? 'Go to Billing' : 'Go to cancel plan'}
          onConfirm={() => onBilling(owed ? undefined : 'cancel')} onCancel={() => setConfirming(false)} />
      )}
      {!blocked && confirming && (
        <ConfirmCard modal title={<>Delete <b>{email || 'this account'}</b>?</>} text="Your plants’ history goes too, unless another account shares them. It cannot be undone."
          action="Delete account" onConfirm={del} onCancel={() => setConfirming(false)} />
      )}
    </SettingRow>
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
      <SettingRow className="sset-row" label="Finish setup" note={fs.left.length === 1 ? '1 step left.' : fs.left.length + ' steps left.'}
        action={<button type="button" className="ghost-btn" onClick={show} disabled={busy}>Show</button>} />
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
    ['battery', 'Battery', 'Over 45 °C, or charging unevenly, and when it’s fixed.'],
    ['panels', 'Panels', 'A string stops while the others make power, and when it’s back.'],
    ['readings', 'Readings', 'No readings for 30 min, and when they’re back.'],
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
  // The email choices still on their way: each switch and its summary shimmer in place.
  const loading = !prefs && !failed;
  // One group: a row that opens its switches, and a switch for all of them. Each switch
  // saves through its own flip, so a group is its switches' saves, one per kind.
  const group = (g, p, flipOne, key, wait) => {
    const anyOn = !p || g.rows.some(([kind]) => p[kind]);
    return (
      <div className="notif-group" key={key}>
        <div className="notif-head">
          <button type="button" className="notif-open" aria-expanded={!!open[key]} aria-controls={'notif-' + key}
                  onClick={() => setOpen(o => ({ ...o, [key]: !o[key] }))}>
            <Icon id="next" />
            <span className="toggle-text">
              <span className="notif-label">{g.label}</span>
              <span className="toggle-hint">{wait ? <window.SkelLine w={g.when ? 190 : 70} h={11} /> : emailGroupSummary(g, p)}</span>
            </span>
          </button>
          <window.Switch loading={wait} on={anyOn} label={g.label}
                  onChange={() => p && g.rows.forEach(([kind]) => { if (p[kind] === anyOn) flipOne(kind, !anyOn, g.label); })} />
        </div>
        <div id={'notif-' + key} className="field notif-rows" role="group" aria-label={g.label} hidden={!open[key]}>
          {g.rows.map(([kind, label, hint]) => (
            <Toggle key={kind} label={label} hint={hint} checked={!p || p[kind]} loading={wait}
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
        <SettingRow label="Couldn’t load your email settings" action={<button type="button" className="ghost-btn" onClick={load}>Try again</button>} />
      ) : <>
        <div className="notif-sub">Email</div>
        <div className="notif-head notif-all">
          <span className="toggle-text">
            <span className="notif-label">All emails</span>
            <span className="toggle-hint">{loading ? <window.SkelLine w={60} h={11} /> : onCount === every.length ? 'All ' + onCount + ' on' : onCount ? onCount + ' of ' + every.length + ' on' : 'Off'}</span>
          </span>
          <window.Switch loading={loading} on={allOn} label="All emails"
                  onChange={() => prefs && every.forEach(([kind]) => { if (prefs[kind] === allOn) flip(kind, !allOn, 'All emails'); })} />
        </div>
        {EMAIL_GROUPS.map(g => group(g, prefs, flip, g.id, loading))}
      </>}
      {/* This browser's pop-up state is still being read: its row, with the switch shimmering */}
      {push === null && (
        <div className="notif-push" aria-hidden="true">
          <div className="notif-sub">On this browser</div>
          <Toggle loading label="Pop-up alerts" hint="The same alerts, shown on this device even when the app is closed." />
        </div>
      )}
      {push && push !== 'none' && (
        <div className={'notif-push ' + push}>
          <div className="notif-sub">On this browser</div>
          <Toggle label="Pop-up alerts" hint="The same alerts, shown on this device even when the app is closed."
                  checked={push === 'on'} onChange={() => push !== 'asking' && push !== 'ios' && togglePush()} />
          {push === 'blocked' && (
            <p className="notif-note warn">Pop-ups are blocked. Allow notifications for {location.host} in your browser’s site settings, then turn this on.</p>
          )}
          {push === 'ios' && (
            <p className="notif-note">On iPhone, pop-ups need the app on your Home Screen. In Safari, tap <b>Share</b>, then <b>Add to Home Screen</b>. iOS 16.4 or later.</p>
          )}
          {push === 'on' && group({ ...alerts, when: null }, pushPrefs, flipPush, 'push', loading)}
        </div>
      )}
    </SettingsSection>
  );
}

// ---------------------------------------------------------------- SETTINGS AREA
// One area, two pages, both the account's (SOLAR-250): Account (the person) and Billing
// (the plan, plants and card). The plant on screen has its own page in the list
// (PlantSettings). A side menu on a desktop. On a phone 'prefs' is that menu as a list you
// tap into, and each page has a back link to it; on a desktop 'prefs' shows Account. Adjust
// plan ('plans') is a page under Billing. The plan is read once here: Billing shows it,
// Account's Delete needs it.
const SETTINGS_NAV = [['account', 'Account'], ['billing', 'Billing']];
// Setup and App each draw their own SettingsArea, so the first plant switched on or the last
// one off mounts a new one; it starts from the plan last read, not the Plan outline. The
// free week's end too, so Plan's line doesn't drop it until the new screen reads api_me.
// Sign-out doesn't reload the page, so it forgets them.
let billingSeen = null;
let weekEndSeen;
window.sb.auth.onAuthStateChange((event) => { if (event === 'SIGNED_OUT') { billingSeen = null; weekEndSeen = undefined; } });
function SettingsArea({ page, onPage, me, plantId, onPlantConfigSaved, links, flash, onFlashed }) {
  const { useState, useEffect } = React;
  const [user, setUser] = useState(null);
  useEffect(() => { window.sb.auth.getSession().then(({ data }) => setUser(data?.session?.user || null)).catch(() => {}); }, []);
  const [billing, setBilling] = useState(() => billingSeen);
  if (me) weekEndSeen = me.freeWeekEndsAt;
  // The stopped plant whose "plan is full" sent the user to the plans: extra room is for it.
  const [forPlant, setForPlant] = useState(null);
  const reloadBilling = () => window.billingRpc('api_billing_status').then(({ data }) => { if (data) { billingSeen = data; setBilling(data); } return data; });
  // A booked change moves which plants stop on the billing date, shown on the plant rows.
  const reloadPlan = () => Promise.all([reloadBilling(), links?.refresh?.()]).then(([b]) => b);
  // Back from a payment: billingReturn checks it (a paid one reloads the page).
  useEffect(() => { reloadBilling().then(b => window.billingReturn(b)).then(r => r === 'card' && reloadBilling()); }, []);
  // a change undone from the Notifications list (SOLAR-212)
  useEffect(() => {
    const again = () => reloadBilling();
    window.addEventListener('ps-billing', again);
    return () => window.removeEventListener('ps-billing', again);
  }, []);
  // Every plant on the logins once (a plant can be on two).
  const live = (links?.accounts || []).filter(a => a.status !== 'disabled');
  const plants = [...new Map(live.flatMap(a => a.plants || []).map(p => [p.plant_id, p])).values()];
  // Account's Your data: the plants on, from the logins, which are here before api_me answers.
  const onPlants = plants.filter(p => !p.paused).map(p => ({ id: Number(p.plant_id), name: p.plant_name }));
  // Billing holds the logins too, so a dead one marks it as a failed payment does.
  const relink = live.some(a => a.status === 'needs_relink');
  const dot = { billing: billing?.state === 'past_due' || relink };
  const shown = page === 'prefs' ? 'account' : page === 'plans' ? 'billing' : page;
  return (
    <SettingsFlash.Provider value={flash ? { id: flash, done: onFlashed } : null}>
      <div className={'set-area' + (page === 'prefs' ? ' set-list' : '')}>
        <nav className="set-nav" aria-label="Settings">
          <h1 className="set-nav-title">Settings</h1>
          {SETTINGS_NAV.map(([id, label]) => (
            <button key={id} type="button" aria-current={shown === id ? 'page' : undefined} onClick={() => onPage(id)}>
              <span>{label}</span>
              {dot[id] && <span className="dot" aria-label={billing?.state === 'past_due' ? 'Needs you' : 'A login needs reconnecting'} />}
              <Icon id="next" className="set-chev" />
            </button>
          ))}
        </nav>
        <div className="set-main">
          <button type="button" className="back-link set-back" onClick={() => onPage('prefs')}><Icon id="back" />Settings</button>
          {shown === 'account' && <AccountPage user={user} billing={billing} plants={onPlants} plantId={plantId} ready={!!me} onBilling={(section) => onPage('billing', section)} />}
          {(page === 'billing' || page === 'plans') && <BillingPage billing={billing} reload={reloadBilling} reloadPlan={reloadPlan} links={links} onPage={onPage} freeWeekEndsAt={me ? me.freeWeekEndsAt : weekEndSeen} onSaved={onPlantConfigSaved}
                                              onCollect={(id) => { setForPlant(id); onPage('plans'); }} />}
          {/* Adjust plan opens over Billing, not as a page of its own (SOLAR-292) */}
          {page === 'plans' && <AdjustPlanPage billing={billing} reload={reloadPlan} onBack={() => onPage('billing')} forPlant={forPlant}
                                               logins={pickableLogins(links)} />}
        </div>
      </div>
    </SettingsFlash.Provider>
  );
}

// Account: the person. Email and sign-in method, emails, their plants' readings as a file,
// then the account's actions. ready: api_me has answered, so Your data knows if it's locked.
const HAD_PASSWORD = 'synsynk.hasPassword';
const hadPassword = () => { try { return localStorage.getItem(HAD_PASSWORD) !== '0'; } catch (e) { return true; } };
function AccountPage({ user, billing, plants, plantId, ready, onBilling }) {
  const email = user?.email || null;
  const providers = user?.app_metadata?.providers || [];
  React.useEffect(() => { if (user) try { localStorage.setItem(HAD_PASSWORD, providers.includes('email') ? '1' : '0'); } catch (e) {} }, [user]);
  const method = providers.includes('google') ? (providers.includes('email') ? 'Google or password' : 'Google') : 'password';
  return (
    <div className="settings-page">
      <div className="page-head">
        <h1>Account</h1>
        <p>{email ? <>{email}<span className="set-method"> · Signs in with {method}</span></> : <window.SkelLine w={260} />}</p>
      </div>
      <NotificationsSection userId={user?.id} />
      {plants.length > 0 && <DownloadSection plants={plants} plantId={plantId} ready={ready} />}
      <SettingsSection id="actions" title="Account actions">
        {email && providers.includes('email') && <PasswordRow email={email} />}
        {/* the session is still being read: the row a password account had last time, held */}
        {!user && hadPassword() && (
          <SettingRow hidden label="Change password" note="Signs out your other devices." action={<window.Skeleton w={112} h={34} r={9} />} />
        )}
        <SettingRow label="Sign out" note="On this device." action={<window.SignOutButton className="ghost-btn" />} />
        <DeleteAccountRow email={email} billing={billing} onBilling={onBilling} />
      </SettingsSection>
      <div className="app-version mono">
        {window.APP_VERSION} · <a href="terms.html" target="_blank" rel="noopener">Terms</a> · <a href="privacy.html" target="_blank" rel="noopener">Privacy</a>
      </div>
    </div>
  );
}

// Billing holds the plants and the logins they come from (moved from Plant, SOLAR-250).
function BillingPage({ billing, reload, reloadPlan, links, onPage, freeWeekEndsAt, onSaved, onCollect }) {
  React.useEffect(() => { if (billing) try { localStorage.setItem(BILL_SHAPE, JSON.stringify(shapeOf(billing))); } catch (e) {} }, [billing]);
  return (
    <div className="settings-page">
      <div className="page-head"><h1>Billing</h1></div>
      <PlanSection billing={billing} reload={reloadPlan} onAdjust={() => onCollect(null)} freeWeekEndsAt={freeWeekEndsAt} />
      {links && <SunSynkConnectionSection onChanged={onSaved} links={links} billing={billing} reloadBilling={reload} onCollect={(id) => onCollect(id ?? null)} />}
      <PaymentsSection billing={billing} />
      <InvoicesSection billing={billing} />
      <CancelSection billing={billing} reload={reloadPlan} logins={pickableLogins(links)} />
    </div>
  );
}

// Plant settings: the plant on screen (picked in the header), a page in the list beside
// Equipment rather than in the account's Settings. Titled with the plant's name.
function PlantSettings({ me, plantId, onSaved, onDirty, switchBlocked, flash, onFlashed }) {
  const plant = (me?.plants || []).find(p => p.id === plantId);
  return (
    <SettingsFlash.Provider value={flash ? { id: flash, done: onFlashed } : null}>
      <div className="settings-page">
        <div className="page-head"><h1>{!me ? <window.SkelLine w={180} h={22} /> : plant?.name || 'Plant settings'}</h1><p>Changes apply to everyone on this plant.</p></div>
        <PlantSections me={me} plantId={plantId} onSaved={onSaved} onDirty={onDirty} switchBlocked={switchBlocked} />
        <FirstStepsSection me={me} plantId={plantId} onSaved={onSaved} />
      </div>
    </SettingsFlash.Provider>
  );
}

Object.assign(window, { LiveTab, SolarTab, HomeTab, GridTab, InvertersTab, SettingsArea, PlantSettings, MiniStat, FsEnterIcon, TabSkeleton });
