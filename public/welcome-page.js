(() => {
  // Hero entrance waits for fonts so the headline doesn't reflow mid-animation,
  // but never more than 400 ms: a slow font must not leave the hero blank.
  Promise.race([document.fonts ? document.fonts.ready : null, new Promise((r) => setTimeout(r, 400))])
    .then(() => document.body.classList.add('ready'));
  const seen = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add('seen'); seen.unobserve(e.target); }
  }, { threshold: 0.06 });
  // The live demo is empty until React has drawn it, so Solar sits right under the hero
  // and would reveal there, then jump down when the demo lands. Reveal only once it's in.
  const demo = document.getElementById('liveDemo');
  const watch = () => document.querySelectorAll('.reveal').forEach((el) => seen.observe(el));
  if (demo.childElementCount) watch();
  else {
    const landed = new MutationObserver(() => {
      if (demo.childElementCount) { landed.disconnect(); watch(); }
    });
    landed.observe(demo, { childList: true });
  }
})();

// Tester places (SOLAR-124): places left under Try it free; once full, an email box
// for the launch replaces the sign-up buttons. If the count can't be read, the page
// stays as it is and the app's own sign-up screen decides.
(async () => {
  const { url, key } = window.SUNSYNK_CONFIG;
  const rpc = (fn, body) => fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}),
  });
  let p;
  try { const r = await rpc('api_tester_places'); if (r.ok) p = await r.json(); } catch {}
  if (typeof p?.left !== 'number') return document.documentElement.classList.remove('places-wait');
  const heroCta = document.querySelector('.hero-side > div');

  if (p.left > 0) {
    const note = document.createElement('p');
    note.className = 'places';
    note.textContent = `${p.left} of ${p.places} tester places left`;
    heroCta.append(note);
    return document.documentElement.classList.remove('places-wait');
  }

  const notifyForm = () => {
    const form = document.createElement('form');
    form.className = 'notify'; form.noValidate = true;
    form.innerHTML = '<input type="email" placeholder="you@example.com" aria-label="Email" autocomplete="email">'
      + '<button class="btn btn-primary" type="submit">Notify me</button>';
    const msg = document.createElement('p');
    msg.className = 'notify-msg'; msg.setAttribute('role', 'alert');
    const input = form.querySelector('input'), btn = form.querySelector('button');
    input.after(msg);
    input.addEventListener('input', () => { msg.textContent = ''; input.removeAttribute('aria-invalid'); });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const email = input.value.trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { msg.textContent = 'Enter a valid email'; input.setAttribute('aria-invalid', 'true'); return; }
      btn.disabled = true; btn.textContent = 'Saving…';
      const ok = await rpc('api_join_waitlist', { p_email: email }).then((r) => r.ok, () => false);
      if (!ok) { btn.disabled = false; btn.textContent = 'Notify me'; msg.textContent = 'Couldn’t save that. Try again.'; return; }
      const done = document.createElement('p');
      done.className = 'notify-done';
      done.textContent = 'You’re on the list. We’ll email you when it opens to everyone.';
      wrap.replaceWith(done);
    });
    const wrap = document.createElement('div');
    wrap.append(form);
    return wrap;
  };

  document.querySelector('.topnav .btn-primary').textContent = 'Sign in';
  // the button is Sign in now, so the link beside it would say it twice
  document.querySelector('.topnav-links .signin').style.display = 'none';
  const fullNote = document.createElement('p');
  fullNote.className = 'full-note';
  fullNote.textContent = 'Tester places are full. Get an email when it opens to everyone.';
  heroCta.replaceChildren(fullNote, notifyForm());
  const card = document.querySelector('.closing-card');
  card.querySelector('h2').textContent = 'Tester places are full.';
  card.querySelector('p').textContent = 'Leave your email and we’ll tell you when it opens to everyone.';
  card.querySelector(':scope > a').replaceWith(notifyForm());
  document.documentElement.classList.remove('places-wait');
})();
