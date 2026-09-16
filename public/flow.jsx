// ============================================================================
// flow.jsx — <PowerFlow/> : live energy flow.  Grid · Solar · Battery → Inverter(s) → Home.
// Desktop: wide horizontal layout. Phones: a compact VERTICAL layout (sources on
// top → inverter → home) so it fits the screen and stays legible. The status line
// + chips below are shared (chips wrap 2×2 on mobile via CSS).
// ============================================================================

// 900, not 600: the wide layout is one scaled SVG, and at tablet widths its text
// shrank to about 7px. Tablets get the stacked layout, which keeps real type sizes.
function useFlowMobile(bp = 900) {
  const [mobile, setMobile] = React.useState(
    () => typeof window !== 'undefined' && window.matchMedia(`(max-width:${bp}px)`).matches
  );
  React.useEffect(() => {
    const mq = window.matchMedia(`(max-width:${bp}px)`);
    const h = (e) => setMobile(e.matches);
    mq.addEventListener('change', h);
    return () => mq.removeEventListener('change', h);
  }, []);
  return mobile;
}

// node colours are hex; cards tint and outline with them at the same strengths everywhere
function flowAlpha(hex, a) {
  const h = String(hex).replace('#', '');
  return `rgba(${parseInt(h.slice(0, 2), 16)},${parseInt(h.slice(2, 4), 16)},${parseInt(h.slice(4, 6), 16)},${a})`;
}

