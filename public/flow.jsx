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

function PowerFlow({ agg, inverters, battInfo, onBattInfo, typicalSoc, typicalHour, features, wall }) {
  const C = window.COLORS;
  const mobile = useFlowMobile();
  // The wide layout is drawn at one unit per screen pixel, so its text keeps the same size
  // at every width and only the gaps between the columns stretch, up to 884 wide; past that
  // it stays 884 and sits centred. Below 640 it would crowd, so it scales down from there;
  // on the wall it scales to fill the room.
  const [wrapRef, wrapW] = useChartSize();
  const VW = wall ? 884 : Math.min(884, Math.max(640, wrapW));
  const feat = features || {};
  const hasBatt = feat.hasBattery !== false;
  const hasGrid = feat.hasGrid !== false;
  const charging = agg.battState === 'charging';
  // Mains gone (no voltage on any inverter): nothing can come from the grid, and its card,
  // icon and line say so. null (not reported yet) shows neither on nor off.
  const gridOff = hasGrid && agg.gridPresent === false;
  const gridKnown = hasGrid && agg.gridPresent != null;
  const gridImport = !gridOff && agg.gridPower > 0 ? agg.gridPower : 0;
  // Export only exists for plants paid to sell (a feed-in rate is set). Every
  // grid-tied inverter leaks a few hundred watts of backflow when the load drops
  // faster than it can throttle; on a site that cannot sell that reads as standby.
  const sells = feat.sells === true;
  const gridExport = sells && !gridOff && agg.gridPower < 0 ? -agg.gridPower : 0;
  const hh = (h) => String(h).padStart(2, '0') + ':00';
  // The usual charge at this hour is hover text on the battery's charge %.
  const usualTitle = typicalSoc != null
    ? 'Usually ' + typicalSoc + '% at ' + (typicalHour != null ? hh(typicalHour) : 'this hour') + ' over complete days'
    : undefined;

  // Detail under each card: one labelled figure ({ k: label, v: value, on: click }),
  // the label small and uppercase, the value in mono, so every card reads the same way.
  const today = v => (v != null ? { k: 'Today', v: window.fmtKwh(Number(v)) } : null);
  // battInfo arrives as "3h 40m to empty" / "1h 55m to full" / "Set pack size"; no time while idle
  const battRow = (() => {
    const m = battInfo && /^(.*) to (empty|full)$/.exec(battInfo);
    if (m) return { k: m[2] === 'empty' ? 'Empty in' : 'Full in', v: m[1] };
    // "Set pack size" stands alone, with no label over it (SOLAR-23)
    if (battInfo) return { k: '', v: battInfo, on: onBattInfo };
    return { k: 'Idle', v: '' };
  })();
  // Sources: only what the plant has. Grid flows both ways — an export runs the
  // animation back towards the grid node. Each card: label, value, then one detail figure.
  const left = [
    { key: 'pv', label: 'Solar', color: C.pv, w: agg.pvNow, icon: 'sun', row: today(agg.pvToday) },
    // w stays the magnitude (animation, stroke); val is the signed figure printed on the node,
    // + = powering the house, as everywhere else in the app.
    // The charge % sits at the foot of the card, big, beside a strip filled to the same level.
    hasBatt && { key: 'bat', label: 'Battery', color: C.batt, w: agg.battPower, val: window.battShown(agg.battOut), icon: 'battery', soc: agg.battSoc, reverse: charging,
      charge: agg.battSoc, row: battRow },
    // bought from the grid today; zero on most days, and that is worth seeing too
    hasGrid && { key: 'grid', label: 'Grid', color: C.grid, w: gridExport > 5 ? gridExport : gridImport, icon: 'bolt', reverse: gridExport > 5, row: today(agg.gridFromToday ?? 0),
      off: gridOff, known: gridKnown },
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
  const pw = w => window.fmtPowerParts(w);

  // One look for every line, desktop and phone: a soft band with dots moving along it,
  // faster with more power. `fixed` is the phone: widths stay in screen pixels where the
  // drawing is stretched to fit (preserveAspectRatio="none"), and the band is slimmer.
  // `broken` is the grid's line once mains has gone: grey and dashed.
  const flowLine = (d, color, w, key, reverse, fixed, broken) => {
    const active = w > 5;
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

  // node icons (kept simple & monoline)
  const icon = (type, cx, cy, color, active, soc, off) => {
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
      return (
        <g>
          <path d={d} fill={color} fillOpacity={active ? 0.22 : 0} stroke={color} strokeWidth="1.5" strokeLinejoin="round" opacity={o} />
          {/* mains gone: a slash through the bolt */}
          {off && <line x1={cx - 8} y1={cy - 8} x2={cx + 8} y2={cy + 8} stroke="var(--muted)" strokeWidth="1.6" strokeLinecap="round" />}
        </g>
      );
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

  // ---------------- DESKTOP (wide, two rows of two) ----------------
  // The canvas's "Balanced" layout (SOLAR-19): Solar over Battery on the left, Grid over
  // Home on the right, the inverter halfway between the rows. Every box shares the same
  // rows: label, value (icon level with it), one detail figure, then a foot.
  function renderDesktop() {
    const BW = 208, BH = 156, GAP = 28, PL = 44, TOP = 4;
    const H = TOP + 2 * BH + GAP + 4;
    const cy = TOP + BH + GAP / 2, row1 = TOP, row2 = TOP + BH + GAP, mid = cy - BH / 2;
    const invX = VW / 2, leftX = 26, rightX = VW - 26 - BW;
    // a plant without a battery or grid centres the one box left on that side
    const solarY = hasBatt ? row1 : mid, homeY = hasGrid ? row2 : mid;
    const at = { pv: [leftX, solarY], bat: [leftX, row2], grid: [rightX, row1] };
    // rows inside a box, from its top edge
    const Y = { label: 27, val: 58, iconC: 48, kv: 80, foot: 101 };

    // Lines meet each box 12 off its edge, level with its middle, and enter the inverter
    // either side of its centre.
    const curve = (x1, y1, x2, y2) => { const mx = (x1 + x2) / 2; return `M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`; };
    const inL = invX - 60, inR = invX + 60, a = cy - 12, b = cy + 12;
    const lineFor = n => {
      const [x, y] = at[n.key];
      return n.key === 'grid'
        ? flowLine(curve(rightX - 12, y + BH / 2, inR, a), n.color, n.w, 'lgrid', n.reverse, false, n.off)
        : flowLine(curve(leftX + BW + 12, y + BH / 2, inL, n.key === 'bat' ? b : hasBatt ? a : cy), n.color, n.w, 'l' + n.key, n.reverse);
    };

    // a detail figure: small uppercase label, then the value in mono
    const kv = (r, x, y) => r && (r.on
      // a prompt that leads somewhere ("Set pack size"): clickable and keyboard-reachable
      ? <text x={x} y={y} className="flow-sub flow-link" role="link" tabIndex={0} onClick={r.on}
          onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); r.on(); } }}>
          {r.k && <tspan className="flow-kv-k">{r.k.toUpperCase()}</tspan>}<tspan dx={r.k ? 6 : 0} className="flow-kv-v">{r.v}</tspan>
        </text>
      : <text x={x} y={y} className="flow-sub">
          {r.k && <tspan className="flow-kv-k">{r.k.toUpperCase()}</tspan>}{r.v && <tspan dx={r.k ? 6 : 0} className="flow-kv-v">{r.v}</tspan>}
        </text>);

    // the box itself: tinted and outlined in its colour while power moves, faint when idle,
    // dashed once the grid has gone
    const card = (n, x, y, foot) => {
      const active = n.w > 5, tx = x + PL;
      return (
        <g key={n.key}>
          <rect x={x} y={y} width={BW} height={BH} rx={16} fill={active ? n.color : 'none'} fillOpacity={active ? 0.07 : 0}
            stroke={n.color} strokeOpacity={active ? 0.6 : 0.22} strokeWidth="1.3" strokeDasharray={n.off ? '5 4' : undefined} />
          {icon(n.icon, x + PL / 2, y + Y.iconC, n.color, active, n.soc, n.off)}
          <text x={tx} y={y + Y.label} className="flow-node-label">{n.label.toUpperCase()}</text>
          <text x={tx} y={y + Y.val} className="flow-node-val" fill={active ? n.color : 'var(--muted)'}>{pw(n.val ?? n.w)[0]}<tspan className="flow-node-unit"> {pw(n.val ?? n.w)[1]}</tspan></text>
          {kv(n.row, tx, y + Y.kv)}
          {foot && foot(tx, y + Y.foot)}
        </g>
      );
    };

    const barW = BW - PL - 16;   // a foot bar runs from the text column to the box's inner edge
    const feet = {
      // the charge strip and its %; the usual charge at this hour is its hover text
      bat: n => (x, fy) => (
        <g>
          {usualTitle && <title>{usualTitle}</title>}
          <rect x={x} y={fy - 2.5} width={barW - 38} height={5} rx={2.5} fill="rgba(255,255,255,0.08)" />
          <rect x={x} y={fy - 2.5} width={((barW - 38) * Math.max(0, Math.min(100, n.charge))) / 100} height={5} rx={2.5} fill={n.color} />
          <text x={x + barW} y={fy + 4.5} textAnchor="end" className="flow-pct" fill={n.color}>{n.charge}%</text>
        </g>
      ),
      // mains there or gone: a status, never green-tinted like solar's power
      grid: n => n.known && ((x, fy) => (
        <g>
          {n.off
            ? <circle cx={x + 3.5} cy={fy} r={2.75} fill="none" stroke="var(--dim)" strokeWidth="1.5" />
            : <circle cx={x + 3.5} cy={fy} r={3.5} fill="var(--ok)" />}
          <text x={x + 15} y={fy + 4.5} className="flow-grid-state">{n.off ? 'Grid off' : 'Grid on'}</text>
        </g>
      )),
    };

    // The split bar under Home: one segment per source feeding it, 2 apart. A 1% share is
    // a pixel wide, and a 2.5 radius on a 1px rect draws a smudge, so every segment gets a
    // readable minimum and the widest one pays for it; the radius never exceeds half a segment.
    const splitW = barW - 2 * Math.max(0, split.length - 1);
    const MIN_SEG = 6;
    const segW = split.map(s => (splitW * s.w) / splitTotal);
    const owed = segW.reduce((acc, w) => acc + Math.max(0, MIN_SEG - w), 0);
    if (owed > 0) {
      const widest = segW.indexOf(Math.max(...segW));
      segW.forEach((w, i) => { if (w < MIN_SEG) segW[i] = MIN_SEG; });
      segW[widest] = Math.max(MIN_SEG, segW[widest] - owed);
    }
    // Each share is named, with its % under the name. The first sits at the bar's left end,
    // the last ends flush with its right end, and a middle one starts under its own segment,
    // pushed along only as far as it needs to clear its neighbours (widths estimated: the
    // label font is ~7.6 per letter with its tracking, the % ~7.6 per digit; measured at
    // the 11px / 12.5px the overview cards use, SOLAR-16).
    const labelW = s => Math.max(s.label.length * 7.6, String(s.pct).length * 7.6 + 9);
    const homeFoot = (x, fy) => {
      let sx = x;
      const lx = split.map((s, i) => {
        if (i === 0) return x;
        if (i === split.length - 1) return x + barW;
        const segX = x + segW.slice(0, i).reduce((acc, w) => acc + w + 2, 0);
        const minX = x + labelW(split[0]) + 8;
        const maxX = x + barW - labelW(split[split.length - 1]) - 8 - labelW(s);
        return Math.min(maxX, Math.max(minX, segX));
      });
      return (
        <g>
          <rect x={x} y={fy - 2.5} width={barW} height={5} rx={2.5} fill="rgba(255,255,255,0.08)" />
          {split.map((s, i) => {
            const w = segW[i];
            const el = <rect key={s.label} x={sx} y={fy - 2.5} width={w} height={5} rx={Math.min(2.5, w / 2)} fill={s.color} />;
            sx += w + 2;
            return el;
          })}
          {split.map((s, i) => {
            const end = i > 0 && i === split.length - 1 ? 'end' : 'start';
            return (
              <g key={s.label}>
                <text x={lx[i]} y={fy + 20} textAnchor={end} className="flow-kv-k">{s.label.toUpperCase()}</text>
                <text x={lx[i]} y={fy + 35} textAnchor={end} className="flow-kv-v" style={{ fill: s.color }}>{s.pct}%</text>
              </g>
            );
          })}
        </g>
      );
    };

    return (
      <svg viewBox={`0 0 ${VW} ${H}`} className="flow-svg" preserveAspectRatio="xMidYMid meet"
        style={wall ? undefined : { width: VW, maxWidth: '100%', margin: '0 auto' }}>
        {left.map(lineFor)}
        {flowLine(curve(inR, hasGrid ? b : cy, rightX - 12, homeY + BH / 2), home.color, home.w, 'lhome', false)}
        <circle cx={invX} cy={cy} r={47} fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.24)" strokeWidth="1.3" />
        <circle cx={invX} cy={cy} r={47} fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth="8" />
        <g transform={`translate(${invX}, ${cy})`} strokeLinecap="round">
          <line x1={0} y1={-20} x2={0} y2={20} stroke="var(--text)" strokeOpacity="0.16" strokeWidth="1.2" />
          <line x1={-24} y1={-4} x2={-8} y2={-4} stroke="var(--soc)" strokeWidth="2.2" />
          <line x1={-22} y1={4} x2={-10} y2={4} stroke="var(--soc)" strokeWidth="2.2" strokeDasharray="3 3" />
          <path d="M 7 3 q 5 -11 9.5 0 q 4.5 11 9.5 0" stroke={C.pv} strokeWidth="2.2" fill="none" />
        </g>
        <text x={invX} y={cy - 62} textAnchor="middle" className="flow-inv-label">INVERTER{inverters > 1 ? 'S' : ''}</text>
        {left.map(n => card(n, at[n.key][0], at[n.key][1], feet[n.key] && feet[n.key](n)))}
        {card({ ...home, key: 'home', icon: 'home' }, rightX, homeY, homeFoot)}
      </svg>
    );
  }

  // ---------------- MOBILE (vertical, card-style HTML nodes) ----------------
  // Like desktop (SOLAR-20): Solar and Battery on top, Home and Grid below with Grid on the
  // right, the inverter between the two rows.
  function renderMobile() {
    const top = left.filter(n => n.key !== 'grid');
    const grid = left.find(n => n.key === 'grid');
    const bottom = [{ ...home, key: 'home', icon: 'home', split: true }, grid].filter(Boolean);
    // tile x-centres as %: the tiles share their row equally
    const cols = row => row.map((_, i) => ((i + 0.5) / row.length) * 100);
    const miniIcon = (type, color, soc, off) => (
      <svg width="17" height="17" viewBox="-11 -11 22 22">{icon(type, 0, 0, color, !off, soc, off)}</svg>
    );

    const mTile = (n) => {
      const active = n.w > 5;
      return (
        <div className="mtile" key={n.key}
          // same outline and tint strengths as the desktop cards
          style={{ borderColor: flowAlpha(n.color, active ? 0.6 : 0.22), borderStyle: n.off ? 'dashed' : undefined, background: active ? flowAlpha(n.color, 0.07) : undefined }}>
          <div className="mtile-head">
            {miniIcon(n.icon, n.color, n.soc, n.off)}
            <span className="mtile-label">{n.label}</span>
          </div>
          <div className="mtile-val" style={{ color: active ? n.color : 'var(--muted)' }}>{pw(n.val ?? n.w)[0]}<span className="u">{pw(n.val ?? n.w)[1]}</span></div>
          {n.row && (
            <div className="mtile-kv">
              {n.row.k && <span>{n.row.k}</span>}
              {n.row.on ? <button type="button" className="mini-link" onClick={n.row.on}>{n.row.v}</button> : n.row.v && <b>{n.row.v}</b>}
            </div>
          )}
          {n.charge != null && (
            <div className="mtile-charge" title={usualTitle}>
              <span className="mtile-strip"><i style={{ width: Math.max(0, Math.min(100, n.charge)) + '%', background: n.color }} /></span>
              <b style={{ color: n.color }}>{n.charge}%</b>
            </div>
          )}
          {n.known && <div className={'mtile-grid' + (n.off ? ' off' : '')}><i />{n.off ? 'Grid off' : 'Grid on'}</div>}
          {n.split && split.length > 0 && <>
            <div className="mflow-split">
              {split.map(s => <i key={s.label} style={{ flexGrow: s.w, background: s.color }} />)}
            </div>
            <div className="mflow-split-words">
              {split.map(s => <span key={s.label} style={{ color: s.color }}>{s.label} {s.pct}%</span>)}
            </div>
          </>}
        </div>
      );
    };

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
      <div className="mflow-sources" style={{ gridTemplateColumns: `repeat(${row.length}, minmax(0, 1fr))` }}>{row.map(mTile)}</div>
    );

    return (
      <div className="mflow">
        {tiles(top)}
        {linkStrip(top, false)}

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
  else if (gridExport > 50) narrative = <><b style={{ color: C.pv }}>Solar</b> is covering the home{hasBatt && charging ? ', charging the battery' : ''} and sending <b style={{ color: C.grid }}>{window.fmtPower(gridExport)}</b> to the grid.</>;
  // >= home - 50, not > home + 50: a home drawing exactly what the panels make is the
  // commonest sunny-afternoon state and fell through to the vague fallback.
  else if (agg.pvNow > 50 && agg.pvNow >= home.w - 50) narrative = <><b style={{ color: C.pv }}>Solar</b> is covering the home{hasBatt && charging ? ' and charging the battery' : ''}.</>;
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
