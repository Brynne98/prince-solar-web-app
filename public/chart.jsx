// ============================================================================
// chart.jsx — <HistoryView/> : the day power graph.
//   • 5-minute power lines for Solar / Battery / Grid / Load, SOC on a right axis
//   • Series toggles, hover crosshair + exact-value tooltip
//   • Mode: Lines  /  Power balance (stacked area: where power came from)
//   • Day picker: step prev/next or jump via the date field, back to the plant's
//     first day of data (/api/history/earliest); today streams in live.
// Self-contained SVG; no external chart libs. `today` (live day series) comes in
// as a prop from <App>; past days are fetched here on demand (/api/history?date=).
// Period totals live in the Overview strip, so there is no range switch here.
// ============================================================================

// Measure WIDTH ONLY; height is fixed (derived from width). Measuring height and
// feeding it back into the SVG creates a ResizeObserver loop that makes the chart
// (and the page) creep larger on every interaction — so we never do that.
function useChartSize() {
  const ref = React.useRef(null);
  const [w, setW] = React.useState(360);
  React.useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const ro = new ResizeObserver(es => { for (const e of es) setW(Math.max(260, Math.round(e.contentRect.width))); });
    ro.observe(el); setW(Math.max(260, Math.round(el.clientWidth)));
    return () => ro.disconnect();
  }, []);
  const height = w < 560 ? 360 : 620; // fixed per breakpoint — no feedback
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
function niceDate(s) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
}

