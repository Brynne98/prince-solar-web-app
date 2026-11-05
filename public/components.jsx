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
// Live power: whole watts under 1 kW ("450 W"), kilowatts from there ("1.25 kW") (SOLAR-24).
// Power is never kWh; that is energy. Chart axes keep kW throughout, one unit per axis.
function fmtPowerParts(w) {
  if (w == null || isNaN(w)) return ['—', ''];
  if (Math.abs(w) < 999.5) return [String(Math.round(w) || 0), 'W'];
  return [(w / 1000).toFixed(2), 'kW'];
}
function fmtPower(w) {
  const [v, u] = fmtPowerParts(w);
  return u ? v + ' ' + u : v;
}
// Battery power as shown everywhere: + = the house is using the battery, − = charging.
// There is no setting for it (SOLAR-71). Within ±5 W it is idle and shows 0, never −0.00.
function battShown(w) {
  if (w == null || isNaN(w)) return w;
  return Math.abs(w) <= 5 ? 0 : w;
}
// The hour it is AT THE PLANT, not on the viewer's device. An owner abroad, or a
// plant in another country, must see "typical at this hour" for the plant's hour.
function plantHour(tz, d = new Date()) {
  try {
    if (tz) return Number(new Intl.DateTimeFormat('en-GB', { timeZone: tz, hour: '2-digit', hour12: false }).format(d)) % 24;
  } catch (e) {}
  return d.getHours();
}
function fmtPlantTime(d, tz) {
  try { return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', timeZone: tz || undefined }); }
  catch (e) { return d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }); }
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
// A YYYY-MM-DD as words, "Fri 2 Oct" by default; opts for others ("2 October 2026").
// Read as UTC so the day never shifts with the device's zone.
function dayText(s, opts = { weekday: 'short', day: 'numeric', month: 'short' }) {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-GB', { ...opts, timeZone: 'UTC' }).replace(',', '');
}
/** Whole minutes as "12 min" / "2h 33m": spoken, not decimal hours, like everything else here. */
function fmtDuration(mins) {
  if (mins < 60) return mins + ' min';
  const h = Math.floor(mins / 60), m = mins % 60;
  return m ? h + 'h ' + m + 'm' : h + 'h';
}
// A plant's name, from any of its shapes (api_me's {id, name}, a login's {plant_id, plant_name}).
const plantLabel = (p) => p.name || p.plant_name || 'Plant ' + (p.id ?? p.plant_id);
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
// No space after a leading symbol: "R57", not the "R 57" en-ZA (and pt-BR) prints. Only the
// space straight after the symbol goes; thousands spaces and a symbol written after the
// amount ("12 MTn") are left alone.
function moneyText(dp, v) {
  const f = moneyFormatter(dp);
  if (!f.formatToParts) return f.format(v);
  const parts = f.formatToParts(v);
  return parts.filter((p, i) => !(p.type === 'literal' && /^\s+$/.test(p.value) && i > 0 && parts[i - 1].type === 'currency')).map(p => p.value).join('');
}
function fmtMoney(v, dp = 2) {
  if (v == null || isNaN(v)) return '—';
  return moneyText(dp, v);
}
// compact: switches to k above 10,000
function fmtMoneySmart(v) {
  if (v == null || isNaN(v)) return '—';
  if (Math.abs(v) >= 10000) return moneyText(1, v / 1000) + 'k';
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
// No coloured left edge: on a tab where every tile is the same subject it was six identical
// strips saying nothing, and where subjects differ the number already carries the colour.
function Card({ children, className = '', style = {}, ...rest }) {
  return (
    <div className={'card ' + className} style={style} {...rest}>
      {children}
    </div>);

}

// A bar filled to pct (0..100) in color. small: the mini tiles' thinner one.
const Meter = ({ pct, color, small }) => (
  <div className={'meter' + (small ? ' sm' : '')}><div className="meter-fill" style={{ width: Math.max(0, Math.min(100, pct)) + '%', background: color }} /></div>
);

// ---- Big number stat tile (the "4 tabs" the user liked) ---------------------
// locked: Free after its week (SOLAR-242), a faint shape for the figure and a lock under it
function StatTile({ label, value, unit, accent, sub, bar, loading, locked }) {
  if (locked) return (
    <Card className="stat-tile">
      <div className="stat-label">{label}</div>
      <div className="stat-value"><HistoryLock tile /></div>
      <div className="stat-sub"><button type="button" className="lock-btn" onClick={() => openPlans(locked)}><LockIcon />See every day</button></div>
    </Card>);
  return (
    <Card className="stat-tile">
      <div className="stat-label">{label}</div>
      {/* The placeholder is sized in the number's own font, so it is 44px on a desktop
          and 34px on a phone, like the number that replaces it. */}
      {loading
        ? <div className="stat-value"><span className="num" style={{ width: '65%' }}><Skeleton h="1em" /></span></div>
        : <div className="stat-value" style={{ color: accent }}>
            <span className="num">{value}</span>{unit && <span className="unit">{unit}</span>}
          </div>}
      {bar != null &&
      <Meter pct={bar} color={accent} />
      }
      {sub && <div className="stat-sub">{sub}</div>}
    </Card>);

}

// ---- Segmented control ------------------------------------------------------
// Every pick-one-of-a-few in the app is this one. disabled: drawn for real while its page loads.
function Segmented({ options, value, onChange, size = 'md', label, className = '', disabled }) {
  return (
    <div className={'segmented seg-' + size + (className ? ' ' + className : '')} role="group" aria-label={label}>
      {options.map((o) => {
        const val = typeof o === 'string' ? o : o.value;
        const lab = typeof o === 'string' ? o : o.label;
        return (
          <button key={val} type="button" className={'seg-btn' + (val === value ? ' active' : '')} aria-pressed={val === value}
          disabled={disabled} onClick={() => onChange(val)}>{lab}</button>);

      })}
    </div>);

}

// ---- Switch, and Toggle: a switch with its label --------------------------
// Every on/off in the app is this one. `label` names it when no <label> wraps it.
// loading: its value still on its way, so a shimmer in its place.
function Switch({ on, onChange, label, disabled, busy, loading }) {
  if (loading) return <Skeleton w={42} h={24} r={14} style={{ flex: 'none' }} />;
  return (
    <button type="button" className={'switch' + (on ? ' on' : '')} role="switch" aria-checked={on} aria-label={label}
            disabled={disabled} aria-busy={busy || undefined} onClick={() => onChange(!on)}>
      <span className="knob" />
    </button>);

}
function Toggle({ checked, onChange, label, hint, loading }) {
  const Row = loading ? 'div' : 'label';
  return (
    <Row className="toggle-row">
      <span className="toggle-text">
        <span className="toggle-label">{label}</span>
        {hint && <span className="toggle-hint">{hint}</span>}
      </span>
      <Switch on={checked} onChange={onChange} loading={loading} label={typeof label === 'string' ? label : undefined} />
    </Row>);

}

// A button whose request is on its way: off, marked busy, and saying so (busyText, e.g.
// "Saving…") in place of its words until it lands.
function BusyButton({ busy, busyText, disabled, type = 'button', className, onClick, children }) {
  return (
    <button type={type} className={className} onClick={onClick} disabled={!!busy || disabled} aria-busy={!!busy}>
      {busy && busyText ? busyText : children}
    </button>
  );
}

// One line of a chart's hover card: the series' dot, its name, its value (children).
// sq: a square dot, and the row in the dot's colour (an outage).
function TipRow({ color, label, sq, children }) {
  return (
    <div className="tip-row" style={sq ? { color } : undefined}>
      <span className={'tip-dot' + (sq ? ' tip-sq' : '')} style={{ background: color }} />
      <span className="tip-l">{label}</span><span className="tip-v mono">{children}</span>
    </div>
  );
}

// ---- Legend chip (clickable series toggle) ----------------------------------
function LegendChip({ color, label, value, active, onClick }) {
  const valStyle = active ? { color } : {};
  return (
    <button className={'legend-chip' + (active ? '' : ' off')} onClick={onClick}>
      {label}
      {value != null && <span className="legend-val" style={valStyle}>{value}</span>}
    </button>);

}

// ---- Skeleton ---------------------------------------------------------------
// A shimmering block standing in for content that hasn't arrived, so the page keeps its
// shape instead of collapsing to a spinner. `as` for a span inside a line of text.
function Skeleton({ w = '100%', h = 14, r = 7, style = {}, className = '', as: Tag = 'div' }) {
  return <Tag className={'skel ' + className} style={{ width: w, height: h, borderRadius: r, ...style }} />;
}

// A line of text still on its way, inline in the line's place. max: the widest it gets.
const SkelLine = ({ w, h = 12, max = '100%' }) => <Skeleton w={w} h={h} r={5} style={{ display: 'inline-block', verticalAlign: 'middle', maxWidth: max }} />;
// ---- Info tooltip dot -------------------------------------------------------
// On open, shift the 210px bubble so it stays 8px inside the window (SOLAR-26).
const placeBubble = (e) => {
  const r = e.currentTarget.getBoundingClientRect(), half = 105, mid = r.left + r.width / 2;
  const shift = Math.max(8 + half - mid, Math.min(0, window.innerWidth - 8 - half - mid));
  e.currentTarget.style.setProperty('--shift', Math.round(shift) + 'px');
  // near the top the sticky header would cover it, so it opens downward instead
  e.currentTarget.classList.toggle('below', r.top < 200);
};
// InfoDot's bubble on anything: hover, a tap or focus opens it. Every hint in the app is
// one of the two, never the browser's title, which a phone can't open. Its bubble is fixed
// to the window, so a box that clips (the flow's, a bar) can't cut it off; it follows on scroll.
const placeTip = (el) => {
  const r = el.getBoundingClientRect(), half = 105, mid = r.left + r.width / 2;
  const x = Math.max(8 + half, Math.min(window.innerWidth - 8 - half, mid));
  el.style.setProperty('--tx', Math.round(x) + 'px');
  // near the top a bubble above covers the header and controls, so it opens downward
  el.classList.toggle('below', r.top < 200);
  el.style.setProperty('--ty', Math.round(el.classList.contains('below') ? r.bottom + 9 : r.top - 9) + 'px');
  el.style.setProperty('--arrow', Math.round(mid - x) + 'px');
};
document.addEventListener('scroll', () => document.querySelectorAll('.tip:hover, .tip:focus').forEach(placeTip), true);
function Tip({ text, as: Tag = 'span', className = '', children, ...rest }) {
  const id = React.useId();
  if (!text) return <Tag className={className || undefined} {...rest}>{children}</Tag>;
  const place = (e) => placeTip(e.currentTarget);
  return (
    <Tag className={'tip ' + className} tabIndex={0} aria-describedby={id} onMouseEnter={place} onFocus={place} {...rest}>
      {children}<span id={id} className="info-bubble" role="tooltip">{text}</span>
    </Tag>);

}
function InfoDot({ text }) {
  // aria-describedby ties the bubble to the dot, so a screen reader on the dot hears the
  // explanation instead of an unnamed note.
  const id = React.useId();
  return (
    <span className="info-dot" tabIndex={0} aria-label="More about this" aria-describedby={id} onMouseEnter={placeBubble} onFocus={placeBubble}>
      <svg width="13" height="13" viewBox="0 0 16 16" aria-hidden="true">
        <circle cx="8" cy="8" r="7" fill="none" stroke="currentColor" strokeWidth="1.3" />
        <path d="M6.1 6.3a1.95 1.95 0 1 1 2.8 1.75c-.55.3-.9.65-.9 1.25v.35" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
        <circle cx="8" cy="11.7" r="0.85" fill="currentColor" />
      </svg>
      <span id={id} className="info-bubble" role="tooltip">{text}</span>
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

// ---- the free week (SOLAR-242) ----------------------------------------------
// api_me's freeWeekEndsAt (0122) is set only for a Free account with a week on record.
// { week } inside it, { over } after it; null for paid, comped and older accounts.
// After it nothing is hidden: the user's own figure shows greyed or blurred with a
// lock, and where history would be, a faint shape and one line. Each opens the plans.
function freeState(me, now = Date.now()) {
  const end = me && me.plan === 'free' && me.freeWeekEndsAt ? Date.parse(me.freeWeekEndsAt) : NaN;
  if (!Number.isFinite(end)) return null;
  return now < end ? { week: true } : { over: true };
}
const FreeCtx = React.createContext(null);
const useFreeOver = () => !!(React.useContext(FreeCtx) || {}).over;
// App listens and opens the plans sheet; `where` names the spot, for analytics only.
function openPlans(where) {
  window.track('lock_tapped', { where });
  window.dispatchEvent(new CustomEvent('ps-plans', { detail: where }));
}
const LockIcon = () => (
  <svg className="lock-ico" width="12" height="12" viewBox="0 0 16 16" aria-hidden="true">
    <rect x="3" y="7" width="10" height="7.5" rx="1.6" fill="currentColor" />
    <path d="M5.25 7V5.1a2.75 2.75 0 0 1 5.5 0V7" fill="none" stroke="currentColor" strokeWidth="1.5" />
  </svg>
);
// The user's own figure, greyed (or blurred), and a lock with `label` that opens the plans.
function Locked({ where, label, blur, children }) {
  return (
    <span className={'locked' + (blur ? ' blur' : '')}>
      <span className="locked-v" aria-hidden="true">{children}</span>
      <button type="button" className="lock-btn" onClick={() => openPlans(where)}><LockIcon />{label}</button>
    </span>
  );
}
// Where history would show: faint bars and the one line. `tile` = a stat tile's value.
const FAINT = [42, 58, 35, 66, 50, 72, 46, 61, 38, 70, 55, 64, 44, 52];
function HistoryLock({ where, tile }) {
  if (tile) return <span className="faint-num" aria-hidden="true" />;
  return (
    <div className="hist-lock">
      <div className="hl-shape" aria-hidden="true">{FAINT.map((h, i) => <i key={i} style={{ height: h + '%' }} />)}</div>
      <button type="button" className="hl-line" onClick={() => openPlans(where)}>
        <LockIcon /><span>Free keeps the last 24 hours. <b>See every day →</b></span>
      </button>
    </div>
  );
}

Object.assign(window, {
  freeState, FreeCtx, useFreeOver, openPlans, LockIcon, Locked, HistoryLock,
  COLORS, fmtPower, fmtPowerParts, battShown, localDateStr, shiftDate, dayText, fmtDuration, plantLabel, fmtKwh, fmtRand, fmtTime, cleanTemp, plantHour, fmtPlantTime,
  Card, StatTile, Segmented, Switch, Toggle, LegendChip, SectionTitle, InfoDot, Tip,
  Skeleton, SkelLine, BusyButton, TipRow, Meter,
  fmtEnergySmart, fmtRandSmart, fmtEnergyParts, fmtMoney, fmtMoneySmart, moneySymbol
});