// ============================================================================
// chart.jsx — <HistoryView/> : the day power graph.
//   • 5-minute power lines for Solar / Battery / Grid / Load, SOC on a right axis
//   • Series toggles, hover crosshair + exact-value tooltip
//   • View, remembered per device: Lines (all series on one plot), Rows (one row per
//     flow, charge at the foot) or Hours (kWh per hour: home use by source above the
//     line, stored or exported below)
//   • Day picker: step prev/next or jump via the date field, back to the plant's
//     first day of data (/api/history/earliest); today streams in live.
// Self-contained SVG; no external chart libs. `today` (live day series) comes in
// as a prop from <App>; past days are fetched here on demand (/api/history?date=).
// Period totals live in the Overview strip, so there is no range switch here.
// ============================================================================

// Measure WIDTH ONLY; height is fixed (derived from width). Measuring height and
// feeding it back into the SVG creates a ResizeObserver loop that makes the chart
// (and the page) creep larger on every interaction — so we never do that.
function useChartSize(heights) {
  const ref = React.useRef(null);
  const [w, setW] = React.useState(360);
  React.useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const ro = new ResizeObserver(es => { for (const e of es) setW(Math.max(260, Math.round(e.contentRect.width))); });
    ro.observe(el); setW(Math.max(260, Math.round(el.clientWidth)));
    return () => ro.disconnect();
  }, []);
  const h = heights || [360, 620];
  const height = w < 560 ? h[0] : h[1]; // fixed per breakpoint — no feedback
  return [ref, w, height];
}

const HM = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

// "Nice" y-axis scale: zero-anchored, round step sizes (1/2/2.5/5 ×10ⁿ) so the
// tick labels come out clean and 0 is always a gridline.
function niceScale(min, max, targetTicks) {
  min = Math.min(0, min);
  max = Math.max(0, max);
  if (max - min === 0) max = 1000;
  const rawStep = (max - min) / Math.max(1, targetTicks);
  const mag = Math.pow(10, Math.floor(Math.log10(rawStep)));
  const norm = rawStep / mag;
  const step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
  const lo = Math.floor(min / step) * step;
  const hi = Math.ceil(max / step) * step;
  const ticks = [];
  for (let v = lo; v <= hi + step / 2; v += step) ticks.push(Math.round(v));
  return { lo, hi, ticks };
}

// Local YYYY-MM-DD (matches the server's localDate(); the dashboard runs on one
// machine, so browser-local and server-local agree).
function localDateStr(d = new Date()) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}
function shiftDate(s, days) {
  const [y, m, d] = s.split('-').map(Number);
  return localDateStr(new Date(y, m - 1, d + days));
}
/** "12 min" / "2h 33m" — spoken, not decimal hours, like everything else here. */
function fmtGap(mins) {
  if (mins < 60) return mins + ' min';
  const h = Math.floor(mins / 60), m = mins % 60;
  return m ? h + 'h ' + m + 'm' : h + 'h';
}

function niceDate(s) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
}


// ---------------------------- SHARED DAY-CHART FRAME ----------------------------
// What every day chart has in common — the Live power chart, and the inverter
// history charts on the Grid and Inverters tabs: a date bar, the 5-minute index
// grid (0..287, stretched to the last bucket on today), x ticks, crosshair index
// from a pointer, and a tooltip that sits beside the crosshair. Each chart keeps
// its own series, axes and overlays; the power chart also keeps its range drag
// to itself.
const DAY_FLOOR_DAYS = 60; // what SunSynk's per-inverter history keeps

/** Selected day + the arrows' bounds. `earliest` may be null (no lower bound). */
function useDayPicker(earliest) {
  const todayStr = localDateStr();
  const [date, setDate] = React.useState(todayStr);
  return {
    date, setDate, todayStr, isToday: date === todayStr,
    canPrev: !earliest || date > earliest, canNext: date < todayStr,
  };
}

function DateBar({ pick, earliest, locked, right, children }) {
  const { date, setDate, todayStr, isToday } = pick;
  // locked: the app is still loading, so the picker shows today and goes nowhere
  const canPrev = pick.canPrev && !locked, canNext = pick.canNext && !locked;
  const todayBtn = !isToday && <button className="hv-today" onClick={() => setDate(todayStr)}>Today</button>;
  return (
    <div className="hv-datebar">
      <button className="hv-daynav" disabled={!canPrev} aria-label="Previous day"
        onClick={() => canPrev && setDate(shiftDate(date, -1))}>‹</button>
      <input className="hv-dateinput" type="date" value={date} disabled={locked}
        min={earliest || undefined} max={todayStr}
        onChange={e => e.target.value && setDate(e.target.value)} />
      <button className="hv-daynav" disabled={!canNext} aria-label="Next day"
        onClick={() => canNext && setDate(shiftDate(date, 1))}>›</button>
      {children}
      {/* anything on the right shares the Today button's push to the end, so the two stay together */}
      {right ? <span className="hv-end">{todayBtn}{right}</span> : todayBtn}
    </div>
  );
}

/** x ticks in minutes-of-day up to `nowMin`: 6 h apart on phones, 3 h on desktop, plus "now" if far from the last. */
function xTicksFor(nowMin, mobile) {
  const ticks = [];
  const step = mobile ? 360 : 180;
  for (let t = 0; t <= nowMin; t += step) ticks.push(t);
  if (nowMin - (ticks[ticks.length - 1] || 0) > step * 0.4) ticks.push(nowMin);
  return ticks;
}
/** Pointer → bucket index over 0..lastIdx. */
const idxFromPointer = (clientX, el, m, innerW, lastIdx) => {
  const mx = clientX - el.getBoundingClientRect().left;
  return Math.max(0, Math.min(lastIdx, Math.round(((mx - m.l) / innerW) * lastIdx)));
};
/** Tooltip left edge: beside the crosshair, flipped near the right edge, never off either end. */
const tipLeftFor = (px, width, tipW = 190, gap = 16) =>
  Math.max(8, Math.min(width - tipW - 8, px + gap + tipW <= width - 8 ? px + gap : px - gap - tipW));
