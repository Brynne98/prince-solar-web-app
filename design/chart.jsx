// ============================================================================
// chart.jsx — <HistoryView/> : the scrutinised graph.
//   • Range: Day (5-min power) · Week · Month · Year (daily/monthly energy)
//   • Series toggles, hover crosshair + exact-value tooltip
//   • SOC on a right axis (shaded band)
//   • Mode: Lines  /  Power balance (stacked area: where power came from)
// Self-contained SVG; no external chart libs.
// ============================================================================

function useSize(minW = 320, minH = 360) {
  const ref = React.useRef(null);
  const [sz, setSz] = React.useState({ w: 960, h: minH });
  React.useLayoutEffect(() => {
    const el = ref.current; if (!el) return;
    const ro = new ResizeObserver(es => { for (const e of es) setSz({ w: Math.max(minW, e.contentRect.width), h: Math.max(minH, e.contentRect.height) }); });
    ro.observe(el); setSz({ w: Math.max(minW, el.clientWidth), h: Math.max(minH, el.clientHeight) });
    return () => ro.disconnect();
  }, []);
  return [ref, sz.w, sz.h];
}

const HM = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;

function HistoryView({ tariff, showSavings }) {
  const C = window.COLORS;
  const [range, setRange] = React.useState('day');
  const [mode, setMode] = React.useState('lines');     // lines | balance
  const [vis, setVis] = React.useState({ pv: true, batt: true, load: true, grid: true, soc: true });
  const [hover, setHover] = React.useState(null);
  const [ref, width, height] = useSize();

  const toggle = k => setVis(v => ({ ...v, [k]: !v[k] }));

  // ---------- data ----------
  const today = React.useMemo(() => window.simulateDay(20260529, 23 * 60 + 10), []);
  const days = React.useMemo(() => {
    if (range === 'week') return window.simulateDays(7, new Date(2026, 4, 29));
    if (range === 'month') return window.simulateDays(30, new Date(2026, 4, 29));
    if (range === 'year') {
      const all = window.simulateDays(365, new Date(2026, 4, 29));
      const by = {};
      all.forEach(d => {
        const k = d.date.slice(0, 7);
        if (!by[k]) by[k] = { key: k, label: d.monthLabel, pv: 0, load: 0, imp: 0, dischg: 0, chg: 0, n: 0 };
        const b = by[k]; b.pv += d.pv; b.load += d.load; b.imp += d.imp; b.dischg += d.dischg; b.chg += d.chg; b.n++;
      });
      return Object.values(by).map(b => ({
        ...b, day: b.label,
        pv: Math.round(b.pv), load: Math.round(b.load), imp: Math.round(b.imp),
        dischg: Math.round(b.dischg),
        selfSuff: Math.min(100, Math.round(((b.load - b.imp) / b.load) * 100)),
      }));
    }
    return null;
  }, [range]);

  const m = { l: 58, r: 56, t: 18, b: 38 };
  const innerW = Math.max(40, width - m.l - m.r);
  const innerH = height - m.t - m.b;

  // ============================ DAY (power) ============================
  function renderDay() {
    const pts = today.points;
    const real = pts.filter(p => p.pv != null);
    const lastIdx = real.length - 1;

    // y-left domain
    let lo = 0, hi = 100;
    real.forEach(p => {
      [vis.pv && p.pv, vis.load && p.load, vis.batt && p.batt, vis.grid && p.grid].forEach(v => {
        if (v === false || v == null) return; hi = Math.max(hi, v); lo = Math.min(lo, v);
      });
    });
    hi = Math.ceil(hi / 1000) * 1000 + 500; lo = Math.floor(lo / 1000) * 1000;
    const x = i => m.l + (i / lastIdx) * innerW;
    const y = v => m.t + innerH - ((v - lo) / (hi - lo)) * innerH;
    const ysoc = s => m.t + innerH - (s / 100) * innerH;

    const line = (key, color) => {
      let d = '';
      pts.forEach((p, i) => { if (p[key] == null) return; d += (d ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(p[key]).toFixed(1) + ' '; });
      return <path d={d} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" />;
    };

    const areaFill = (key, color) => {
      let d = '', started = false;
      for (let i = 0; i <= lastIdx; i++) { const p = pts[i]; if (p[key] == null) continue; d += (started ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(p[key]).toFixed(1) + ' '; started = true; }
      if (!started) return null;
      d += `L ${x(lastIdx).toFixed(1)} ${y(0).toFixed(1)} L ${x(0).toFixed(1)} ${y(0).toFixed(1)} Z`;
      return <path d={d} fill={color} fillOpacity="0.13" />;
    };

    // balance stacked areas
    function balance() {
      const areas = [];
      const stackArea = (getBands, sign) => {
        // getBands(p) => [{v,color}] stacked from zero outward
        const layers = getBands(pts[0]).map(() => []);
        // build cumulative paths
        const tops = pts.map(p => 0);
        let baseArr = pts.map(() => 0);
        getBands(pts[0]).forEach((_, li) => {
          const upper = pts.map((p, i) => {
            const bands = getBands(p); const val = bands[li] ? bands[li].v : 0;
            return baseArr[i] + val * sign;
          });
          let d = '';
          pts.forEach((p, i) => { if (p.pv == null) return; d += (d ? 'L' : 'M') + x(i).toFixed(1) + ' ' + y(upper[i]).toFixed(1) + ' '; });
          for (let i = pts.length - 1; i >= 0; i--) { if (pts[i].pv == null) continue; d += 'L' + x(i).toFixed(1) + ' ' + y(baseArr[i]).toFixed(1) + ' '; }
          d += 'Z';
          const col = getBands(pts[0])[li].color;
          areas.push(<path key={'a' + sign + li} d={d} fill={col} fillOpacity="0.55" stroke={col} strokeOpacity="0.5" strokeWidth="0.6" />);
          baseArr = upper;
        });
      };
      // consumption coverage (above 0): solar→load, battery discharge, grid import
      stackArea(p => {
        const bd = p.batt < 0 ? -p.batt : 0, gi = p.grid > 0 ? p.grid : 0;
        const sl = Math.max(0, p.load - bd - gi);
        return [{ v: sl, color: C.pv }, { v: bd, color: C.batt }, { v: gi, color: C.grid }];
      }, 1);
      // surplus disposal (below 0): battery charge (excess solar is curtailed, never exported)
      stackArea(p => {
        const bc = p.batt > 0 ? p.batt : 0;
        return [{ v: bc, color: C.batt }];
      }, -1);
      return areas;
    }

    // SOC band
    let socD = '', socArea = '';
    if (vis.soc) {
      pts.forEach((p, i) => { if (p.soc == null) return; socD += (socD ? 'L' : 'M') + x(i).toFixed(1) + ' ' + ysoc(p.soc).toFixed(1) + ' '; });
      socArea = socD + `L ${x(lastIdx)} ${m.t + innerH} L ${x(0)} ${m.t + innerH} Z`;
    }

    // axes
    const yticks = []; const stepY = (hi - lo) / 5;
    for (let i = 0; i <= 5; i++) { const v = lo + stepY * i; yticks.push(v); }
    const nowMin = pts[lastIdx].t;
    const xticks = [];
    for (let t = 0; t <= nowMin; t += 180) xticks.push(t);
    if (nowMin - (xticks[xticks.length - 1] || 0) > 75) xticks.push(nowMin);

    const hp = hover != null ? pts[hover] : null;
    return (
      <svg width={width} height={height} className="chart-svg"
        onMouseLeave={() => setHover(null)}
        onMouseMove={e => {
          const r = e.currentTarget.getBoundingClientRect();
          const mx = e.clientX - r.left;
          let i = Math.round(((mx - m.l) / innerW) * lastIdx);
          i = Math.max(0, Math.min(lastIdx, i));
          setHover(i);
        }}>
        <defs>
          <clipPath id="plotclip"><rect x={m.l} y={m.t - 8} width={innerW} height={innerH + 16} /></clipPath>
        </defs>
        {/* gridlines */}
        {yticks.map((v, i) => (
          <g key={'gy' + i}>
            <line x1={m.l} x2={m.l + innerW} y1={y(v)} y2={y(v)} stroke="rgba(255,255,255,0.05)" />
            <text x={m.l - 10} y={y(v) + 3} textAnchor="end" className="ax">{+(v / 1000).toFixed(1)}</text>
          </g>
        ))}
        {vis.soc && [0, 50, 100].map(s => (
          <text key={'sc' + s} x={m.l + innerW + 10} y={ysoc(s) + 3} className="ax" fill={C.soc} fillOpacity="0.7">{s}</text>
        ))}
        {xticks.map(t => (
          <text key={'gx' + t} x={x(t / 5)} y={m.t + innerH + 22} textAnchor="middle" className="ax">{HM(t)}</text>
        ))}
        <line x1={m.l} x2={m.l + innerW} y1={y(0)} y2={y(0)} stroke="rgba(255,255,255,0.16)" />

        {/* SOC line only (no fill under SOC) */}
        {vis.soc && <path d={socD} fill="none" stroke={C.soc} strokeWidth="1.8" strokeOpacity="0.8" />}

        {mode === 'balance' ? balance() : (
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
        )}

        {/* crosshair */}
        {hp && (
          <g>
            <line x1={x(hover)} x2={x(hover)} y1={m.t} y2={m.t + innerH} stroke="rgba(255,255,255,0.25)" />
            {mode === 'lines' && ['pv', 'load', 'batt', 'grid'].filter(k => vis[k] && hp[k] != null).map(k => (
              <circle key={k} cx={x(hover)} cy={y(hp[k])} r="3.5" fill={C[k]} stroke="#0b0e12" strokeWidth="1.5" />
            ))}
            {vis.soc && hp.soc != null && <circle cx={x(hover)} cy={ysoc(hp.soc)} r="3" fill={C.soc} stroke="#0b0e12" strokeWidth="1.5" />}
          </g>
        )}
      </svg>
    );
  }

  // ============================ WEEK/MONTH/YEAR (energy bars) ============================
  function renderBars() {
    const data = days;
    const n = data.length;
    const maxLoad = Math.max(...data.map(d => Math.max(d.load, d.pv)), 1);
    const hi = Math.ceil(maxLoad / 5) * 5;
    const bw = Math.min(54, (innerW / n) * 0.6);
    const x = i => m.l + (i + 0.5) * (innerW / n);
    const y = v => m.t + innerH - (v / hi) * innerH;
    const ysuff = s => m.t + innerH - (s / 100) * innerH;
    const R = Math.min(7, bw / 2), GAP = 2.5;

    const yticks = []; for (let i = 0; i <= 4; i++) yticks.push((hi / 4) * i);
    let suffD = '';
    data.forEach((d, i) => { suffD += (suffD ? 'L' : 'M') + x(i).toFixed(1) + ' ' + ysuff(d.selfSuff).toFixed(1) + ' '; });

    // rounded-rect path with independent top/bottom corner radii
    const seg = (xx, yy, w, h, rt, rb) => {
      rt = Math.max(0, Math.min(rt, w / 2, h)); rb = Math.max(0, Math.min(rb, w / 2, h));
      return `M ${xx} ${yy + rt} Q ${xx} ${yy} ${xx + rt} ${yy} L ${xx + w - rt} ${yy} Q ${xx + w} ${yy} ${xx + w} ${yy + rt} L ${xx + w} ${yy + h - rb} Q ${xx + w} ${yy + h} ${xx + w - rb} ${yy + h} L ${xx + rb} ${yy + h} Q ${xx} ${yy + h} ${xx} ${yy + h - rb} Z`;
    };

    return (
      <svg width={width} height={height} className="chart-svg" onMouseLeave={() => setHover(null)}>
        <defs>
          {[['gpv', C.pv], ['gbatt', C.batt], ['ggrid', C.grid]].map(([id, c]) => (
            <linearGradient key={id} id={id} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={c} stopOpacity="1" />
              <stop offset="100%" stopColor={c} stopOpacity="0.5" />
            </linearGradient>
          ))}
        </defs>
        {yticks.map((v, i) => (
          <g key={i}>
            <line x1={m.l} x2={m.l + innerW} y1={y(v)} y2={y(v)} stroke="rgba(255,255,255,0.05)" />
            <text x={m.l - 10} y={y(v) + 3} textAnchor="end" className="ax">{Math.round(v)}</text>
          </g>
        ))}
        {vis.soc && [0, 50, 100].map(s => <text key={s} x={m.l + innerW + 10} y={ysuff(s) + 3} className="ax" fill={C.soc} fillOpacity="0.7">{s}%</text>)}

        {data.map((d, i) => {
          const bd = d.dischg, gi = d.imp;
          const sl = Math.max(0, d.load - bd - gi);
          const segs = [{ v: sl, g: 'gpv' }, { v: bd, g: 'gbatt' }, { v: gi, g: 'ggrid' }].filter(s => s.v > 0.05);
          let base = 0; const hovered = hover === i; const last = segs.length - 1;
          return (
            <g key={i} onMouseEnter={() => setHover(i)}>
              <rect x={x(i) - (innerW / n) / 2} y={m.t} width={innerW / n} height={innerH} fill={hovered ? 'rgba(255,255,255,0.05)' : 'transparent'} rx="7" />
              {segs.map((s, si) => {
                const h = (s.v / hi) * innerH; const yT = y(base + s.v); base += s.v;
                const isTop = si === last, isBot = si === 0;
                const hh = Math.max(1, h - (isTop ? 0 : GAP));
                return <path key={si} d={seg(x(i) - bw / 2, yT, bw, hh, isTop ? R : 0, isBot ? R : 0)} fill={`url(#${s.g})`} opacity={hovered ? 1 : 0.92} />;
              })}
              <text x={x(i)} y={m.t + innerH + 22} textAnchor="middle" className={'ax' + (hovered ? ' ax-hi' : '')}>{range === 'month' ? (i % 3 === 0 ? d.day : '') : (range === 'year' ? d.day : d.label)}</text>
            </g>
          );
        })}
        {vis.soc && <path d={suffD} fill="none" stroke={C.soc} strokeWidth="6" strokeOpacity="0.12" strokeLinejoin="round" strokeLinecap="round" />}
        {vis.soc && <path d={suffD} fill="none" stroke={C.soc} strokeWidth="2.4" strokeLinejoin="round" strokeLinecap="round" />}
        {vis.soc && data.map((d, i) => <circle key={i} cx={x(i)} cy={ysuff(d.selfSuff)} r={hover === i ? 4.5 : 2.4} fill={hover === i ? C.soc : 'var(--bg)'} stroke={C.soc} strokeWidth="1.6" />)}
      </svg>
    );
  }

  // ---------- tooltip ----------
  function tooltip() {
    if (hover == null) return null;
    if (range === 'day') {
      const p = today.points[hover]; if (!p || p.pv == null) return null;
      const li = today.points.filter(p => p.pv != null).length - 1; const px = m.l + (hover / li) * innerW;
      const left = Math.min(width - 188, Math.max(8, px + 14));
      const rows = [
        ['Solar', p.pv, C.pv, 'W'],
        ['Battery', Math.abs(p.batt), C.batt, 'W'],
        ['Grid', Math.max(0, p.grid), C.grid, 'W'],
        ['Load', p.load, C.load, 'W'],
        ['Charge', p.soc, C.soc, '%'],
      ];
      return (
        <div className="chart-tip" style={{ left, top: 24 }}>
          <div className="tip-time">{HM(p.t)}</div>
          {rows.map(([l, v, c, u]) => (
            <div className="tip-row" key={l}><span className="tip-dot" style={{ background: c }} /><span className="tip-l">{l}</span>
              <span className="tip-v mono">{u === 'W' ? window.fmtPower(v) : v + ' ' + u}</span></div>
          ))}
        </div>
      );
    }
    const d = days[hover]; if (!d) return null;
    const px = m.l + (hover + 0.5) * (innerW / days.length);
    const left = Math.min(width - 200, Math.max(8, px - 90));
    const rows = [['Generated', d.pv, C.pv], ['Consumed', d.load, C.load], ['Imported', d.imp, C.grid], ['Self-suff.', d.selfSuff + '%', C.soc, true]];
    return (
      <div className="chart-tip" style={{ left, top: 24 }}>
        <div className="tip-time">{range === 'year' ? d.day : (d.date || d.label)}</div>
        {rows.map(([l, v, c, pct]) => (
          <div className="tip-row" key={l}><span className="tip-dot" style={{ background: c }} /><span className="tip-l">{l}</span>
            <span className="tip-v mono">{pct ? v : window.fmtKwh(v)}</span></div>
        ))}
      </div>
    );
  }

  // ---------- range summary ----------
  const summary = React.useMemo(() => {
    if (range === 'day') {
      const t = today.totals; return { pv: t.pv, load: t.load, imp: t.imp,
        suff: Math.min(100, Math.round(((t.load - t.imp) / t.load) * 100)) };
    }
    const s = days.reduce((a, d) => ({ pv: a.pv + d.pv, load: a.load + d.load, imp: a.imp + d.imp }), { pv: 0, load: 0, imp: 0 });
    s.suff = Math.min(100, Math.round(((s.load - s.imp) / s.load) * 100));
    return s;
  }, [range, days, today]);
  const saved = (summary.load - summary.imp) * tariff.import;
  const gridCost = summary.imp * tariff.import;

  const legend = [['pv', 'Solar', C.pv], ['batt', 'Battery', C.batt], ['grid', 'Grid', C.grid], ['load', 'Load', C.load], ['soc', 'Charge', C.soc]];

  return (
    <div className="hv-root">
      {/* legend + mode toggle (inline, toggle right) */}
      <div className="legend-row">
        {legend.map(([k, l, c]) => <window.LegendChip key={k} color={c} label={l} active={vis[k]} onClick={() => toggle(k)} />)}
        <span className="legend-mode">
          <window.Segmented size="sm" options={[{ value: 'lines', label: 'Lines' }, { value: 'balance', label: 'Power balance' }]} value={mode} onChange={setMode} />
          <window.InfoDot text="“Power balance” stacks how each moment’s load was covered — solar, then battery, then grid. Below the zero line is surplus solar charging the battery." />
        </span>
      </div>

      {/* plot */}
      <div className="chart-area" ref={ref} style={{ position: 'relative' }}>
        {range === 'day' ? renderDay() : renderBars()}
        {tooltip()}
      </div>
    </div>
  );
}

function SumCell({ label, value, color, sub }) {
  return (
    <div className="sum-cell">
      <div className="sum-label">{label}</div>
      <div className="sum-value mono" style={{ color }}>{value}</div>
      {sub && <div className="sum-sub">{sub}</div>}
    </div>
  );
}

window.HistoryView = HistoryView;
