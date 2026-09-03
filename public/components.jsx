// ============================================================================
// components.jsx — shared atoms + formatting helpers + the energy palette
// ============================================================================

const COLORS = {
  pv: '#3ddc84', // solar green
  batt: '#a78bfa', // battery purple
  grid: '#facc15', // grid yellow
  load: '#f87171', // load red
  soc: '#22d3ee' // SOC (state of charge) cyan
};

// ---- formatting -------------------------------------------------------------
function fmtPower(w) {
  if (w == null || isNaN(w)) return '—';
  return (w / 1000).toFixed(2) + ' kWh';
}
function fmtPowerParts(w) {
  if (w == null || isNaN(w)) return ['—', ''];
  return [(w / 1000).toFixed(2), 'kWh'];
}
function fmtKwh(k) {
  if (k == null || isNaN(k)) return '—';
  return (Math.round(k * 10) / 10).toLocaleString('en', { minimumFractionDigits: 1, maximumFractionDigits: 1 }) + ' kWh';
}
// compact energy: switches to MWh above 1,000 kWh so big totals stay short
function fmtEnergySmart(k) {
  if (k == null || isNaN(k)) return '—';
  if (Math.abs(k) >= 1000) return (k / 1000).toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' MWh';
  return fmtKwh(k);
}
// energy as [number, unit] for big stat tiles (kWh, or MWh above 1,000)
function fmtEnergyParts(k) {
  if (k == null || isNaN(k)) return ['—', ''];
  if (Math.abs(k) >= 1000) return [(k / 1000).toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 }), 'MWh'];
  return [(Math.round(k * 10) / 10).toLocaleString('en', { minimumFractionDigits: 1, maximumFractionDigits: 1 }), 'kWh'];
}
// Money in the plant's currency. Intl handles symbol, placement and decimals for
// any ISO code, so a UK plant shows £ and an Irish one € with nothing else changing.
const _moneyFmt = {};
// The currency's home locale, so R / £ / € / A$ render as their owners expect rather
// than as "ZAR 12" in a browser set to another language.
const CURRENCY_LOCALE = { ZAR: 'en-ZA', GBP: 'en-GB', EUR: 'en-IE', AUD: 'en-AU', NZD: 'en-NZ', USD: 'en-US', KES: 'en-KE', NGN: 'en-NG', ZMW: 'en-ZM', BWP: 'en-BW', NAD: 'en-NA', MZN: 'pt-MZ', INR: 'en-IN', PKR: 'en-PK', BRL: 'pt-BR' };
function moneyFormatter(dp) {
  const cur = window.PLANT_CURRENCY || 'ZAR';
  const key = cur + ':' + dp;
  if (!_moneyFmt[key]) {
    try {
      _moneyFmt[key] = new Intl.NumberFormat(CURRENCY_LOCALE[cur] || navigator.language || 'en', { style: 'currency', currency: cur, minimumFractionDigits: dp, maximumFractionDigits: dp });
    } catch (e) {
      _moneyFmt[key] = { format: (v) => cur + '\u2009' + v.toFixed(dp) };
    }
  }
  return _moneyFmt[key];
}
function fmtMoney(v, dp = 2) {
  if (v == null || isNaN(v)) return '—';
  return moneyFormatter(dp).format(v);
}
// compact: switches to k above 10,000
function fmtMoneySmart(v) {
  if (v == null || isNaN(v)) return '—';
  if (Math.abs(v) >= 10000) return moneyFormatter(1).format(v / 1000) + 'k';
  return fmtMoney(v, 0);
}
// the symbol alone, for labels like "R/kWh"
function moneySymbol() {
  try { return moneyFormatter(0).formatToParts(0).find(p => p.type === 'currency')?.value || window.PLANT_CURRENCY; }
  catch (e) { return window.PLANT_CURRENCY || ''; }
}
const fmtRand = fmtMoney, fmtRandSmart = fmtMoneySmart;
function fmtTime(d) {
  return d.toLocaleTimeString('en', { hour: '2-digit', minute: '2-digit', hour12: false });
}
// bad-sensor guard (e.g. battery temp -100°C per API caveat)
function cleanTemp(t) {return t == null || t <= -50 || t > 120 ? null : t;}

// ---- Card -------------------------------------------------------------------
function Card({ accent, children, className = '', style = {}, ...rest }) {
  return (
    <div className={'card ' + className}
    style={{ borderLeft: accent ? `2px solid ${accent}` : undefined, ...style }} {...rest}>
      {children}
    </div>);

}

// ---- Big number stat tile (the "4 tabs" the user liked) ---------------------
function StatTile({ label, value, unit, accent, sub, bar, loading }) {
  return (
    <Card accent={accent} className="stat-tile">
      <div className="stat-label">{label}</div>
      {loading
        ? <div className="stat-value"><Skeleton w="65%" h={44} /></div>
        : <div className="stat-value" style={{ color: accent }}>
            <span className="num">{value}</span>{unit && <span className="unit">{unit}</span>}
          </div>}
      {bar != null &&
      <div className="meter"><div className="meter-fill" style={{ width: Math.max(0, Math.min(100, bar)) + '%', background: accent }} /></div>
      }
      {sub && <div className="stat-sub">{sub}</div>}
    </Card>);

}

// ---- Small label / readout row ---------------------------------------------
function Metric({ label, value, unit, accent, mono = true }) {
  return (
    <div className="metric">
      <div className="metric-label">{label}</div>
      <div className="metric-value" style={{ color: accent || 'var(--text)' }}>
        <span className={mono ? 'mono' : ''}>{value}</span>
        {unit && <span className="metric-unit">{unit}</span>}
      </div>
    </div>);

}

