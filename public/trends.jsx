// ============================================================================
// trends.jsx — <TrendsTab/> : grouped by purpose into two views.
//   • Battery  — electricity used per day-segment (kWh), split by source (solar/
//                battery/grid). From our own logged data.
//   • Energy   — lines, by Day / Month / Season (toggle): generated, consumed, and how
//                much of that consumption came off the grid. The Daily view adds a
//                dotted `Expected` line — that day's irradiance times a median
//                conversion ratio, so generation sits under it when the battery fills
//                and above it on heavy-use days. The sparse Month/Season views live
//                here until a year banks.
// Data: /api/trends/* (local log; daily/monthly from SunSynk; irradiance from
// solar_forecast, which the `forecast` Edge Function keeps topped up).
// ============================================================================
const kW = (w) => (w == null ? '—' : (w / 1000).toFixed(2) + ' kW');
const hhmm = (h) => String(h).padStart(2, '0') + ':00';

function useWidth() {
  const ref = React.useRef(null);
  const [w, setW] = React.useState(360);
  React.useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const ro = new ResizeObserver((es) => { for (const e of es) setW(Math.max(260, Math.round(e.contentRect.width))); });
    ro.observe(el); setW(Math.max(260, Math.round(el.clientWidth)));
    return () => ro.disconnect();
  }, []);
  return [ref, w];
}

function niceCeil(v) {
  if (v <= 0) return 1;
  const mag = Math.pow(10, Math.floor(Math.log10(v)));
  const n = v / mag;
  return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag;
}

// Consumption splits into the part your own solar/battery covered and the part bought
// from the grid. Clamped, because grid import can exceed household load on a day the
// grid also charged the battery — without the clamp the "own" part would go negative.
function splitLoad(load, imp) {
  const l = Math.max(0, load || 0);
  const gridPart = Math.min(Math.max(0, imp || 0), l);
  return { own: l - gridPart, gridPart };
}

// ---------- Bar chart for the Energy view ----------
// The original. Kept alongside LineChart because at 14 days bars read better than a
// line, and at 60 they become a picket fence — so it is a toggle, not a decision.
// Dashed series (the Expected line) are skipped: a dotted bar means nothing.
function BarChart({ bars, series, labelEvery = 1 }) {
  const [ref, width] = useWidth();
  const [hover, setHover] = React.useState(null);
  const fmtKwh = window.fmtKwh;
  if (!bars.length) return <div className="trend-chart" ref={ref}><div className="trend-empty">No data for this range yet.</div></div>;
  const mobile = width < 560;
  const height = mobile ? 300 : 380;
  const m = { l: 42, r: 12, t: 16, b: 40 };
  const innerW = Math.max(40, width - m.l - m.r);
  const innerH = height - m.t - m.b;
  const niceMax = niceCeil(Math.max(1, ...bars.flatMap((b) => series.map((s) => b[s.key] || 0))));
  const slot = innerW / bars.length;
  const groupW = Math.min(slot * 0.74, 30 * series.length);
  const bw = Math.max(2, groupW / series.length - (series.length > 1 ? 2 : 0));
  const y = (v) => m.t + innerH - (Math.max(0, v) / niceMax) * innerH;
  const yticks = []; for (let i = 0; i <= 4; i++) yticks.push((niceMax / 4) * i);
  // beside the hovered bar, not parked in a corner — same rule as the line chart
  const tipW = 200, gap = 14;
  const tipLeft = hover == null ? 0 : Math.max(6, Math.min(width - tipW - 6,
    (m.l + slot * (hover + 0.5)) + gap + tipW <= width - 6
      ? (m.l + slot * (hover + 0.5)) + gap
      : (m.l + slot * (hover + 0.5)) - gap - tipW));

  return (
    <div className="trend-chart" ref={ref} style={{ position: 'relative', height }}>
      <svg width={width} height={height} className="chart-svg" onMouseLeave={() => setHover(null)}>
        {yticks.map((v, i) => (
          <g key={i}>
            <line x1={m.l} y1={y(v)} x2={m.l + innerW} y2={y(v)} stroke="rgba(255,255,255,0.06)" />
            <text x={m.l - 6} y={y(v) + 3} textAnchor="end" className="ax">{v >= 1000 ? (v / 1000).toFixed(1) + 'k' : Math.round(v)}</text>
          </g>
        ))}
        {bars.map((b, i) => {
          const cx = m.l + slot * (i + 0.5);
          const x0 = cx - groupW / 2;
          const seg = groupW / series.length;
          return (
            <g key={i} onMouseEnter={() => setHover(i)}>
              <rect x={cx - slot / 2} y={m.t} width={slot} height={innerH} fill="transparent" />
              {series.map((s, si) => {
                const top = y(b[s.key] || 0);
                return <rect key={s.key} x={x0 + si * seg + (seg - bw) / 2} y={top} width={bw} height={Math.max(0, m.t + innerH - top)} rx="2" fill={s.color} fillOpacity={hover === i ? 0.95 : 0.72} />;
              })}
              {(i % labelEvery === 0 || i === bars.length - 1) && <text x={cx} y={height - 12} textAnchor="middle" className="ax">{b.label}</text>}
            </g>
          );
        })}
      </svg>
      {hover != null && bars[hover] && (
        <div className="trend-tip" style={{ left: tipLeft, width: tipW }}>
          <div className="tip-time">{bars[hover].full || bars[hover].label}</div>
          {series.map((s) => (
            <div className="tip-row" key={s.key}><span className="tip-dot" style={{ background: s.color }} /><span className="tip-l">{s.label}</span><span className="tip-v mono">{fmtKwh(bars[hover][s.key])}</span></div>
          ))}
          {bars[hover].sub && <div className="tip-row"><span className="tip-l">{bars[hover].sub}</span></div>}
        </div>
      )}
    </div>
  );
}

