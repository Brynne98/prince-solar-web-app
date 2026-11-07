// ============================================================================
// app.jsx — shell + live data owner: header, tab bar, fetch/refresh, persistence
// Fetches /api/overview (live snapshot) on a 60s tick, /api/history
// (today's chart) every 5 min, and lazily loads /api/energy per period on demand.
// ============================================================================
const { useState, useEffect, useRef, useCallback } = React;

// Every page always shows and battery power always reads + = the house is using it; the
// old per-user switches for both are gone (SOLAR-71), so drop what they left behind.
try { localStorage.removeItem('synsynk.settings'); } catch (e) {}

// "2 min ago" for the header; ticks with useNow so it stays honest between refreshes.
function fmtAgo(d, now) {
  const s = Math.max(0, Math.round((now - d.getTime()) / 1000));
  if (s < 45) return 'just now';
  const m = Math.round(s / 60);
  if (m < 90) return m + ' min ago';
  const h = Math.round(m / 60);
  if (h < 36) return h + 'h ago';
  return readAgo(d.getTime(), now); // older than a day and a half: the date and time
}
// How long ago a reading was, the way the cards say it: the time, and the date once it is over a day and a half old.
const readAgo = (t, now) => now - t > 36 * 3600e3
  ? new Date(t).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) + ', ' + window.fmtTime(new Date(t))
  : window.fmtTime(new Date(t));
function useNow(ms) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), ms); return () => clearInterval(t); }, [ms]);
  return now;
}
Object.assign(window, { fmtAgo, readAgo, useNow, plantStatus }); // Equipment's reading ages; Solar and Grid's silent plant

// Header status: one word, coloured. Live = fresh data and every inverter up;
// Stale = the poller is behind (> 3 min) or an inverter is down; Offline = no data
// for 15 min or nothing reporting.
function plantStatus(snap, now) {
  const online = snap.inverters.filter(i => i.status === 'online').length;
  const total = snap.inverters.length;
  const offline = total - online;
  const last = snap.lastReading || snap.updated;
  // Judged as of the last answer, not the clock: a hidden page stops asking (SOLAR-140),
  // and coming back read red until the catch-up landed (SOLAR-149).
  const ageS = (Math.min(now, snap.updated.getTime()) - last.getTime()) / 1000;
  const bad = (total > 0 && offline >= total) || ageS > 900 ? 'offline' : (offline > 0 || ageS > 180) ? 'stale' : 'live';
  // A plant's first 60 days are still loading (SOLAR-167): its newest stored day is
  // the load's, not the inverters', and a slow second inverter isn't news yet.
  // Say it's loading instead of Offline or Stale; "Fetching history" sits beside it.
  const loading = window.syncProgress(snap.sync) != null;
  const status = loading && bad !== 'live' ? 'loading' : bad;
  return {
    status, last, old: status !== 'loading' && ageS > 180,
    // every login dead (snap.loginCut, set by App): Reconnect in red as soon as the poller
    // marks it, not after 15 min silent (SOLAR-385). tone is the colour; status stays the age.
    tone: snap.loginCut ? 'offline' : status,
    // today's figures are not now: greyed (an old reading or a dead login), SOLAR-386
    faded: !!snap.loginCut || (status !== 'loading' && ageS > 180),
    word: snap.loginCut ? 'Reconnect' : { live: 'Live', stale: 'Stale', offline: 'Offline', loading: 'Setting up' }[status],
    detail: offline > 0 ? offline + ' of ' + total + ' inverters offline' : 'updated ' + fmtAgo(last, now),
  };
}

// The status pill's dot and word, then what it adds (children).
const StatusBits = ({ word, children }) => <><span className="status-dot" /><span className="status-word">{word}</span>{children}</>;

// The same status on the fullscreen flow, which covers the header. Its own clock, so
// the tick re-renders this line and not the Live tab.
function WallStatus({ snap }) {
  const s = plantStatus(snap, useNow(15000));
  return (
    <window.Tip className={'wall-status below status-' + s.tone} text={'Last reading ' + window.fmtTime(s.last)}>
      <StatusBits word={s.word}><span className="status-detail">{s.detail}</span></StatusBits>
    </window.Tip>
  );
}
window.WallStatus = WallStatus;

// ---- the frame (SOLAR-13) ---------------------------------------------------
// A sidebar of pages with the account at its foot, a header with the plant and its
// status, and on a phone a bottom bar instead of the sidebar. Tablet (600–1023 px)
// narrows the sidebar to an icon rail in CSS; nothing here knows the width.

const NAV_ICONS = {
  tick: '<polyline points="20 6 9 17 4 12"/>',
  live: '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
  solar: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  battery: '<rect x="2" y="7" width="16" height="10" rx="2"/><path d="M22 11v2M6 11v2M10 11v2"/>',
  home: '<path d="M3 11 12 3l9 8"/><path d="M5 9.5V21h14V9.5"/><path d="M10 21v-6h4v6"/>',
  grid: '<path d="M13 2 3 14h9l-1 8 10-12h-9l1-8z"/>',
  inverters: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 12h4"/><circle cx="16" cy="12" r="2"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
  system: '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
  more: '<circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>',
  account: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  signout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><path d="m16 17 5-5-5-5"/><path d="M21 12H9"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  close: '<path d="M6 6l12 12M18 6 6 18"/>',
  back: '<path d="m15 6-6 6 6 6"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
  plug: '<path d="M9 2v6M15 2v6M6 8h12v4a6 6 0 0 1-12 0V8zM12 18v4"/>',
  power: '<path d="M12 2v9"/><path d="M6.3 6.3a8 8 0 1 0 11.4 0"/>',
  bell: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
  next: '<path d="m9 6 6 6-6 6"/>',
  card: '<rect x="2.5" y="5" width="19" height="14" rx="2"/><path d="M2.5 10h19M6.5 15h4"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  calendar: '<rect x="3.5" y="5" width="17" height="15" rx="2"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
  panel: '<path d="M5 4h14l2 11H3z"/><path d="M4 9.5h16M9.7 4l-.7 11M14.3 4l.7 11M12 15v5M8 20h8"/>',
};
// fixed strings from the table above, never data
const Icon = ({ id, className }) => <svg className={'ico' + (className ? ' ' + className : '')} viewBox="0 0 24 24" aria-hidden="true" dangerouslySetInnerHTML={{ __html: NAV_ICONS[id] }} />;

// While on, Escape anywhere on the page calls onEscape (the latest one passed).
function useEscape(on, onEscape) {
  const fn = useRef(onEscape);
  fn.current = onEscape;
  useEffect(() => {
    if (!on) return;
    const key = e => { if (e.key === 'Escape') fn.current(e); };
    document.addEventListener('keydown', key);
    return () => document.removeEventListener('keydown', key);
  }, [on]);
}

// A motion step from :root in ms (SOLAR-351); 0 under reduced motion.
const motionMs = (name) => parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name)) || 0;
window.motionMs = motionMs;
// [shown, leaving] for a pop-up that is `on`: once off it stays shown for --dur-fast with
// leaving true, so its CSS can play it out (pop-out, sheet-out).
function useExit(on) {
  const [shown, setShown] = useState(on);
  useEffect(() => {
    if (on) { setShown(true); return; }
    const t = setTimeout(() => setShown(false), motionMs('--dur-fast'));
    return () => clearTimeout(t);
  }, [on]);
  return [on || shown, !on && shown];
}

// An open menu closes on a click elsewhere or Escape (focus goes back to its button), and
// takes the arrow keys while focus is inside it. No keyboard shortcuts beyond that, by decision.
// The open state it hands back stays true while the menu leaves; its box gets [data-leaving].
function usePopover() {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return;
    const away = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener('pointerdown', away);
    return () => document.removeEventListener('pointerdown', away);
  }, [open]);
  useEscape(open, () => { setOpen(false); ref.current?.querySelector('button')?.focus(); });
  const [shown, leaving] = useExit(open);
  React.useLayoutEffect(() => { ref.current?.toggleAttribute('data-leaving', leaving); }, [leaving]);
  return [shown, setOpen, ref];
}
function MenuList({ className, label, children }) {
  const ref = useRef(null);
  useEffect(() => { (ref.current.querySelector('[aria-checked="true"]') || ref.current.querySelector('button'))?.focus(); }, []);
  const keys = e => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
    const items = [...ref.current.querySelectorAll('button:not(:disabled)')], i = items.indexOf(document.activeElement);
    const n = e.key === 'Home' ? 0 : e.key === 'End' ? items.length - 1 : (i + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
    items[n]?.focus(); e.preventDefault();
  };
  return <div className={'menu ' + className} role="menu" aria-label={label} ref={ref} onKeyDown={keys}>{children}</div>;
}
// A choice in a form: a field-sized button that opens a MenuList, the chosen row ticked.
// The app's own, never the browser's <select>, so it looks the same everywhere.
function PickMenu({ id, label, value, options, onPick }) {
  const [open, setOpen, ref] = usePopover();
  const cur = options.find(o => o.value === value);
  return (
    <div className="pick" ref={ref}>
      <button type="button" id={id} className="fs-in pick-btn" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(o => !o)}>
        <span className="pick-val">{cur ? cur.label : ''}</span><Icon id="chevron" />
      </button>
      {open && (
        <MenuList className="pick-menu" label={label}>
          {options.map(o => (
            <button key={o.value} type="button" role="menuitemradio" aria-checked={o.value === value}
                    onClick={() => { setOpen(false); ref.current.querySelector('button').focus(); if (o.value !== value) onPick(o.value); }}>
              <span aria-hidden="true">{o.value === value ? '✓' : ''}</span><span className="nm">{o.label}</span>
            </button>
          ))}
        </MenuList>
      )}
    </div>
  );
}

// One menu row's state, by the header's rules (SOLAR-182): a dead login reads Reconnect.
function MenuState({ st, cut, now }) {
  if (cut) return <span className="pm-state status-offline"><span className="pm-dot" />Reconnect</span>;
  if (!st || st.lastTs == null) return null;
  const s = plantStatus({
    inverters: Array.from({ length: st.inverters || 0 }, (_, i) => ({ status: i < (st.online || 0) ? 'online' : 'offline' })),
    lastReading: new Date(st.lastTs * 1000), updated: new Date(now), sync: st.sync,
  }, now);
  const p = window.syncProgress(st.sync);
  // still on its first load: Setting up, even when its readings are live
  const status = p != null ? 'loading' : s.status, word = p != null ? 'Setting up' : s.word;
  return (
    <span className={'pm-state status-' + status}>
      {p != null ? <span className="sync-arc" aria-hidden="true" /> : <span className="pm-dot" />}{word}
      {p != null && <span className="mono pm-pct">{Math.round(100 * p)}%</span>}
      {status === 'stale' && <span className="mono pm-pct">{window.fmtTime(s.last)}</span>}
    </span>
  );
}

// The plant on screen, left in the header; a menu once there is more than one. Each row
// says how its plant is doing, asked when the menu opens (SOLAR-182).
// Grouped by SunSynk login (SOLAR-251): each login's email, then its plants. A stopped
// plant has no readings to open; it reads Stopped and opens Billing, where it starts.
function PlantMenu({ me, plantId, onPlant, fallback, cutOff, currentSync, accounts, onStopped }) {
  const plants = me?.plants || [];
  const current = plants.find(p => p.id === plantId);
  const name = current ? window.plantLabel(current) : (fallback || '');
  const [open, setOpen, ref] = usePopover();
  const [states, setStates] = useState({});
  useEffect(() => {
    if (!open) return;
    let alive = true;
    window.fetchPlantStates().then(rows => {
      if (alive) setStates({ at: Date.now(), ...Object.fromEntries(rows.map(r => [r.id, r])) });
    }).catch(() => {});
    return () => { alive = false; };
  }, [open]);
  // Each plant once, under the first login that brings it.
  const seen = new Set();
  const groups = (accounts || []).filter(a => a.status !== 'disabled').map(a => ({
    login: a.sunsynk_username,
    plants: (a.plants || []).filter(p => !seen.has(p.plant_id) && seen.add(p.plant_id)),
  })).filter(g => g.plants.length);
  const total = groups.reduce((n, g) => n + g.plants.length, 0);
  if (Math.max(total, plants.length) < 2 || !onPlant) return <div className="plant"><span className="plant-btn static"><span className="plant-name">{name}</span></span></div>;
  return (
    <div className="plant" ref={ref}>
      <button type="button" className="plant-btn" aria-haspopup="menu" aria-expanded={open} aria-label={'Plant: ' + name + '. Switch plant'} onClick={() => setOpen(o => !o)}>
        <span className="plant-name">{name}</span><Icon id="chevron" />
      </button>
      {open && (
        <MenuList className="plant-menu" label="Plants">
          {(groups.length ? groups : [{ login: null, plants: plants.map(p => ({ plant_id: p.id })) }]).map(g => (
            <div key={g.login || ''} role="group" aria-label={g.login || 'Plants'}>
              {g.login && <div className="pm-login" aria-hidden="true">{g.login}</div>}
              {g.plants.map(row => {
                const p = plants.find(x => x.id === row.plant_id);
                if (!p) {
                  return (
                    <button key={row.plant_id} type="button" role="menuitem" className="pm-stopped"
                            onClick={() => { setOpen(false); onStopped && onStopped(); }}>
                      <span className="tick" aria-hidden="true" /><span className="nm">{window.plantLabel(row)}</span>
                      <span className="pm-state">Stopped</span>
                    </button>
                  );
                }
                // the plant on screen takes the header's progress, so the two % always match
                const st = states[p.id] && { ...states[p.id], sync: p.id === plantId && currentSync ? currentSync : window.firstLoadSync(states[p.id].sync, p.linkedAt) };
                return (
                  <button key={p.id} type="button" role="menuitemradio" aria-checked={p.id === plantId}
                          onClick={() => { setOpen(false); if (p.id !== plantId) onPlant(p.id); }}>
                    <span className="tick" aria-hidden="true">{p.id === plantId ? '✓' : ''}</span><span className="nm">{window.plantLabel(p)}</span>
                    <MenuState st={st} cut={cutOff && cutOff(p.id)} now={states.at || Date.now()} />
                  </button>
                );
              })}
            </div>
          ))}
        </MenuList>
      )}
    </div>
  );
}

