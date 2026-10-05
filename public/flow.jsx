// ============================================================================
// flow.jsx — <PowerFlow/> : live energy flow.  Grid · Solar · Battery → Inverter(s) → Home.
// Desktop: two rows of two boxes either side of the inverter. Phones and tablets: the
// same boxes stacked, sources on top → inverter → home and grid. The summary line opens both.
// ============================================================================

// 900, not 600: under that the wide layout's boxes are too narrow for a figure and a
// Today column side by side, so tablets get the stacked layout.
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

function PowerFlow({ agg, inverters, battInfo, onBattInfo, typicalSoc, typicalHour, features, wall, battPositive }) {
  const C = window.COLORS;
  const mobile = useFlowMobile();
  // The boxes stretch with the card (SOLAR-39); its width only decides the lane's.
  const [wrapRef, wrapW] = useChartSize();
  const feat = features || {};
  const hasBatt = feat.hasBattery !== false;
  const hasGrid = feat.hasGrid !== false;
  const charging = agg.battState === 'charging';
  // Mains gone (no voltage on any inverter): nothing can come from the grid, and its card,
  // icon and line say so. null (not reported yet) shows neither on nor off.
  const gridOff = hasGrid && agg.gridPresent === false;
  const gridKnown = hasGrid && agg.gridPresent != null;
  const gridImport = !gridOff && agg.gridPower > 0 ? agg.gridPower : 0;
  // Export shows whatever the tariff, as SunSynk's own flow does (SOLAR-38).
  const gridExport = !gridOff && agg.gridPower < 0 ? -agg.gridPower : 0;
  const hh = (h) => String(h).padStart(2, '0') + ':00';
  // The usual charge at this hour is hover text on the battery's charge %.
  const usualTitle = typicalSoc != null
    ? 'Usually ' + typicalSoc + '% at ' + (typicalHour != null ? hh(typicalHour) : 'this hour') + ' over complete days'
    : undefined;

  // battInfo arrives as "3h 40m to empty" / "1h 55m to full" / "Set pack size"; no time while idle
  const battRow = (() => {
    const m = battInfo && /^(.*) to (empty|full)$/.exec(battInfo);
    if (m) return { k: m[2] === 'empty' ? 'Empty in' : 'Full in', v: m[1] };
    // "Set pack size" stands alone, a link to Settings (SOLAR-23)
    if (battInfo) return { k: '', v: battInfo, on: onBattInfo };
    // under 200 W there is no time (tabs.jsx), but the power is still moving (SOLAR-44)
    return { k: charging ? 'Trickle charging' : agg.battState === 'discharging' ? 'Discharging' : 'Idle', v: '' };
  })();
  const battState = battRow.on
    ? <button type="button" className="mini-link" onClick={battRow.on}>{battRow.v}</button>
    : <>{battRow.k}{battRow.v && <b>{battRow.v}</b>}</>;

  // Where the home's power is coming from right now: the battery only while discharging,
  // the grid only while importing, solar whatever is left (never more than it is making).
  const battIn = hasBatt && !charging && agg.battPower > 5 ? agg.battPower : 0;
  const gridIn = hasGrid ? gridImport : 0;
  const solarIn = Math.max(0, Math.min(agg.pvNow, agg.loadNow - battIn - gridIn));
  // and where solar is going: home, battery and grid in proportion to their watts. When the
  // inverters' readings add up to more than solar made, all three shrink alike rather than
  // the grid alone taking the cut (SOLAR-55).
  const sunToHome = Math.max(0, agg.loadNow - battIn - gridIn);
  const sunToBatt = hasBatt && charging ? agg.battPower : 0;
  const sunOut = sunToHome + sunToBatt + gridExport;
  const sunScale = sunOut > agg.pvNow ? agg.pvNow / sunOut : 1;

  // Today's figures, in a column of their own on desktop and under a rule on a phone.
  const today = (...rows) => rows.filter(r => r[1] != null);
  const flows = { pv: agg.pvNow, bat: agg.battPower, home: agg.loadNow };
  const nodes = {
    pv: { key: 'pv', label: 'Solar', color: C.pv, w: agg.pvNow, icon: 'sun',
      split: [['Home', C.load, sunToHome * sunScale], ['Battery', C.batt, sunToBatt * sunScale], ['Grid', C.grid, gridExport * sunScale]],
      today: today(['Made', agg.pvToday]) },
    // w stays the magnitude (animation, stroke); val is the signed figure printed on the box,
    // + = powering the house, as everywhere else in the app.
    bat: hasBatt && { key: 'bat', label: 'Battery', color: C.batt, w: agg.battPower, val: window.battShown(agg.battOut, battPositive),
      icon: 'battery', soc: agg.battSoc, reverse: charging, state: battState, charge: agg.battSoc,
      today: today(['Charged', agg.battChgToday], ['Used', agg.battDischgToday]) },
    // flows both ways: an export runs the animation back towards the grid and prints
    // negative (SOLAR-41), as a discharging battery does
    grid: hasGrid && { key: 'grid', label: 'Grid', color: C.grid, w: gridExport > 0 ? gridExport : gridImport,
      val: gridExport > 0 ? -gridExport : gridImport, icon: 'bolt',
      reverse: gridExport > 0, off: gridOff, known: gridKnown,
      state: gridOff ? 'No supply' : gridExport > 0 ? 'Sending out' : gridImport > 0 ? 'Drawing' : 'Not drawing',
      today: today(['Bought', agg.gridFromToday ?? 0], ['Sent out', agg.gridToToday ?? 0]) },
    home: { key: 'home', label: 'Home', color: C.load, w: agg.loadNow, icon: 'home',
      split: [['Solar', C.pv, solarIn], ['Battery', C.batt, battIn], ['Grid', C.grid, gridIn]],
      today: today(['Used', agg.loadToday]) },
  };

  const CEIL = 8000;
  const pw = w => window.fmtPowerParts(w);

  // One look for every line, desktop and phone: a soft band with dots moving along it,
  // faster with more power. `fixed` is the phone: widths stay in screen pixels where the
  // drawing is stretched to fit (preserveAspectRatio="none"), and the band is slimmer.
  // `broken` is the grid's line once mains has gone: grey and dashed.
  // Any flow at all moves, however small (SOLAR-41): a 5 W dusk trickle is real.
  const flowLine = (d, color, w, key, reverse, fixed, broken) => {
    const active = w > 0;
    const dur = Math.max(0.9, 3.2 - (Math.min(w, CEIL) / CEIL) * 2.3);
    const ve = fixed ? 'non-scaling-stroke' : undefined;
    return (
      <g key={key}>
        <path d={d} fill="none" stroke={active ? color : `rgba(255,255,255,${broken ? 0.22 : 0.08})`}
          strokeOpacity={active ? 0.16 : 1} strokeWidth={active ? (fixed ? 6 : 11) : (broken ? 2 : fixed ? 2 : 2.5)}
          strokeDasharray={broken ? '3 7' : undefined} strokeLinecap="round" vectorEffect={ve} />
        {active && (
          <path d={d} fill="none" stroke={color} strokeOpacity="1" strokeWidth={fixed ? 2.2 : 2.8}
            strokeDasharray="2 13" strokeLinecap="round" vectorEffect={ve}
            style={{ animation: `flow ${dur}s linear infinite ${reverse ? 'reverse' : 'normal'}` }} />
        )}
      </g>
    );
  };

  // node icons (kept simple & monoline), drawn round 0,0
  const icon = (type, color, active, soc, off) => {
    const o = active ? 1 : 0.5;
    if (type === 'sun') {
      const rays = [];
      for (let a = 0; a < 360; a += 45) {
        const r = a * Math.PI / 180;
        rays.push(<line key={a} x1={Math.cos(r) * 6.5} y1={Math.sin(r) * 6.5} x2={Math.cos(r) * 9} y2={Math.sin(r) * 9} />);
      }
      return <g stroke={color} strokeWidth="1.5" strokeLinecap="round" opacity={o}><circle r="4.2" fill={active ? color : 'none'} fillOpacity={active ? 0.45 : 0} />{rays}</g>;
    }
    if (type === 'battery') {
      const lvl = Math.max(0, Math.min(1, (soc || 0) / 100));
      return (
        <g opacity={o}>
          <rect x={-9.5} y={-6.5} width="16" height="13" rx="3.2" fill="none" stroke={color} strokeWidth="1.6" />
          <rect x={7} y={-3} width="3" height="6" rx="1.4" fill={color} />
          <rect x={-7.3} y={-4.1} width={lvl * 12} height="8.2" rx="1.6" fill={color} />
        </g>
      );
    }
    if (type === 'bolt') {
      return (
        <g>
          <path d="M 2 -8 L -5 1.5 L -0.5 1.5 L -1.5 8 L 5.5 -2 L 1 -2 Z" fill={color} fillOpacity={active ? 0.22 : 0} stroke={color} strokeWidth="1.5" strokeLinejoin="round" opacity={o} />
          {/* mains gone: a slash through the bolt */}
          {off && <line x1={-8} y1={-8} x2={8} y2={8} stroke="var(--muted)" strokeWidth="1.6" strokeLinecap="round" />}
        </g>
      );
    }
    return (
      <g opacity={o}>
        <path d="M -8 8 L -8 -2 L 0 -10 L 8 -2 L 8 8 Z" fill={active ? color : 'none'} fillOpacity={active ? 0.18 : 0} stroke={color} strokeWidth="1.5" strokeLinejoin="round" />
        <rect x={-2.2} y={1} width="4.4" height="4.4" rx="0.6" fill="none" stroke={color} strokeWidth="1.2" />
      </g>
    );
  };

  // A share bar: one segment per part over 5 W, each named with its % under it.
  const splitFoot = parts => {
    const on = parts.filter(p => p[2] > 5);
    const total = on.reduce((a, p) => a + p[2], 0);
    // round down, then hand the missing points to the biggest remainders, so the
    // shares always total 100 (SOLAR-57)
    const exact = on.map(p => p[2] / total * 100);
    const pct = exact.map(Math.floor);
    let left = 100 - pct.reduce((a, v) => a + v, 0);
    exact.map((v, i) => i).sort((a, b) => (exact[b] - pct[b]) - (exact[a] - pct[a]))
      .forEach(i => { if (left > 0) { pct[i]++; left--; } });
    return (
      <div className="fbox-foot">
        <div className="fbox-bar">{on.map(p => <i key={p[0]} style={{ flexGrow: p[2], background: p[1] }} />)}</div>
        {on.length > 0 && (
          <div className="fbox-split">
            {on.map((p, i) => <span key={p[0]}><em>{p[0]}</em><b style={{ color: p[1] }}>{pct[i]}%</b></span>)}
          </div>
        )}
      </div>
    );
  };

  // The box, the same on desktop and phone: icon and name, the figure, a state line, a foot
  // (share bar, charge strip or grid on/off), then today's figures. Tinted and outlined in
  // its colour while power moves, faint when idle, dashed once the grid has gone.
  const box = n => {
    const active = n.w > 0;
    const [v, u] = pw(n.val ?? n.w);
    return (
      <div className={'fbox' + (n.off ? ' off' : '')} key={n.key}
        style={{ borderColor: flowAlpha(n.color, active ? 0.6 : 0.22), background: active ? flowAlpha(n.color, 0.07) : undefined }}>
        <div className="fbox-now">
          <div className="fbox-head">
            <svg width="18" height="18" viewBox="-11 -11 22 22">{icon(n.icon, n.color, active, n.soc, n.off)}</svg>
            <span className="fbox-label">{n.label}</span>
          </div>
          <div className="fbox-val" style={{ color: active ? n.color : 'var(--muted)' }}>{v}<span className="u">{u}</span></div>
          {n.state && <div className="fbox-state">{n.state}</div>}
          {n.split && splitFoot(n.split)}
          {n.charge != null && (
            <div className="fbox-foot fbox-charge" title={usualTitle}>
              <div className="fbox-bar"><i style={{ width: Math.max(0, Math.min(100, n.charge)) + '%', background: n.color }} /></div>
              <b style={{ color: n.color }}>{n.charge}%</b>
            </div>
          )}
          {/* mains there or gone: a status, never green-tinted like solar's power */}
          {n.known && <div className={'fbox-foot fbox-grid' + (n.off ? ' off' : '')}><i />{n.off ? 'Grid off' : 'Grid on'}</div>}
        </div>
        {n.today.length > 0 && (
          <div className="fbox-today">
            <div className="fbox-today-h">Today</div>
            {n.today.map(([k, kwh]) => <div key={k}><span>{k}</span><b>{(Math.round(Number(kwh) * 10) / 10).toFixed(1)}<span className="u">kWh</span></b></div>)}
          </div>
        )}
      </div>
    );
  };

  const inverterMark = (
    <g strokeLinecap="round">
      <line x1={0} y1={-20} x2={0} y2={20} stroke="var(--text)" strokeOpacity="0.16" strokeWidth="1.2" />
      <line x1={-24} y1={-4} x2={-8} y2={-4} stroke="var(--soc)" strokeWidth="2.2" />
      <line x1={-22} y1={4} x2={-10} y2={4} stroke="var(--soc)" strokeWidth="2.2" strokeDasharray="3 3" />
      <path d="M 7 3 q 5 -11 9.5 0 q 4.5 11 9.5 0" stroke={C.pv} strokeWidth="2.2" fill="none" />
    </g>
  );
  const invLabel = 'INVERTER' + (inverters > 1 ? 'S' : '');

  // ---------------- DESKTOP (two rows of two, SOLAR-19 / SOLAR-39) ----------------
  // Solar over Battery on the left, Grid over Home on the right, the inverter in a lane
  // between them. The boxes take whatever width the card has; the lane is fixed, so its
  // lines are drawn one unit per pixel. Under 1000 wide the lane and the inverter shrink.
  function renderDesktop() {
    const narrow = !wall && wrapW < 1000;
    const LW = narrow ? 200 : 240, R = narrow ? 40 : 47, BH = 176, GAP = 22, H = 2 * BH + GAP;
    const cx = LW / 2, cy = H / 2, row1 = BH / 2, row2 = BH + GAP + BH / 2;
    // a plant without a battery or grid centres the one box left on that side
    const solarY = nodes.bat ? row1 : cy, homeY = nodes.grid ? row2 : cy;
    const curve = (x1, y1, x2, y2) => { const mx = (x1 + x2) / 2; return `M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`; };
    // lines leave a box 10 off its edge and enter the inverter either side of its centre
    const inL = cx - R - 11, inR = cx + R + 11, a = cy - 12, b = cy + 12;
    const cell = (n, col, row) => n && (
      <div className="pflow-cell" style={{ gridColumn: col, gridRow: row ?? '1 / span 2', alignSelf: row ? undefined : 'center', height: row ? undefined : BH }}>{box(n)}</div>
    );
    return (
      <div className={'pflow' + (narrow ? ' narrow' : '')} style={{ gridTemplateColumns: `minmax(0, 1fr) ${LW}px minmax(0, 1fr)`, gridTemplateRows: `${BH}px ${BH}px`, rowGap: GAP }}>
        {cell(nodes.pv, 1, nodes.bat ? 1 : null)}
        {cell(nodes.bat, 1, 2)}
        {cell(nodes.grid, 3, 1)}
        {cell(nodes.home, 3, nodes.grid ? 2 : null)}
        <div className="pflow-lane" style={{ gridColumn: 2, gridRow: '1 / span 2' }}>
          <svg width={LW} height={H} viewBox={`0 0 ${LW} ${H}`}>
            {flowLine(curve(10, solarY, inL, nodes.bat ? a : cy), C.pv, flows.pv, 'lpv')}
            {nodes.bat && flowLine(curve(10, row2, inL, b), C.batt, flows.bat, 'lbat', nodes.bat.reverse)}
            {nodes.grid && flowLine(curve(LW - 10, row1, inR, a), C.grid, nodes.grid.w, 'lgrid', nodes.grid.reverse, false, nodes.grid.off)}
            {flowLine(curve(inR, nodes.grid ? b : cy, LW - 10, homeY), C.load, flows.home, 'lhome', false)}
            <circle cx={cx} cy={cy} r={R} fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.24)" strokeWidth="1.3" />
            <circle cx={cx} cy={cy} r={R} fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth="8" />
            <g transform={`translate(${cx}, ${cy})${narrow ? ' scale(0.85)' : ''}`}>{inverterMark}</g>
          </svg>
          <div className="pflow-inv-label" style={{ top: cy - R - 26 }}>{invLabel}</div>
        </div>
      </div>
    );
  }

  // ---------------- MOBILE (stacked tiles) ----------------
  // Like desktop (SOLAR-20): Solar and Battery on top, Home and Grid below with Grid on the
  // right, the inverter between the two rows.
  function renderMobile() {
    const top = [nodes.pv, nodes.bat].filter(Boolean);
    const bottom = [nodes.home, nodes.grid].filter(Boolean);
    // tile x-centres as %: the tiles share their row equally
    const cols = row => row.map((_, i) => ((i + 0.5) / row.length) * 100);

    // Like desktop: each line starts a gap from its tile and stops a gap short of the
    // inverter, spread out rather than merging into one point. Lines are drawn tile →
    // inverter; Home's runs the other way, out of the inverter.
    const linkStrip = (row, below) => {
      const xs = cols(row);
      return (
        <svg className="mflow-links" viewBox="0 0 100 72" preserveAspectRatio="none">
          {row.map((n, i) => {
            const sx = xs[i];
            const ex = 50 + (sx - 50) * 0.2;
            const [ty, iy, tc, ic] = below ? [60, 12, 32, 40] : [12, 60, 40, 32];
            return flowLine(`M ${sx} ${ty} C ${sx} ${tc}, ${ex} ${ic}, ${ex} ${iy}`, n.color, n.w, n.key, n.key === 'home' ? !n.reverse : n.reverse, true, n.off);
          })}
        </svg>
      );
    };
    const tiles = row => (
      <div className="mflow-sources" style={{ gridTemplateColumns: `repeat(${row.length}, minmax(0, 1fr))` }}>{row.map(box)}</div>
    );

    return (
      <div className="mflow">
        {tiles(top)}
        {linkStrip(top, false)}

        <div className="mflow-inv">
          <svg width="84" height="84" viewBox="-42 -42 84 84">
            <circle r="40" fill="rgba(255,255,255,0.04)" stroke="rgba(255,255,255,0.16)" strokeWidth="1.3" />
            {inverterMark}
          </svg>
          <div className="mflow-inv-label">{invLabel}</div>
        </div>

        {linkStrip(bottom, true)}
        {tiles(bottom)}
      </div>
    );
  }

  // The one-line summary of what is happening; it opens the card, above the diagram.
  let narrative;
  if (gridOff) {
    const timeLeft = battRow.k === 'Empty in' ? battRow.v : null;
    narrative = <><b>The grid is off.</b>{hasBatt && agg.battPower > 5 && !charging
      ? <> Your <b style={{ color: C.batt }}>battery</b> is powering the home{timeLeft ? <>, with about {timeLeft} left</> : ''}.</>
      : agg.pvNow > 50 ? <> <b style={{ color: C.pv }}>Solar</b> is powering the home.</> : null}</>;
  }
  // Exporting while the battery also feeds the home: solar alone isn't covering it (SOLAR-46).
  else if (gridExport > 50) narrative = battIn > 50
    ? <><b style={{ color: C.pv }}>Solar</b> and your <b style={{ color: C.batt }}>battery</b> are powering the home and sending <b style={{ color: C.grid }}>{window.fmtPower(gridExport)}</b> to the grid.</>
    : <><b style={{ color: C.pv }}>Solar</b> is covering the home{hasBatt && charging ? ', charging the battery' : ''} and sending <b style={{ color: C.grid }}>{window.fmtPower(gridExport)}</b> to the grid.</>;
  // >= home - 50, not > home + 50: a home drawing exactly what the panels make is the
  // commonest sunny-afternoon state and fell through to the vague fallback.
  else if (agg.pvNow > 50 && agg.pvNow >= agg.loadNow - 50) narrative = <><b style={{ color: C.pv }}>Solar</b> is covering the home{hasBatt && charging ? ' and charging the battery' : ''}.</>;
  // Solar can still be making something here, just less than the home draws, so only
  // leave it out when it is effectively zero.
  else if (hasBatt && agg.battPower > 5 && !charging && gridImport < 50) narrative = agg.pvNow > 50
    ? <><b style={{ color: C.pv }}>Solar</b> and your <b style={{ color: C.batt }}>battery</b> are powering the home.</>
    : <>Your <b style={{ color: C.batt }}>battery</b> is powering the home.</>;
  else if (gridImport > 50) narrative = <>Pulling <b style={{ color: C.grid }}>{window.fmtPower(gridImport)}</b> from the grid to meet demand.</>;
  else if (!hasGrid && agg.pvNow < 50) narrative = <>Off-grid, after dark — the home is running on <b style={{ color: C.batt }}>stored energy</b>.</>;
  else if (!hasBatt) narrative = <><b style={{ color: C.pv }}>Solar</b> covers what it can; the grid covers the rest.</>;
  else narrative = <>Solar, battery and grid are <b>sharing the load</b>.</>;

  return (
    <div className="flow-wrap" ref={wrapRef}>
      <div className="flow-narrative">{narrative}</div>
      {mobile ? renderMobile() : renderDesktop()}
    </div>
  );
}

window.PowerFlow = PowerFlow;