// ---------- Line chart for the Energy view ----------
// This replaced a grouped bar chart: at 30-60 daily points the bars became a picket
// fence, and lines show the shape of a run of dull days far better.
//
// Grid gets its own line rather than being stacked inside consumption: it rides near
// zero most days and spikes where the house leaned on the grid. The split of consumption
// into own-supply vs grid is shown on the Consumed stat card instead, where it can be
// read as exact figures rather than estimated off a band's thickness.
function LineChart({ bars, series, labelEvery = 1 }) {
  const [ref, width] = useWidth();
  const [hover, setHover] = React.useState(null);
  const fmtKwh = window.fmtKwh;
  if (!bars.length) return <div className="trend-chart" ref={ref}><div className="trend-empty">No data for this range yet.</div></div>;
  const mobile = width < 560;
  const height = mobile ? 300 : 380;
  const m = { l: 42, r: 12, t: 16, b: 40 };
  const innerW = Math.max(40, width - m.l - m.r);
  const innerH = height - m.t - m.b;
  const niceMax = niceCeil(Math.max(1, ...bars.flatMap((b) => series.map((s) => b[s.key] || 0).filter(Number.isFinite))));
  const n = bars.length;
  // A single point has no span to divide by; park it in the middle rather than /0.
  const x = (i) => n === 1 ? m.l + innerW / 2 : m.l + (i / (n - 1)) * innerW;
  const y = (v) => m.t + innerH - (Math.max(0, v) / niceMax) * innerH;
  const yticks = []; for (let i = 0; i <= 4; i++) yticks.push((niceMax / 4) * i);

  // Breaks at null rather than plotting it as zero — `expected` is absent on days with
  // no irradiance on file, and a dive to the axis would read as "no sun that day".
  const path = (key) => {
    let d = '', pen = false;
    bars.forEach((b, i) => {
      const v = b[key];
      if (v == null) { pen = false; return; }
      d += (pen ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(v).toFixed(1) + ' ';
      pen = true;
    });
    return d;
  };
  const area = (key) => path(key) + ` L ${x(n - 1).toFixed(1)} ${y(0).toFixed(1)} L ${x(0).toFixed(1)} ${y(0).toFixed(1)} Z`;

  const idxFromX = (clientX, el) => {
    const mx = clientX - el.getBoundingClientRect().left;
    return Math.max(0, Math.min(n - 1, Math.round(((mx - m.l) / innerW) * (n - 1))));
  };

  // Tooltip beside the cursor, flipping near the right edge — same rule as the day chart.
  const tipW = 200, gap = 14;
  const tipLeft = hover == null ? 0 : Math.max(6, Math.min(width - tipW - 6,
    x(hover) + gap + tipW <= width - 6 ? x(hover) + gap : x(hover) - gap - tipW));

  return (
    <div className="trend-chart" ref={ref} style={{ position: 'relative', height }}>
      <svg width={width} height={height} className="chart-svg" style={{ cursor: 'crosshair' }}
           onMouseMove={(e) => setHover(idxFromX(e.clientX, e.currentTarget))}
           onMouseLeave={() => setHover(null)}
           onTouchStart={(e) => e.touches[0] && setHover(idxFromX(e.touches[0].clientX, e.currentTarget))}
           onTouchMove={(e) => e.touches[0] && setHover(idxFromX(e.touches[0].clientX, e.currentTarget))}>
        {yticks.map((v, i) => (
          <g key={i}>
            <line x1={m.l} y1={y(v)} x2={m.l + innerW} y2={y(v)} stroke="rgba(255,255,255,0.06)" />
            <text x={m.l - 6} y={y(v) + 3} textAnchor="end" className="ax">{v >= 1000 ? (v / 1000).toFixed(1) + 'k' : Math.round(v)}</text>
          </g>
        ))}
        {series.filter((s) => s.fill).map((s) => (
          <path key={s.key + '-f'} d={area(s.key)} fill={s.color} fillOpacity="0.10" />
        ))}
        {series.map((s) => (
          <path key={s.key} d={path(s.key)} fill="none" stroke={s.color}
                strokeWidth={s.dash ? 1.5 : 1.8} strokeDasharray={s.dash} strokeOpacity={s.dash ? 0.85 : 1}
                strokeLinejoin="round" strokeLinecap="round" />
        ))}
        {hover != null && (
          <g>
            <line x1={x(hover)} x2={x(hover)} y1={m.t} y2={m.t + innerH} stroke="var(--line-2)" strokeWidth="1" />
            {series.filter((s) => bars[hover][s.key] != null).map((s) => (
              <circle key={s.key} cx={x(hover)} cy={y(bars[hover][s.key])} r="3.5"
                      fill="var(--panel)" stroke={s.color} strokeWidth="2" />
            ))}
          </g>
        )}
        {bars.map((b, i) => (
          (i % labelEvery === 0 || i === n - 1)
            ? <text key={i} x={x(i)} y={height - 12} textAnchor="middle" className="ax">{b.label}</text>
            : null
        ))}
      </svg>
      {hover != null && bars[hover] && (
        <div className="trend-tip" style={{ left: tipLeft, width: tipW }}>
          <div className="tip-time">{bars[hover].full || bars[hover].label}</div>
          {series.map((s) => (
            <div className="tip-row" key={s.key}>
              <span className="tip-dot" style={{ background: s.color }} /><span className="tip-l">{s.label}</span>
              <span className="tip-v mono">{fmtKwh(bars[hover][s.key])}</span>
            </div>
          ))}
          {bars[hover].sub && <div className="tip-row"><span className="tip-l">{bars[hover].sub}</span></div>}
        </div>
      )}
    </div>
  );
}

function TrendStats({ bars, unit }) {
  if (!bars || !bars.length) return null;
  const C = window.COLORS, f = window.fmtKwh;
  const n = bars.length;
  const sum = (k) => bars.reduce((a, b) => a + (b[k] || 0), 0);
  const pv = sum('pv'), load = sum('load'), imp = sum('imp');
  const suff = load > 0 ? Math.round(((load - imp) / load) * 100) : null;
  // Where the consumed energy came from. Clamped the same way the chart is: import can
  // exceed household load on a day the grid also charged the battery.
  const { own, gridPart } = splitLoad(load, imp);
  const ownPct = load > 0 ? (own / load) * 100 : 0;
  return (
    <div className="trend-stats">
      <div><div className="ts-l">Generated</div><div className="ts-v mono" style={{ color: C.pv }}>{f(pv)}</div><div className="ts-sub">avg {f(pv / n)}/{unit}</div></div>
      <div>
        <div className="ts-l">Consumed</div>
        <div className="ts-v mono" style={{ color: C.load }}>{f(load)}</div>
        <div className="ts-sub">avg {f(load / n)}/{unit}</div>
        {load > 0 && (
          <>
            <div className="ts-split" title={`${f(own)} came from your own solar and battery, ${f(gridPart)} was bought from the grid`}>
              <span style={{ width: ownPct + '%', background: C.load }} />
              <span style={{ width: (100 - ownPct) + '%', background: C.grid }} />
            </div>
            <div className="ts-split-key">
              <span><i style={{ background: C.load }} />solar/battery <b className="mono">{f(own)}</b></span>
              <span><i style={{ background: C.grid }} />grid <b className="mono">{f(gridPart)}</b></span>
            </div>
          </>
        )}
      </div>
      <div><div className="ts-l">Self-sufficiency</div><div className="ts-v mono" style={{ color: C.soc }}>{suff != null ? suff + '%' : '—'}</div></div>
    </div>
  );
}

// Average power per day-segment, with each segment's load split by source. At night
// the split is battery-vs-grid (no sun); by day it's mostly direct solar.
const SEG_DEFS = [
  { seg: 0, name: 'Deep night', range: '00:00 – 04:00', hrs: 4 },
  { seg: 1, name: 'Morning geysers', range: '04:00 – 06:00', hrs: 2 },
  { seg: 2, name: 'Dawn', range: '06:00 – 08:00', hrs: 2 },
  { seg: 3, name: 'Daytime', range: '08:00 – 17:00', hrs: 9 },
  { seg: 4, name: 'Evening', range: '17:00 – 00:00', hrs: 7 },
];
function SegmentUsage({ data }) {
  const C = window.COLORS;
  const by = Object.fromEntries((data || []).map((s) => [s.seg, s]));
  const src = [
    { k: 'solar_w', label: 'Solar', c: C.pv },
    { k: 'batt_w', label: 'Battery', c: C.batt },
    { k: 'grid_w', label: 'Grid', c: C.grid },
  ];
  // Work in ENERGY (kWh) so bar LENGTH = how many units that part of the day uses.
  // A long, gentle window (daytime) then correctly out-weighs a short fierce one
  // (the geysers) — matching the eye's "longer = more". kWh = avg power × hours.
  // The avg kW rides alongside as the intensity ("how hard", not "how much").
  const rows = SEG_DEFS.map((def) => {
    const s = by[def.seg];
    if (!s) return null;
    const e = (w) => (w || 0) / 1000 * def.hrs;
    return { def, loadKw: (s.load_w || 0) / 1000, loadKwh: e(s.load_w), parts: src.map((x) => ({ ...x, kwh: e(s[x.k]) })) };
  }).filter(Boolean);
  const maxKwh = Math.max(1, ...rows.map((r) => r.loadKwh));

  // Floating tooltip (same look as the day chart's): hover/tap a row → its source
  // breakdown with each source's kWh and % of that segment's total.
  const [hover, setHover] = React.useState(null); // { seg, x, y, w, h }
  const wrapRef = React.useRef(null);
  const track = (seg) => (e) => {
    const el = wrapRef.current; if (!el) return;
    const r = el.getBoundingClientRect();
    const pt = e.touches && e.touches[0] ? e.touches[0] : e;
    setHover({ seg, x: pt.clientX - r.left, y: pt.clientY - r.top, w: r.width, h: r.height });
  };
  const hv = hover && rows.find((r) => r.def.seg === hover.seg);

  return (
    <div ref={wrapRef} style={{ position: 'relative' }}>
      <div className="seg-list">
        {rows.map((r) => {
          const dom = r.parts.filter((p) => p.kwh > 0).sort((a, b) => b.kwh - a.kwh)[0];
          return (
            <div className="seg-row" key={r.def.seg}
              onMouseMove={track(r.def.seg)} onMouseLeave={() => setHover(null)} onTouchStart={track(r.def.seg)}>
              <div className="seg-head">
                <span className="seg-name">{r.def.name}<span className="seg-range"> · {r.def.range}</span></span>
                <span className="seg-avg mono">{r.loadKwh.toFixed(1)} kWh<span className="seg-kwh"> · {r.loadKw.toFixed(1)} kW avg</span></span>
              </div>
              <div className="seg-bar">
                {r.parts.map((p) => (p.kwh > 0
                  ? <div key={p.k} className="seg-seg" style={{ width: (p.kwh / maxKwh * 100) + '%', background: p.c }} />
                  : null))}
              </div>
              {dom && <div className="seg-from">mostly {dom.label.toLowerCase()}</div>}
            </div>
          );
        })}
      </div>
      {hv && (() => {
        const estW = 230, tot = hv.loadKwh || 1; // est width only for edge-flip; box sizes to content
        const left = hover.x > hover.w / 2 ? Math.max(6, hover.x - estW) : Math.max(6, Math.min(hover.x + 14, hover.w - estW - 6));
        const top = hover.y > hover.h / 2 ? Math.max(2, hover.y - 112) : hover.y + 16;
        return (
          <div className="chart-tip" style={{ left, top }}>
            <div className="tip-time">{hv.def.name} · {hv.def.range}</div>
            {hv.parts.filter((p) => p.kwh > 0.001).sort((a, b) => b.kwh - a.kwh).map((p) => (
              <div className="tip-row" key={p.k}>
                <span className="tip-dot" style={{ background: p.c }} />
                <span className="tip-l">{p.label}</span>
                <span className="tip-v mono">{p.kwh.toFixed(1)} kWh · {Math.round(p.kwh / tot * 100)}%</span>
              </div>
            ))}
            <div className="tip-row tip-total">
              <span className="tip-l">Total</span>
              <span className="tip-v mono">{hv.loadKwh.toFixed(1)} kWh</span>
            </div>
          </div>
        );
      })()}
      <div className="trend-legend" style={{ marginTop: 14 }}>
        {src.map((x) => <span className="tl-item" key={x.k}><span className="tl-dot" style={{ background: x.c }} />{x.label}</span>)}
      </div>
    </div>
  );
}

// (Removed 2026-06: PhaseUsage / the overnight "battery at midnight" card — the
// per-segment usage card below now covers the overnight breakdown.)

// 24 stacked bars: each hour's load split into solar / battery / grid as % of
// that hour's load (so every bar is 100% tall — mix, not kWh). Charge rides on
// the same 0–100 axis. Current hour is marked. This is the fine grain under the
// five day-segments above: those answer "where the day's units went"; this one
// answers "what 23:00 actually looks like".
function HourMixChart({ hours, nowHour }) {
  const C = window.COLORS;
  const [ref, width] = useWidth();
  const [hover, setHover] = React.useState(null);
  const src = [
    { k: 'solar', label: 'Solar', c: C.pv },
    { k: 'batt', label: 'Battery', c: C.batt },
    { k: 'grid', label: 'Grid', c: C.grid },
  ];
  const by = Object.fromEntries((hours || []).map((h) => [Number(h.hour), h]));
  const rows = [];
  for (let hour = 0; hour < 24; hour++) {
    const h = by[hour];
    const s = Number(h && h.solar_w) || 0;
    const b = Number(h && h.batt_load_w) || 0;
    const g = Number(h && h.grid_load_w) || 0;
    const tot = s + b + g;
    const soc = h && h.soc != null && Number.isFinite(Number(h.soc)) ? Math.round(Number(h.soc)) : null;
    rows.push({
      hour,
      solar: tot > 0 ? s / tot * 100 : 0,
      batt: tot > 0 ? b / tot * 100 : 0,
      grid: tot > 0 ? g / tot * 100 : 0,
      soc,
      empty: tot <= 0,
    });
  }
  if (!(hours || []).length) return <div className="trend-chart" ref={ref}><div className="trend-empty">No data yet.</div></div>;

  const mobile = width < 560;
  const height = mobile ? 200 : 240;
  const m = { l: 36, r: 12, t: 14, b: 28 };
  const innerW = Math.max(40, width - m.l - m.r);
  const innerH = height - m.t - m.b;
  const slot = innerW / 24;
  const bw = Math.max(3, slot * 0.72);
  const y = (v) => m.t + innerH - (Math.max(0, Math.min(100, v)) / 100) * innerH;
  const x = (i) => m.l + slot * (i + 0.5);
  const hh = (h) => String(h).padStart(2, '0') + ':00';
  const tipW = 200, gap = 14;
  const tipLeft = hover == null ? 0 : Math.max(6, Math.min(width - tipW - 6,
    x(hover) + gap + tipW <= width - 6 ? x(hover) + gap : x(hover) - gap - tipW));

  let socD = '';
  let pen = false;
  rows.forEach((r, i) => {
    if (r.soc == null) { pen = false; return; }
    socD += (pen ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(r.soc).toFixed(1) + ' ';
    pen = true;
  });

  return (
    <div className="trend-chart" ref={ref} style={{ position: 'relative', height }}>
      <svg width={width} height={height} className="chart-svg" style={{ cursor: 'crosshair' }}
           onMouseLeave={() => setHover(null)}>
        {[0, 50, 100].map((v) => (
          <g key={v}>
            <line x1={m.l} y1={y(v)} x2={m.l + innerW} y2={y(v)} stroke="rgba(255,255,255,0.06)" />
            <text x={m.l - 6} y={y(v) + 3} textAnchor="end" className="ax">{v}%</text>
          </g>
        ))}
        {rows.map((r, i) => {
          const cx = x(i);
          const now = nowHour === r.hour;
          let y0 = m.t + innerH;
          const segs = src.map((s) => {
            const hgt = (r[s.k] / 100) * innerH;
            y0 -= hgt;
            return { ...s, y: y0, h: hgt };
          });
          return (
            <g key={r.hour} onMouseEnter={() => setHover(i)} onTouchStart={() => setHover(i)}>
              <rect x={cx - slot / 2} y={m.t} width={slot} height={innerH} fill="transparent" />
              {now && <rect x={cx - bw / 2 - 1.5} y={m.t} width={bw + 3} height={innerH} rx="3" fill="rgba(255,255,255,0.06)" />}
              {segs.filter((s) => s.h > 0.4).map((s) => (
                <rect key={s.k} x={cx - bw / 2} y={s.y} width={bw} height={s.h}
                  fill={s.c} fillOpacity={now ? 0.95 : (hover === i ? 0.88 : 0.7)} />
              ))}
              {(r.hour % 6 === 0 || now) && (
                <text x={cx} y={height - 8} textAnchor="middle" className={'ax' + (now ? ' ax-hi' : '')}>{hh(r.hour)}</text>
              )}
            </g>
          );
        })}
        {socD && <path d={socD} fill="none" stroke={C.soc} strokeWidth="1.6" strokeOpacity="0.95" />}
        {rows.map((r, i) => r.soc != null
          ? <circle key={'s' + r.hour} cx={x(i)} cy={y(r.soc)} r={nowHour === r.hour || hover === i ? 3 : 0}
              fill={C.soc} stroke="#0b0e12" strokeWidth="1.2" />
          : null)}
      </svg>
      {hover != null && rows[hover] && !rows[hover].empty && (
        <div className="chart-tip" style={{ left: tipLeft, top: 12, width: tipW }}>
          <div className="tip-time">{hh(rows[hover].hour)}{nowHour === rows[hover].hour ? ' · now' : ''}</div>
          {src.filter((s) => rows[hover][s.k] >= 0.5).map((s) => (
            <div className="tip-row" key={s.k}>
              <span className="tip-dot" style={{ background: s.c }} />
              <span className="tip-l">{s.label}</span>
              <span className="tip-v mono">{Math.round(rows[hover][s.k])}%</span>
            </div>
          ))}
          {rows[hover].soc != null && (
            <div className="tip-row">
              <span className="tip-dot" style={{ background: C.soc }} />
              <span className="tip-l">Charge</span>
              <span className="tip-v mono">{rows[hover].soc}%</span>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// SA (southern-hemisphere) seasons
const SEASONS = [
  { key: 'summer', label: 'Summer', months: [12, 1, 2] },
  { key: 'autumn', label: 'Autumn', months: [3, 4, 5] },
  { key: 'winter', label: 'Winter', months: [6, 7, 8] },
  { key: 'spring', label: 'Spring', months: [9, 10, 11] },
];
const MONTHS = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// Chart-shaped placeholder: a stat row and a plot area at the real chart's height, so
// the card doesn't resize when the data lands.
function ChartSkeleton({ stats = true }) {
  const S = window.Skeleton;
  return (
    <div>
      {stats && (
        <div className="trend-stats">
          {/* labels are static; only the figures wait on data */}
          {['Generated', 'Consumed', 'Self-sufficiency'].map(l => (
            <div key={l}>
              <div className="ts-l">{l}</div>
              <div className="ts-v"><S w="70%" h={23} /></div>
            </div>
          ))}
        </div>
      )}
      {/* .trend-chart renders at 380px */}
      <S h={380} r={12} style={{ marginTop: 14 }} />
    </div>
  );
}

function TrendsTab({ refreshKey, auto, settings, config }) {
  const C = window.COLORS;
  const { Card, SectionTitle, Segmented } = window;
  const [view, setView] = React.useState('battery');   // battery | energy
  const [gran, setGran] = React.useState('daily');
  // remembered, like the other view choices — it's a preference, not a session thing
  const [kind, setKind] = React.useState(() => {
    try { return localStorage.getItem('synsynk.trendChart') === 'bar' ? 'bar' : 'line'; } catch (e) { return 'line'; }
  });
  const setKindSaved = (v) => { setKind(v); try { localStorage.setItem('synsynk.trendChart', v); } catch (e) {} };      // energy granularity: daily | monthly | seasonal
  const [dailyDays, setDailyDays] = React.useState(30);
  const [daily, setDaily] = React.useState(null);
  const [monthly, setMonthly] = React.useState(null);
  const [segData, setSegData] = React.useState(null);
  const [hourData, setHourData] = React.useState(null);
  const [segDays, setSegDays] = React.useState(7);
  const [loading, setLoading] = React.useState(false);
  const [tick, setTick] = React.useState(0); // bumped by auto-refresh

  // auto-refresh while this tab is open (trends are slow-moving aggregates, so 5 min is plenty)
  React.useEffect(() => {
    if (!auto) return;
    const id = setInterval(() => setTick(t => t + 1), 300000);
    return () => clearInterval(id);
  }, [auto]);

  // Fetch per active view. Re-runs on view/range change, on manual Refresh
  // (refreshKey), and on the auto tick. The render keeps the existing chart while
  // refetching (loader only shows when there's no data yet), so updates are silent.
  React.useEffect(() => {
    let alive = true; setLoading(true);
    const done = (set) => (d) => { if (alive) { set(d); setLoading(false); } };
    const fail = () => { if (alive) setLoading(false); };
    if (view === 'energy') {
      if (gran === 'daily') window.fetchTrendDaily(dailyDays).then(done(setDaily)).catch(fail);
      else window.fetchTrendMonthly().then(done(setMonthly)).catch(fail); // monthly + seasonal share data
    } else { // battery: per-segment usage split + hour-of-day mix
      Promise.all([window.fetchSegments(segDays), window.fetchHourly(segDays)])
        .then(([seg, hour]) => { if (!alive) return; setSegData(seg); setHourData(hour); setLoading(false); })
        .catch(fail);
    }
    return () => { alive = false; };
  }, [view, gran, dailyDays, segDays, refreshKey, tick]);

  const dailyBars = React.useMemo(() => {
    const rows = daily || [];
    let i = 0; // trim leading pre-commission zero days
    while (i < rows.length && (rows[i].pv || 0) === 0 && (rows[i].load || 0) === 0) i++;
    return rows.slice(i).map((r) => ({ label: String(r.day), full: r.date, pv: r.pv, load: r.load, imp: r.imp, expected: r.expected ?? null, ...splitLoad(r.load, r.imp) }));
  }, [daily]);
  const monthlyBars = React.useMemo(() => (monthly || []).map((r) => ({
    label: MONTHS[r.month] + (r.year !== new Date().getFullYear() ? " '" + String(r.year).slice(2) : ''),
    full: MONTHS[r.month] + ' ' + r.year, pv: r.pv, load: r.load, imp: r.imp, ...splitLoad(r.load, r.imp),
  })), [monthly]);
  const seasonBars = React.useMemo(() => {
    const acc = {};
    (monthly || []).forEach((r) => {
      const s = SEASONS.find((s) => s.months.includes(r.month)); if (!s) return;
      const a = acc[s.key] || (acc[s.key] = { pv: 0, load: 0, imp: 0, cnt: 0 });
      a.pv += r.pv; a.load += r.load; a.imp += (r.imp || 0); a.cnt += 1;
    });
    return SEASONS.map((s) => { const a = acc[s.key] || { pv: 0, load: 0, imp: 0, cnt: 0 }; return { label: s.label, full: s.label, pv: a.pv, load: a.load, imp: a.imp, ...splitLoad(a.load, a.imp), sub: a.cnt + ' month(s) of data' }; });
  }, [monthly]);

  // Three plain lines. Consumption's split into own-supply vs grid lives on the Consumed
  // stat card above the chart, not in the chart itself.
  const SERIES = [
    { key: 'pv', label: 'Generated', color: C.pv, fill: true },
    { key: 'load', label: 'Consumed', color: C.load },
    { key: 'gridPart', label: 'From grid', color: C.grid },
  ];
  // Daily only. Monthly and seasonal would need irradiance summed across whole months,
  // and only ~120 days of it is kept, so those totals would be silently part-covered.
  const DAILY_SERIES = SERIES.concat([
    { key: 'expected', label: 'Expected', color: C.pv, dash: '2 4' },
  ]);
  // Bars can't render a dashed reference, so Expected is line-only.
  const Chart = kind === 'bar' ? BarChart : LineChart;
  const seriesFor = (list) => kind === 'bar' ? list.filter((x) => !x.dash) : list;
  const genConsLegend = (
    <div className="trend-legend">
      <span className="tl-item"><span className="tl-dot" style={{ background: C.pv }} />Generated</span>
      <span className="tl-item"><span className="tl-dot" style={{ background: C.load }} />Consumed</span>
      <span className="tl-item"><span className="tl-dot" style={{ background: C.grid }} />From grid</span>
      {/* line-only: bars can't carry a dashed reference, so don't advertise one */}
      {kind !== 'bar' && <span className="tl-item"><span className="tl-dash" style={{ borderColor: C.pv }} />Expected</span>}
    </div>
  );


  const VIEWS = [{ value: 'battery', label: 'Battery' }, { value: 'energy', label: 'Energy' }];
  const GRAN = [{ value: 'daily', label: 'Daily' }, { value: 'monthly', label: 'Monthly' }, { value: 'seasonal', label: 'Seasonal' }];

  return (
    <div className="stack">
      <div className="overview-head">
        <SectionTitle>TRENDS</SectionTitle>
        <Segmented size="sm" value={view} onChange={setView} options={VIEWS} />
      </div>

      {/* ---------- BATTERY: per-segment usage split + hour-of-day mix ---------- */}
      {view === 'battery' && (
        <>
          <div className="trend-subnav">
            <div className="trend-rec-label">Electricity used by time of day</div>
            <Segmented size="sm" value={segDays} onChange={setSegDays} options={[{ value: 7, label: '7d' }, { value: 14, label: '14d' }, { value: 30, label: '30d' }]} />
          </div>
          <Card>
            <div className="seg-key"><b>Bar length</b> = units used (kWh) — longer = more · <b>colours</b> = where it came from</div>
            {loading && !segData ? <ChartSkeleton stats={false} /> : segData && segData.segments && segData.segments.length ? (
              <SegmentUsage data={segData.segments} />
            ) : <div className="trend-empty">No data yet.</div>}
            <div className="hint-line">
              Typical units (kWh) used in each part of the day over the last {segData ? segData.days : segDays} days, coloured by what supplied them. The <b>kW avg</b> alongside is the intensity — how hard you pull (the geysers are short but fierce). <b>At night the split is battery vs grid</b> (with your {config?.reserve ?? 20}% floor the grid carries the bit below it); by day it's mostly direct solar.
            </div>
          </Card>
          <Card>
            <div className="trend-rec-label">Usual mix by hour</div>
            <div className="seg-key" style={{ marginTop: 8 }}><b>Bar</b> = share of the house load · <b>line</b> = typical charge · highlighted = this hour</div>
            {loading && !hourData ? <window.Skeleton h={240} r={12} style={{ marginTop: 14 }} /> : hourData && hourData.hours && hourData.hours.length ? (
              <HourMixChart hours={hourData.hours} nowHour={new Date().getHours()} />
            ) : <div className="trend-empty">No data yet.</div>}
            <div className="trend-legend" style={{ marginTop: 12 }}>
              <span className="tl-item"><span className="tl-dot" style={{ background: C.pv }} />Solar</span>
              <span className="tl-item"><span className="tl-dot" style={{ background: C.batt }} />Battery</span>
              <span className="tl-item"><span className="tl-dot" style={{ background: C.grid }} />Grid</span>
              <span className="tl-item"><span className="tl-dash" style={{ borderColor: C.soc }} />Charge</span>
            </div>
            <div className="hint-line">
              What usually covers the house at each hour, over the last {hourData ? hourData.days : segDays} complete days. The cyan line is typical charge at that hour — the same number Live shows under the battery as <b>usually N%</b>.
            </div>
          </Card>
        </>
      )}

      {/* ---------- ENERGY: generated vs consumed, by day / month / season ---------- */}
      {view === 'energy' && (
        <Card>
          <div style={{ marginBottom: 10 }}>{genConsLegend}</div>
          {/* every control on this view sits right; .trend-subnav is space-between, so
              they need wrapping in one box to travel together */}
          <div className="trend-subnav" style={{ justifyContent: 'flex-end' }}>
            <div className="trend-ctl">
              <Segmented size="sm" value={kind} onChange={setKindSaved}
                options={[{ value: 'line', label: 'Line' }, { value: 'bar', label: 'Bar' }]} />
              <Segmented size="sm" value={gran} onChange={setGran} options={GRAN} />
            </div>
          </div>
          {gran === 'daily' && (
            <>
              <div className="trend-subnav" style={{ marginBottom: 8, justifyContent: 'flex-end' }}>
                <Segmented size="sm" value={dailyDays} onChange={setDailyDays} options={[{ value: 7, label: '7d' }, { value: 14, label: '14d' }, { value: 30, label: '30d' }]} />
              </div>
              {loading && !daily ? <ChartSkeleton /> : (
                <>
                  <TrendStats bars={dailyBars} unit="day" />
                  <Chart series={seriesFor(DAILY_SERIES)} labelEvery={dailyDays > 14 ? 3 : 1} bars={dailyBars} />
                </>
              )}
              <div className="hint-line">Solar generated, home consumption, and how much of it came off the grid, each day for the last {dailyDays} days. The dotted <b>Expected</b> line is what a typical day of yours converts from that day's sunshine — generation falls below it when the battery fills and the panels throttle, and rises above it on heavy-use days when nothing holds them back.</div>
            </>
          )}
          {gran === 'monthly' && (
            <>
              {loading && !monthly ? <ChartSkeleton /> : <><TrendStats bars={monthlyBars} unit="month" /><Chart series={seriesFor(SERIES)} bars={monthlyBars} /></>}
              <div className="hint-line">Solar generated vs home consumption per month across every year on record. One new point lands each month.</div>
            </>
          )}
          {gran === 'seasonal' && (
            <>
              {loading && !monthly ? <ChartSkeleton stats={false} /> : <Chart series={seriesFor(SERIES)} bars={seasonBars} />}
              <div className="hint-line">
                Generation vs consumption rolled into SA seasons (Summer Dec–Feb · Autumn Mar–May · Winter Jun–Aug · Spring Sep–Nov).
                <b> Sparse for now</b> — this only becomes meaningful with a full year of data, when winter-vs-summer solar (a big swing here) shows up. The logger is banking toward it.
              </div>
            </>
          )}
        </Card>
      )}
    </div>
  );
}

window.TrendsTab = TrendsTab;