// The person: avatar, name and plant count in the sidebar; the avatar alone in a phone's
// header. A dead SunSynk login puts a red dot on the avatar and on Account.
// stepsLeft (the free week, SOLAR-242): a dot on the avatar and the count on Settings
function AccountMenu({ user, plantCount, alert, stepsLeft, onSettings, active, variant }) {
  const [open, setOpen, ref] = usePopover();
  // plantCount is null while the plants load: the row shows, its count shimmers
  const sub = alert ? 'Reconnect a login' : plantCount == null ? '' : plantCount + (plantCount === 1 ? ' plant' : ' plants');
  return (
    <div className={'acct acct-' + variant} ref={ref}>
      <button type="button" className={'acct-btn' + (alert ? ' needs' : stepsLeft ? ' steps' : '')} aria-haspopup="menu" aria-expanded={open}
              aria-current={active ? 'page' : undefined} onClick={() => setOpen(o => !o)}
              aria-label={'Account menu' + (alert ? '. A SunSynk login needs reconnecting' : stepsLeft ? '. Setup steps left' : '')}>
        <span className="avatar" aria-hidden="true">{user.initials}</span>
        {variant === 'rail' && <span className="who" aria-hidden="true"><b>{user.name}</b><span className={alert ? 'bad' : ''} style={sub ? undefined : { position: 'relative' }}>{sub || <>{'\u00a0'}<window.Skeleton as="span" w={52} h={11} r={6} style={{ position: 'absolute', left: 0, top: 2 }} /></>}</span></span>}
      </button>
      {open && (
        <MenuList className="acct-menu" label="Account">
          <div className="menu-email">{user.email}</div>
          {/* Settings left the page list for here (SOLAR-224); Account, Billing and Plant are
              one Settings area since SOLAR-250 */}
          <button type="button" onClick={() => { setOpen(false); onSettings(); }}>
            <Icon id="settings" />Settings{stepsLeft > 0 && <span className="menu-left">{stepsLeft} left</span>}
            {alert && <span className="dot" aria-label="A login needs reconnecting" />}
          </button>
          <hr />
          <window.SignOutButton className="menu-signout"><Icon id="signout" />Sign out</window.SignOutButton>
        </MenuList>
      )}
    </div>
  );
}

function Sidebar({ tabs, tab, onTab, account, steps }) {
  return (
    <aside className="rail">
      <div className="rail-logo"><span className="sun" aria-hidden="true" /><span className="app-name">Prince Solar Hub</span></div>
      <nav className="nav" aria-label="Pages">
        {tabs.map(t => (
          <button key={t.id} type="button" aria-current={tab === t.id ? 'page' : undefined}
                  onClick={onTab && (() => onTab(t.id))} disabled={!onTab}>
            <Icon id={t.id} /><span className="t">{t.label}</span>
          </button>
        ))}
        {steps && steps('rail')}
      </nav>
      {account && <AccountMenu {...account} variant="rail" />}
    </aside>
  );
}