function PowerFlow({ agg, inverters, battInfo, onBattInfo, typicalSoc, typicalHour, features }) {
  const C = window.COLORS;
  const mobile = useFlowMobile();
  const feat = features || {};
  const hasBatt = feat.hasBattery !== false;
  const hasGrid = feat.hasGrid !== false;
  const charging = agg.battState === 'charging';
  const gridImport = agg.gridPower > 0 ? agg.gridPower : 0;
  // Export only exists for plants paid to sell (a feed-in rate is set). Every
  // grid-tied inverter leaks a few hundred watts of backflow when the load drops
  // faster than it can throttle; on a site that cannot sell that reads as standby.
  const sells = feat.sells === true;
  const gridExport = sells && agg.gridPower < 0 ? -agg.gridPower : 0;
  const hh = (h) => String(h).padStart(2, '0') + ':00';
  // The usual charge at this hour is hover text on the battery's charge %.
  const usualTitle = typicalSoc != null
    ? 'Usually ' + typicalSoc + '% at ' + (typicalHour != null ? hh(typicalHour) : 'this hour') + ' over complete days'
    : undefined;

  // Detail under each card: one labelled figure ({ k: label, v: value, on: click }),
  // the label small and uppercase, the value in mono, so every card reads the same way.
  const today = v => (v != null ? { k: 'Today', v: Number(v).toFixed(1) + ' kWh' } : null);
  // battInfo arrives as "3h 40m to empty" / "1h 55m to full" / "Set pack size"; no time while idle
  const battRow = (() => {
    const m = battInfo && /^(.*) to (empty|full)$/.exec(battInfo);
    if (m) return { k: m[2] === 'empty' ? 'Empty in' : 'Full in', v: m[1] };
    if (battInfo) return { k: 'Time left', v: battInfo, on: onBattInfo };
    return { k: 'Idle', v: '' };
  })();
  // Sources: only what the plant has. Grid flows both ways — an export runs the
  // animation back towards the grid node. Each card: label, value, then one detail figure.
  const left = [
    { key: 'pv', label: 'Solar', color: C.pv, w: agg.pvNow, icon: 'sun', row: today(agg.pvToday) },
    // w stays the magnitude (animation, stroke); val is the signed figure printed on the node,
    // always + = charging; Settings → Display applies everywhere except here.
    // The charge % sits at the foot of the card, big, beside a strip filled to the same level.
    hasBatt && { key: 'bat', label: 'Battery', color: C.batt, w: agg.battPower, val: window.battShown(agg.battOut, 'charge'), icon: 'battery', soc: agg.battSoc, reverse: charging,
      charge: agg.battSoc, row: battRow },
    // bought from the grid today; zero on most days, and that is worth seeing too
    hasGrid && { key: 'grid', label: 'Grid', color: C.grid, w: gridExport > 5 ? gridExport : gridImport, icon: 'bolt', reverse: gridExport > 5, row: today(agg.gridFromToday ?? 0) },
  ].filter(Boolean);

  // Where the home's power is coming from right now: the battery only while discharging,
  // the grid only while importing, solar whatever is left (never more than it is making).
  const battIn = hasBatt && !charging && agg.battPower > 5 ? agg.battPower : 0;
  const gridIn = hasGrid ? gridImport : 0;
  const solarIn = Math.max(0, Math.min(agg.pvNow, agg.loadNow - battIn - gridIn));
  const split = [
    { label: 'Solar', color: C.pv, w: solarIn },
    { label: 'Battery', color: C.batt, w: battIn },
    { label: 'Grid', color: C.grid, w: gridIn },
  ].filter(s => s.w > 5);
  const splitTotal = split.reduce((a, s) => a + s.w, 0);
  split.forEach(s => { s.pct = Math.round((s.w / splitTotal) * 100); });
  const home = { label: 'Home', color: C.load, w: agg.loadNow, row: today(agg.loadToday) };

  const CEIL = 8000, MAXTH = 30;
  const th = w => Math.max(3.5, Math.min(MAXTH, (w / CEIL) * MAXTH + 3.5));
  const valKW = w => (w / 1000).toFixed(2);

  // One look for every line, desktop and phone: a soft band with dots moving along it,
  // faster with more power. `fixed` is the phone: widths stay in screen pixels where the
  // drawing is stretched to fit (preserveAspectRatio="none"), and the band is slimmer.
  const flowLine = (d, color, w, key, reverse, fixed) => {
    const active = w > 5;
    const dur = Math.max(0.9, 3.2 - (Math.min(w, CEIL) / CEIL) * 2.3);
    const ve = fixed ? 'non-scaling-stroke' : undefined;
    return (
      <g key={key}>
        <path d={d} fill="none" stroke={active ? color : 'rgba(255,255,255,0.08)'}
          strokeOpacity={active ? 0.16 : 1} strokeWidth={active ? (fixed ? 6 : 11) : (fixed ? 2 : 2.5)} strokeLinecap="round" vectorEffect={ve} />
        {active && (
          <path d={d} fill="none" stroke={color} strokeOpacity="1" strokeWidth={fixed ? 2.2 : 2.8}
            strokeDasharray="2 13" strokeLinecap="round" vectorEffect={ve}
            style={{ animation: `flow ${dur}s linear infinite ${reverse ? 'reverse' : 'normal'}` }} />
        )}
      </g>
    );
  };

  // node icons (kept simple & monoline)
  const icon = (type, cx, cy, color, active, soc) => {
    const o = active ? 1 : 0.5;
    if (type === 'sun') {
      const rays = [];
      for (let a = 0; a < 360; a += 45) {
        const r = a * Math.PI / 180;
        rays.push(<line key={a} x1={cx + Math.cos(r) * 6.5} y1={cy + Math.sin(r) * 6.5} x2={cx + Math.cos(r) * 9} y2={cy + Math.sin(r) * 9} />);
      }
      return <g stroke={color} strokeWidth="1.5" strokeLinecap="round" opacity={o}><circle cx={cx} cy={cy} r="4.2" fill={active ? color : 'none'} fillOpacity={active ? 0.45 : 0} />{rays}</g>;
    }
    if (type === 'battery') {
      const lvl = Math.max(0, Math.min(1, (soc || 0) / 100));
      return (
        <g opacity={o}>
          <rect x={cx - 9.5} y={cy - 6.5} width="16" height="13" rx="3.2" fill="none" stroke={color} strokeWidth="1.6" />
          <rect x={cx + 7} y={cy - 3} width="3" height="6" rx="1.4" fill={color} />
          <rect x={cx - 7.3} y={cy - 4.1} width={lvl * 12} height="8.2" rx="1.6" fill={color} />
        </g>
      );
    }
    if (type === 'bolt') {
      const d = `M ${cx + 2} ${cy - 8} L ${cx - 5} ${cy + 1.5} L ${cx - 0.5} ${cy + 1.5} L ${cx - 1.5} ${cy + 8} L ${cx + 5.5} ${cy - 2} L ${cx + 1} ${cy - 2} Z`;
      return <path d={d} fill={color} fillOpacity={active ? 0.22 : 0} stroke={color} strokeWidth="1.5" strokeLinejoin="round" opacity={o} />;
    }
    if (type === 'home') {
      const d = `M ${cx - 8} ${cy + 8} L ${cx - 8} ${cy - 2} L ${cx} ${cy - 10} L ${cx + 8} ${cy - 2} L ${cx + 8} ${cy + 8} Z`;
      return (
        <g opacity={o}>
          <path d={d} fill={active ? color : 'none'} fillOpacity={active ? 0.18 : 0} stroke={color} strokeWidth="1.5" strokeLinejoin="round" />
          <rect x={cx - 2.2} y={cy + 1} width="4.4" height="4.4" rx="0.6" fill="none" stroke={color} strokeWidth="1.2" />
        </g>
      );
    }
    return <rect x={cx - 7} y={cy - 7} width="14" height="14" rx="3.5" fill={active ? color : 'none'} stroke={color} strokeWidth="1.6" opacity={o} />;
  };

  const defs = (
    <defs>
      <pattern id="flgrid" width="28" height="28" patternUnits="userSpaceOnUse">
        <circle cx="1.2" cy="1.2" r="1.2" fill="rgba(255,255,255,0.035)" />
      </pattern>
      <filter id="flglow" x="-60%" y="-60%" width="220%" height="220%">
        <feGaussianBlur stdDeviation="2.6" result="b" />
        <feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
      </filter>
    </defs>
  );

  // ---------------- DESKTOP (wide, horizontal) ----------------
  function renderDesktop() {
    // Source cards and Home are 96 high: label, value, detail, and the battery's charge foot.
    // Fewer sources sit centred on the same slots.
    const nodeW = 184, nodeH = 96, nx = -76, ny = -nodeH / 2;
    const pitch = nodeH + 16, top0 = 58 + nodeH / 2;
    const W = 980, H = 58 + 3 * nodeH + 2 * 16 + 20;
    const invX = 490, invY = top0 + pitch;
    // Cards grow right so the left edge (and the SOURCES column) stay put.
    const srcX = 150, homeX = W - 150;
    const sy = left.map((_, i) => top0 + i * pitch + ((3 - left.length) * pitch) / 2);
    const srcRight = srcX + nx + nodeW;
    const srcMid = srcX + nx + nodeW / 2;

    const link = (x1, y1, x2, y2, color, w, key, reverse) => {
      const mx = (x1 + x2) / 2;
      return flowLine(`M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`, color, w, key, reverse);
    };

    // a detail figure: small uppercase label, then the value in mono
    const kv = (r, x, y) => r && (r.on
      // a prompt that leads somewhere ("Set pack size"): clickable and keyboard-reachable
      ? <text x={x} y={y} className="flow-sub flow-link" role="link" tabIndex={0} onClick={r.on}
          onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); r.on(); } }}>
          <tspan className="flow-kv-k">{r.k.toUpperCase()}</tspan><tspan dx="6" className="flow-kv-v">{r.v}</tspan>
        </text>
      : <text x={x} y={y} className="flow-sub">
          <tspan className="flow-kv-k">{r.k.toUpperCase()}</tspan>{r.v && <tspan dx="6" className="flow-kv-v">{r.v}</tspan>}
        </text>);

    const sideNode = (n, i) => {
      const active = n.w > 5;
      const ly = ny + 22, vy = ny + 47;
      return (
        <g key={n.key} transform={`translate(${srcX},${sy[i]})`}>
          {active && <rect x={nx} y={ny} width={nodeW} height={nodeH} rx={15} fill={n.color} opacity="0.07" />}
          <rect x={nx} y={ny} width={nodeW} height={nodeH} rx={15} fill="rgba(255,255,255,0.015)"
            stroke={n.color} strokeOpacity={active ? 0.6 : 0.22} strokeWidth="1.3" filter={active ? 'url(#flglow)' : undefined} />
          {icon(n.icon, -56, vy - 7, n.color, active, n.soc)}
          <text x={-36} y={ly} className="flow-node-label">{n.label.toUpperCase()}</text>
          <text x={-36} y={vy} className="flow-node-val" fill={active ? n.color : 'var(--muted)'} textAnchor="start">{valKW(n.val ?? n.w)}<tspan className="flow-node-unit"> kW</tspan></text>
          {kv(n.row, -36, ny + 67)}
          {n.charge != null && (
            <g>
              {usualTitle && <title>{usualTitle}</title>}
              <rect x={-36} y={ny + 79} width={84} height={5} rx={2.5} fill="rgba(255,255,255,0.08)" />
              <rect x={-36} y={ny + 79} width={(84 * Math.max(0, Math.min(100, n.charge))) / 100} height={5} rx={2.5} fill={n.color} />
              <text x={nx + nodeW - 14} y={ny + 87} textAnchor="end" className="flow-pct" fill={n.color} style={{ fontSize: 17 }}>{n.charge}%</text>
            </g>
          )}
        </g>
      );
    };
    const homeActive = home.w > 5;
    // the split bar under Home: one segment per source feeding it, 2 apart
    const splitBar = 130;
    let sx = -52;
    const splitW = splitBar - 2 * Math.max(0, split.length - 1);

    return (
      <svg viewBox={`48 20 884 ${H - 20}`} className="flow-svg" preserveAspectRatio="xMidYMid meet">
        {defs}
        <rect x="0" y="58" width={W} height={H - 58} fill="url(#flgrid)" />
        {left.map((n, i) => link(srcRight + 12, sy[i], invX - 60, invY + (sy[i] - invY) * 0.2, n.color, n.w, 'l' + n.key, n.reverse))}
        {link(invX + 60, invY, homeX - 104, invY, home.color, home.w, 'lhome', false)}
        <circle cx={invX} cy={invY} r={47} fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.24)" strokeWidth="1.3" />
        <circle cx={invX} cy={invY} r={47} fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth="8" />
        <g transform={`translate(${invX}, ${invY})`} strokeLinecap="round">
          <line x1={0} y1={-20} x2={0} y2={20} stroke="var(--text)" strokeOpacity="0.16" strokeWidth="1.2" />
          <line x1={-24} y1={-4} x2={-8} y2={-4} stroke="var(--soc)" strokeWidth="2.2" />
          <line x1={-22} y1={4} x2={-10} y2={4} stroke="var(--soc)" strokeWidth="2.2" strokeDasharray="3 3" />
          <path d="M 7 3 q 5 -11 9.5 0 q 4.5 11 9.5 0" stroke={C.pv} strokeWidth="2.2" fill="none" />
        </g>
        <text x={invX} y={invY - 62} textAnchor="middle" className="flow-inv-label">INVERTER{inverters > 1 ? 'S' : ''}</text>
        {/* Home is as wide as the source cards, so the split in words fits under its bar */}
        <g transform={`translate(${homeX},${invY})`}>
          {homeActive && <rect x={-92} y={-58} width={184} height={116} rx={15} fill={home.color} opacity="0.07" />}
          <rect x={-92} y={-58} width={184} height={116} rx={15} fill="rgba(255,255,255,0.015)"
            stroke={home.color} strokeOpacity="0.6" strokeWidth="1.3" filter={homeActive ? 'url(#flglow)' : undefined} />
          {icon('home', -72, -18, home.color, homeActive)}
          <text x={-52} y={-36} className="flow-node-label">HOME</text>
          <text x={-52} y={-11} className="flow-node-val" fill={home.color} textAnchor="start">{valKW(home.w)}<tspan className="flow-node-unit"> kW</tspan></text>
          {kv(home.row, -52, 8)}
          {/* where it is coming from: the bar, and the same split in words under it */}
          <rect x={-52} y={19} width={splitBar} height={5} rx={2.5} fill="rgba(255,255,255,0.08)" />
          {split.map(s => {
            const w = (splitW * s.w) / splitTotal;
            const el = <rect key={s.label} x={sx} y={19} width={w} height={5} rx={2.5} fill={s.color} />;
            sx += w + 2;
            return el;
          })}
          <text x={-52} y={40} className="flow-sub">
            {/* three sources: the colours already match the bar, so just the shares */}
            {split.map((s, j) => <tspan key={s.label} dx={j ? 8 : 0} fill={s.color}>{split.length > 2 ? '' : s.label + ' '}{s.pct}%</tspan>)}
          </text>
        </g>
        {left.map(sideNode)}
        <text x={srcMid} y={32} textAnchor="middle" className="flow-col-title">SOURCES</text>
        <text x={homeX} y={32} textAnchor="middle" className="flow-col-title">CONSUMER</text>
      </svg>
    );
  }

  // ---------------- MOBILE (vertical, card-style HTML nodes) ----------------
  function renderMobile() {
    const homeActive = home.w > 5;
    // tile x-centres as %: the tiles share the row equally, however many sources the plant has
    const cols = left.map((_, i) => ((i + 0.5) / left.length) * 100);
    const miniIcon = (type, color, soc) => (
      <svg width="17" height="17" viewBox="-11 -11 22 22">{icon(type, 0, 0, color, true, soc)}</svg>
    );

    const mTile = (n) => {
      const active = n.w > 5;
      return (
        <div className="mtile" key={n.key}
          // same outline and tint strengths as the desktop cards
          style={{ borderColor: flowAlpha(n.color, active ? 0.6 : 0.22), background: active ? flowAlpha(n.color, 0.07) : undefined }}>
          <div className="mtile-head">
            {miniIcon(n.icon, n.color, n.soc)}
            <span className="mtile-label">{n.label}</span>
          </div>
          <div className="mtile-val" style={{ color: active ? n.color : 'var(--muted)' }}>{valKW(n.val ?? n.w)}<span className="u">kW</span></div>
          {n.row && (
            <div className="mtile-kv">
              <span>{n.row.k}</span>
              {n.row.on ? <button type="button" className="mini-link" onClick={n.row.on}>{n.row.v}</button> : n.row.v && <b>{n.row.v}</b>}
            </div>
          )}
          {n.charge != null && (
            <div className="mtile-charge" title={usualTitle}>
              <span className="mtile-strip"><i style={{ width: Math.max(0, Math.min(100, n.charge)) + '%', background: n.color }} /></span>
              <b style={{ color: n.color }}>{n.charge}%</b>
            </div>
          )}
        </div>
      );
    };

    // Like desktop: each line starts a gap below its tile and stops a gap short of the
    // inverter, spread out rather than merging into one point.
    const linkStrip = (
      <svg className="mflow-links" viewBox="0 0 100 72" preserveAspectRatio="none">
        {left.map((n, i) => {
          const sx = cols[i];
          const ex = 50 + (sx - 50) * 0.2;
          return flowLine(`M ${sx} 12 C ${sx} 40, ${ex} 32, ${ex} 60`, n.color, n.w, n.key, n.reverse, true);
        })}
      </svg>
    );

    return (
      <div className="mflow">
        <div className="mflow-sources" style={{ gridTemplateColumns: `repeat(${left.length}, minmax(0, 1fr))` }}>{left.map(mTile)}</div>

        {linkStrip}

        <div className="mflow-inv">
          <svg width="84" height="84" viewBox="-42 -42 84 84">
            <circle r="40" fill="rgba(255,255,255,0.04)" stroke="rgba(255,255,255,0.16)" strokeWidth="1.3" />
            <g strokeLinecap="round">
              <line x1="0" y1="-17" x2="0" y2="17" stroke="var(--text)" strokeOpacity="0.16" strokeWidth="1.2" />
              <line x1="-20" y1="-4" x2="-7" y2="-4" stroke="var(--soc)" strokeWidth="2.4" />
              <line x1="-18" y1="4" x2="-9" y2="4" stroke="var(--soc)" strokeWidth="2.4" strokeDasharray="3 3" />
              <path d="M 6 3 q 5 -12 10 0 q 5 12 10 0" stroke={C.pv} strokeWidth="2.4" fill="none" />
            </g>
          </svg>
          <div className="mflow-inv-label">INVERTER{inverters > 1 ? 'S' : ''}</div>
        </div>

        <svg className="mflow-down" viewBox="0 0 10 100" preserveAspectRatio="none">
          {flowLine('M 5 21 L 5 79', home.color, home.w, 'home', false, true)}
        </svg>

        <div className="mflow-home"
          style={{ borderColor: flowAlpha(home.color, 0.6), background: homeActive ? flowAlpha(home.color, 0.07) : undefined }}>
          <svg width="22" height="22" viewBox="-12 -12 24 24">{icon('home', 0, 0, home.color, homeActive)}</svg>
          <div className="mflow-home-text">
            <span className="mflow-home-label">HOME</span>
            <span className="mflow-home-val" style={{ color: home.color }}>{valKW(home.w)}<span className="u">kW</span></span>
          </div>
          {home.row && <div className="mflow-home-today mtile-kv"><span>{home.row.k}</span><b>{home.row.v}</b></div>}
          <div className="mflow-split">
            {split.map(s => <i key={s.label} style={{ flexGrow: s.w, background: s.color }} />)}
          </div>
          <div className="mflow-split-words">
            {split.map(s => <span key={s.label} style={{ color: s.color }}>{s.label} {s.pct}%</span>)}
          </div>
        </div>
      </div>
    );
  }

  // The one-line summary of what is happening; it opens the card, above the diagram.
  let narrative;
  if (gridExport > 50) narrative = <><b style={{ color: C.pv }}>Solar</b> is covering the home{hasBatt && charging ? ', charging the battery' : ''} and sending <b style={{ color: C.grid }}>{valKW(gridExport)} kW</b> to the grid.</>;
  // >= home - 50, not > home + 50: a home drawing exactly what the panels make is the
  // commonest sunny-afternoon state and fell through to the vague fallback.
  else if (agg.pvNow > 50 && agg.pvNow >= home.w - 50) narrative = <><b style={{ color: C.pv }}>Solar</b> is covering the home{hasBatt && charging ? ' and charging the battery' : ''}.</>;
  // Solar can still be making something here, just less than the home draws, so only
  // leave it out when it is effectively zero.
  else if (hasBatt && agg.battPower > 5 && !charging && gridImport < 50) narrative = agg.pvNow > 50
    ? <><b style={{ color: C.pv }}>Solar</b> and your <b style={{ color: C.batt }}>battery</b> are powering the home.</>
    : <>Your <b style={{ color: C.batt }}>battery</b> is powering the home.</>;
  else if (gridImport > 50) narrative = <>Pulling <b style={{ color: C.grid }}>{valKW(gridImport)} kW</b> from the grid to meet demand.</>;
  else if (!hasGrid && agg.pvNow < 50) narrative = <>Off-grid, after dark — the home is running on <b style={{ color: C.batt }}>stored energy</b>.</>;
  else if (!hasBatt) narrative = <><b style={{ color: C.pv }}>Solar</b> covers what it can; the grid covers the rest.</>;
  else narrative = <>Solar, battery and grid are <b>sharing the load</b>.</>;

  return (
    <div className="flow-wrap">
      <div className="flow-narrative">{narrative}</div>
      {mobile ? renderMobile() : renderDesktop()}
    </div>
  );
}

window.PowerFlow = PowerFlow;
