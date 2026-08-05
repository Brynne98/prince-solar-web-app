// ============================================================================
// trends.jsx — <TrendsTab/> : grouped by purpose into two views.
//   • Battery  — electricity used per day-segment (kWh), split by source (solar/
//                battery/grid). From our own logged data.
//   • Energy   — generated vs consumed, by Day / Month / Season (toggle). The sparse
//                Month/Season views live here until a year banks.
// Data: /api/trends/* (local log; daily/monthly from SunSynk).
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

// ---------- Reusable categorical bar chart — grouped series (daily / monthly / seasonal) ----------
// bars: [{ label, full, [key]: value, ... }]   series: [{ key, label, color }]
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
        <div className="trend-tip" style={{ left: hover > bars.length / 2 ? 8 : 'auto', right: hover > bars.length / 2 ? 'auto' : 8 }}>
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

function TrendStats({ bars, unit }) {
  if (!bars || !bars.length) return null;
  const C = window.COLORS, f = window.fmtKwh;
  const n = bars.length;
  const sum = (k) => bars.reduce((a, b) => a + (b[k] || 0), 0);
  const pv = sum('pv'), load = sum('load'), imp = sum('imp');
  const suff = load > 0 ? Math.round(((load - imp) / load) * 100) : null;
  return (
    <div className="trend-stats">
      <div><div className="ts-l">Generated</div><div className="ts-v mono" style={{ color: C.pv }}>{f(pv)}</div><div className="ts-sub">avg {f(pv / n)}/{unit}</div></div>
      <div><div className="ts-l">Consumed</div><div className="ts-v mono" style={{ color: C.load }}>{f(load)}</div><div className="ts-sub">avg {f(load / n)}/{unit}</div></div>
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

// SA (southern-hemisphere) seasons
const SEASONS = [
  { key: 'summer', label: 'Summer', months: [12, 1, 2] },
  { key: 'autumn', label: 'Autumn', months: [3, 4, 5] },
  { key: 'winter', label: 'Winter', months: [6, 7, 8] },
  { key: 'spring', label: 'Spring', months: [9, 10, 11] },
];
const MONTHS = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function TrendsTab({ refreshKey, auto, settings }) {
  const C = window.COLORS;
  const { Card, SectionTitle, Segmented } = window;
  const [view, setView] = React.useState('battery');   // battery | energy
  const [gran, setGran] = React.useState('daily');      // energy granularity: daily | monthly | seasonal
  const [dailyDays, setDailyDays] = React.useState(30);
  const [daily, setDaily] = React.useState(null);
  const [monthly, setMonthly] = React.useState(null);
  const [segData, setSegData] = React.useState(null);
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
    } else { // battery: per-segment usage split
      window.fetchSegments(segDays).then(done(setSegData)).catch(fail);
    }
    return () => { alive = false; };
  }, [view, gran, dailyDays, segDays, refreshKey, tick]);

  const dailyBars = React.useMemo(() => {
    const rows = daily || [];
    let i = 0; // trim leading pre-commission zero days
    while (i < rows.length && (rows[i].pv || 0) === 0 && (rows[i].load || 0) === 0) i++;
    return rows.slice(i).map((r) => ({ label: String(r.day), full: r.date, pv: r.pv, load: r.load, imp: r.imp }));
  }, [daily]);
  const monthlyBars = React.useMemo(() => (monthly || []).map((r) => ({
    label: MONTHS[r.month] + (r.year !== new Date().getFullYear() ? " '" + String(r.year).slice(2) : ''),
    full: MONTHS[r.month] + ' ' + r.year, pv: r.pv, load: r.load, imp: r.imp,
  })), [monthly]);
  const seasonBars = React.useMemo(() => {
    const acc = {};
    (monthly || []).forEach((r) => {
      const s = SEASONS.find((s) => s.months.includes(r.month)); if (!s) return;
      const a = acc[s.key] || (acc[s.key] = { pv: 0, load: 0, imp: 0, cnt: 0 });
      a.pv += r.pv; a.load += r.load; a.imp += (r.imp || 0); a.cnt += 1;
    });
    return SEASONS.map((s) => { const a = acc[s.key] || { pv: 0, load: 0, imp: 0, cnt: 0 }; return { label: s.label, full: s.label, pv: a.pv, load: a.load, imp: a.imp, sub: a.cnt + ' month(s) of data' }; });
  }, [monthly]);

  const SERIES = [{ key: 'pv', label: 'Generated', color: C.pv }, { key: 'load', label: 'Consumed', color: C.load }];
  const genConsLegend = (
    <div className="trend-legend">
      <span className="tl-item"><span className="tl-dot" style={{ background: C.pv }} />Generated</span>
      <span className="tl-item"><span className="tl-dot" style={{ background: C.load }} />Consumed</span>
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

      {/* ---------- BATTERY: per-segment usage split ---------- */}
      {view === 'battery' && (
        <>
          <Card>
            <div className="trend-subnav">
              <div className="trend-rec-label">Electricity used by time of day</div>
              <Segmented size="sm" value={segDays} onChange={setSegDays} options={[{ value: 7, label: '7d' }, { value: 14, label: '14d' }, { value: 30, label: '30d' }]} />
            </div>
            <div className="seg-key"><b>Bar length</b> = units used (kWh) — longer = more · <b>colours</b> = where it came from</div>
            {loading && !segData ? <div className="trend-empty">Loading…</div> : segData && segData.segments && segData.segments.length ? (
              <SegmentUsage data={segData.segments} />
            ) : <div className="trend-empty">No data yet.</div>}
            <div className="hint-line">
              Typical units (kWh) used in each part of the day over the last {segData ? segData.days : segDays} days, coloured by what supplied them. The <b>kW avg</b> alongside is the intensity — how hard you pull (the geysers are short but fierce). <b>At night the split is battery vs grid</b> (with your 20% floor the grid carries the bit below it); by day it's mostly direct solar.
            </div>
          </Card>
        </>
      )}

      {/* ---------- ENERGY: generated vs consumed, by day / month / season ---------- */}
      {view === 'energy' && (
        <Card>
          <div className="trend-subnav">
            {genConsLegend}
            <Segmented size="sm" value={gran} onChange={setGran} options={GRAN} />
          </div>
          {gran === 'daily' && (
            <>
              <div className="trend-subnav" style={{ justifyContent: 'flex-end', marginBottom: 8 }}>
                <Segmented size="sm" value={dailyDays} onChange={setDailyDays} options={[{ value: 14, label: '14d' }, { value: 30, label: '30d' }, { value: 60, label: '60d' }]} />
              </div>
              {loading && !daily ? <div className="trend-empty">Loading…</div> : (
                <>
                  <TrendStats bars={dailyBars} unit="day" />
                  <BarChart series={SERIES} labelEvery={dailyDays > 30 ? 5 : dailyDays > 14 ? 3 : 1} bars={dailyBars} />
                </>
              )}
              <div className="hint-line">Solar generated vs home consumption each day (SunSynk's daily totals, last {dailyDays} days). Hover a bar for the exact figures.</div>
            </>
          )}
          {gran === 'monthly' && (
            <>
              {loading && !monthly ? <div className="trend-empty">Loading…</div> : <><TrendStats bars={monthlyBars} unit="month" /><BarChart series={SERIES} bars={monthlyBars} /></>}
              <div className="hint-line">Solar generated vs home consumption per month across every year on record. One new bar lands each month.</div>
            </>
          )}
          {gran === 'seasonal' && (
            <>
              {loading && !monthly ? <div className="trend-empty">Loading…</div> : <BarChart series={SERIES} bars={seasonBars} />}
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
