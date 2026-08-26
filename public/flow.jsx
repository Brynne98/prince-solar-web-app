// ============================================================================
// flow.jsx — <PowerFlow/> : live energy flow.  Grid · Solar · Battery → Inverter(s) → Home.
// Desktop: wide horizontal layout. Phones: a compact VERTICAL layout (sources on
// top → inverter → home) so it fits the screen and stays legible. The status line
// + chips below are shared (chips wrap 2×2 on mobile via CSS).
// ============================================================================

function useFlowMobile(bp = 600) {
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

function PowerFlow({ agg, inverters, battInfo, typicalSoc, typicalHour }) {
  const C = window.COLORS;
  const mobile = useFlowMobile();
  const charging = agg.battState === 'charging';
  const gridImport = agg.gridPower > 0 ? agg.gridPower : 0;
  const kwhToday = v => (v != null ? v.toFixed(1) + ' kWh today' : null);
  const hh = (h) => String(h).padStart(2, '0') + ':00';
  // Typical used to share the ETA line and shoved "2h 0m to empty" off the node.
  // They are separate whispers: usual charge (cyan) and runtime (muted). The node
  // grows a little when both are present rather than concatenating them.
  const typicalLabel = typicalSoc != null ? 'usually ' + typicalSoc + '%' : null;
  const typicalTitle = typicalSoc != null
    ? 'Typical charge at ' + (typicalHour != null ? hh(typicalHour) : 'this hour') + ' over complete days'
    : null;

  const left = [
    { key: 'pv', label: 'Solar', color: C.pv, w: agg.pvNow, icon: 'sun', tag: null, sub: kwhToday(agg.pvToday) },
    { key: 'bat', label: 'Battery', color: C.batt, w: agg.battPower, icon: 'battery', soc: agg.battSoc, reverse: charging,
      tag: agg.battPower > 5 ? (charging ? 'charging' : 'discharging') : 'idle', pct: agg.battSoc,
      sub: battInfo || null, usual: typicalLabel, typicalTitle },
    { key: 'grid', label: 'Grid', color: C.grid, w: gridImport, icon: 'bolt', tag: null, sub: kwhToday(agg.gridFromToday) },
  ];
  const home = { label: 'Home', color: C.load, w: agg.loadNow, sub: kwhToday(agg.loadToday) };

  const CEIL = 8000, MAXTH = 30;
  const th = w => Math.max(3.5, Math.min(MAXTH, (w / CEIL) * MAXTH + 3.5));
  const valKW = w => (w / 1000).toFixed(2);

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
    const W = 980, H = 436;
    const invX = 490, invY = H / 2;
    const srcX = 150, homeX = W - 150;
    const sy = [110, 218, 326];

    const link = (x1, y1, x2, y2, color, w, key, reverse) => {
      const mx = (x1 + x2) / 2;
      const d = `M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`;
      const active = w > 5;
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

    const sideNode = (n, i) => {
      const active = n.w > 5;
      const both = !!(n.usual && n.sub);
      // Two whispers (usual + ETA) need a taller battery node; other source
      // cards stay the original 88×152 so the column still lines up.
      const h = both ? 104 : 88, y0 = both ? -52 : -44;
      const ly = n.tag ? (both ? -30 : -24) : -16;
      const vy = n.tag ? (both ? -5 : 1) : 7;
      const ty = n.tag ? (both ? 14 : 20) : null;
      const usualY = both ? 32 : (n.tag ? 37 : 28);
      const subY = both ? 46 : (n.tag ? 37 : 28);
      return (
        <g key={n.key} transform={`translate(${srcX},${sy[i]})`}>
          {active && <rect x={-76} y={y0} width={152} height={h} rx={15} fill={n.color} opacity="0.07" />}
          <rect x={-76} y={y0} width={152} height={h} rx={15} fill="rgba(255,255,255,0.015)"
            stroke={n.color} strokeOpacity={active ? 0.6 : 0.22} strokeWidth="1.3" filter={active ? 'url(#flglow)' : undefined} />
          {icon(n.icon, -56, both ? -10 : -4, n.color, active, n.soc)}
          <text x={-36} y={ly} className="flow-node-label">{n.label.toUpperCase()}</text>
          <text x={-36} y={vy} className="flow-node-val" fill={active ? n.color : 'var(--muted)'} textAnchor="start">{valKW(n.w)}<tspan className="flow-node-unit"> kWh</tspan></text>
          {n.tag && <text x={-36} y={ty} className="flow-node-tag" textAnchor="start" fill={active ? n.color : 'var(--dim)'} fillOpacity="0.9">{n.tag}{n.pct != null && <tspan dx="6" className="flow-pct" fill={n.color}>{n.pct}%</tspan>}</text>}
          {n.usual && <text x={-36} y={usualY} className="flow-sub flow-usual">{n.typicalTitle && <title>{n.typicalTitle}</title>}{n.usual}</text>}
          {n.sub && <text x={-36} y={subY} className="flow-sub">{n.sub}</text>}
        </g>
      );
    };
    const homeActive = home.w > 5;

    return (
      <svg viewBox="48 20 884 396" className="flow-svg" preserveAspectRatio="xMidYMid meet">
        {defs}
        <rect x="0" y="58" width={W} height={H - 58} fill="url(#flgrid)" />
        {left.map((n, i) => link(srcX + 88, sy[i], invX - 60, invY + (sy[i] - invY) * 0.34, n.color, n.w, 'l' + n.key, n.reverse))}
        {link(invX + 60, invY, homeX - 90, invY, home.color, home.w, 'lhome', false)}
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
    );
  }

  // ---------------- MOBILE (vertical, card-style HTML nodes) ----------------
  function renderMobile() {
    const dur = w => Math.max(0.9, 3.2 - (Math.min(w, CEIL) / CEIL) * 2.3);
    const homeActive = home.w > 5;
    const cols = [16.67, 50, 83.33]; // tile x-centres as % (3 equal flex columns)
    const miniIcon = (type, color, soc) => (
      <svg width="17" height="17" viewBox="-11 -11 22 22">{icon(type, 0, 0, color, true, soc)}</svg>
    );

    const mTile = (n) => {
      const active = n.w > 5;
      return (
        <div className="mtile" key={n.key}
          style={active ? { borderColor: n.color, boxShadow: `inset 0 0 0 1px ${n.color}`, background: n.color + '12' } : null}>
          <div className="mtile-head">
            {miniIcon(n.icon, n.color, n.soc)}
            <span className="mtile-label">{n.label}</span>
          </div>
          <div className="mtile-val" style={{ color: active ? n.color : 'var(--muted)' }}>{valKW(n.w)}<span className="u">kWh</span></div>
          {n.key === 'bat'
            ? <>
                <div className="mtile-state" style={{ color: active ? n.color : 'var(--dim)' }}>{n.tag}{n.pct != null ? ` · ${n.pct}%` : ''}</div>
                {n.usual && <div className="mtile-sub mtile-usual" title={n.typicalTitle || undefined}>{n.usual}</div>}
                {n.sub && <div className="mtile-sub">{n.sub}</div>}
              </>
            : (n.sub && <div className="mtile-sub">{n.sub}</div>)}
        </div>
      );
    };

    const linkStrip = (
      <svg className="mflow-links" viewBox="0 0 100 54" preserveAspectRatio="none">
        {left.map((n, i) => {
          const sx = cols[i];
          const active = n.w > 5;
          const d = `M ${sx} 1 C ${sx} 30, 50 22, 50 53`;
          return (
            <g key={n.key}>
              <path d={d} fill="none" stroke={active ? n.color : 'rgba(255,255,255,0.09)'} strokeOpacity={active ? 0.18 : 1}
                strokeWidth={active ? 5 : 1.6} vectorEffect="non-scaling-stroke" strokeLinecap="round" />
              {active && <path d={d} fill="none" stroke={n.color} strokeWidth="2.4" vectorEffect="non-scaling-stroke"
                strokeDasharray="2 11" strokeLinecap="round"
                style={{ animation: `flow ${dur(n.w)}s linear infinite ${n.reverse ? 'reverse' : 'normal'}` }} />}
            </g>
          );
        })}
      </svg>
    );

    return (
      <div className="mflow">
        <div className="mflow-sources">{left.map(mTile)}</div>

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
          <div className="mflow-inv-sub">{inverters} online</div>
        </div>

        <svg className="mflow-down" viewBox="0 0 10 100" preserveAspectRatio="none">
          <line x1="5" y1="0" x2="5" y2="100" stroke={homeActive ? home.color : 'rgba(255,255,255,0.09)'} strokeOpacity={homeActive ? 0.18 : 1}
            strokeWidth={homeActive ? 5 : 1.6} vectorEffect="non-scaling-stroke" />
          {homeActive && <line x1="5" y1="0" x2="5" y2="100" stroke={home.color} strokeWidth="2.4" vectorEffect="non-scaling-stroke"
            strokeDasharray="2 11" style={{ animation: `flow ${dur(home.w)}s linear infinite` }} />}
        </svg>

        <div className="mflow-home"
          style={homeActive ? { borderColor: home.color, boxShadow: `inset 0 0 0 1px ${home.color}`, background: home.color + '10' } : null}>
          <svg width="22" height="22" viewBox="-12 -12 24 24">{icon('home', 0, 0, home.color, homeActive)}</svg>
          <div className="mflow-home-text">
            <span className="mflow-home-label">HOME</span>
            <span className="mflow-home-val" style={{ color: home.color }}>{valKW(home.w)}<span className="u">kWh</span></span>
          </div>
          {home.sub && <div className="mflow-home-today">{home.sub}</div>}
        </div>
      </div>
    );
  }

  const homeActive = home.w > 5;
  const chips = [
    { label: 'Solar', color: C.pv, active: agg.pvNow > 5, state: agg.pvNow > 5 ? valKW(agg.pvNow) + ' kWh' : 'idle' },
    { label: 'Battery', color: C.batt, active: agg.battPower > 5, state: agg.battPower > 5 ? (charging ? 'charging' : 'discharging') : 'idle' },
    { label: 'Grid', color: C.grid, active: gridImport > 5, state: gridImport > 5 ? 'importing' : 'standby' },
    { label: 'Home', color: C.load, active: homeActive, state: valKW(home.w) + ' kWh' },
  ];
  let narrative;
  if (agg.pvNow > home.w + 50) narrative = <><b style={{ color: C.pv }}>Solar</b> is covering the home{charging ? ' and charging the battery' : ''}.</>;
  else if (agg.battPower > 5 && !charging && gridImport < 50) narrative = <>Your <b style={{ color: C.batt }}>battery</b> is powering the home — solar offline.</>;
  else if (gridImport > 50) narrative = <>Pulling <b style={{ color: C.grid }}>{valKW(gridImport)} kWh</b> from the grid to meet demand.</>;
  else narrative = <>System balanced — home running on <b style={{ color: C.batt }}>stored energy</b>.</>;

  return (
    <div className="flow-wrap">
      {mobile ? renderMobile() : renderDesktop()}
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
