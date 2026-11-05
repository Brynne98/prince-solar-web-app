// The not-found page's endless day (SOLAR-352). A file, not inline: the site's CSP allows only 'self' scripts.
(() => {
  const { mix, rgb, skyAt } = window.Sky;
  const $ = id => document.getElementById(id), root = document.documentElement;
  // stars: the showcase's field, same seed
  const st = $('stars'); let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  for (let i = 0; i < 140; i++) { const s = document.createElement('i'); s.style.left = rnd() * 100 + '%'; s.style.top = rnd() * 62 + '%'; s.style.opacity = (.25 + rnd() * .75).toFixed(2); if (rnd() > .85) s.style.width = s.style.height = '3px'; st.appendChild(s); }
  const START = 4.5; // opens at night, the moon at the top of its arc and clear of the words
  function paint(h) {
    const s = skyAt(h), W = innerWidth, H = innerHeight;
    ['--s1', '--s2', '--s3', '--l1', '--l2'].forEach((n, i) => root.style.setProperty(n, s.c[i]));
    st.style.opacity = s.stars; $('moon').style.opacity = Math.min(1, s.stars * 1.4); $('wins').style.opacity = .25 + .75 * s.stars;
    root.style.setProperty('--ink', s.ink > .5 ? '#1d1408' : '#f3eee4'); document.body.classList.toggle('light', s.ink > .5);
    const foot = H - (W <= 860 ? 70 : 120), crown = W <= 860 ? 90 : 110;
    const arc = (t, el) => { const u = Math.min(1, Math.max(0, t)); el.style.transform = `translate(${W * (.06 + .88 * u)}px,${foot - Math.pow(Math.sin(Math.PI * u), .55) * (foot - crown)}px)`; };
    const t = (h - 5.9) / (18.8 - 5.9), sun = $('sun'); arc(t, sun); sun.style.opacity = t > -.02 && t < 1.02 ? 1 : 0;
    const warm = Math.sin(Math.PI * Math.min(1, Math.max(0, t)));
    sun.style.setProperty('--sunc', rgb(mix([233, 110, 40], [255, 214, 120], warm)));
    sun.style.setProperty('--glow', `rgba(255,${Math.round(150 + warm * 70)},${Math.round(70 + warm * 50)},${(.45 + warm * .2).toFixed(2)})`);
    arc(((h < 12 ? h + 24 : h) - 13.3) / 32.7, $('moon'));
  }
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) { paint(START); addEventListener('resize', () => paint(START)); return; }
  // one day is ten screens of scroll (three raced by on a laptop trackpad); the page holds three days
  // and the scroll is kept in the middle one, so it never reaches an end either way. The sky repeats
  // each day, so the jump does not show.
  const day = () => innerHeight * 10, track = document.querySelector('.track');
  const size = () => { track.style.height = 3 * day() + innerHeight + 'px'; };
  size();
  let busy = false;
  function frame() {
    busy = false;
    const D = day();
    if (scrollY < D) { scrollTo(0, scrollY + D); return; }
    if (scrollY >= 2 * D) { scrollTo(0, scrollY - D); return; }
    paint((START + (scrollY - D) / D * 24) % 24);
  }
  const ask = () => { if (!busy) { busy = true; requestAnimationFrame(frame); } };
  addEventListener('scroll', ask, { passive: true });
  addEventListener('resize', () => { size(); scrollTo(0, day()); ask(); });
  scrollTo(0, day()); paint(START);
})();