// A sheet up from the bottom of a phone. A tap on the dimmed page or Escape closes it; focus
// goes into it on open, unless something inside took it first, and back to `opener` (a
// selector) on Escape. `label` makes the panel the dialog; leave it out when the content is one.
function Sheet({ label, onClose, opener, className = '', children }) {
  const ref = useRef(null);
  useEffect(() => { if (!ref.current.contains(document.activeElement)) ref.current.querySelector('button')?.focus(); }, []);
  useEscape(true, () => { onClose(); opener && document.querySelector(opener)?.focus(); });
  return (
    <div className={'sheet' + (className ? ' ' + className : '')} onClick={e => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="sheet-panel" ref={ref} {...(label ? { role: 'dialog', 'aria-label': label } : {})}>
        <div className="sheet-grip" aria-hidden="true" />
        {children}
      </div>
    </div>
  );
}

// Phone: at most five slots. Settings opens from the account menu (SOLAR-224). More than
// five pages (App's six, with Plant settings): the first four, then More, which opens a
// sheet with the rest.
function PhoneBar({ tabs, tab, onTab }) {
  const [more, setMore] = useState(false);
  const [moreShown, moreLeaving] = useExit(more);
  const split = tabs.length > 5;
  const bar = split ? tabs.slice(0, 4) : tabs;
  const rest = split ? tabs.slice(4) : [];
  const go = (id) => { setMore(false); onTab && onTab(id); };
  const slot = (t) => (
    <button key={t.id} type="button" aria-current={tab === t.id ? 'page' : undefined} onClick={() => go(t.id)} disabled={!onTab}>
      <Icon id={t.id} /><span>{t.label}</span>
    </button>
  );
  return (
    <>
      <nav className="phonebar" aria-label="Pages">
        {bar.map(slot)}
        {split && (
          <button type="button" className={'bar-more' + (rest.some(t => t.id === tab) ? ' on' : '')} aria-expanded={more} aria-haspopup="dialog"
                  onClick={() => setMore(m => !m)} disabled={!onTab}>
            <Icon id="more" /><span>More</span>
          </button>
        )}
      </nav>
      {moreShown && <Sheet label="More pages" className={moreLeaving ? 'leaving' : ''} onClose={() => setMore(false)} opener=".phonebar .bar-more">{rest.map(slot)}</Sheet>}
    </>
  );
}

// ---- Notifications (SOLAR-244, SOLAR-327) ------------------------------------
// A bell in the header with the unread count. It opens the alerts of the last 30 days
// (api_notifications): a panel under the bell, a full page on a phone. Closing it marks
// what it showed as read; a row is not a link. See all opens AlertsPage: every alert,
// one row each with when it went back (api_alerts), filtered by time, kind and unread.

// the icon and colour of each alert switch
const NOTIF_GLYPH = { grid: 'grid', battery: 'battery', panels: 'solar', readings: 'live', sunsynk: 'live' };

function notifDay(day) {
  const today = window.localDateStr();
  if (day === today) return 'Today';
  if (day === window.shiftDate(today, -1)) return 'Yesterday';
  return window.dayText(day);
}

// Billing notices (SOLAR-212): the facts api_notifications pins (0148), in the emails'
// words (_shared/email.ts). They stay at the top of the list until their state ends.
// A failed payment and plants about to go are a banner on every page too; only the
// second can be closed. act: { plan, plans, undo } from App.
const FREE_PAID = 'readings are kept for 30 days, then only the last 24 hours. Alerts stay on; reports stop.';
function billNotice(n, act) {
  const { rand, billDay } = window.billingFmt;
  const plan = PLAN_NAME[n.plan];
  switch (n.kind) {
    case 'bill_failed': return { banner: true, tone: 'bad', icon: 'card', title: `Payment of ${rand(n.amount)} failed`, short: 'Payment failed',
      body: n.nextTry ? `Next try ${billDay(n.nextTry)}. Moves to Free on ${billDay(n.freeOn)} if unpaid.`
        : `Last try failed. Moves to Free on ${billDay(n.freeOn)} if unpaid.`,
      button: 'Pay with another card', run: () => window.settlePayment() };
    case 'bill_removal_soon': {
      // up to 3 names, then a count: the banner stays short on a phone
      const p = n.plants, one = p.length === 1;
      const list = p.length > 3 ? `${p.slice(0, 3).join(', ')} and ${p.length - 3} more`
        : p.length > 1 ? `${p.slice(0, -1).join(', ')} and ${p[p.length - 1]}` : p[0] || 'A plant';
      const why = `Your plan covers ${n.room} plant${n.room === 1 ? '' : 's'}. ${one ? 'Its' : 'Their'} history goes too.`;
      return { banner: true, tone: 'warn', icon: 'trash', closable: 'bill_removal_soon:' + n.on,
        title: `${list} will be deleted on ${billDay(n.on)}`,
        short: `Deleting ${one ? p[0] : p.length + ' plants'} on ${billDay(n.on)}`,
        lead: why,
        body: why,
        button: one ? `Keep ${p[0]}` : 'Keep them', run: act.plan };
    }
    case 'bill_free': {
      const stopped = n.stopped || [];
      return { icon: 'card', title: 'Your account is now on Free',
        body: `On Free, ${FREE_PAID}` + (stopped.length ? ` Stopped, deleted on ${billDay(n.deleteOn)}: ${stopped.join(', ')}.` : ''),
        button: stopped.length ? 'Pay to keep these plants' : 'Pay now', run: act.plans };
    }
    case 'bill_change': {
      const cancel = n.nextPlan === 'free', on = billDay(n.on);
      return { icon: 'calendar', title: cancel ? `${plan} ends on ${on}` : n.nextPlan ? `You move to ${PLAN_NAME[n.nextPlan]} on ${on}`
          : n.nextPeriod ? `You switch to ${n.nextPeriod} on ${on}` : `Extra plants drop to ${n.nextExtraPlants} on ${on}`,
        body: cancel ? `After that, on Free, ${FREE_PAID}` : '',
        // the same undo as Billing's Plan section (bookedChange)
        button: n.nextPlan ? `Keep ${plan}` : n.nextPeriod ? `Stay ${n.period}` : `Keep ${5 + (n.extraPlants || 0)} plants`,   // Family's 5 plus the extras held (SOLAR-367, SOLAR-371)
        run: () => act.undo(n) };
    }
    case 'bill_renewal_notice': return { icon: 'calendar', title: `Your yearly ${plan} plan renews on ${billDay(n.on)}`,
      body: `${rand(n.amount)}. To stop it, cancel before ${billDay(n.on)}.`,
      button: 'Go to cancel plan', run: act.cancel };
    case 'free_week_soon': {
      const day = new Date(n.endsAt).toLocaleDateString('en-GB', { weekday: 'long', timeZone: 'Africa/Johannesburg' });
      return { tone: 'warn', icon: 'clock', title: `${n.days > 1 ? n.days + ' days of history' : 'History'} for ${n.plant || 'your plant'} go${n.days > 1 ? '' : 'es'} on ${day}`,
        body: `Free keeps only the last 24 hours. Keep it all for R${n.perMonth} a month, billed yearly.`,
        button: 'Keep my history', run: act.plans };
    }
    // FreeWeekOver's words
    case 'free_week_ended': return { icon: 'clock', title: 'Your free week has ended', body: 'Free keeps the last 24 hours. Upgrade and your last 60 days come back.',
      button: 'See plans', run: act.plans };
    default: return null;
  }
}

// The banner's close is kept on this device, for that one deletion date.
const NOTICE_CLOSED = 'synsynk.noticeClosed';
function BillBanners({ notices }) {
  const [closed, setClosed] = useState(() => { try { return localStorage.getItem(NOTICE_CLOSED); } catch (e) { return null; } });
  const close = (n) => {
    window.track('notice_closed', { kind: n.kind });
    try { localStorage.setItem(NOTICE_CLOSED, n.closable); } catch (e) { /* private mode: closed until reload */ }
    setClosed(n.closable);
  };
  const shown = notices.filter(n => n.banner && (!n.closable || n.closable !== closed));
  if (!shown.length) return null;
  return (
    <div className="bill-banners">
      {shown.map(n => (
        <div key={n.kind} className={'bill-banner ' + n.tone + (n.closable ? ' closable' : '')} role={n.closable ? 'status' : 'alert'}>
          <span className={'nl-glyph g-' + n.tone}><Icon id={n.icon} /></span>
          <p><b>{n.title}</b><b className="bb-short">{n.short}</b><span>{n.lead || n.body}</span></p>
          <button type="button" className="ghost-btn" onClick={() => n.act('banner')}>{n.button}</button>
          {/* phone: one line; the whole row opens the bell, where the details and button are (SOLAR-345) */}
          <button type="button" className="bill-banner-more" aria-label={n.title + '. Details'}
                  onClick={() => { window.track('notice_opened', { kind: n.kind }); window.dispatchEvent(new Event('ps-open-bell')); }}>
            <Icon id="next" />
          </button>
          {/* top right at every width, out of the flow, so a wrap never moves it */}
          {n.closable && <button type="button" className="bill-banner-x" aria-label="Close" onClick={() => close(n)}><Icon id="close" /></button>}
        </div>
      ))}
    </div>
  );
}

// disabled: the loading header holds its place, dimmed like Refresh (SOLAR-248)
function NotifBell({ data, pinned = [], onOpen, onSeen, onReadAll, onSettings, onSeeAll, disabled }) {
  const [open, setOpen, ref] = usePopover();
  const shown = useRef(null);
  useEffect(() => { if (open) onOpen(); }, [open]);
  // a phone banner's tap opens the list (SOLAR-345)
  useEffect(() => {
    if (disabled) return;
    const show = () => setOpen(true);
    window.addEventListener('ps-open-bell', show);
    return () => window.removeEventListener('ps-open-bell', show);
  }, [disabled]);
  // what the open list showed unread; read once it closes, so the dots stay while it's open
  useEffect(() => { if (open) shown.current = (data?.items || []).filter(it => !it.read).map(it => it.id); }, [open, data]);
  useEffect(() => {
    if (open || !shown.current) return;
    if (shown.current.length) onSeen(shown.current);
    shown.current = null;
  }, [open]);
  // a billing notice counts until its state ends
  const unread = (data?.unread || 0) + pinned.length;
  const close = () => setOpen(false);
  const items = data?.items;
  return (
    <div className="bell" ref={ref}>
      <button type="button" className="bell-btn" aria-haspopup="dialog" aria-expanded={open} onClick={() => setOpen(o => !o)} disabled={disabled}
              aria-label={'Notifications' + (unread ? ', ' + unread + ' unread' : '')}>
        <Icon id="bell" />{unread > 0 && <span className="bell-count mono" aria-hidden="true">{unread > 99 ? '99+' : unread}</span>}
      </button>
      {open && (
        <div className="notif-panel" role="dialog" aria-label="Notifications">
          <div className="nl-head">
            <button type="button" className="nl-back" aria-label="Back" onClick={close}><Icon id="back" /></button>
            <h2>Notifications</h2>
            {data?.unread > 0 && <button type="button" className="nl-all" onClick={onReadAll}>Mark all read</button>}
            <button type="button" className="nl-gear" aria-label="Notification settings" onClick={() => { close(); onSettings(); }}><Icon id="settings" /></button>
          </div>
          {/* only the list scrolls: the head and See all stay, so the scroll bar runs between them (SOLAR-390) */}
          <div className="nl-scroll">
          {/* one list (SOLAR-353): billing notices lead Today, above its alerts */}
          {pinned.length > 0 && <div className="nl-day">Today</div>}
          <NoticeRows pinned={pinned} onAct={n => { close(); n.act('list'); }} />
          {items && !items.length && !pinned.length && (
            <div className="nl-empty">
              <span className="nl-glyph g-readings"><Icon id="bell" /></span>
              <b>No notifications</b>
            </div>
          )}
          {items && items.length > 0 && <NotifRows items={items} when={it => it.time} from={pinned.length ? window.localDateStr() : null} />}
          </div>
          {/* older alerts can be there with none in the last 30 days */}
          {/* its unread rows go with it, read once the page is left, so the page still shows them */}
          {items && <button type="button" className="nl-foot" onClick={() => { const ids = shown.current || []; shown.current = null; close(); onSeeAll(ids); }}>See all</button>}
        </div>
      )}
    </div>
  );
}

// Billing notices (SOLAR-212) with their buttons, as the bell list and the full page show them.
function NoticeRows({ pinned, onAct }) {
  return pinned.map(n => (
    <div key={n.kind} className="nl-row nl-pin">
      <span className="nl-dot" />
      <span className={'nl-glyph g-' + (n.tone || 'readings')}><Icon id={n.icon} /></span>
      <span className="nl-text">
        <span className="nl-title">{n.title}</span>
        {n.body && <span className="nl-body">{n.body}</span>}
        <span className="nl-act-wrap"><button type="button" className="nl-act" onClick={() => onAct(n)}>{n.button}</button></span>
      </span>
    </div>
  ));
}

// Alert rows under day headings, as the bell list and the full page show them.
// when(it): the time line after the plant's name. heads={false}: no day headings.
// from: the day whose heading is already above (the bell's Today over its notices).
function NotifRows({ items, when, heads = true, from = null }) {
  let day = from;
  return items.map(it => {
    const head = heads && it.day !== day ? <div className="nl-day">{notifDay(it.day)}</div> : null;
    day = it.day;
    return (
      <React.Fragment key={it.id}>
        {head}
        <div className={'nl-row' + (it.read ? '' : ' unread')}>
          <span className="nl-dot" aria-label={it.read ? undefined : 'Unread'} />
          {/* a dead login is red, a plug; its Reconnected keeps SunSynk's grey (SOLAR-380) */}
          <span className={'nl-glyph g-' + (it.kind === 'needs_relink' ? 'bad' : it.switch)}>
            <Icon id={it.kind === 'needs_relink' || it.kind === 'relinked' ? 'plug' : NOTIF_GLYPH[it.switch] || 'live'} />
          </span>
          <span className="nl-text">
            <span className="nl-title">{it.title}</span>
            <span className="nl-body">{it.body}</span>
            <span className="nl-where">{it.plantName || 'Plant ' + it.plant} · {when(it)}</span>
          </span>
        </div>
      </React.Fragment>
    );
  });
}

// "14:02 to 16:47, 2h 45m"; "22:10 to 01:30 Sat" past midnight; "17:42, not back yet".
function alertSpan(it) {
  if (it.open) return it.time + ', not back yet';
  if (it.endAt == null) return it.time;
  const end = it.endTime + (it.endDay !== it.day ? ' ' + window.dayText(it.endDay, { weekday: 'short' }) : '');
  return `${it.time} to ${end}, ${window.fmtDuration(Math.max(1, Math.round((it.endAt - it.at) / 60)))}`;
}

// [[day, items]] in the order given
const alertDays = (items) => [...items.reduce((m, it) => m.set(it.day, [...(m.get(it.day) || []), it]), new Map())];

const ALERT_RANGES = [['day', 'Day', 1], ['week', 'Week', 7], ['month', 'Month', 30], ['year', 'Year', 365], ['all', 'All', null]];
// Billing is a kind like the alert switches: one list, filtered by kind (SOLAR-353)
const ALERT_KINDS = [{ value: 'all', label: 'All' }, { value: 'billing', label: 'Billing' }, { value: 'grid', label: 'Grid' }, { value: 'battery', label: 'Battery' },
  { value: 'panels', label: 'Panels' }, { value: 'readings', label: 'Readings' }, { value: 'sunsynk', label: 'SunSynk' }];

// The full page (SOLAR-327). onShown(ids): unread rows it showed, read once the page is left.
// pinned: the billing notices the bell shows; they lead Today's card unless the kind filter
// picks an alert switch.
function AlertsPage({ pinned = [], onBack, onSettings, onShown, onReadAll }) {
  const [range, setRange] = useState('month');
  const [kind, setKind] = useState('all');
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [res, setRes] = useState(null);
  const [failed, setFailed] = useState(false);
  const [more, setMore] = useState(false);
  const ask = (before) => {
    if (kind === 'billing') return Promise.resolve({ items: [], unread: 0, more: false });
    const days = ALERT_RANGES.find(r => r[0] === range)[2];
    return window.fetchAlerts({ from: days ? new Date(Date.now() - days * 86400000) : null, kind: kind === 'all' ? null : kind,
      unread: unreadOnly, before });
  };
  const keep = (r) => { onShown(r.items.filter(it => !it.read).flatMap(it => it.ids)); return r; };
  // only the latest filters' answer lands
  const req = useRef(0);
  const load = () => {
    const n = ++req.current;
    setRes(null); setFailed(false);
    ask().then(r => n === req.current && setRes(keep(r))).catch(() => n === req.current && setFailed(true));
  };
  useEffect(() => { load(); }, [range, kind, unreadOnly]);
  const filter = (name, value, set) => { window.track('alerts_filter_done', { filter: name, value }); set(value); };
  const showMore = () => {
    setMore(true);
    ask(res.items[res.items.length - 1])
      .then(r => { keep(r); setRes(p => ({ ...r, items: p.items.concat(r.items) })); })
      .catch(() => window.toast('Couldn’t load more. Try again.'))
      .finally(() => setMore(false));
  };
  const readAll = () => {
    window.track('alerts_read_all_done');
    setRes(p => (unreadOnly ? { ...p, unread: 0, items: [], more: false } : { ...p, unread: 0, items: p.items.map(it => ({ ...it, read: true })) }));
    onReadAll();
  };
  const notices = kind === 'all' || kind === 'billing' ? pinned : [];
  const today = window.localDateStr();
  const days = res ? alertDays(res.items) : [];
  if (res && notices.length && days[0]?.[0] !== today) days.unshift([today, []]);
  return (
    <div className="alerts-page">
      <div className="nl-head alerts-head">
        <button type="button" className="nl-back" aria-label="Back" onClick={onBack}><Icon id="back" /></button>
        <div className="page-head"><h1>Notifications</h1></div>
        {res?.unread > 0 && <button type="button" className="nl-all" onClick={readAll}>Mark all read</button>}
        <button type="button" className="nl-gear" aria-label="Notification settings" onClick={onSettings}><Icon id="settings" /></button>
      </div>
      <div className="alerts-filters">
        <Segmented label="Time" size="sm" className="alerts-range" value={range} onChange={v => filter('range', v, setRange)}
                   options={ALERT_RANGES.map(([value, label]) => ({ value, label }))} />
        <div className="alerts-row2">
          <div className="alerts-kind"><PickMenu label="Kind" value={kind} options={ALERT_KINDS} onPick={v => filter('kind', v, setKind)} /></div>
          <label className="alerts-unread">Unread only<Switch on={unreadOnly} label="Unread only" onChange={v => filter('unread', v, setUnreadOnly)} /></label>
        </div>
      </div>
      {failed && (
        <div className="nl-empty">
          <b>Couldn’t load your notifications</b>
          <p>Check your connection, then try again.</p>
          <button type="button" className="save-btn" onClick={load}>Try again</button>
        </div>
      )}
      {!failed && !res && <div className="alerts-list">{[0, 1, 2].map(i => <Skeleton key={i} h={150} r={16} style={{ marginTop: 40 }} />)}</div>}
      {/* a card per day, under its date, as Settings puts each section's card under its title */}
      {days.length > 0 && <div className="alerts-list">{days.map(([day, rows]) => (
        <section key={day} className="alerts-day" aria-label={notifDay(day)}>
          <div className="nl-day">{notifDay(day)}</div>
          <Card className="alerts-card">
            {day === today && <NoticeRows pinned={notices} onAct={n => n.act('page')} />}
            <NotifRows items={rows} when={alertSpan} heads={false} />
          </Card>
        </section>
      ))}</div>}
      {res && !days.length && (
        <div className="nl-empty">
          <span className="nl-glyph g-readings"><Icon id="bell" /></span>
          <b>No notifications</b>
        </div>
      )}
      {res?.more && <div className="alerts-more"><BusyButton className="ghost-btn" busy={more} busyText="Loading…" onClick={showMore}>Show more</BusyButton></div>}
    </div>
  );
}

// Status word right of the plant, coloured; the age only once it is worth reading.
function HeaderStatus({ snap, onRefresh, busy, idleWord }) {
  const now = useNow(15000);
  if (!snap) {
    return (
      <>
        <div className="status status-idle" role="status"><StatusBits word={idleWord} /></div>
        <button type="button" className={'refresh' + (busy ? ' busy' : '')} aria-label="Refresh" disabled><Icon id="refresh" /></button>
      </>
    );
  }
  const s = plantStatus(snap, now);
  const sync = window.syncProgress(snap.sync), pct = sync == null ? null : Math.round(100 * sync);
  return (
    <>
      <window.Tip as="div" className={'status below status-' + s.tone + (sync != null ? ' fetching' : '')} text={'Last reading ' + window.fmtTime(s.last)} role="status">
        <StatusBits word={s.word} />
        {/* an old reading's date shows from tablet width up; a phone keeps the room for the plant name */}
        {s.old && (() => { const p = fmtAgo(s.last, now).replace(' ago', '').split(', ');
          return <span className="status-age mono">{p.length === 2 && <span className="age-date">{p[0]}, </span>}{p[p.length - 1]}</span>; })()}
        {/* A freshly linked plant: the last 60 days of readings and temperatures
            arrive in 2-minute rounds (0093). Quiet once both are in (SOLAR-176). */}
        {sync != null && (
          <span className="status-sync">
            <span className="sync-arc" aria-hidden="true" />Fetching history
            <span className="sync-pct mono">{pct}%</span>
          </span>
        )}
      </window.Tip>
      {/* takes the status colour once something is wrong; the icon alone at every width (SOLAR-375) */}
      <button type="button" className={'refresh refresh-' + s.tone + (busy ? ' busy' : '') + (sync != null ? ' fetching' : '')} aria-busy={busy} onClick={onRefresh}
              aria-label={s.status === 'offline' ? 'Retry' : 'Refresh'}>
        <Icon id="refresh" />
      </button>
    </>
  );
}

// Says on the page when its numbers are old, and why. Grid off is red, as on the Grid card (SOLAR-374).
function PageNotice({ snap, cutOff, onReconnect, relinkedAt }) {
  const now = useNow(15000);
  const s = plantStatus(snap, now);
  const at = readAgo(s.last.getTime(), now); // with the date once it is over a day old
  const a = snap.aggregate || {};
  // a reading normally lands within a minute; after 15 the plain offline banner is back
  if (s.status === 'offline' && relinkedAt && now - relinkedAt < 900000) return (
    <div className="notice stale" role="status">
      <p><b>Reconnected.</b> Waiting for the first reading.</p>
    </div>
  );
  // a dead login says so at once, whatever the reading's age (SOLAR-385)
  if (cutOff) return (
    <div className="notice offline" role="alert">
      <p><b>SunSynk login stopped working.</b> Readings paused at {at}.</p>
      <button type="button" className="save-btn" onClick={onReconnect}>Reconnect</button>
    </div>
  );
  // First load (SOLAR-167): no Offline or Stale banner while the 60 days come in;
  // the header's "Setting up" and "Fetching history" say it (SOLAR-169)
  if (s.status === 'loading') return null;
  if (s.status === 'offline') return (
    <div className="notice offline" role="alert">
      <p><b>{s.old ? 'No readings since ' + at + '.' : 'No inverter is reporting.'}</b></p>
    </div>
  );
  // stale readings still say the grid is off, so both banners can show
  return (
    <>
      {s.status === 'stale' && (
        <div className="notice stale" role="status">
          <p>{s.old ? <><b>Last reading at {at},</b> {fmtAgo(s.last, Date.now())}.</> : <b>{s.detail}.</b>}</p>
        </div>
      )}
      {a.gridPresent === false && snap.features?.hasGrid !== false && (
        <div className="notice gridoff" role="status">
          <p><b>Grid off.</b> {snap.features?.hasBattery === false ? 'Running on solar.' : 'Running on solar and battery.'}</p>
        </div>
      )}
    </>
  );
}

// First steps (SOLAR-170): a new plant's rate, battery and panels, one at a time, from a
// card in the sidebar (docked above the bottom bar on a phone). A step is done once its
// setting is in plant_config, the same columns Settings edits. The reserve starts at 20, so
// it counts once confirmed here or changed; the confirmation is on the plant too
// (battery_reserve_confirmed, SOLAR-247). Hidden is the user's, kept in prefs per plant,
// so it follows the user to every device; no step means no card.
const STEPS = {
  rate: { title: 'Electricity rate', how: 'The price per unit on your bill, with VAT. Shows what solar saved you.', ph: '0.00' },
  size: { title: 'Battery size', how: 'All your batteries together. Shows how long the battery will last.' },
  reserve: { title: 'Battery reserve', how: 'The battery stops powering your home at this charge. Match the number set on your inverter.', ph: '0' },
  panels: { title: 'Solar panels', how: 'All your panels’ watts added up. Shows how much of that the sun gets out of them.' },
};
// Settings shows the same titles and lines; empty boxes show the number's shape, not a sample (SOLAR-400)
window.STEPS = STEPS;
// The marks hold the plant's linkedAt (0097): a plant removed and added again keeps its id
// but gets a new link, so marks from before the re-add are dropped and it starts fresh.
const stepMarks = (me, plant) => {
  const raw = (me?.prefs?.firstSteps || {})[plant.id] || {};
  return raw.at === (plant.linkedAt ?? undefined) ? raw : {};
};
function firstSteps(me, plantId) {
  const plant = (me?.plants || []).find(p => p.id === plantId);
  if (!plant) return null;
  const c = plant.config || {};
  const mine = stepMarks(me, plant);
  // finished once, finished for good: clearing a setting later does not bring the card back
  if (mine.done) return { cfg: c, mine, steps: [], left: [] };
  const batt = c.has_battery !== false;   // not yet detected counts as a battery
  const steps = [
    { id: 'rate', done: c.tariff_import > 0 },
    batt && { id: 'size', done: c.battery_kwh > 0 },
    batt && { id: 'reserve', done: !!c.battery_reserve_confirmed || (c.battery_reserve_pct ?? 20) !== 20 },
    { id: 'panels', done: c.system_kwp > 0 },
  ].filter(Boolean);
  return { cfg: c, mine, steps, left: steps.filter(s => !s.done) };
}
window.firstSteps = firstSteps;
// prefs merge one key deep, so the whole firstSteps object goes back with this plant's change
const saveFirstSteps = (me, plantId, patch) => {
  const plant = (me.plants || []).find(p => p.id === plantId) || { id: plantId };
  return window.savePrefs({
    firstSteps: { ...(me.prefs?.firstSteps || {}), [plantId]: { ...stepMarks(me, plant), ...patch, at: plant.linkedAt ?? undefined } },
  });
};
window.saveFirstSteps = saveFirstSteps;

// Battery size and panels share one box (SumBox): a total, or count × size rows that add up.
const STEP_SUMS = {
  size: { unit: 'kWh', each: 'kWh', per: 1, ph: '0.00', totPh: '0.0', add: 'Add battery size', sizeLabel: 'kWh each', ok: (e) => e > 0 },
  panels: { unit: 'kW', each: 'W', per: 1000, ph: '0', totPh: '0.0', add: 'Add panel size', sizeLabel: 'Watts each', ok: (e) => Number.isInteger(e) && e >= 50 && e <= 1000 },
};
// typed as text, so a comma keyboard's 5,12 reads as 5.12
const stepNum = (v) => (v ?? '') === '' ? NaN : Number(String(v).replace(',', '.'));
const stepFix = (x) => String(+x.toFixed(2));
const wholeNum = (x, lo, hi) => Number.isInteger(stepNum(x)) && stepNum(x) >= lo && stepNum(x) <= hi;
// A plant's saved settings as the boxes show them, by step id; groups: its panel rows, if saved.
const cfgFields = (c) => {
  const groups = Array.isArray(c?.panel_groups) && c.panel_groups.length ? c.panel_groups : null;
  // the reserve's stored 20 is only a stand-in until the owner says, so it opens empty
  const standIn = !c?.battery_reserve_confirmed && (c?.battery_reserve_pct ?? 20) === 20;
  return { groups, rate: c?.tariff_import > 0 ? String(c.tariff_import) : '', reserve: standIn ? '' : String(c.battery_reserve_pct),
    size: c?.battery_kwh > 0 ? String(c.battery_kwh) : '', panels: !groups && c?.system_kwp > 0 ? String(c.system_kwp) : '' };
};
// What saving the panels sends: the way on screen (sumOf's answer), empty meaning none.
const panelsPatch = (now, mode) => (now.empty ? { system_kwp: null, panel_groups: null }
  : { system_kwp: now.value, panel_groups: mode === 'total' ? null : now.filled.map(r => ({ count: stepNum(r.c), watts: stepNum(r.e) })) });
Object.assign(window, { stepNum, wholeNum, cfgFields, panelsPatch });

// What a sum box holds now: its value, whether it can be saved, and (By size) the rows
// typed. A row counts once its size is typed; a fresh "1 ×" row on its own changes nothing.
function sumOf(kind, mode, tot, rows) {
  const sum = STEP_SUMS[kind];
  if (mode === 'total') {
    const v = stepNum(tot);
    return { empty: (tot ?? '') === '', ok: (tot ?? '') === '' || v > 0, value: v > 0 ? v : NaN, filled: [] };
  }
  const filled = rows.filter(r => r.e !== '');
  const ok = filled.every(r => wholeNum(r.c, 1, 2000) && sum.ok(stepNum(r.e)));
  // whole products added first, then divided once: 20 × 450 + 6 × 550 is 12.3 kW exactly,
  // which the database checks panel_groups against (0053)
  const value = filled.length && ok ? filled.reduce((t, r) => t + stepNum(r.c) * stepNum(r.e), 0) / sum.per : NaN;
  return { empty: !filled.length, ok, value, filled };
}
window.sumOf = sumOf;
// The large field the steps use: a unit before or after, a numeric keyboard, typed as text.
function StepField({ id, value, onChange, label, pre, unit, inputMode, ph, invalid, describedBy }) {
  return (
    <div className={'fs-in' + (invalid ? ' bad' : '')}>
      {pre && <span className="fs-unit">{pre}</span>}
      <input id={id} type="text" inputMode={inputMode} autoComplete="off" aria-label={label} aria-invalid={invalid || undefined}
             aria-describedby={describedBy} placeholder={ph} value={value} onChange={e => onChange(e.target.value)} />
      {unit && <span className="fs-unit">{unit}</span>}
    </div>
  );
}
window.StepField = StepField;
// Battery size and panels: Total or By size, the value on the switch's line in its own place,
// so nothing moves as it changes. Controlled: the caller holds mode, total and rows.
const SUM_MODES = [{ value: 'total', label: 'Total' }, { value: 'rows', label: 'By size' }];
window.SUM_MODES = SUM_MODES;
function SumBox({ kind, mode, onMode, tot, onTot, rows, onRows, label }) {
  const sum = STEP_SUMS[kind];
  const now = sumOf(kind, mode, tot, rows);
  const setRow = (i, k, x) => onRows(rows.map((r, j) => j === i ? { ...r, [k]: x } : r));
  return (
    <div className="fs-sum">
      <div className="fs-sumhead">
        <window.Segmented size="sm" label="How to enter it" value={mode} onChange={onMode} options={SUM_MODES} />
        <b className={'fs-val mono' + (now.value > 0 ? ' ' + kind : '')} aria-live="polite">{now.value > 0 ? stepFix(now.value) : '—'}<small>{sum.unit}</small></b>
      </div>
      {mode === 'total' ? <StepField value={tot} onChange={onTot} label={label + ' in total'} unit={sum.unit} inputMode="decimal" ph={sum.totPh} invalid={!now.ok} /> : (
        <div className="fs-rows">
          {rows.map((r, i) => (
            <div key={i} className={'fs-row' + (rows.length === 1 ? ' solo' : '')}>
              <input className="fs-cnt mono" type="text" inputMode="numeric" autoComplete="off" aria-label={'How many, size ' + (i + 1)}
                     value={r.c} onChange={e => setRow(i, 'c', e.target.value)} />
              <span className="fs-times" aria-hidden="true">×</span>
              <StepField value={r.e} onChange={x => setRow(i, 'e', x)} label={sum.sizeLabel + ', size ' + (i + 1)} unit={sum.each}
                         inputMode={kind === 'panels' ? 'numeric' : 'decimal'} ph={sum.ph} />
              {/* one size has nothing to remove: no button, and its box takes the room */}
              {rows.length > 1 && <button type="button" className="fs-rm" aria-label={'Remove size ' + (i + 1)}
                      onClick={() => onRows(rows.filter((_, j) => j !== i))}><TrashIcon /></button>}
            </div>
          ))}
          <button type="button" className="fs-add" onClick={() => onRows([...rows, { c: '1', e: '' }])}>{sum.add}</button>
        </div>
      )}
    </div>
  );
}
window.SumBox = SumBox;
// the rows a saved plant opens on: its panel groups, or one empty row
const rowsFrom = (groups) => Array.isArray(groups) && groups.length ? groups.map(g => ({ c: String(g.count), e: String(g.watts) })) : [{ c: '1', e: '' }];
window.rowsFrom = rowsFrom;

// One step's boxes. Save stays off until the value is one the database takes. A step opened
// again (Back, or a step bar) starts from what is saved.
// Panels' rows are saved as panel_groups, as Settings saves them; the battery keeps only kWh.
function StepForm({ id, cfg, busy, onSave, onSkip }) {
  const sum = STEP_SUMS[id];
  const [saved] = useState(() => cfgFields(cfg));
  const [v, setV] = useState(saved[id]);
  const [mode, setMode] = useState(id === 'panels' && saved.groups ? 'rows' : 'total');
  const [rows, setRows] = useState(() => rowsFrom(saved.groups));
  const box = useRef(null);
  useEffect(() => { box.current?.querySelector('input')?.focus(); }, [mode]);
  const now = sum ? sumOf(id, mode, v, rows) : null;
  const ok = id === 'rate' ? stepNum(v) > 0 : id === 'reserve' ? wholeNum(v, 0, 50) : now.value > 0;
  const save = (e) => {
    e.preventDefault();
    if (!ok) return;
    // the way on screen is the one saved; the other is only kept to switch back to
    onSave(id === 'rate' ? { tariff_import: stepNum(v) } : id === 'reserve' ? { battery_reserve_pct: stepNum(v) }
      : id === 'size' ? { battery_kwh: +now.value.toFixed(3) } : panelsPatch(now, mode));
  };
  const sym = window.moneySymbol ? window.moneySymbol() : 'R';
  return (
    <form className="fs-form" onSubmit={save} ref={box}>
      {id === 'rate' && <StepField value={v} onChange={setV} label={STEPS.rate.title} pre={sym} unit="/unit" inputMode="decimal" ph={STEPS.rate.ph} />}
      {id === 'reserve' && <StepField value={v} onChange={setV} label={STEPS.reserve.title} unit="%" inputMode="numeric" ph={STEPS.reserve.ph} />}
      {sum && <SumBox kind={id} mode={mode} onMode={setMode} tot={v} onTot={setV} rows={rows} onRows={setRows} label={STEPS[id].title} />}
      <div className="fs-actions">
        <button type="button" className="ghost-btn" onClick={onSkip} disabled={busy}>Skip</button>
        <window.BusyButton type="submit" className="save-btn" busy={busy} busyText="Saving…" disabled={!ok}>Save</window.BusyButton>
      </div>
    </form>
  );
}

// The card, and the step it opens: beside the sidebar ('rail'), or a sheet from the bottom ('phone').
// After the free week (SOLAR-242), no card.
// Back and the step bars move between steps, done ones too; Skip leaves one for later.
// The card lists every step (SOLAR-252), led by two already done to show progress so far; a
// row opens its step, done ones too. A tap on the header folds it to the next step; a
// phone starts folded.
const STEPS_DONE = ['Sign up', 'Add plant'];
function FirstSteps({ me, plantId, onSaved, variant }) {
  const [open, setOpen, ref] = usePopover();
  const [skipped, setSkipped] = useState([]);
  const [cur, setCur] = useState(null);      // the step open; null = the next one waiting
  const [gone, setGone] = useState(false);   // Hide pressed, until prefs come back
  const [busy, setBusy] = useState(false);
  const [fold, setFold] = useState(variant === 'phone');   // folded to the next step; a phone starts folded
  useEffect(() => { setOpen(false); setSkipped([]); setCur(null); setGone(false); }, [plantId]);
  const over = window.useFreeOver();
  const fs = firstSteps(me, plantId);
  // Every step done, here or in Settings: marked done, so it stays away. Both copies of the
  // card (sidebar and phone) see it; the ref keeps each to one write.
  const marked = useRef(null);
  const finished = !!fs && fs.steps.length > 0 && !fs.left.length && !fs.mine.done;
  useEffect(() => {
    if (!finished || marked.current === plantId) return;
    marked.current = plantId;
    saveFirstSteps(me, plantId, { done: true }).then(onSaved).catch(() => { marked.current = null; });
  }, [finished, plantId]);
  if (!fs || !fs.left.length || fs.mine.hidden || gone || over) return null;
  const ids = fs.steps.map(s => s.id);
  // the next step waiting, after `after` where there is one, skipped ones last
  const nextOf = (left, sk, after) => {
    const waiting = left.filter(s => !sk.includes(s.id));
    const pool = waiting.length ? waiting : left;
    const later = after ? pool.filter(s => ids.indexOf(s.id) > ids.indexOf(after)) : [];
    return (later[0] || pool[0])?.id;
  };
  const nextId = nextOf(fs.left, skipped);
  const stepId = cur && ids.includes(cur) ? cur : nextId;
  const at = ids.indexOf(stepId);
  const n = ids.length, done = n - fs.left.length;
  const count = (done + STEPS_DONE.length) + '/' + (n + STEPS_DONE.length);
  const S = STEPS[stepId];
  const go = (id) => setCur(id);
  const hide = () => {
    setGone(true); setOpen(false);
    // A failed hide brings the card back, and the red toast says so (SOLAR-166)
    saveFirstSteps(me, plantId, { hidden: true }).then(onSaved)
      .catch(() => { setGone(false); window.toast('Couldn’t hide First steps. Try again.', { error: true }); });
  };
  // Skip leaves the step for later; past the last one it comes round again.
  const skip = () => {
    const sk = skipped.includes(stepId) ? skipped : [...skipped, stepId];
    const sk2 = fs.left.every(x => sk.includes(x.id)) ? [stepId] : sk;
    const next = nextOf(fs.left, sk2, stepId);
    setSkipped(sk2);
    if (!next || next === stepId) setOpen(false); else setCur(next);
  };
  const save = async (patch) => {
    setBusy(true);
    try {
      // Save on the reserve confirms it for everyone on the plant (SOLAR-247)
      await window.savePlantConfig(plantId, stepId === 'reserve' ? { ...patch, battery_reserve_confirmed: true } : patch);
      await onSaved();
      const left = fs.left.filter(s => s.id !== stepId);
      if (!left.length) setOpen(false); else setCur(nextOf(left, skipped, stepId));
    } catch (e) { window.toast('Couldn’t save. Try again.', { error: true }); }
    finally { setBusy(false); }
  };
  const toggle = () => { if (!open) setCur(null); setOpen(o => !o); };
  const pick = (id) => { if (open && id === stepId) setOpen(false); else { setCur(id); setOpen(true); } };
  const panel = (
    <div className="fs-panel" role="dialog" aria-label={S.title}>
      <div className="fs-top">
        {at > 0 && <button type="button" className="fs-back" onClick={() => go(ids[at - 1])}><Icon id="back" />Back</button>}
        <span className="fs-lbl">Step {at + 1} of {n}</span>
        <button type="button" className="fs-x" aria-label="Close" onClick={() => setOpen(false)}><Icon id="close" /></button>
      </div>
      <div className="fs-bars">
        {fs.steps.map((s, i) => (
          <button key={s.id} type="button" className={(s.done ? 'on' : '') + (s.id === stepId ? ' cur' : '')}
                  aria-label={'Step ' + (i + 1) + ', ' + STEPS[s.id].title} aria-current={s.id === stepId ? 'step' : undefined} onClick={() => go(s.id)}><i /></button>
        ))}
      </div>
      <h2 className="fs-title">{S.title}</h2>
      <p className="fs-how">{S.how}</p>
      <StepForm key={stepId} id={stepId} cfg={fs.cfg} busy={busy} onSave={save} onSkip={skip} />
    </div>
  );
  return (
    <div className={'fs-wrap fs-' + variant} ref={ref}>
      <section className={'fs-card' + (open ? ' open' : '')} aria-label="Finish setup">
        <div className="fs-top">
          <button type="button" className="fs-fold" aria-expanded={!fold} onClick={() => setFold(f => !f)}>
            <span className="fs-lbl">Finish setup</span><span className="fs-n mono">{count}</span><Icon id="chevron" /></button>
          <button type="button" className="fs-x" aria-label="Hide" onClick={hide}><Icon id="close" /></button></div>
        <ul className="fs-list">
          {!fold && STEPS_DONE.map(t => (
            <li key={t}><div className="fs-item done"><span className="fs-tick"><Icon id="tick" /></span><span className="fs-name">{t}</span></div></li>
          ))}
          {fs.steps.map(s => {
            const here = open ? s.id === stepId : s.id === nextId;
            if (fold && !here) return null;
            return (
              <li key={s.id}>
                <button type="button" className={'fs-item' + (s.done ? ' done' : '') + (here ? ' cur' : '')}
                        aria-expanded={open && s.id === stepId} onClick={() => pick(s.id)}>
                  <span className="fs-tick">{s.done && <Icon id="tick" />}</span>
                  <span className="fs-name">{STEPS[s.id].title}</span>
                  <Icon id="next" />
                </button>
              </li>
            );
          })}
        </ul>
      </section>
      {/* the tablet's narrow sidebar: a ring and the count, opening the same step */}
      {variant === 'rail' && (
        <button type="button" className="fs-mini" aria-expanded={open} aria-label={'Finish setup, ' + count.replace('/', ' of ') + ' done'} onClick={toggle}>
          <svg viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="7" className="track" /><circle cx="9" cy="9" r="7" className="fill" strokeDasharray={(44 * done / n) + ' 44'} transform="rotate(-90 9 9)" /></svg>
          <span className="mono">{count}</span>
        </button>
      )}
      {open && (variant === 'phone'
        ? <Sheet className="fs-sheet" onClose={() => setOpen(false)}>{panel}</Sheet>
        : <div className="fs-pop">{panel}</div>)}
    </div>
  );
}

const TABS = [
  { id: 'live', label: 'Live' },
  { id: 'solar', label: 'Solar' },
  { id: 'home', label: 'Home' },
  { id: 'grid', label: 'Grid' },
  { id: 'inverters', label: 'Equipment' },
  { id: 'system', label: 'Plant settings' },
];
// The Settings area's pages (SOLAR-250), reached from the account menu rather than the page
// list: the phone's menu list, Account, Billing and Adjust plan. All of them are the
// account's; the plant's own settings are a page in the list ('system').
const SETTINGS_PAGES = ['prefs', 'account', 'billing', 'plans'];
const isSettings = (id) => SETTINGS_PAGES.includes(id);
const pageOk = (tabs, id) => isSettings(id) || tabs.some(t => t.id === id);
// A section a link or a button opens, and the page that holds it. The plant's fields are
// one section since SOLAR-250, so the old ids land on it.
const SECTION_ALIAS = { tariff: 'system', battery: 'system', plant: 'system' };
const SECTION_PAGE = { connection: 'billing', system: 'system', steps: 'system', download: 'account', notifications: 'account', plan: 'billing', payments: 'billing', plants: 'billing', cancel: 'billing' };
// A saved or linked Battery page opens Equipment, where the packs now are; the plant's
// settings were Settings' System page ('settings') until they moved to the list.
const tabAlias = (id) => (id === 'battery' ? 'inverters' : id === 'settings' ? 'system' : id);
// The page to open: Account for a password reset, else the address's, else the one last shown here ('' for none).
const TAB_KEY = 'synsynk.tab';
const savedTab = () => window.resetAsked() ? 'account'
  : tabAlias(new URLSearchParams(location.search).get('tab') || localStorage.getItem(TAB_KEY) || '');
// Remembers the page, and puts it (and the plant) in the address, so a reload opens them.
const writeTab = (tab, plant) => {
  localStorage.setItem(TAB_KEY, tab);
  const url = new URL(location.href);
  url.searchParams.set('tab', tab);
  if (plant != null) url.searchParams.set('plant', plant);
  if (url.href !== location.href) history.replaceState(history.state, '', url);
};
// Setup has no plant to set: its list leaves Plant settings out.
const SETUP_TABS = TABS.filter(t => t.id !== 'system');

// The plants a link-sunsynk answer brings that collect now, not added stopped (plan full).
const comingOn = (r) => {
  const paused = new Set((r?.paused || []).map(Number));
  return (r?.plants || []).map(p => Number(p.id)).filter(id => !paused.has(id));
};

// Back to the top of the page: the box under the header scrolls beside a sidebar, the document on a phone.
const toTop = () => { document.querySelector('.frame-scroll')?.scrollTo({ top: 0 }); window.scrollTo({ top: 0 }); };

// The frame around every page: sidebar, header, content, phone bar.
// `steps` draws First steps for 'rail' or 'phone'; a phone leaves it off Settings and
// Plant settings, where it would sit on the save bar.
function Frame({ tabs, tab, onTab, head, account, busy, steps, children }) {
  return (
    <div className="frame">
      <Sidebar tabs={tabs} tab={tab} onTab={onTab} account={account} steps={steps} />
      <div className="frame-body">
        <header className="head">
          {head}
          {account && <AccountMenu {...account} variant="head" />}
        </header>
        {/* phone: First steps sits at the top of the page, in the flow, so it never covers a chart (SOLAR-345) */}
        <div className="frame-scroll">
          <main className="content" aria-busy={busy || undefined}>{steps && !isSettings(tab) && tab !== 'system' && steps('phone')}{children}</main>
        </div>
      </div>
      <PhoneBar tabs={tabs} tab={tab} onTab={onTab} />
      <SaveToast />
    </div>
  );
}

// What a save did, one line at the foot of the screen for 2.5 s (SOLAR-166):
// window.toast('Saved: rate R3.45 a unit.'). A new one replaces the last. Every failure
// that isn't one box's typing mistake is window.toast(text, { error: true, action:
// { label, onClick } }): red, 6 s, at most one link. Frame mounts the host; the
// signed-out screens mount their own (window.SaveToast).
// A toast sent as its host goes (signing out swaps the frame for the sign-in screen in the
// same render, as after Delete account, SOLAR-359) moves to the next host.
let toastShow = null;
let toastLast = null;
window.toast = (text, opts = {}) => {
  toastLast = { text, ...opts, at: Date.now() };
  if (toastShow) toastShow(toastLast);
};
function SaveToast() {
  const [t, setT] = useState(null);
  const host = useRef(null);
  useEffect(() => {
    toastShow = setT;
    if (toastLast && Date.now() - toastLast.at < 1000) setT(toastLast);
    return () => { toastShow = null; };
  }, []);
  useEffect(() => {
    if (!t) return;
    if (t === toastLast) toastLast = null;   // drawn here: the next host must not show it again (SOLAR-365)
    // A pop-up's backdrop sits in the top layer over everything else; showing the host as a
    // popover again puts each new toast above whatever pop-up is open.
    const h = host.current;
    if (h?.showPopover) { if (h.matches(':popover-open')) h.hidePopover(); h.showPopover(); }
    const id = setTimeout(() => setT(null), t.error ? 6000 : 2500);
    return () => clearTimeout(id);
  }, [t]);
  return (
    <div ref={host} popover="manual" className="toast-host" role={t?.error ? 'alert' : 'status'} aria-live={t?.error ? 'assertive' : 'polite'}>
      {t && (
        <div key={t.at} className={'toast' + (t.error ? ' error' : '')}>
          {!t.error && <Icon id="tick" />}
          <span>{t.text}{t.action && <> <button type="button" className="toast-act" onClick={() => { setT(null); t.action.onClick(); }}>{t.action.label}</button></>}</span>
        </div>
      )}
    </div>
  );
}
window.SaveToast = SaveToast;

// Shown while the session and the SunSynk link are still being checked, before App
// mounts. Same frame as App's own not-yet-loaded gate, so the hand-over does not flash.
function BootShell() {
  const user = useUser();
  // No remembered tab means this browser hasn't shown this account a dashboard since the
  // last sign-out: most likely a new account on its way to Connect SunSynk. A skeleton
  // would flash a dashboard it will never get, so show the empty sign-in backdrop.
  if (!localStorage.getItem(TAB_KEY)) return <div className="login-wrap" />;
  const saved = savedTab();
  const tab = pageOk(TABS, saved) ? saved : 'live';
  return (
    <Frame tabs={TABS} tab={tab} busy account={{ user, plantCount: null, onSettings: () => {} }}
      head={<><PlantMenu fallback="Connecting to SunSynk…" /><HeaderStatus idleWord="Connecting" /><NotifBell disabled /></>}>
      {/* TabSkeleton is in tabs.js, which loads after sign-in (SOLAR-143) */}
      {!isSettings(tab) && tab !== 'system' && window.TabSkeleton && <window.TabSkeleton tab={tab} />}
    </Frame>
  );
}

// The signed-in person, for the account menu: name, initials, email. Kept between
// BootShell and App so the name doesn't blank out at the hand-over.
let lastUser = { name: '', initials: '', email: '' };
function useUser() {
  const [user, setUserState] = useState(lastUser);
  const setUser = (u) => { lastUser = u; setUserState(u); };
  useEffect(() => {
    window.sb.auth.getSession().then(({ data }) => {
      const u = data?.session?.user; if (!u) return;
      const email = u.email || '';
      const name = u.user_metadata?.full_name || u.user_metadata?.name || email.split('@')[0];
      const initials = name.split(/[\s._-]+/).filter(Boolean).slice(0, 2).map(w => w[0].toUpperCase()).join('');
      setUser({ name, initials, email });
    }).catch(() => {});
  }, []);
  return user;
}


// Signed in, with no SunSynk plant yet: a new account, or every login removed. The frame
// is the real one, every page opens, and Account (with Delete account) works. Every other
// page shows its own layout as a still, faint outline, with one card centred in view saying
// what will appear there (the same card, one size, on each page). Add plant, there or
// in the header, opens that card into the form where it stands; Cancel or Esc folds it back
// (SOLAR-96). Once a login lists a plant the gate's refresh swaps this for App (SOLAR-93, SOLAR-94).
function Setup({ links }) {
  const user = useUser();
  // The remembered page too, so removing the last login on Account stays on Account.
  // Plant settings isn't here, so the address or memory naming it opens Live.
  const [tab, setTab] = useState(() => {
    const t = savedTab();
    return pageOk(SETUP_TABS, t) ? t : 'live';
  });
  const [connecting, setConnecting] = useState(false);
  // Billing's Plan says when the free week ends; it runs from the first login, plant on or not.
  const [me, setMe] = useState(null);
  useEffect(() => { window.fetchMe().then(setMe).catch(() => {}); }, []);
  const go = (id) => { setTab(id); setConnecting(false); toTop(); if (location.hash) history.replaceState(history.state, '', location.pathname + location.search); };
  // No plant is on screen here: a ?plant= left from App (its login removed, its plant
  // stopped) leaves the address. linked() sets it again for the plant a login brings.
  useEffect(() => {
    const url = new URL(location.href);
    if (!url.searchParams.has('plant')) return;
    url.searchParams.delete('plant');
    history.replaceState(history.state, '', url);
  }, []);
  // The address names the page here too, as in App, so a reload stays on it.
  useEffect(() => writeTab(tab), [tab]);
  // The settings pages have no card, so the header's button opens it on Live from them.
  const connect = () => { if (isSettings(tab)) setTab('live'); setConnecting(true); };
  useEscape(connecting, () => setConnecting(false));
  useEffect(() => { window.track('screen_viewed', { stage: 'setup', screen: connecting ? 'connect' : tab }); }, [tab, connecting]);
  const dead = links.accounts.filter(a => a.status === 'needs_relink');
  const relink = dead.length > 0 && !links.accounts.some(a => a.status === 'active');
  const account = { user, plantCount: 0, alert: dead.length > 0, onSettings: () => go('prefs'), active: isSettings(tab) };
  // Every plant on a working login switched off: turning one on comes first, adding one second.
  const plantsOff = !relink && links.accounts.some(a => a.status !== 'disabled' && (a.plants || []).length > 0);
  const [flash, setFlash] = useState(null);
  const turnOn = () => { window.track('setup_turn_on_done'); setConnecting(false); setFlash('connection'); setTab('billing'); toTop(); };
  const connectBtn = (cls, onClick = connect) => (
    <button type="button" className={(plantsOff ? 'ghost-btn' : 'save-btn') + ' setup-btn ' + cls} onClick={onClick} aria-label="Add plant"><Icon id="plug" /><span>Add plant</span></button>
  );
  // The header's Add plant with plants off: the form over the page, so Cancel leaves you where
  // you were. A plant that comes on goes to Live; plants added stopped (plan full) close the
  // form with a toast, and their switches offer the upgrade (SOLAR-368).
  const [adding, setAdding] = useState(false);
  const addedFromHead = (r) => {
    const on = comingOn(r).length, n = (r?.plants || []).length;
    if (on) setTab('live');
    else if (n) window.toast(n === 1 ? `${window.plantLabel(r.plants[0])} added. It's off: your plan is full.` : `${n} plants added. They're off: your plan is full.`);
    if (on || n) setAdding(false);
    return linked(r);
  };
  const turnOnBtn = (cls) => (
    <button type="button" className={'save-btn setup-btn ' + cls} onClick={turnOn} aria-label="Turn on a plant"><Icon id="power" /><span>Turn on a plant</span></button>
  );
  // App opens on the page the address names. A plant just added opens on Live, as in App
  // (SOLAR-174); one switched back on stays put.
  const linked = (r) => {
    const added = comingOn(r)[0];
    if (added) {
      const url = new URL(location.href);
      url.searchParams.set('tab', 'live'); url.searchParams.set('plant', added);
      history.replaceState(history.state, '', url);
    }
    return links.refresh();
  };
  const card = connecting ? (
    <div className="setup-form">
      <window.LinkForm relink={relink} onLinked={linked} onCancel={() => setConnecting(false)}
                       initialUsername={relink ? dead[0].sunsynk_username : undefined} />
    </div>
  ) : plantsOff ? (
    <div className="setup-empty-box">
      <Icon id="power" />
      <h2>Your plants are off</h2>
      <p>Turn one on, or add another, to see your solar, battery, grid and home here.</p>
      <div className="setup-btns">{turnOnBtn('')}{connectBtn('')}</div>
    </div>
  ) : (
    // One card, the same words on every page (SOLAR-97).
    <div className="setup-empty-box">
      <Icon id="plug" />
      <h2>Add your plant</h2>
      <p>Your solar, battery, grid and home show here once it’s added.</p>
      {connectBtn('')}
    </div>
  );
  const stage = (
    <div className="setup-stage">
      <div className="setup-outline" aria-hidden="true" inert=""><window.TabSkeleton tab={tab} /></div>
      <div className="setup-empty">{card}</div>
    </div>
  );
  // Account and Billing work; Plant settings waits for a plant.
  return (
    <Frame tabs={SETUP_TABS} tab={tab} onTab={go} account={account}
      head={<><PlantMenu fallback={plantsOff ? 'Plants off' : 'No plant yet'} />
        {!connecting && (plantsOff
          ? <span className="setup-head-btns">{turnOnBtn('setup-head-btn')}{connectBtn('setup-head-btn', () => setAdding(true))}</span>
          : connectBtn('setup-head-btn'))}</>}>
      {isSettings(tab) ? <window.SettingsArea page={tab} onPage={(p, section) => { if (section) setFlash(section); go(p); }} me={me} links={links} onPlantConfigSaved={linked}
                                              flash={flash} onFlashed={() => setFlash(null)} /> : stage}
      {adding && (
        <window.LinkDialog title="Add plant" onLinked={addedFromHead} onCancel={() => setAdding(false)} />
      )}
    </Frame>
  );
}

// The day the free week ends, first open after it (SOLAR-242): said once, kept in prefs so
// it follows the user to every device.
function FreeWeekOver({ onDone }) {
  const done = (choice) => {
    window.track('free_week_card_done', { choice });
    window.savePrefs({ freeWeekOverSeen: true }).catch(() => {});
    onDone();
    if (choice === 'plans') window.openPlans('free_week_card');
  };
  return (
    <section className="card free-over" aria-label="Free week ended">
      <h2>Your free week has ended</h2>
      <p>Free keeps the last 24 hours. Upgrade and your last 60 days come back.</p>
      <div className="free-over-acts">
        <button type="button" className="ghost-btn" onClick={() => done('later')}>Not now</button>
        <button type="button" className="save-btn" onClick={() => done('plans')}>See plans</button>
      </div>
    </section>
  );
}

function App({ links }) {
  // plan, preferences (the last plant viewed) and plants for the signed-in user (api_me)
  const [me, setMe] = useState(null);
  const [plantId, setPlantId] = useState(null);
  const shownPlant = useRef(null);
  shownPlant.current = plantId;
  const [tab, setTab] = useState(() => savedTab() || 'live');
  const auto = true; // refresh runs on its own; the header button forces one now
  const [rawSnap, setSnap] = useState(null);
  // Every login of the plant needs a reconnect and no reading lands (SOLAR-373): nothing is
  // fetched, so its history load is not "in progress". Without this the stalled temperature
  // fetch read "Setting up 99%", which hid Offline, the banner and the silent pages.
  // the working logins a plant is read through
  const loginsFor = (id) => links.accounts.filter(a => a.status !== 'disabled' && (a.plants || []).some(p => String(p.plant_id) === String(id)));
  // a plant whose every login stopped working reads Reconnect in the menu
  const loginsCut = (id) => {
    const ls = loginsFor(id);
    return ls.length > 0 && !ls.some(a => a.status === 'active');
  };
  const loginCut = !!rawSnap && plantStatus(rawSnap, Date.now()).status !== 'live' && loginsCut(plantId);
  const linkedAt = (me?.plants || []).find(p => p.id === plantId)?.linkedAt;
  const snap = React.useMemo(() => (!rawSnap ? rawSnap : loginCut ? { ...rawSnap, sync: null, loginCut: true }
    : { ...rawSnap, sync: window.firstLoadSync(rawSnap.sync, linkedAt) }), [rawSnap, loginCut, linkedAt]);
  // Readings starting or stopping can mean a login came back or died: read the logins
  // again at once, so the sidebar's "Reconnect a login" turns with the header instead of
  // on the next minute's read (SOLAR-389).
  const readingLive = !!rawSnap && plantStatus(rawSnap, Date.now()).status === 'live';
  useEffect(() => { if (rawSnap) links.refresh(); }, [readingLive]); // eslint-disable-line react-hooks/exhaustive-deps
  const [today, setToday] = useState(null);
  const [energy, setEnergy] = useState({});
  // > 0 while a snapshot fetch is in flight; the Refresh icon spins on it. Held to a
  // whole number of 800 ms turns so it never stops mid-rotation.
  const [busy, setBusy] = useState(0);
  const [err, setErr] = useState(null);
  const [flashSection, setFlashSection] = useState(null); // a Settings section to flash once on arrival
  // The day an alert opens Grid or Solar on: {date}, a new object per tap so a second tap
  // on the same day still moves the chart. A pop-up's tap brings it as ?day= (sw.js).
  const [openDay, setOpenDay] = useState(() => {
    const d = new URLSearchParams(location.search).get('day');
    return /^\d{4}-\d{2}-\d{2}$/.test(d || '') ? { date: d } : null;
  });
  const [notifs, setNotifs] = useState(null);
  // "Set your rate", "Set pack size", Reconnect: open the page that holds that section
  // (SECTION_PAGE) and flash it once; the section scrolls itself into view.
  // The address keeps it as #section, so a reload scrolls back to it (SOLAR-165).
  const openSettings = (asked) => {
    const section = SECTION_ALIAS[asked] || asked;
    setFlashSection(section); setTab(SECTION_PAGE[section] || 'system'); toTop();
    history.replaceState(history.state, '', '#' + section);
  };
  const user = useUser();
  // Settings with unsaved plant edits holds the plant where it is; a switch asked for
  // meanwhile bumps switchBlocked, and the save bar says why nothing happened.
  const settingsDirty = useRef(false);
  const [switchBlocked, setSwitchBlocked] = useState(0);
  const [refreshKey, setRefreshKey] = useState(0); // bumped on manual refresh so the chart re-fetches its current day

  const energyRef = useRef({});
  const inflight = useRef({});
  useEffect(() => { energyRef.current = energy; }, [energy]);

  useEffect(() => { window.track('screen_viewed', { stage: 'dashboard', screen: tab }); }, [tab]);
  // Back from Paystack's card page without paying, on a page outside Settings (which checks it itself).
  useEffect(() => { if (!isSettings(tab)) window.billingReturn(); }, []);

  const loadNotifs = useCallback(() => { window.fetchNotifications().then(setNotifs).catch(() => {}); }, []);
  // ?day= and ?opened= (a pop-up's tap) are read once, then leave the address, as ?section= does.
  useEffect(() => {
    const url = new URL(location.href);
    const opened = Number(url.searchParams.get('opened'));
    if (!url.searchParams.has('day') && !url.searchParams.has('opened')) return;
    url.searchParams.delete('day'); url.searchParams.delete('opened');
    history.replaceState(history.state, '', url);
    if (opened) {
      window.track('notification_opened', { source: 'push' });
      window.readNotifications([opened]).then(loadNotifs).catch(() => {});
    }
  }, []);

  // The address names the page and plant, so a reload opens them; the saved page is for a
  // bare address (SOLAR-165). ?section= is left for loadMe to read.
  useEffect(() => writeTab(tab, plantId), [tab, plantId]);

  // spin = false on the 60 s auto tick, so the icon only turns for something the
  // person asked for (a click, first load, a plant switch).
  // A tablet waking from sleep often fails its first check while wifi reconnects, so an
  // automatic check only raises the banner on the second failure in a row, and a failure
  // is retried in 10 s (three times) rather than waiting for the next minute's tick.
  const liveFails = useRef(0);
  const liveRetry = useRef(null);
  const loadLive = useCallback(async (spin = true) => {
    const t0 = Date.now();
    if (spin) setBusy(b => b + 1);
    clearTimeout(liveRetry.current);
    try { setSnap(await window.fetchSnapshot()); setErr(null); liveFails.current = 0; }
    catch (e) {
      liveFails.current += 1;
      if (spin || liveFails.current >= 2) setErr(e.message);
      if (liveFails.current <= 3) liveRetry.current = setTimeout(() => { if (document.visibilityState === 'visible') loadLive(false); }, 10000);
    }
    finally { if (spin) setTimeout(() => setBusy(b => b - 1), Math.ceil((Date.now() - t0) / 800) * 800 - (Date.now() - t0)); }
  }, []);
  const loadToday = useCallback(async () => {
    try { setToday(await window.fetchDay()); } catch (e) { /* chart shows its own placeholder */ }
  }, []);
  // today has no series yet, or the plant is still on its first load (SOLAR-181)
  const todayThin = useRef(true);
  todayThin.current = !today?.points?.length || !!today.approx || window.syncProgress(snap?.sync) != null;
  // Week to Lifetime are finished days plus today, and the pages add today from the live
  // reading, so the rows change only when the plant's date turns and when the 04:15 sync
  // swaps the finished day in (0058). Asked again then, or on a manual refresh (SOLAR-140).
  const snapRef = useRef(null);
  useEffect(() => { snapRef.current = snap; }, [snap]);
  const energyStampRef = useRef(null);
  const energyStamp = () => {
    const tz = snapRef.current?.config?.timezone, d = new Date();
    return window.plantDateStr(tz, d) + (window.plantHour(tz, d) >= 5 ? 'b' : 'a');
  };
  const onNeedEnergy = useCallback((period) => {
    if (energyRef.current[period] || inflight.current[period]) return;
    if (energyStampRef.current == null) energyStampRef.current = energyStamp();
    inflight.current[period] = true;
    window.fetchEnergy(period)
      .then(rows => setEnergy(e => ({ ...e, [period]: rows })))
      .catch(() => {})
      .finally(() => { inflight.current[period] = false; });
  }, []);
  // Refetch every already-loaded period together so their totals stay current AND
  // mutually consistent (e.g. Year and Lifetime share today's growing total rather
  // than each being frozen at whenever it was first opened). Updates in place — no flicker.
  const refreshEnergy = useCallback((force) => {
    const stamp = energyStamp();
    if (!force && stamp === energyStampRef.current) return;
    energyStampRef.current = stamp;
    Object.keys(energyRef.current).forEach((period) => {
      window.fetchEnergy(period).then(rows => setEnergy(e => ({ ...e, [period]: rows }))).catch(() => {});
    });
  }, []);

  const loadMe = useCallback(async () => {
    try {
      const m = await window.fetchMe();
      setMe(m);
      const ids = (m.plants || []).map(p => p.id);
      // The address names its plant (?plant=, from an email or a reload); one that isn't the
      // user's falls back quietly. An email's Reconnect button adds section=logins: open
      // Account on the logins, as the in-app Reconnect does.
      const url = new URL(location.href);
      const linked = Number(url.searchParams.get('plant'));
      // A report or alert footer adds section=notifications: open Account on the email switches.
      // A payment email or Paystack's return adds section=plan: Billing.
      const section = { logins: 'connection', notifications: 'notifications', plan: 'plan', cancel: 'cancel', system: 'system' }[url.searchParams.get('section')];
      if (url.searchParams.has('section')) {
        url.searchParams.delete('section'); history.replaceState(history.state, '', url);
      }
      if (section) openSettings(section);
      if (ids.includes(linked)) window.savePrefs({ lastPlant: linked }).catch(() => {});
      const wanted = ids.includes(linked) ? linked
        : m.prefs && ids.includes(Number(m.prefs.lastPlant)) ? Number(m.prefs.lastPlant) : (ids[0] ?? null);
      const cfg = (m.plants || []).find(p => p.id === wanted)?.config;
      // The plant on screen stopped (SOLAR-251): clear its readings, as a switch does.
      if (shownPlant.current != null && wanted !== shownPlant.current) clearPlant();
      window.setCurrentPlant(wanted, cfg?.currency);
      setPlantId(wanted);
      // how much history this plant has — drives the "collecting your first day" copy
      window.fetchPlantDays().then(d => { window.PLANT_DAYS = d; }).catch(() => {});
    } catch (e) { setErr(e.message); }
  }, []);
  // Name of the plant just switched to, shown in the status pill until the new
  // snapshot has been on screen for a moment; null the rest of the time.
  const [notice, setNotice] = useState(null);
  useEffect(() => {
    if (!notice) return;
    // A failed load leaves snap null; the pill must not sit on "Switching" forever.
    if (err) { setNotice(null); return; }
    if (!snap) return;
    const t = setTimeout(() => setNotice(null), 2500);
    return () => clearTimeout(t);
  }, [notice, snap, err]);
  // Off with the last plant's readings, before the next plant's load.
  const clearPlant = () => {
    setEnergy({}); energyRef.current = {}; setSnap(null); setToday(null);
    window.PLANT_DAYS = null; window.SYNC = null; syncDaysRef.current = null;
  };
  const switchPlant = (id) => {
    if (tab === 'system' && settingsDirty.current) { setSwitchBlocked(n => n + 1); return; }
    const plant = (me?.plants || []).find(p => p.id === Number(id));
    const cfg = plant?.config;
    window.setCurrentPlant(id, cfg?.currency);
    setPlantId(Number(id));
    setNotice(window.plantLabel(plant || { id }));
    window.savePrefs({ lastPlant: Number(id) }).catch(() => {});
    clearPlant();
    // how much history THIS plant has — the empty-state copy reads it
    window.fetchPlantDays().then(d => { window.PLANT_DAYS = d; }).catch(() => {});
    loadLive(); loadToday(); setRefreshKey(k => k + 1);
  };
  // Fresh-link sync state (0048) rides on every snapshot; the empty-state copy reads
  // it from window.SYNC during render, so it is assigned here in the render path,
  // before any child renders (an effect would run after they had already painted
  // with the previous value). When the walk lands more days, the logged-days count
  // that drives "only N days so far" is refreshed too, so it does not stick at 2.
  window.SYNC = snap?.sync ?? null;
  const syncDaysRef = useRef(null);
  useEffect(() => {
    const sync = snap?.sync ?? null;
    if (!sync) return;
    if (syncDaysRef.current != null && sync.days !== syncDaysRef.current) {
      window.fetchPlantDays().then(d => { window.PLANT_DAYS = d; }).catch(() => {});
    }
    syncDaysRef.current = sync.days;
  }, [snap]);
  // A config save can change which plant is shown (a removed login); the data follows it.
  // A reconnected login also clears the banner, so the gate's list is read again.
  // linked: link-sunsynk's answer when a login was just added. A plant it brings that the
  // account didn't have yet is opened on Live, where Setting up and First steps are (SOLAR-174).
  const reloadPlantConfig = (linked) => {
    links.refresh();
    const had = new Set((me?.plants || []).map(p => p.id));
    const added = comingOn(linked).find(id => !had.has(id));
    return loadMe().then(() => {
      if (added) { switchPlant(added); go('live'); return; }
      // a saved setting can change the shared trend and 30-day answers too, so they are asked again
      setRefreshKey(k => k + 1);
      loadLive();
    });
  };

  // initial load: who am I and which plant, then the data
  useEffect(() => { loadMe().then(() => { loadLive(); loadToday(); loadNotifs(); window.pushResync().catch(() => {}); }); }, []);
  // auto refresh: live every minute (matches SunSynk's cadence), today and energy every
  // 5th minute. On the clock, not from page load, so devices side by side show the same
  // numbers (SOLAR-33). The second past the minute is the plant's own, 12–42 s, so every
  // device on one plant still asks together, after the reading has landed (by ~:06), while
  // different plants ask at different moments instead of all in one second (SOLAR-70).
  useEffect(() => {
    if (!auto) return;
    let a;
    const off = 12000 + ((Number(plantId) || 0) * 7919 % 31) * 1000;
    const next = () => { const ms = 60000 - (Date.now() - off) % 60000; a = setTimeout(tick, ms < 1000 ? ms + 60000 : ms); };
    // Nothing is asked for while the page is off screen (another tab, minimised, phone on
    // another app); wake below catches up the moment it is back (SOLAR-140).
    const tick = () => {
      if (document.visibilityState === 'visible') {
        loadLive(false);
        if (new Date().getMinutes() % 5 === 0) { loadToday(); refreshEnergy(); loadNotifs(); }
        // a plant just added: today's series is asked each minute until it draws (SOLAR-181)
        else if (todayThin.current) loadToday();
      }
      next();
    };
    next();
    // timers sleep with a tablet's screen; catch up the moment it is back or online again
    const wake = () => { if (document.visibilityState === 'visible') { loadLive(false); loadToday(); refreshEnergy(); loadNotifs(); } };
    document.addEventListener('visibilitychange', wake);
    window.addEventListener('online', wake);
    return () => {
      clearTimeout(a); clearTimeout(liveRetry.current);
      document.removeEventListener('visibilitychange', wake); window.removeEventListener('online', wake);
    };
  }, [auto, plantId]);

  const plantLogins = loginsFor(plantId);
  // useLinkStatus reads the logins again each minute (SOLAR-153), so one that dies later
  // shows as cut off and Reconnect reads as a reconnect.
  // every login dead and no reading since (snap.loginCut): cut off at once, not after 15 min (SOLAR-385)
  const plantCutOff = !!snap?.loginCut;
  // The login came back but no new reading has landed yet: until one does, the banner says
  // so instead of "No readings since …", which read as a failed reconnect (SOLAR-147).
  const [relinked, setRelinked] = useState(null);
  const wasCutOff = useRef(null);
  useEffect(() => {
    const was = wasCutOff.current;
    if (was && was.plantId === plantId && was.cut && !plantCutOff && plantLogins.some(a => a.status === 'active')) setRelinked({ plantId, at: Date.now() });
    wasCutOff.current = { plantId, cut: plantCutOff };
  }, [plantCutOff, plantId]);

  const refresh = () => { if (busy) return; loadLive(); loadToday(); refreshEnergy(true); setRefreshKey(k => k + 1); };

  const go = (id) => { setTab(id); setOpenDay(null); toTop(); if (location.hash) history.replaceState(history.state, '', location.pathname + location.search); };
  // Every lock (window.openPlans) opens Adjust plan: Free, Home and Family side by side.
  useEffect(() => {
    const on = () => go('plans');
    window.addEventListener('ps-plans', on);
    return () => window.removeEventListener('ps-plans', on);
  }, []);
  // Alerts seen in a list (the bell's as it closes, the full page as it goes): read, then
  // the count again. null: every one.
  const readNotifs = (ids) => {
    if (!ids) setNotifs(n => n && ({ ...n, unread: 0, items: n.items.map(x => ({ ...x, read: true })) }));
    window.readNotifications(ids).then(loadNotifs).catch(() => {});
  };
  // See all: the full page; its back goes to the page it came from. What it showed unread
  // is read once it's left: here, not as it unmounts, since the first reading remounts it.
  const alertsFrom = useRef('live');
  const alertsShown = useRef(new Set());
  useEffect(() => {
    if (tab === 'alerts' || !alertsShown.current.size) return;
    readNotifs([...alertsShown.current]);
    alertsShown.current.clear();
  }, [tab]);
  const seeAll = (ids) => {
    ids.forEach(id => alertsShown.current.add(id));
    if (tab !== 'alerts') alertsFrom.current = tab;
    window.track('alerts_page_opened'); go('alerts');
  };
  // Billing notices (SOLAR-212). An undo re-reads the list, so the notice goes, and tells
  // an open Billing page (ps-billing) to re-read the plan. Before tabs.js is here, Billing.
  const noticeAct = {
    plan: () => openSettings('plan'),
    // "To stop it, cancel before": Billing's Cancellation, as the renewal email opens it (SOLAR-365)
    cancel: () => openSettings('cancel'),
    // Adjust plan: Free, Home and Family side by side, as the emails open it (SOLAR-341)
    plans: () => go('plans'),
    undo: (n) => (window.undoBooked ? window.undoBooked(n, loadNotifs).then(ok => {
      if (!ok) return;
      window.dispatchEvent(new Event('ps-billing'));
      window.toast('The change you booked is undone.');
    }) : openSettings('plan')),
  };
  const notices = (notifs?.pinned || []).map(n => {
    const t = billNotice(n, noticeAct);
    return t && { ...t, kind: n.kind, act: (where) => { window.track('notice_action_done', { kind: n.kind, where }); t.run(); } };
  }).filter(Boolean);
  const bell = <NotifBell data={notifs} pinned={notices} onOpen={loadNotifs} onSeen={readNotifs} onReadAll={() => readNotifs(null)}
                         onSeeAll={seeAll} onSettings={() => openSettings('notifications')} />;
  const alertsPage = <AlertsPage key="alerts" pinned={notices} onBack={() => go(alertsFrom.current)} onSettings={() => openSettings('notifications')}
                                 onShown={ids => ids.forEach(id => alertsShown.current.add(id))}
                                 onReadAll={() => { alertsShown.current.clear(); readNotifs(null); }} />;
  const loginDead = links.accounts.some(a => a.status === 'needs_relink');
  // The free week (SOLAR-242): steps left mark the avatar; after it, history locks.
  const free = window.freeState(me);
  const stepsLeft = free?.week ? (firstSteps(me, plantId)?.left || []).length : 0;
  const [overSeen, setOverSeen] = useState(false);
  const overCard = free?.over && !overSeen && !me?.prefs?.freeWeekOverSeen;
  const account = { user, plantCount: me ? (me.plants || []).length : null, alert: loginDead, stepsLeft, onSettings: () => go('prefs'), active: isSettings(tab) };
  const plantMenu = <PlantMenu me={me} plantId={plantId} onPlant={switchPlant} fallback={snap?.plant?.name} cutOff={loginsCut} currentSync={snap?.sync}
                               accounts={links.accounts} onStopped={() => openSettings('connection')} />;
  // A page's section, from Billing's Reconnect: openSettings; otherwise the page itself
  // key: the loading and loaded pages put it at different child positions; without it the
  // first reading remounted it and Billing's Plan drew its outline twice (SOLAR-281).
  // Plant settings draws from api_me, not the snapshot, so it shares the slot with Settings.
  const settingsPage = tab === 'system'
    ? <window.PlantSettings key="system" me={me} plantId={plantId} onSaved={reloadPlantConfig}
        flash={flashSection} onFlashed={() => setFlashSection(null)} onDirty={d => { settingsDirty.current = d; }} switchBlocked={switchBlocked} />
    : <window.SettingsArea key="settings" page={tab} onPage={(p, section) => (section ? openSettings(section) : go(p))}
        me={me} plantId={plantId} onPlantConfigSaved={reloadPlantConfig} links={links}
        flash={flashSection} onFlashed={() => setFlashSection(null)} />;
  const steps = me && ((v) => <FirstSteps me={me} plantId={plantId} onSaved={reloadPlantConfig} variant={v} />);

  // ---- not-yet-loaded gate ----
  //
  // The whole frame with skeletons where the data will go. Pages stay live while loading:
  // there is no reason to trap someone on Live because the first snapshot hasn't landed.
  const dataPage = !isSettings(tab) && tab !== 'system' && tab !== 'alerts';
  if (!snap) {
    return (
      <window.FreeCtx.Provider value={free}>
      <Frame tabs={TABS} tab={tab} onTab={go} account={account} busy steps={steps}
        head={<>{(me?.plants || []).length > 0 && !err ? plantMenu : <PlantMenu fallback={err ? 'Connection error' : 'Connecting to SunSynk…'} />}
          <HeaderStatus idleWord={notice ? 'Switching' : 'Connecting'} busy={busy > 0} /><NotifBell disabled /></>}>
        {err && <div className="notice offline" role="alert"><p><b>Can't reach the server.</b> Retrying every minute.</p></div>}
        <BillBanners notices={notices} />
        {null}
        {/* The Settings area never touches the snapshot: it draws for real. It sits in
            the same slot as in the loaded page below, so the first reading doesn't remount
            it (the Plan section flashed back to its outline). */}
        <div className="page">
          {!dataPage && (tab === 'alerts' ? alertsPage : settingsPage)}
          {dataPage && <window.TabSkeleton tab={tab} cfg={(me?.plants || []).find(p => p.id === plantId)?.config} />}
        </div>
      </Frame>
      </window.FreeCtx.Provider>
    );
  }

  const old = dataPage && plantStatus(snap, Date.now()).old;
  return (
    <window.FreeCtx.Provider value={free}>
    <Frame tabs={TABS} tab={tab} onTab={go} account={account} steps={steps}
      head={<>{plantMenu}<HeaderStatus snap={snap} onRefresh={refresh} busy={busy > 0} />{bell}</>}>
      {/* The raw error stays in the title; on screen it was a Postgres or JWT string a
          homeowner cannot act on. */}
      {err && <div className="notice stale" role="status" title={String(err)}>{/* reuse-check: allow */}<p><b>Couldn't refresh.</b> Showing the last good reading.</p></div>}
      <BillBanners notices={notices} />
      {/* For the plant on screen. A plant still read through someone else's copy of the
          login stays quiet; a dead login still marks the avatar and Account with a dot. */}
      {dataPage && <PageNotice snap={snap} cutOff={plantCutOff} onReconnect={() => openSettings('connection')}
        relinkedAt={relinked?.plantId === plantId ? relinked.at : null} />}
      <div className={'page' + (old ? ' old' : '')}>
        {dataPage && overCard && <FreeWeekOver onDone={() => setOverSeen(true)} />}
        {!dataPage && (tab === 'alerts' ? alertsPage : settingsPage)}
        {tab === 'live' && <window.LiveTab snap={snap} today={today} energy={energy} onNeedEnergy={onNeedEnergy} refreshKey={refreshKey}
          onOpenSettings={openSettings} />}
        {tab === 'solar' && <window.SolarTab alertDay={openDay} snap={snap} energy={energy} onNeedEnergy={onNeedEnergy} today={today} refreshKey={refreshKey} onOpenSettings={openSettings} />}
        {tab === 'home' && <window.HomeTab snap={snap} energy={energy} onNeedEnergy={onNeedEnergy} today={today} refreshKey={refreshKey} />}
        {tab === 'grid' && <window.GridTab alertDay={openDay} snap={snap} energy={energy} onNeedEnergy={onNeedEnergy} today={today} refreshKey={refreshKey} onOpenSettings={openSettings} />}
        {tab === 'inverters' && <window.InvertersTab snap={snap} today={today} refreshKey={refreshKey} />}
      </div>
    </Frame>
    </window.FreeCtx.Provider>
  );
}

// Terms and privacy are pages beside the app (terms.html, privacy.html); old ?page= links go there.
const legalPage = new URLSearchParams(location.search).get('page');
if (legalPage === 'terms' || legalPage === 'privacy') {
  location.replace(`${legalPage}.html`);
} else {
  ReactDOM.createRoot(document.getElementById('root')).render(
    <window.AuthGate fallback={<BootShell />}><SignedIn /></window.AuthGate>
  );
}

// flow.js, chart.js and tabs.js (listed in index.html's #pages) load once someone is signed
// in, while LinkGate fetches their logins, so the sign-in screen draws without them (SOLAR-143).
// Once per page: signing out and in again reuses the first load.
let pagesLoad = null;
const loadPages = () => pagesLoad || (pagesLoad = Promise.all(
  JSON.parse(document.getElementById('pages').textContent).map(src => new Promise((ok, fail) => {
    const s = document.createElement('script');
    s.src = src; s.async = false; // fetched together, run in list order
    s.onload = ok; s.onerror = () => fail(new Error('Could not load ' + src));
    document.body.appendChild(s);
  }))
));

function SignedIn() {
  const [pages, setPages] = useState('loading'); // loading | ready | failed
  useEffect(() => { loadPages().then(() => setPages('ready'), () => setPages('failed')); }, []);
  if (pages === 'failed') return <div className="login-fine">The app didn’t load. Check your connection and reload.</div>;
  return (
    <window.LinkGate fallback={<BootShell />}>
      {(links) => (pages !== 'ready' ? <BootShell />
        : window.hasActivePlant(links.accounts) ? <App links={links} /> : <Setup links={links} />)}
    </window.LinkGate>
  );
}