function HistoryView({ today, refreshKey }) {
  const C = window.COLORS;
  const todayStr = localDateStr();
  const [vis, setVis] = React.useState({ pv: true, batt: true, load: true, grid: true, soc: true });
  const [hover, setHover] = React.useState(null);
  const [sel, setSel] = React.useState(null);    // [i0,i1] selected range (totals readout)
  const [drag, setDrag] = React.useState(null);  // { i0, i1 } in-progress drag (drives the band visual)
  const dragRef = React.useRef(null);            // live drag state (avoids stale-closure in move handler)
  const [date, setDate] = React.useState(todayStr);
  const [earliest, setEarliest] = React.useState(null);
  const [potential, setPotential] = React.useState(null); // clear-sky "could-have-made" profile (dotted line)
  const [pastDay, setPastDay] = React.useState(null); // fetched series for a non-today date
  const [loading, setLoading] = React.useState(false);
  const [ref, width, height] = useChartSize();
  const mobile = width < 560;
  const isToday = date === todayStr;

  // lower bound for the picker (≈ commission date)
  React.useEffect(() => { window.fetchEarliest().then(setEarliest); }, []);

  // clear-sky "potential generation" profile for the displayed date (dotted line)
  React.useEffect(() => { window.fetchPotential(date).then(setPotential).catch(() => {}); }, [date, refreshKey]);

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
  const pts = (dayData && dayData.points) || [];
  const real = pts.filter(p => p.pv != null); // anything with data (est = cloud-sourced, drawn dotted)
  const hasData = real.length > 1;

  // clear-sky "potential" (dotted line) at any minute-of-day (profile is per-5-min).
  // Always drawn (no legend pill / toggle) — labelled only in the hover tooltip.
  // It's a visual reference for a clear day, NOT a measurement (no wasted-solar maths).
  const hasPot = potential && potential.points && potential.points.length > 0;
  const potAt = (t) => {
    if (!hasPot) return 0;
    const i = Math.max(0, Math.min(potential.points.length - 1, Math.round(t / 5)));
    return potential.points[i].w || 0;
  };

  // value shown inside each legend pill: the hovered point, else the latest reading
  const cur = (hover != null && pts[hover] && pts[hover].pv != null) ? pts[hover] : (real.length ? real[real.length - 1] : null);
  const chipVal = (k) => {
    if (!cur) return null;
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
    // include the dotted potential overlay so the line always fits the axis
    if (hasPot) potential.points.forEach(p => { if (p.t <= (pts[lastIdx] ? pts[lastIdx].t : 1440)) dmax = Math.max(dmax, p.w); });
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

    // dotted "potential generation" line (calibrated clear-sky for the day) — always on
    let avgD = '';
    if (hasPot) {
      pts.forEach((p, i) => { avgD += (avgD ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(potAt(p.t)).toFixed(1) + ' '; });
    }

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
    const xticks = [];
    const xstep = mobile ? 360 : 180; // 6h apart on phones, 3h on desktop
    for (let t = 0; t <= nowMin; t += xstep) xticks.push(t);
    if (nowMin - (xticks[xticks.length - 1] || 0) > xstep * 0.4) xticks.push(nowMin);

    const hp = hover != null ? pts[hover] : null;
    const idxFromX = (clientX, el) => {
      const mx = clientX - el.getBoundingClientRect().left;
      return Math.max(0, Math.min(lastIdx, Math.round(((mx - m.l) / innerW) * lastIdx)));
    };
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
        <text x={m.l - 10} y={m.t - 9} textAnchor="end" className="ax" fillOpacity="0.55">kWh</text>
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
          {hasPot && <path d={avgD} fill="none" stroke={C.pv} strokeWidth="1.5" strokeDasharray="1.5 4" strokeLinecap="round" strokeOpacity="0.9" />}
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

  function tooltip() {
    if (sel || drag || hover == null || !hasData) return null;  // range mode suppresses the point tooltip
    const p = pts[hover]; if (!p || p.pv == null) return null;
    const li = pts.length - 1; const px = m.l + (hover / li) * innerW;
    // Sit beside the crosshair rather than in a far corner — on a wide screen the old
    // fixed corner meant reading a value a whole screen-width from the point it
    // described. Flips to the other side of the cursor near the right edge, and is
    // clamped so it can never hang off either end.
    const tipW = 190, gap = 16;
    const left = Math.max(8, Math.min(width - tipW - 8,
      px + gap + tipW <= width - 8 ? px + gap : px - gap - tipW));
    const rows = [
      ['Solar', p.pv, C.pv, 'W'],
      ...(hasPot ? [['Potential', potAt(p.t), C.pv, 'W']] : []), // dotted clear-sky line value
      ['Battery', p.batt, C.batt, 'W'], // signed: − = discharging
      ['Grid', p.grid, C.grid, 'W'], // signed: − = exporting
      ['Load', p.load, C.load, 'W'],
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
    if (!sel || !hasData) return null;
    const [a, b] = sel;
    let gen = 0, cons = 0, gImp = 0, gExp = 0, bChg = 0, bDis = 0;
    for (let i = a; i <= b && i < pts.length; i++) {
      const p = pts[i]; if (!p || p.pv == null) continue; // est (cloud-recovered) counts — it's part of history
      const nx = pts[i + 1];
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
        <div className="tip-row"><span className="tip-dot" style={{ background: C.load }} /><span className="tip-l">Consumed</span><span className="tip-v mono">{f(cons)} kWh</span></div>
        <div className="tip-row"><span className="tip-dot" style={{ background: C.grid }} /><span className="tip-l">Grid in / out</span><span className="tip-v mono">{f(gImp)} / {f(gExp)}</span></div>
        <div className="tip-row"><span className="tip-dot" style={{ background: C.batt }} /><span className="tip-l">Batt chg / dis</span><span className="tip-v mono">{f(bChg)} / {f(bDis)}</span></div>
        {dSoc != null && <div className="tip-row"><span className="tip-dot" style={{ background: C.soc }} /><span className="tip-l">Charge</span><span className="tip-v mono">{soc0}% → {soc1}% ({dSoc >= 0 ? '+' : ''}{dSoc}%)</span></div>}
      </div>
    );
  }

  const legend = [['pv', 'Solar', C.pv], ['batt', 'Battery', C.batt], ['grid', 'Grid', C.grid], ['load', 'Load', C.load], ['soc', 'Charge', C.soc]];

  const canPrev = !earliest || date > earliest;
  const canNext = date < todayStr;
  const emptyMsg = loading ? 'Loading…' : isToday ? 'Loading today’s data…' : 'No data for this day';

  return (
    <div className="hv-root">
      <div className="hv-datebar">
        <button className="hv-daynav" disabled={!canPrev} aria-label="Previous day"
          onClick={() => canPrev && setDate(shiftDate(date, -1))}>‹</button>
        <input className="hv-dateinput" type="date" value={date}
          min={earliest || undefined} max={todayStr}
          onChange={e => e.target.value && setDate(e.target.value)} />
        <button className="hv-daynav" disabled={!canNext} aria-label="Next day"
          onClick={() => canNext && setDate(shiftDate(date, 1))}>›</button>
        <span className="hv-datelabel">{isToday ? 'Today' : niceDate(date)}</span>
        {/* The "Xh Ym missing" chip was removed by choice. api_history still returns
            gapMinutes/recoveredMinutes, so it can come back as a one-liner here. */}
        {!isToday && <button className="hv-today" onClick={() => setDate(todayStr)}>Today</button>}
      </div>

      <div className="legend-row">
        {legend.map(([k, l, c]) => <window.LegendChip key={k} color={c} label={l} value={chipVal(k)} active={vis[k]} onClick={() => toggle(k)} />)}
      </div>

      <div className="chart-area" ref={ref} style={{ position: 'relative', height: height }}>
        {hasData ? renderDay()
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