// ---- Badge ------------------------------------------------------------------
function Badge({ tone = 'neutral', children, dot }) {
  return <span className={'badge badge-' + tone}>{dot && <i className="badge-dot" />}{children}</span>;
}

// ---- Segmented control ------------------------------------------------------
function Segmented({ options, value, onChange, size = 'md' }) {
  return (
    <div className={'segmented seg-' + size}>
      {options.map((o) => {
        const val = typeof o === 'string' ? o : o.value;
        const lab = typeof o === 'string' ? o : o.label;
        return (
          <button key={val} className={'seg-btn' + (val === value ? ' active' : '')}
          onClick={() => onChange(val)}>{lab}</button>);

      })}
    </div>);

}

// ---- Toggle (switch) --------------------------------------------------------
function Toggle({ checked, onChange, label, hint }) {
  return (
    <label className="toggle-row">
      <span className="toggle-text">
        <span className="toggle-label">{label}</span>
        {hint && <span className="toggle-hint">{hint}</span>}
      </span>
      <button className={'switch' + (checked ? ' on' : '')} onClick={() => onChange(!checked)} role="switch" aria-checked={checked}>
        <span className="knob" />
      </button>
    </label>);

}

// ---- Legend chip (clickable series toggle) ----------------------------------
function LegendChip({ color, label, value, active, onClick }) {
  // kWh values reserve room for a negative 2-decimal number; % values are short, so narrow them
  const pct = value != null && String(value).trim().endsWith('%');
  const valStyle = { ...(active ? { color } : {}), ...(pct ? { minWidth: '5ch' } : {}) };
  return (
    <button className={'legend-chip' + (active ? '' : ' off')} onClick={onClick}>
      <span className="legend-dot" style={{ background: active ? color : 'transparent', borderColor: color }} />
      {label}
      {value != null && <span className="legend-val" style={valStyle}>{value}</span>}
    </button>);

}

// ---- tiny inline sparkline --------------------------------------------------
function Sparkline({ data, color, width = 120, height = 32, fill = true }) {
  const vals = data.filter((v) => v != null);
  if (!vals.length) return <svg width={width} height={height} />;
  const max = Math.max(...vals, 1),min = Math.min(...vals, 0);
  const rng = max - min || 1;
  const step = width / (data.length - 1);
  let d = '',area = '';
  data.forEach((v, i) => {
    if (v == null) return;
    const x = i * step,y = height - (v - min) / rng * (height - 4) - 2;
    d += (d ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1) + ' ';
    area += (area ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1) + ' ';
  });
  area += `L ${width} ${height} L 0 ${height} Z`;
  const gid = 'sg' + color.replace('#', '');
  return (
    <svg width={width} height={height} className="sparkline">
      {fill && <defs><linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stopColor={color} stopOpacity="0.28" />
        <stop offset="100%" stopColor={color} stopOpacity="0" />
      </linearGradient></defs>}
      {fill && <path d={area} fill={`url(#${gid})`} />}
      <path d={d} fill="none" stroke={color} strokeWidth="1.6" strokeLinejoin="round" strokeLinecap="round" />
    </svg>);

}

// ---- Info tooltip dot -------------------------------------------------------
// Skeleton placeholder. A shimmering block standing in for content that hasn't
// arrived, so the page keeps its shape instead of collapsing to a spinner.
function Skeleton({ w = '100%', h = 14, r = 7, style = {}, className = '' }) {
  return <div className={'skel ' + className} style={{ width: w, height: h, borderRadius: r, ...style }} />;
}

// A stat tile's worth of skeleton — label line, value line, matching the real card so
// nothing jumps when the data lands.
// The LABEL is static text, so it renders for real — only the value shimmers. Heights
// are measured off the live card (.mini-label 14px, .mini-value 26px) so the tile lands
// at the same 95px either way and nothing shifts when the number arrives.
function SkeletonTile({ label }) {
  return (
    <Card className="mini-stat">
      <div className="mini-label">{label}</div>
      <div className="mini-value"><Skeleton w="72%" h={26} /></div>
    </Card>
  );
}

function InfoDot({ text }) {
  return (
    <span className="info-dot" tabIndex={0} role="note">
      <svg width="13" height="13" viewBox="0 0 16 16" aria-hidden="true">
        <circle cx="8" cy="8" r="7" fill="none" stroke="currentColor" strokeWidth="1.3" />
        <circle cx="8" cy="4.7" r="1" fill="currentColor" />
        <rect x="7.25" y="6.9" width="1.5" height="5" rx="0.75" fill="currentColor" />
      </svg>
      <span className="info-bubble">{text}</span>
    </span>);

}

// ---- Section heading --------------------------------------------------------
function SectionTitle({ children, right }) {
  return (
    <div className="section-title">
      <span>{children}</span>
      {right && <span className="section-right">{right}</span>}
    </div>);

}

Object.assign(window, {
  COLORS, fmtPower, fmtPowerParts, fmtKwh, fmtRand, fmtTime, cleanTemp,
  Card, StatTile, Metric, Badge, Segmented, Toggle, LegendChip, Sparkline, SectionTitle, InfoDot,
  Skeleton, SkeletonTile,
  fmtEnergySmart, fmtRandSmart, fmtEnergyParts, fmtMoney, fmtMoneySmart, moneySymbol
});