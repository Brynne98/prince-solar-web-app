// ============================================================================
// flow.jsx — <PowerFlow/> : live energy flow.
// Grid · Solar · Battery  →  Inverter(s)  →  Home.
// All source/consumer nodes are ALWAYS shown (even at 0 W). Active links animate
// flowing particles + glow; idle links sit faint. Battery link reverses on charge.
// ============================================================================

function PowerFlow({ agg, inverters, battInfo }) {
  const C = window.COLORS;
  const charging = agg.battState === 'charging';
  const gridImport = agg.gridPower > 0 ? agg.gridPower : 0;
  const kwhToday = v => (v != null ? v.toFixed(1) + ' kWh today' : null);

  const W = 980, H = 436;
  const invX = 490, invY = H / 2, invW = 116, invH = 132;
  const srcX = 150, homeX = W - 150;
  const sy = [110, 218, 326];

  const left = [
    { key: 'pv', label: 'Solar', color: C.pv, w: agg.pvNow, y: sy[0], icon: 'sun', tag: null, sub: kwhToday(agg.pvToday) },
    { key: 'bat', label: 'Battery', color: C.batt, w: agg.battPower, y: sy[1], icon: 'battery', soc: agg.battSoc, reverse: charging,
      tag: agg.battPower > 5 ? (charging ? 'charging' : 'discharging') : 'idle', pct: agg.battSoc, sub: battInfo },
    { key: 'grid', label: 'Grid', color: C.grid, w: gridImport, y: sy[2], icon: 'bolt', tag: null, sub: kwhToday(agg.gridFromToday) },
  ];
  const home = { label: 'Home', color: C.load, w: agg.loadNow, sub: kwhToday(agg.loadToday) };

  const CEIL = 8000, MAXTH = 30;
  const th = w => Math.max(3.5, Math.min(MAXTH, (w / CEIL) * MAXTH + 3.5));
  const valKW = w => (w / 1000).toFixed(2);

  const link = (x1, y1, x2, y2, color, w, key, reverse) => {
    const mx = (x1 + x2) / 2;
    const d = `M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`;
    const active = w > 5; const t = th(w);
    const dur = Math.max(0.9, 3.2 - (Math.min(w, CEIL) / CEIL) * 2.3);
    return (
      <g key={key}>
        <path d={d} fill="none" stroke={active ? color : 'rgba(255,255,255,0.08)'}
          strokeOpacity={active ? 0.16 : 1} strokeWidth={active ? 11 : 2.5} strokeLinecap="round" />
        {active && (
          <path d={d} fill="none" stroke={color} strokeOpacity="1" strokeWidth="2.8"
            strokeDasharray="2 13" strokeLinecap="round"
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
          <rect x={cx - 7.3} y={cy - 4.1} width={Math.max(0, active ? lvl * 12 : 0)} height="8.2" rx="1.6" fill={color} />
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
    // square fallback
    return <rect x={cx - 7} y={cy - 7} width="14" height="14" rx="3.5" fill={active ? color : 'none'} stroke={color} strokeWidth="1.6" opacity={o} />;
  };

  const sideNode = (n) => {
    const active = n.w > 5;
    const ly = n.tag ? -24 : -16, vy = n.tag ? 1 : 7, sy2 = n.tag ? 37 : 28;
    return (
      <g key={n.key} transform={`translate(${srcX},${n.y})`}>
        {active && <rect x={-76} y={-44} width={152} height={88} rx={15} fill={n.color} opacity="0.07" />}
        <rect x={-76} y={-44} width={152} height={88} rx={15} fill="rgba(255,255,255,0.015)"
          stroke={n.color} strokeOpacity={active ? 0.6 : 0.22} strokeWidth="1.3" filter={active ? 'url(#flglow)' : undefined} />
        {icon(n.icon, -56, -4, n.color, active, n.soc)}
        <text x={-36} y={ly} className="flow-node-label">{n.label.toUpperCase()}</text>
        <text x={-36} y={vy} className="flow-node-val" fill={active ? n.color : 'var(--muted)'} textAnchor="start">{valKW(n.w)}<tspan className="flow-node-unit"> kWh</tspan></text>
        {n.tag && <text x={-36} y={20} className="flow-node-tag" textAnchor="start" fill={active ? n.color : 'var(--dim)'} fillOpacity="0.9">{n.tag}{n.pct != null && <tspan dx="6" className="flow-pct" fill={n.color}>{n.pct}%</tspan>}</text>}
        {n.sub && <text x={-36} y={sy2} className="flow-sub">{n.sub}</text>}
      </g>
    );
  };

  const homeActive = home.w > 5;
  const chips = [
    { label: 'Solar', color: C.pv, active: agg.pvNow > 5, state: agg.pvNow > 5 ? valKW(agg.pvNow) + ' kWh' : 'idle' },
    { label: 'Battery', color: C.batt, active: agg.battPower > 5, state: agg.battPower > 5 ? (charging ? 'charging' : 'discharging') : 'idle' },
    { label: 'Grid', color: C.grid, active: gridImport > 5, state: gridImport > 5 ? 'importing' : 'standby' },
    { label: 'Home', color: C.load, active: homeActive, state: valKW(home.w) + ' kWh' },
  ];
  let narrative;
  if (agg.pvNow > home.w + 50) narrative = <>Solar is covering the home{charging ? ' and charging the battery' : ''}.</>;
  else if (agg.battPower > 5 && !charging && gridImport < 50) narrative = <>Your <b style={{ color: C.batt }}>battery</b> is powering the home — solar offline.</>;
  else if (gridImport > 50) narrative = <>Pulling <b style={{ color: C.grid }}>{valKW(gridImport)} kWh</b> from the grid to meet demand.</>;
  else narrative = <>System balanced — home running on stored energy.</>;

  return (
    <div className="flow-wrap">
      <svg viewBox={`0 0 ${W} ${H}`} className="flow-svg" preserveAspectRatio="xMidYMid meet">
        <defs>
          <pattern id="flgrid" width="28" height="28" patternUnits="userSpaceOnUse">
            <circle cx="1.2" cy="1.2" r="1.2" fill="rgba(255,255,255,0.035)" />
          </pattern>
          <filter id="flglow" x="-60%" y="-60%" width="220%" height="220%">
            <feGaussianBlur stdDeviation="2.6" result="b" />
            <feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
          </filter>
        </defs>
        <rect x="0" y="58" width={W} height={H - 58} fill="url(#flgrid)" />

        {left.map(n => link(srcX + 88, n.y, invX - 60, invY + (n.y - invY) * 0.34, n.color, n.w, 'l' + n.key, n.reverse))}
        {link(invX + 60, invY, homeX - 90, invY, home.color, home.w, 'lhome', false)}

        {/* inverter — circular hub with a DC→AC symbol */}
        <circle cx={invX} cy={invY} r={47} fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.24)" strokeWidth="1.3" />
        <circle cx={invX} cy={invY} r={47} fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth="8" />
        <g transform={`translate(${invX}, ${invY})`} strokeLinecap="round">
          <line x1={0} y1={-20} x2={0} y2={20} stroke="var(--text)" strokeOpacity="0.16" strokeWidth="1.2" />
          <line x1={-24} y1={-4} x2={-8} y2={-4} stroke="var(--soc)" strokeWidth="2.2" />
          <line x1={-22} y1={4} x2={-10} y2={4} stroke="var(--soc)" strokeWidth="2.2" strokeDasharray="3 3" />
          <path d="M 7 3 q 5 -11 9.5 0 q 4.5 11 9.5 0" stroke={C.pv} strokeWidth="2.2" fill="none" />
        </g>
        <text x={invX} y={invY - 62} textAnchor="middle" className="flow-inv-label">INVERTER{inverters > 1 ? 'S' : ''}</text>
        <text x={invX} y={invY + 70} textAnchor="middle" className="flow-inv-sub">{inverters} online</text>

        {/* home */}
        <g transform={`translate(${homeX},${invY})`}>
          {homeActive && <rect x={-78} y={-44} width={156} height={88} rx={15} fill={home.color} opacity="0.07" />}
          <rect x={-78} y={-44} width={156} height={88} rx={15} fill="rgba(255,255,255,0.015)"
            stroke={home.color} strokeOpacity="0.6" strokeWidth="1.3" filter={homeActive ? 'url(#flglow)' : undefined} />
          {icon('home', -56, -4, home.color, homeActive)}
          <text x={-36} y={-16} className="flow-node-label">HOME</text>
          <text x={-36} y={7} className="flow-node-val" fill={home.color} textAnchor="start">{valKW(home.w)}<tspan className="flow-node-unit"> kWh</tspan></text>
          {home.sub && <text x={-36} y={28} className="flow-sub">{home.sub}</text>}
        </g>

        {left.map(sideNode)}

        <text x={srcX} y={32} textAnchor="middle" className="flow-col-title">SOURCES</text>
        <text x={homeX} y={32} textAnchor="middle" className="flow-col-title">CONSUMER</text>
      </svg>

      <div className="flow-status">
        <div className="flow-narrative">{narrative}</div>
        <div className="flow-chips">
          {chips.map(c => (
            <span className="flow-chip" key={c.label}>
              <i className="flow-chip-dot" style={{ background: c.active ? c.color : 'transparent', borderColor: c.color }} />
              {c.label} <b style={{ color: c.active ? c.color : 'var(--muted)' }}>{c.state}</b>
            </span>
          ))}
        </div>
      </div>
    </div>
  );
}

window.PowerFlow = PowerFlow;