/** Axis fitted to the data (not zero-anchored): 40–60 °C or 230 V should fill the plot. */
function fitScale(lo, hi, unit) {
  if (!isFinite(lo) && !isFinite(hi)) { lo = 0; hi = unit; }
  else if (!isFinite(lo)) lo = hi; else if (!isFinite(hi)) hi = lo;
  const pad = unit;
  lo = Math.floor((lo - pad) / unit) * unit; hi = Math.ceil((hi + pad) / unit) * unit;
  if (hi - lo < unit * 2) hi = lo + unit * 2;
  const step = (hi - lo) / unit > 8 ? unit * 2 : unit;
  const ticks = []; for (let v = lo; v <= hi + 1e-9; v += step) ticks.push(+v.toFixed(2));
  return { lo, hi, ticks };
}
/** Path through get(p) at each index, broken wherever it is null. */
function seriesPath(pts, x, y, get) {
  let d = '', pen = false;
  pts.forEach((p, i) => {
    const v = get(p);
    if (v == null) { pen = false; return; }
    d += (pen ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(v).toFixed(1) + ' ';
    pen = true;
  });
  return d;
}
/** Filled band from lo(p) up to hi(p), in pieces broken wherever hi(p) is null. */
function seriesBand(pts, x, y, lo, hi) {
  const segs = []; let seg = null;
  pts.forEach((p, i) => {
    const v = hi(p);
    if (v == null) { seg = null; return; }
    if (!seg) { seg = []; segs.push(seg); }
    seg.push([x(i), y(lo(p)), y(v)]);
  });
  return segs.map(s => 'M' + s.map(q => q[0].toFixed(1) + ' ' + q[2].toFixed(1)).join(' L')
    + ' L' + [...s].reverse().map(q => q[0].toFixed(1) + ' ' + q[1].toFixed(1)).join(' L') + ' Z').join(' ');
}
/** An x-axis time label; the one at the right edge ends there instead of being cut in half. */
const xLabel = (t, px, right, y) => {
  const end = px > right - 16;
  return <text key={'gx' + t} x={end ? right : px} y={y} textAnchor={end ? 'end' : 'middle'} className="ax">{HM(t)}</text>;
};
/** Where one five-minute reading's power went, in W. The house draws on solar first, then
 *  the battery, then the grid; whatever inverter losses leave unexplained goes to the
 *  biggest of those, and to none when nothing was supplying it, so a grid-less plant is
 *  never handed grid power. Takes the raw series: batt + = powering the house, grid + = importing. */
function powerSplit(p) {
  const pv = Math.max(0, p.pv || 0), load = Math.max(0, p.load || 0);
  const dis = Math.max(0, p.batt || 0), chg = Math.max(0, -(p.batt || 0));
  const imp = Math.max(0, p.grid || 0), exp = Math.max(0, -(p.grid || 0));
  let sH = Math.min(pv, load), rest = load - sH;
  let bH = Math.min(dis, rest); rest -= bH;
  let gH = Math.min(imp, rest); rest -= gH;
  const top = Math.max(sH, bH, gH);
  if (rest > 0 && top > 0) { if (gH === top) gH += rest; else if (bH === top) bH += rest; else sH += rest; }
  return { sH, bH, gH, chg, exp };
}
const DAY_VIEWS = [{ value: 'lines', label: 'Lines' }, { value: 'rows', label: 'Rows' }, { value: 'hours', label: 'Hours' }];

// ---------------------------- INVERTER HISTORY (Grid / Inverters tabs) ----------------------------
// Per-inverter samples from SunSynk's history (api_inverter_history), bucketed to
// the same 5-minute grid as the Live chart. Fetched by `recover` every six hours,
// so it lags the live numbers on the same tab; the "to HH:MM" stamp says how far.
//   kind="temp"   AC temperature per inverter (DC dashed when the sensor moves)
//   kind="ac"     AC terminal voltage band per inverter + grid frequency (right axis);
//                 minutes where the grid read 0 Hz are shaded as an outage
//   kind="output" as "ac" but the inverter's own frequency, for an off-grid plant
const INV_COLORS = ['#fb923c', '#f472b6', '#60a5fa', '#fbbf24', '#34d399', '#c084fc'];
function InverterHistoryChart({ kind, refreshKey }) {
  const C = window.COLORS;
  const earliest = shiftDate(localDateStr(), -DAY_FLOOR_DAYS);
  const pick = useDayPicker(earliest);
  const { date, isToday } = pick;
  const [invs, setInvs] = React.useState(null); // null = loading
  const [hover, setHover] = React.useState(null);
  const [ref, width, height] = useChartSize([220, 300]);
  const mobile = width < 560;

  React.useEffect(() => {
    let alive = true;
    setInvs(null); setHover(null);
    window.fetchInverterHistory(date)
      .then(r => { if (alive) setInvs(r); })
      .catch(() => { if (alive) setInvs([]); });
    return () => { alive = false; };
  }, [date, refreshKey]);

  const isTemp = kind === 'temp';
  const fKey = kind === 'output' ? ['fmin', 'fmax'] : ['gmin', 'gmax'];
  const has = (i, p) => isTemp ? (p.ac != null || (p.dc != null && !i.dcFlat)) : (p.v != null || p[fKey[0]] != null);
  const shown = (invs || []).filter(i => i.points && i.points.some(p => has(i, p)));
  const nInv = shown.length;

  // today stretches to the last bucket with data, like the Live chart; a past day is the full 288
  let lastData = -1;
  shown.forEach(i => i.points.forEach((p, k) => { if (has(i, p) && k > lastData) lastData = k; }));
  const lastIdx = isToday ? Math.max(1, lastData) : 287;
  const nowMin = lastIdx * 5;

  const m = { l: mobile ? 34 : 42, r: isTemp ? (mobile ? 12 : 16) : (mobile ? 40 : 46), t: 24, b: 34 };
  const innerW = Math.max(40, width - m.l - m.r);
  const innerH = height - m.t - m.b;
  const x = i => m.l + (i / lastIdx) * innerW;

  // left axis: °C or V, fitted to the data; right axis: Hz, fitted
  let lo = Infinity, hi = -Infinity, flo = Infinity, fhi = -Infinity;
  shown.forEach(i => i.points.forEach((p, k) => {
    if (k > lastIdx) return;
    if (isTemp) {
      if (p.ac != null) { lo = Math.min(lo, p.ac); hi = Math.max(hi, p.ac); }
      if (!i.dcFlat && p.dc != null) { lo = Math.min(lo, p.dc); hi = Math.max(hi, p.dc); }
    } else {
      // a 0 V / 0 Hz sample is an outage, drawn as shading, not as a point on the axis
      if (p.vmin != null && p.vmin > 50) lo = Math.min(lo, p.vmin);
      if (p.vmax != null && p.vmax > 50) hi = Math.max(hi, p.vmax);
      if (p[fKey[0]] != null && p[fKey[0]] > 10) flo = Math.min(flo, p[fKey[0]]);
      if (p[fKey[1]] != null && p[fKey[1]] > 10) fhi = Math.max(fhi, p[fKey[1]]);
    }
  }));
  const hasV = isFinite(lo), hasF = isFinite(flo);
  const ys = fitScale(lo, hi, 5);
  const fs = fitScale(flo, fhi, 0.1);
  const y = v => m.t + innerH - ((v - ys.lo) / (ys.hi - ys.lo)) * innerH;
  const yf = v => m.t + innerH - ((v - fs.lo) / (fs.hi - fs.lo)) * innerH;

  const line = (pts, k, yFn, ok) => {
    let d = '', pen = false;
    pts.forEach((p, i) => {
      if (i > lastIdx || p[k] == null || (ok && !ok(p[k]))) { pen = false; return; }
      d += (pen ? 'L' : 'M') + x(i).toFixed(1) + ' ' + yFn(p[k]).toFixed(1) + ' ';
      pen = true;
    });
    return d;
  };
  // band between two keys, as closed segments that break at nulls
  const band = (pts, kLo, kHi, yFn, ok) => {
    const segs = []; let seg = null;
    pts.forEach((p, i) => {
      if (i > lastIdx || p[kLo] == null || p[kHi] == null || (ok && !(ok(p[kLo]) && ok(p[kHi])))) { seg = null; return; }
      if (!seg) { seg = []; segs.push(seg); }
      seg.push([x(i), yFn(p[kLo]), yFn(p[kHi])]);
    });
    return segs.map(sg => 'M' + sg.map(q => q[0].toFixed(1) + ' ' + q[2].toFixed(1)).join(' L') + ' L' + [...sg].reverse().map(q => q[0].toFixed(1) + ' ' + q[1].toFixed(1)).join(' L') + ' Z').join(' ');
  };
  // outage: buckets where the grid (or the inverter's output) read 0 Hz, or the terminal 0 V
  const outages = [];
  if (!isTemp && nInv) {
    let run = null;
    for (let i = 0; i <= lastIdx; i++) {
      const out = shown.some(inv => { const p = inv.points[i]; return p && ((p[fKey[0]] != null && p[fKey[0]] < 10) || (p.vmin != null && p.vmin < 50)); });
      if (out) { if (!run) { run = [i, i]; outages.push(run); } else run[1] = i; } else run = null;
    }
  }
  const outageMin = outages.reduce((n, r) => n + (r[1] - r[0] + 1) * 5, 0);

  // legend value: hovered bucket, else the latest reading; never a reading from another time
  const valAt = (inv, k) => {
    if (hover != null) { const p = inv.points[hover]; return p ? p[k] : null; }
    for (let i = Math.min(lastIdx, inv.points.length - 1); i >= 0; i--) if (inv.points[i][k] != null) return inv.points[i][k];
    return null;
  };
  const fmtC = v => (v == null ? null : Math.round(v) + ' °C');
  const fmtV = v => (v == null ? null : Math.round(v) + ' V');
  const fmtHz = v => (v == null ? null : v.toFixed(2) + ' Hz');
  const lagNote = lastData >= 0 && (isToday || lastData < 287) ? `to ${HM(lastData * 5)}` : null;
  const color = k => INV_COLORS[k % INV_COLORS.length];
  const freqLabel = kind === 'output' ? 'Frequency' : 'Grid frequency';
  // frequency chip and line: one series across inverters (grid) or per inverter (output);
  // drawn from the first inverter that actually carries it
  const fInv = shown.find(i => i.points.some(p => p[fKey[0]] != null)) || null;
  const fVal = fInv ? valAt(fInv, fKey[1]) : null;

  const onMove = e => setHover(idxFromPointer(e.clientX, e.currentTarget, m, innerW, lastIdx));
  const hp = hover != null && nInv ? hover : null;
  const xticks = xTicksFor(nowMin, mobile);

  const tooltip = () => {
    if (hp == null) return null;
    const px = x(hp);
    const rows = [];
    shown.forEach((inv, k) => {
      const p = inv.points[hp] || {};
      if (isTemp) {
        rows.push([nInv > 1 ? inv.alias : 'AC side', fmtC(p.ac), color(k)]);
        if (!inv.dcFlat) rows.push([(nInv > 1 ? inv.alias + ' ' : '') + 'DC side', fmtC(p.dc), color(k)]);
      } else {
        rows.push([nInv > 1 ? inv.alias : 'Voltage', p.vmin != null ? `${Math.round(p.vmin)}–${Math.round(p.vmax)} V` : null, color(k)]);
      }
    });
    if (!isTemp && fInv) { const p = fInv.points[hp] || {}; rows.push([freqLabel, p[fKey[0]] != null ? `${p[fKey[0]].toFixed(2)}–${p[fKey[1]].toFixed(2)} Hz` : null, C.soc]); }
    return (
      <div className="chart-tip" style={{ left: tipLeftFor(px, width), top: 24 }}>
        <div className="tip-time">{HM(hp * 5)}</div>
        {rows.map(([l, v, c]) => (
          <div className="tip-row" key={l}><span className="tip-dot" style={{ background: c }} /><span className="tip-l">{l}</span>
            <span className="tip-v mono">{v == null ? '—' : v}</span></div>
        ))}
      </div>
    );
  };

  // A past day can be empty for three reasons; say which (0048).
  const sync = window.SYNC;
  const emptyMsg = invs == null ? '' : isToday
    ? 'Nothing for today yet — it arrives with the six-hourly sync.'
    : sync && sync.invPending && sync.tempNext && date >= sync.tempNext
      ? (sync.tempNext > earliest
          ? `Still fetching this day — fetched up to ${niceDate(shiftDate(sync.tempNext, -1))} so far, a few more days every six hours.`
          : 'Still fetching this day — older days arrive first, a few every six hours.')
      : date < earliest ? 'Only the last 60 days could be fetched; this day is before that.'
      : 'No data for this day.';

  return (
    <div className="hv-root">
      <DateBar pick={pick} earliest={earliest}>
        {lagNote && <span className="hv-lag mono" title="From SunSynk's history, fetched every six hours; the live numbers above run ahead of it">{lagNote}</span>}
        {outageMin > 0 && <span className="hv-gap" title="Five-minute buckets with at least one reading under 50 V or 10 Hz — a blackout, to the nearest bucket">{fmtGap(outageMin)} out</span>}
      </DateBar>
      <div className="legend-row">
        {shown.map((inv, k) => (
          <window.LegendChip key={inv.sn} color={color(k)} label={nInv > 1 ? inv.alias : (isTemp ? 'AC side' : 'Voltage')}
            value={isTemp ? fmtC(valAt(inv, 'ac')) : fmtV(valAt(inv, 'v'))} active />
        ))}
        {isTemp && shown.filter(i => !i.dcFlat).map((inv, k) => (
          <window.LegendChip key={inv.sn + 'dc'} color={color(shown.indexOf(inv))} label={(nInv > 1 ? inv.alias + ' ' : '') + 'DC side'} value={fmtC(valAt(inv, 'dc'))} active />
        ))}
        {!isTemp && fInv && <window.LegendChip color={C.soc} label={freqLabel} value={fmtHz(fVal)} active />}
      </div>
      <div className="chart-area" ref={ref} style={{ position: 'relative', height }}>
        {nInv === 0 ? (
          invs == null ? <window.Skeleton h={height} r={12} />
            : <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height, color: 'var(--muted)', fontSize: 13, textAlign: 'center', padding: '0 16px' }}>{emptyMsg}</div>
        ) : (
          <svg width={width} height={height} className="chart-svg" style={{ cursor: 'crosshair' }}
            onMouseMove={onMove} onMouseLeave={() => setHover(null)}
            onTouchStart={e => e.touches[0] && setHover(idxFromPointer(e.touches[0].clientX, e.currentTarget, m, innerW, lastIdx))}
            onTouchMove={e => e.touches[0] && setHover(idxFromPointer(e.touches[0].clientX, e.currentTarget, m, innerW, lastIdx))}>
            {hasV && ys.ticks.map(v => (
              <g key={'y' + v}>
                <line x1={m.l} x2={m.l + innerW} y1={y(v)} y2={y(v)} stroke="rgba(255,255,255,0.05)" />
                <text x={m.l - 10} y={y(v) + 3} textAnchor="end" className="ax">{v}</text>
              </g>
            ))}
            {hasV && <text x={m.l - 10} y={m.t - 9} textAnchor="end" className="ax" fillOpacity="0.55">{isTemp ? '°C' : 'V'}</text>}
            {!isTemp && hasF && fs.ticks.map(v => (
              <text key={'f' + v} x={m.l + innerW + 10} y={yf(v) + 3} className="ax" fill={C.soc} fillOpacity="0.75">{v.toFixed(1)}</text>
            ))}
            {!isTemp && hasF && <text x={m.l + innerW + 10} y={m.t - 9} className="ax" fill={C.soc} fillOpacity="0.55">Hz</text>}
            {outages.map(([a, b], i) => (
              <rect key={'o' + i} x={x(Math.max(0, a - 0.5))} y={m.t - 8} width={Math.max(2, x(Math.min(lastIdx, b + 0.5)) - x(Math.max(0, a - 0.5)))} height={innerH + 8} fill={C.load} fillOpacity="0.18" />
            ))}
            {shown.map((inv, k) => {
              const c = color(k);
              return isTemp ? (
                <g key={inv.sn}>
                  {!inv.dcFlat && <path d={line(inv.points, 'dc', y)} fill="none" stroke={c} strokeWidth="1" strokeOpacity="0.5" strokeDasharray="3 3" />}
                  <path d={line(inv.points, 'ac', y)} fill="none" stroke={c} strokeWidth="1.4" strokeLinejoin="round" />
                </g>
              ) : (
                <g key={inv.sn}>
                  <path d={band(inv.points, 'vmin', 'vmax', y, v => v > 50)} fill={c} fillOpacity="0.22" />
                  <path d={line(inv.points, 'v', y, v => v > 50)} fill="none" stroke={c} strokeWidth="1.2" strokeLinejoin="round" />
                </g>
              );
            })}
            {!isTemp && fInv && (
              <g>
                <path d={band(fInv.points, fKey[0], fKey[1], yf, v => v > 10)} fill={C.soc} fillOpacity="0.18" />
                <path d={line(fInv.points, fKey[1], yf, v => v > 10)} fill="none" stroke={C.soc} strokeWidth="1" strokeOpacity="0.9" />
              </g>
            )}
            {xticks.map(t => (
              <text key={'gx' + t} x={x(t / 5)} y={m.t + innerH + 22} textAnchor="middle" className="ax">{HM(t)}</text>
            ))}
            {hp != null && <line x1={x(hp)} x2={x(hp)} y1={m.t - 8} y2={m.t + innerH} stroke="rgba(255,255,255,0.25)" />}
          </svg>
        )}
        {tooltip()}
      </div>
    </div>
  );
}
window.InverterHistoryChart = InverterHistoryChart;

function HistoryView({ today, refreshKey, locked, battPositive }) {
  const C = window.COLORS;
  const [vis, setVis] = React.useState({ pv: true, batt: true, load: true, grid: true, soc: true });
  const [hover, setHover] = React.useState(null);
  const [sel, setSel] = React.useState(null);    // [i0,i1] selected range (totals readout)
  const [drag, setDrag] = React.useState(null);  // { i0, i1 } in-progress drag (drives the band visual)
  const dragRef = React.useRef(null);            // live drag state (avoids stale-closure in move handler)
  const [earliest, setEarliest] = React.useState(null);
  const pick = useDayPicker(earliest);
  const { date, setDate, todayStr, isToday } = pick;
  const [pastDay, setPastDay] = React.useState(null); // fetched series for a non-today date
  const [loading, setLoading] = React.useState(false);
  const [view, setViewState] = React.useState(() => {
    try { const v = localStorage.getItem('synsynk.dayView'); return DAY_VIEWS.some(o => o.value === v) ? v : 'lines'; } catch (e) { return 'lines'; }
  });
  const setView = v => {
    setViewState(v); setHover(null); setSel(null); setDrag(null); dragRef.current = null;
    try { localStorage.setItem('synsynk.dayView', v); } catch (e) {}
  };
  // Rows stacks five labelled rows, so on a phone it needs more height than one plot
  const [ref, width, height] = useChartSize(view === 'rows' ? [430, 620] : undefined);
  const mobile = width < 560;

  // lower bound for the picker (≈ commission date)
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);

  // Fetch a past day's series. `silent` keeps the current chart on screen while
  // refetching (used by the Refresh button) instead of flashing the loader.
  const loadDay = React.useCallback((d, silent) => {
    if (!silent) { setLoading(true); setPastDay(null); setHover(null); }
    let alive = true;
    window.fetchDay(d)
      .then(r => { if (alive) { setPastDay(r); setLoading(false); } })
      .catch(() => { if (alive) { setPastDay({ points: [], totals: {} }); setLoading(false); } });
    return () => { alive = false; };
  }, []);

  // Today's series streams in live via the `today` prop; any other day we fetch
  // on demand here whenever the selected date changes.
  React.useEffect(() => {
    if (isToday) { setPastDay(null); setLoading(false); return; }
    return loadDay(date, false);
  }, [date, isToday, loadDay]);

  // Manual refresh: re-fetch the day on screen. Today refreshes through its prop
  // (App calls loadToday), so here we only need to refresh a selected past day.
  React.useEffect(() => {
    if (!refreshKey || isToday) return;
    return loadDay(date, true);
  }, [refreshKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const toggle = k => setVis(v => ({ ...v, [k]: !v[k] }));

  const m = { l: mobile ? 32 : 38, r: mobile ? 36 : 42, t: 24, b: 34 };
  const innerW = Math.max(40, width - m.l - m.r);
  const innerH = height - m.t - m.b;

  const dayData = isToday ? today : pastDay;
  const raw = (dayData && dayData.points) || [];
  // The battery series is + = powering the house; Settings → Display can flip it, and
  // idle reads 0. Gaps stay null. Range totals read `raw`, so charged never swaps with
  // discharged.
  const pts = React.useMemo(() => raw.map(p => (p.batt == null ? p : { ...p, batt: window.battShown(p.batt, battPositive) })),
    [dayData, battPositive]); // eslint-disable-line react-hooks/exhaustive-deps
  const real = pts.filter(p => p.pv != null); // anything with data (est = cloud-sourced, drawn dotted)
  const hasData = real.length > 1;

  // value shown inside each legend pill: the hovered point, else the latest reading
  const cur = (hover != null && pts[hover] && pts[hover].pv != null) ? pts[hover] : (real.length ? real[real.length - 1] : null);
  const chipVal = (k) => {
    // still fetching: keep the value slot so the chips (and the row wrap) hold their size
    if (!cur) return (loading || (isToday && !dayData)) ? ' ' : null;
    if (k === 'soc') return cur.soc != null ? cur.soc + '%' : null;
    const v = cur[k];
    return v != null ? window.fmtPower(v) : null;
  };

  // ---------------------------- DAY (power) ----------------------------
  function renderDay() {
    // Index over ALL points: the series is a complete 5-min grid with nulls where
    // the logger was offline, so index ↔ time-of-day stays aligned across gaps.
    const lastIdx = pts.length - 1;

    // y-left domain — scan ALL power series (not just visible, including the
    // dotted est fill) so toggling a pill on/off never rescales the axis.
    // Then snap to a nice zero-anchored scale.
    let dmin = 0, dmax = 0;
    pts.forEach(p => {
      [p.pv, p.load, p.batt, p.grid].forEach(v => {
        if (v == null) return; dmax = Math.max(dmax, v); dmin = Math.min(dmin, v);
      });
    });
    const { lo, hi, ticks: yticks } = niceScale(dmin, dmax, 8);
    const x = i => m.l + (i / lastIdx) * innerW;
    const y = v => m.t + innerH - ((v - lo) / (hi - lo)) * innerH;   // power → left axis (kW)
    const ysoc = s => m.t + innerH - (s / 100) * innerH;            // SOC → right axis (independent, 0–100%)

    // Cloud-recovered (est) points render exactly like measured ones — the
    // "cloud-filled" pill and the hover tooltip carry the provenance. Lines
    // still BREAK at nulls (minutes with no data anywhere): those can't be drawn.
    const line = (key, color) => {
      let d = '', pen = false;
      pts.forEach((p, i) => {
        if (p[key] == null) { pen = false; return; }
        d += (pen ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(p[key]).toFixed(1) + ' ';
        pen = true;
      });
      return <path d={d} fill="none" stroke={color} strokeWidth="1.1" strokeLinejoin="round" strokeLinecap="round" />;
    };

    const areaFill = (key, color) => {
      const segs = [];
      let seg = null;
      pts.forEach((p, i) => {
        if (p[key] == null) { seg = null; return; }
        if (!seg) { seg = []; segs.push(seg); }
        seg.push([i, p[key]]);
      });
      if (!segs.length) return null;
      const d = segs.map((s) => {
        const path = s.map(([i, v], k) => (k ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(v).toFixed(1)).join(' ');
        return `${path} L ${x(s[s.length - 1][0]).toFixed(1)} ${y(0).toFixed(1)} L ${x(s[0][0]).toFixed(1)} ${y(0).toFixed(1)} Z`;
      }).join(' ');
      return <path d={d} fill={color} fillOpacity="0.13" />;
    };

    // SOC line — overlaid on the power series, mapped to the independent right axis
    let socD = '';
    if (vis.soc) {
      let pen = false;
      pts.forEach((p, i) => {
        if (p.soc == null) { pen = false; return; }
        socD += (pen ? 'L' : 'M') + x(i).toFixed(1) + ' ' + ysoc(p.soc).toFixed(1) + ' ';
        pen = true;
      });
    }

    // axes
    const nowMin = pts[lastIdx].t;
    const xticks = xTicksFor(nowMin, mobile);

    const hp = hover != null ? pts[hover] : null;
    const idxFromX = (clientX, el) => idxFromPointer(clientX, el, m, innerW, lastIdx);
    // drag-to-range is a mouse interaction; on touch layouts the synthetic mouse
    // events from taps would pop the range panel over the plot, so skip it
    const onDown = e => { if (mobile) { setHover(idxFromX(e.clientX, e.currentTarget)); return; } const i = idxFromX(e.clientX, e.currentTarget); dragRef.current = { i0: i, i1: i }; setSel(null); setHover(null); setDrag({ i0: i, i1: i }); };
    const onMove = e => { const i = idxFromX(e.clientX, e.currentTarget); if (dragRef.current) { dragRef.current = { ...dragRef.current, i1: i }; setDrag({ ...dragRef.current }); } else setHover(i); };
    const onUp = () => { const d = dragRef.current; if (d) { dragRef.current = null; const a = Math.min(d.i0, d.i1), b = Math.max(d.i0, d.i1); setDrag(null); setSel(b - a >= 1 ? [a, b] : null); } };
    const band = drag ? [Math.min(drag.i0, drag.i1), Math.max(drag.i0, drag.i1)] : sel;
    return (
      <svg width={width} height={height} className="chart-svg" style={{ cursor: 'crosshair' }}
        onMouseDown={onDown}
        onMouseUp={onUp}
        onMouseLeave={() => { setHover(null); onUp(); }}
        onMouseMove={onMove}
        onTouchStart={e => e.touches[0] && setHover(idxFromX(e.touches[0].clientX, e.currentTarget))}
        onTouchMove={e => e.touches[0] && setHover(idxFromX(e.touches[0].clientX, e.currentTarget))}>
        <defs>
          <clipPath id="plotclip"><rect x={m.l} y={m.t - 8} width={innerW} height={innerH + 16} /></clipPath>
        </defs>
        {/* left axis: power (kW) */}
        {yticks.map((v, i) => (
          <g key={'gy' + i}>
            <line x1={m.l} x2={m.l + innerW} y1={y(v)} y2={y(v)} stroke={v === 0 ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.05)'} />
            <text x={m.l - 10} y={y(v) + 3} textAnchor="end" className={'ax' + (v === 0 ? ' ax-hi' : '')}>{+(v / 1000).toFixed(1)}</text>
          </g>
        ))}
        <text x={m.l - 10} y={m.t - 9} textAnchor="end" className="ax" fillOpacity="0.55">kW</text>
        {/* right axis: SOC — independent 0–100% scale */}
        {vis.soc && [0, 25, 50, 75, 100].map(s => (
          <text key={'sc' + s} x={m.l + innerW + 10} y={ysoc(s) + 3} className="ax" fill={C.soc} fillOpacity="0.75">{s}%</text>
        ))}
        {xticks.map(t => (
          <text key={'gx' + t} x={x(t / 5)} y={m.t + innerH + 22} textAnchor="middle" className="ax">{HM(t)}</text>
        ))}
        <line x1={m.l} x2={m.l + innerW} y1={y(0)} y2={y(0)} stroke="rgba(255,255,255,0.16)" />

        {band && (
          <g>
            <rect x={x(band[0])} y={m.t} width={Math.max(1, x(band[1]) - x(band[0]))} height={innerH} fill="rgba(255,255,255,0.07)" stroke="rgba(255,255,255,0.4)" strokeDasharray="3 3" />
            {(() => {
              const a = pts[band[0]], bEnd = pts[band[1]];
              if (!a) return null;
              if (!bEnd || band[1] === band[0]) {
                return <text x={Math.max(m.l + 16, x(band[0]))} y={m.t - 5} textAnchor="middle" className="ax" fillOpacity="0.9">{HM(a.t)}</text>;
              }
              // Two separate labels collide once the band is narrower than they are
              // wide (~34px each). Below that, draw one "start – end" label centred on
              // the band instead of letting the timestamps overlap into mush.
              const x0 = x(band[0]), x1 = x(band[1]);
              if (x1 - x0 < 78) {
                const cx = Math.min(m.l + innerW - 44, Math.max(m.l + 44, (x0 + x1) / 2));
                return <text x={cx} y={m.t - 5} textAnchor="middle" className="ax" fillOpacity="0.9">{HM(a.t)} – {HM(bEnd.t)}</text>;
              }
              return (
                <>
                  <text x={Math.max(m.l + 16, x0)} y={m.t - 5} textAnchor="middle" className="ax" fillOpacity="0.9">{HM(a.t)}</text>
                  <text x={Math.min(m.l + innerW - 16, x1)} y={m.t - 5} textAnchor="middle" className="ax" fillOpacity="0.9">{HM(bEnd.t)}</text>
                </>
              );
            })()}
          </g>
        )}

        <g clipPath="url(#plotclip)">
          {vis.pv && areaFill('pv', C.pv)}
          {vis.load && areaFill('load', C.load)}
          {vis.grid && areaFill('grid', C.grid)}
          {vis.batt && areaFill('batt', C.batt)}
          {vis.grid && line('grid', C.grid)}
          {vis.batt && line('batt', C.batt)}
          {vis.load && line('load', C.load)}
          {vis.pv && line('pv', C.pv)}
        </g>

        {/* SOC drawn last so it sits on top of the power series (right axis) */}
        {vis.soc && <path d={socD} fill="none" stroke={C.soc} strokeWidth="1.1" strokeOpacity="0.9" />}

        {hp && (
          <g>
            <line x1={x(hover)} x2={x(hover)} y1={m.t} y2={m.t + innerH} stroke="rgba(255,255,255,0.25)" />
            {['pv', 'load', 'batt', 'grid'].filter(k => vis[k] && hp[k] != null).map(k => (
              <circle key={k} cx={x(hover)} cy={y(hp[k])} r="3" fill={C[k]} stroke="#0b0e12" strokeWidth="1.5" />
            ))}
            {vis.soc && hp.soc != null && <circle cx={x(hover)} cy={ysoc(hp.soc)} r="3" fill={C.soc} stroke="#0b0e12" strokeWidth="1.5" />}
          </g>
        )}
      </svg>
    );
  }

  // ---------------------------- ROWS ----------------------------
  // Solar, Home, Battery and Grid each get a row on one shared kW-per-pixel scale, so a
  // quiet grid is a flat row instead of a line buried under the others. Charge takes its
  // own 0–100% row at the foot rather than a second scale over the power. The readings
  // sit beside the row names, so there is no tooltip over the plot.
  function renderRows() {
    const lastIdx = pts.length - 1;
    const mr = { l: mobile ? 34 : 40, r: mobile ? 4 : 8, t: 2, b: 30 };
    const iW = Math.max(40, width - mr.l - mr.r), R = mr.l + iW;
    const x = i => mr.l + (i / lastIdx) * iW;
    const HEAD = 22, GAP = 12, CH = mobile ? 44 : 60, MIN = 18;
    const rows = [['pv', 'Solar'], ['load', 'Home'], ['batt', 'Battery'], ['grid', 'Grid']].map(([k, name]) => {
      let lo = 0, hi = 0;
      pts.forEach(p => { if (p[k] != null) { lo = Math.min(lo, p[k]); hi = Math.max(hi, p[k]); } });
      lo = Math.floor(lo / 500) * 500; hi = Math.ceil(hi / 500) * 500;
      if (hi - lo < 500) hi = lo + 500;
      return { k, name, lo, hi };
    });
    // one watts-to-pixels ratio for every row; a row too flat to read is held at MIN
    // and the rest share what is left
    const avail = height - mr.t - mr.b - rows.length * (HEAD + GAP) - HEAD - CH;
    const total = rows.reduce((n, r) => n + r.hi - r.lo, 0);
    // held rows take more than their share, which can push another under MIN, so settle it
    let perW = avail / total;
    for (let pass = 0; pass < rows.length; pass++) {
      const small = rows.filter(r => (r.hi - r.lo) * perW < MIN);
      const next = small.length ? (avail - small.length * MIN) / Math.max(1, total - small.reduce((n, r) => n + r.hi - r.lo, 0)) : perW;
      if (next === perW) break;
      perW = next;
    }
    let top = mr.t;
    rows.forEach(r => {
      r.head = top; r.top = top + HEAD; r.h = Math.max(MIN, (r.hi - r.lo) * perW);
      r.y = v => r.top + ((r.hi - v) / (r.hi - r.lo)) * r.h;
      top = r.top + r.h + GAP;
    });
    const socHead = top, socTop = top + HEAD;
    const ysoc = s => socTop + CH - (s / 100) * CH;

    // the hovered reading, else the latest; over a gap, no values rather than the latest
    // under a pointer at another time. The words come from the raw sign so they read the
    // same whichever way Settings flips the battery line.
    const at = hover != null ? (pts[hover] && pts[hover].pv != null ? hover : -1) : (cur ? pts.indexOf(cur) : -1);
    const valueOf = k => {
      const v = at >= 0 ? pts[at][k] : null;
      if (v == null) return null;
      if (k === 'batt') return [v === 0 ? '' : raw[at].batt < 0 ? 'charging ' : 'powering home ', window.fmtPower(Math.abs(v))];
      if (k === 'grid') return [v < 0 ? 'exporting ' : '', window.fmtPower(Math.abs(v))];
      return ['', window.fmtPower(v)];
    };
    const head = (y, color, name, val) => (
      <g>
        <circle cx={mr.l + 4} cy={y + 8} r="4" fill={color} />
        <text x={mr.l + 14} y={y + 12} className="lane-name">{name}</text>
        {val && <text x={R} y={y + 12} textAnchor="end" className="lane-val">{val[0] && <tspan className="lane-word">{val[0]}</tspan>}{val[1]}</text>}
      </g>
    );
    const hp = hover != null && pts[hover] && pts[hover].pv != null ? hover : null;
    const idxFromX = (clientX, el) => idxFromPointer(clientX, el, mr, iW, lastIdx);
    const pillW = 44, pillX = hp != null ? Math.max(mr.l, Math.min(R - pillW, x(hp) - pillW / 2)) : 0;
    return (
      <svg width={width} height={height} className="chart-svg" style={{ cursor: 'crosshair' }}
        onMouseMove={e => setHover(idxFromX(e.clientX, e.currentTarget))}
        onMouseLeave={() => setHover(null)}
        onTouchStart={e => e.touches[0] && setHover(idxFromX(e.touches[0].clientX, e.currentTarget))}
        onTouchMove={e => e.touches[0] && setHover(idxFromX(e.touches[0].clientX, e.currentTarget))}>
        {rows.map(r => (
          <g key={r.k}>
            {head(r.head, C[r.k], r.name, valueOf(r.k))}
            {r.hi > 0 && <line x1={mr.l} x2={R} y1={r.top} y2={r.top} stroke="rgba(255,255,255,0.05)" />}
            {r.hi > 0 && <text x={mr.l - 8} y={r.top + 4} textAnchor="end" className="ax">{+(r.hi / 1000).toFixed(1)}</text>}
            {r.lo < 0 && <line x1={mr.l} x2={R} y1={r.top + r.h} y2={r.top + r.h} stroke="rgba(255,255,255,0.05)" />}
            {r.lo < 0 && <text x={mr.l - 8} y={r.top + r.h + 3} textAnchor="end" className="ax">{+(r.lo / 1000).toFixed(1)}</text>}
            {r.lo < 0 && r.hi > 0 && r.h > 40 && <text x={mr.l - 8} y={r.y(0) + 3} textAnchor="end" className="ax ax-hi">0</text>}
            <line x1={mr.l} x2={R} y1={r.y(0)} y2={r.y(0)} stroke="rgba(255,255,255,0.16)" />
            <path d={seriesBand(pts, x, r.y, () => 0, p => p[r.k])} fill={C[r.k]} fillOpacity="0.2" />
            <path d={seriesPath(pts, x, r.y, p => p[r.k])} fill="none" stroke={C[r.k]} strokeWidth="1.3" strokeLinejoin="round" />
          </g>
        ))}
        {head(socHead, C.soc, 'Charge', at >= 0 && pts[at].soc != null ? ['', pts[at].soc + '%'] : null)}
        <line x1={mr.l} x2={R} y1={socTop} y2={socTop} stroke="rgba(255,255,255,0.05)" />
        <line x1={mr.l} x2={R} y1={socTop + CH} y2={socTop + CH} stroke="rgba(255,255,255,0.16)" />
        <text x={mr.l - 8} y={socTop + 4} textAnchor="end" className="ax">100%</text>
        <text x={mr.l - 8} y={socTop + CH + 3} textAnchor="end" className="ax">0</text>
        <path d={seriesBand(pts, x, ysoc, () => 0, p => p.soc)} fill={C.soc} fillOpacity="0.1" />
        <path d={seriesPath(pts, x, ysoc, p => p.soc)} fill="none" stroke={C.soc} strokeWidth="1.4" strokeLinejoin="round" />
        {xTicksFor(pts[lastIdx].t, mobile).map(t => xLabel(t, x(t / 5), R, height - 8))}
        {hp != null && (
          <g>
            <line x1={x(hp)} x2={x(hp)} y1={rows[0].top} y2={socTop + CH} stroke="rgba(255,255,255,0.28)" />
            {rows.map(r => pts[hp][r.k] != null && <circle key={r.k} cx={x(hp)} cy={r.y(pts[hp][r.k])} r="3" fill={C[r.k]} stroke="#0b0e12" strokeWidth="1.5" />)}
            {pts[hp].soc != null && <circle cx={x(hp)} cy={ysoc(pts[hp].soc)} r="3" fill={C.soc} stroke="#0b0e12" strokeWidth="1.5" />}
            {/* the time sits over the x axis, where the eye already is */}
            <rect x={pillX} y={height - 22} width={pillW} height="20" rx="6" fill="#1c2430" stroke="rgba(255,255,255,0.14)" />
            <text x={pillX + pillW / 2} y={height - 8} textAnchor="middle" className="ax ax-hi">{HM(pts[hp].t)}</text>
          </g>
        )}
      </svg>
    );
  }

  // ---------------------------- HOURS ----------------------------
  // Each hour's energy as a bar. Above the line, what the house used, split by where it
  // came from; below it, what went into the battery or out to the grid. Charge keeps its
  // own row. Built from the raw series, so the battery sign setting does not apply.
  const mh = { l: mobile ? 32 : 38, r: mobile ? 8 : 12, t: 22, b: 30 };
  const hourData = (view === 'hours' && hasData) ? (() => {
    const lastIdx = raw.length - 1;
    const domain = isToday ? Math.min(1440, Math.ceil((raw[lastIdx].t + 5) / 60) * 60) : 1440;
    const hours = [];
    for (let h = 0; h < domain / 60; h++) hours.push({ h, sH: 0, bH: 0, gH: 0, chg: 0, exp: 0, n: 0, soc0: null, soc1: null });
    raw.forEach(p => {
      const o = p && p.pv != null && hours[Math.floor(p.t / 60)];
      if (!o) return;
      const s = powerSplit(p), dt = 5 / 60; // W over five minutes → Wh
      o.sH += s.sH * dt; o.bH += s.bH * dt; o.gH += s.gH * dt; o.chg += s.chg * dt; o.exp += s.exp * dt;
      o.n++;
      if (p.soc != null) { if (o.soc0 == null) o.soc0 = p.soc; o.soc1 = p.soc; }
    });
    // a short hour is drawn fainter: today's last one is still filling, any other has a gap
    const lastH = Math.floor(raw[lastIdx].t / 60);
    hours.forEach(o => { o.partial = o.n < 12; o.filling = isToday && o.h === lastH; });
    return { hours, domain, slot: Math.max(40, width - mh.l - mh.r) / hours.length };
  })() : null;

  function renderHours() {
    const { hours, domain, slot } = hourData;
    const iW = Math.max(40, width - mh.l - mh.r), R = mh.l + iW;
    const CH = mobile ? 40 : 56, GAP = 18;
    const mainH = height - mh.t - mh.b - CH - GAP;
    let up = 0, dn = 0;
    hours.forEach(o => { up = Math.max(up, o.sH + o.bH + o.gH); dn = Math.max(dn, o.chg + o.exp); });
    const { lo, hi, ticks } = niceScale(-dn, up, mobile ? 4 : 6);
    const y = v => mh.t + ((hi - v) / (hi - lo)) * mainH;
    const xm = t => mh.l + (t / domain) * iW;
    const xs = i => xm(pts[i].t + 2.5);
    const socTop = mh.t + mainH + GAP, ysoc = s => socTop + CH - (s / 100) * CH;
    const bw = Math.max(3, slot * (mobile ? 0.66 : 0.62)), gap = mobile ? 1 : 2, rad = Math.min(3, bw / 2);
    // one stacked segment from a to b (Wh, signed); the outermost gets its far corners rounded
    const seg = (key, x0, a, b, color, op, round) => {
      const ya = y(a), yb = y(b), h = Math.abs(yb - ya) - gap;
      if (h < 0.8) return null;
      const upward = b > a, top = upward ? yb : ya + gap;
      if (!round) return <rect key={key} x={x0} y={top} width={bw} height={h} fill={color} fillOpacity={op} />;
      const r = Math.min(rad, h), x1 = x0 + bw, bot = top + h;
      const d = upward
        ? `M${x0} ${bot} V${top + r} Q${x0} ${top} ${x0 + r} ${top} H${x1 - r} Q${x1} ${top} ${x1} ${top + r} V${bot} Z`
        : `M${x0} ${top} V${bot - r} Q${x0} ${bot} ${x0 + r} ${bot} H${x1 - r} Q${x1} ${bot} ${x1} ${bot - r} V${top} Z`;
      return <path key={key} d={d} fill={color} fillOpacity={op} />;
    };
    const hourFromX = (clientX, el) => Math.max(0, Math.min(hours.length - 1, Math.floor((clientX - el.getBoundingClientRect().left - mh.l) / slot)));
    return (
      <svg width={width} height={height} className="chart-svg" style={{ cursor: 'pointer' }}
        onMouseMove={e => setHover(hourFromX(e.clientX, e.currentTarget))}
        onMouseLeave={() => setHover(null)}
        onTouchStart={e => e.touches[0] && setHover(hourFromX(e.touches[0].clientX, e.currentTarget))}
        onTouchMove={e => e.touches[0] && setHover(hourFromX(e.touches[0].clientX, e.currentTarget))}>
        {ticks.map((v, i) => (
          <g key={'gy' + i}>
            <line x1={mh.l} x2={R} y1={y(v)} y2={y(v)} stroke={v === 0 ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.05)'} />
            <text x={mh.l - 8} y={y(v) + 3} textAnchor="end" className={'ax' + (v === 0 ? ' ax-hi' : '')}>{+(Math.abs(v) / 1000).toFixed(2)}</text>
          </g>
        ))}
        <text x={mh.l - 8} y={mh.t - 10} textAnchor="end" className="ax" fillOpacity="0.55">kWh</text>
        <text x={mh.l + 8} y={mh.t + 12} className="chart-zone">Home used</text>
        <text x={mh.l + 8} y={mh.t + mainH - 6} className="chart-zone">Stored or exported</text>
        {hours.map(o => {
          const x0 = mh.l + o.h * slot + (slot - bw) / 2;
          const dim = (hover != null && hover !== o.h ? 0.35 : 1) * (o.partial ? 0.55 : 1);
          const ups = [['sH', C.pv], ['bH', C.batt], ['gH', C.grid]].filter(([k]) => o[k] > 1);
          const dns = [['chg', C.batt], ['exp', C.grid]].filter(([k]) => o[k] > 1);
          let acc = 0;
          const upSegs = ups.map(([k, c], n) => { const s = seg(k, x0, acc, acc + o[k], c, 0.85 * dim, n === ups.length - 1); acc += o[k]; return s; });
          acc = 0;
          const dnSegs = dns.map(([k, c], n) => { const s = seg(k, x0, -acc, -acc - o[k], c, 0.4 * dim, n === dns.length - 1); acc += o[k]; return s; });
          return <g key={o.h}>{upSegs}{dnSegs}</g>;
        })}
        <line x1={mh.l} x2={R} y1={socTop} y2={socTop} stroke="rgba(255,255,255,0.05)" />
        <line x1={mh.l} x2={R} y1={socTop + CH} y2={socTop + CH} stroke="rgba(255,255,255,0.16)" />
        <text x={mh.l - 8} y={socTop + 4} textAnchor="end" className="ax">100%</text>
        <text x={mh.l - 8} y={socTop + CH + 3} textAnchor="end" className="ax">0</text>
        <path d={seriesBand(pts, xs, ysoc, () => 0, p => p.soc)} fill={C.soc} fillOpacity="0.1" />
        <path d={seriesPath(pts, xs, ysoc, p => p.soc)} fill="none" stroke={C.soc} strokeWidth="1.4" strokeLinejoin="round" />
        {/* a full day ends its axis at 23:55 like Lines, not at a 24:00 no one else prints */}
        {xTicksFor(Math.min(domain, 1435), mobile).map(t => xLabel(t, xm(t), R, height - 8))}
      </svg>
    );
  }

  function tooltipHours() {
    if (hover == null || !hourData) return null;
    const o = hourData.hours[hover]; if (!o) return null;
    const px = mh.l + (hover + 0.5) * hourData.slot;
    const kwh = wh => window.fmtKwh(wh / 1000);
    const part = (color, op, label, wh) => wh >= 50 && (
      <div className="tip-row sub" key={label}><span className="tip-sq" style={{ background: color, opacity: op }} /><span className="tip-l">{label}</span><span className="tip-v mono">{kwh(wh)}</span></div>
    );
    return (
      <div className="chart-tip" style={{ left: tipLeftFor(px, width), top: 24 }}>
        <div className="tip-time">{HM(o.h * 60)}–{HM(Math.min(1440, o.h * 60 + 60))}{o.filling ? ' so far' : o.n && o.partial ? ` · ${o.n * 5} of 60 min` : ''}</div>
        {!o.n ? <div className="tip-row"><span className="tip-l">No readings</span></div> : <>
          <div className="tip-row head"><span className="tip-dot" style={{ background: C.load }} /><span className="tip-l">Home</span><span className="tip-v mono">{kwh(o.sH + o.bH + o.gH)}</span></div>
          {part(C.pv, 0.85, 'from solar', o.sH)}
          {part(C.batt, 0.85, 'from battery', o.bH)}
          {part(C.grid, 0.85, 'from grid', o.gH)}
          {o.chg + o.exp >= 50 && <>
            <div className="tip-gap" />
            <div className="tip-row head"><span className="tip-l">Stored or exported</span><span className="tip-v mono">{kwh(o.chg + o.exp)}</span></div>
            {part(C.batt, 0.4, 'into battery', o.chg)}
            {part(C.grid, 0.4, 'exported', o.exp)}
          </>}
          {o.soc0 != null && <>
            <div className="tip-gap" />
            <div className="tip-row"><span className="tip-dot" style={{ background: C.soc }} /><span className="tip-l">Charge</span><span className="tip-v mono">{o.soc0}% → {o.soc1}%</span></div>
          </>}
        </>}
      </div>
    );
  }

  function tooltip() {
    if (view === 'hours') return tooltipHours();
    if (view !== 'lines') return null;
    if (sel || drag || hover == null || !hasData) return null;  // range mode suppresses the point tooltip
    const p = pts[hover]; if (!p || p.pv == null) return null;
    const li = pts.length - 1; const px = m.l + (hover / li) * innerW;
    // Sit beside the crosshair rather than in a far corner — on a wide screen the old
    // fixed corner meant reading a value a whole screen-width from the point it
    // described. Flips to the other side of the cursor near the right edge, and is
    // clamped so it can never hang off either end.
    const left = tipLeftFor(px, width);
    const rows = [
      ['Solar', p.pv, C.pv, 'W'],
      ['Battery', p.batt, C.batt, 'W'], // signed the way Settings → Display says
      ['Grid', p.grid, C.grid, 'W'], // signed: − = exporting
      ['Home', p.load, C.load, 'W'],
      ['Charge', p.soc, C.soc, '%'],
    ];
    return (
      <div className="chart-tip" style={{ left, top: 24 }}>
        {/* cloud-recovered points no longer announce themselves here; `p.est` still
            marks them in the data if that ever wants surfacing again */}
        <div className="tip-time">{HM(p.t)}</div>
        {rows.map(([l, v, c, u]) => (
          <div className="tip-row" key={l}><span className="tip-dot" style={{ background: c }} /><span className="tip-l">{l}</span>
            <span className="tip-v mono">{u === 'W' ? window.fmtPower(v) : v + ' ' + u}</span></div>
        ))}
      </div>
    );
  }

  // Totals over a drag-selected time range (energy = ∫ power dt across the points).
  function rangeSummary() {
    if (view !== 'lines' || !sel || !hasData) return null;
    const [a, b] = sel;
    let gen = 0, cons = 0, gImp = 0, gExp = 0, bChg = 0, bDis = 0;
    for (let i = a; i <= b && i < raw.length; i++) {
      const p = raw[i]; if (!p || p.pv == null) continue; // est (cloud-recovered) counts — it's part of history
      const nx = raw[i + 1];
      const dt = (nx && nx.t > p.t ? nx.t - p.t : 5) / 60; // hours to next sample
      gen += (p.pv || 0) / 1000 * dt;
      cons += (p.load || 0) / 1000 * dt;
      const g = p.grid || 0; if (g > 0) gImp += g / 1000 * dt; else gExp += -g / 1000 * dt;
      const bt = p.batt || 0; if (bt < 0) bChg += -bt / 1000 * dt; else bDis += bt / 1000 * dt; // chart: −batt = charging
    }
    const t0 = pts[a].t, t1 = pts[b].t, mins = t1 - t0;
    const dur = mins >= 60 ? `${Math.floor(mins / 60)}h ${String(mins % 60).padStart(2, '0')}m` : `${mins}m`;
    const soc0 = pts[a].soc, soc1 = pts[b].soc;
    const dSoc = (soc0 != null && soc1 != null) ? soc1 - soc0 : null;
    const f = v => v.toFixed(2);
    return (
      <div className="chart-range">
        <div className="cr-head"><span className="tip-time">{HM(t0)} – {HM(t1)} · {dur}</span><button className="cr-x" onClick={() => setSel(null)} aria-label="Clear">×</button></div>
        <div className="tip-row"><span className="tip-dot" style={{ background: C.pv }} /><span className="tip-l">Generated</span><span className="tip-v mono">{f(gen)} kWh</span></div>
        <div className="tip-row"><span className="tip-dot" style={{ background: C.load }} /><span className="tip-l">Home</span><span className="tip-v mono">{f(cons)} kWh</span></div>
        <div className="tip-row"><span className="tip-dot" style={{ background: C.grid }} /><span className="tip-l">Grid in / out</span><span className="tip-v mono">{f(gImp)} / {f(gExp)}</span></div>
        <div className="tip-row"><span className="tip-dot" style={{ background: C.batt }} /><span className="tip-l">Batt chg / dis</span><span className="tip-v mono">{f(bChg)} / {f(bDis)}</span></div>
        {dSoc != null && <div className="tip-row"><span className="tip-dot" style={{ background: C.soc }} /><span className="tip-l">Charge</span><span className="tip-v mono">{soc0}% → {soc1}% ({dSoc >= 0 ? '+' : ''}{dSoc}%)</span></div>}
      </div>
    );
  }

  const legend = [['pv', 'Solar', C.pv], ['batt', 'Battery', C.batt], ['grid', 'Grid', C.grid], ['load', 'Home', C.load], ['soc', 'Charge', C.soc]];

  // The server sends no series until today has about half an hour of readings
  // (`approx`), so a freshly linked plant sees a blank chart, not a short history.
  // A past day with nothing: still being fetched (fresh link, 0048), before the
  // 60 days the fetch reaches, or a real gap. Say which.
  // The walk is oldest-first from the bookmark: a day before it has been walked
  // (a real gap); a day at or after it is still to come, including the last two
  // weeks, which the normal sweep fills once the first walked day is in.
  const sync = window.SYNC;
  const pastMsg = sync && sync.spinePending && sync.backfillNext && date >= sync.backfillNext
    ? 'Still fetching this day — older days arrive first, a few every six hours.'
    : sync && sync.spinePending && date < shiftDate(todayStr, -DAY_FLOOR_DAYS) ? 'Only the last 60 days could be fetched; this day is before that.'
    : 'No data for this day';
  const emptyMsg = loading ? 'Loading…'
    : isToday && dayData?.approx ? 'Collecting today’s first readings — the chart starts after about half an hour of logging.'
    : isToday ? window.emptyText(window.PLANT_DAYS, 'Loading today’s data…') : pastMsg;

  return (
    <div className="hv-root">
      <DateBar pick={pick} earliest={earliest} locked={locked}
        right={<window.Segmented size="sm" options={DAY_VIEWS} value={view} onChange={setView} />} />
      {/* No count of missing minutes: most are single minutes inside a five-minute bucket
          the graph cannot show, and a hole long enough to matter already breaks the lines. */}

      {/* Rows names each series beside its own row, so it needs no legend */}
      {view === 'lines' && (
        <div className="legend-row">
          {legend.map(([k, l, c]) => <window.LegendChip key={k} color={c} label={l} value={chipVal(k)} active={vis[k]} onClick={() => toggle(k)} />)}
        </div>
      )}
      {view === 'hours' && (
        <div className="legend-row">
          {[['Solar', C.pv], ['Battery', C.batt], ['Grid', C.grid]].map(([l, c]) => (
            <span className="legend-chip" key={l}><span className="legend-swatch" style={{ background: c }} />{l}</span>
          ))}
          <span className="legend-chip"><span className="legend-dot" style={{ background: C.soc, borderColor: C.soc }} />Charge</span>
        </div>
      )}

      <div className="chart-area" ref={ref} style={{ position: 'relative', height: height }}>
        {hasData ? (view === 'rows' ? renderRows() : view === 'hours' ? renderHours() : renderDay())
          : (loading || (isToday && !dayData))
            // still fetching: hold the chart's shape rather than printing "Loading…"
            ? <window.Skeleton h={height} r={12} />
            : <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: height, color: 'var(--muted)', fontSize: 13 }}>{emptyMsg}</div>}
        {tooltip()}
        {rangeSummary()}
      </div>
    </div>
  );
}

window.HistoryView = HistoryView;
