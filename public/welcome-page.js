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
  const heroCta = document.querySelector('.moment[data-k="0"] .cta');

  if (p.left > 0) {
    const note = document.createElement('p');
    note.className = 'places';
    note.textContent = `${p.left} of ${p.places} tester places left`;
    heroCta.after(note);
    return document.documentElement.classList.remove('places-wait');
  }

  const notifyForm = () => {
    const form = document.createElement('form');
    form.className = 'notify'; form.noValidate = true;
    form.innerHTML = '<input type="email" placeholder="you@example.com" aria-label="Email" autocomplete="email">'
      + '<button class="btn sun" type="submit">Notify me</button>';
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

  document.querySelector('.top .btn.sun').textContent = 'Sign in';
  // the button is Sign in now, so the link beside it would say it twice
  document.querySelector('.top .signin').style.display = 'none';
  const fullNote = document.createElement('p');
  fullNote.className = 'full-note';
  fullNote.textContent = 'Tester places are full. Get an email when it opens to everyone.';
  heroCta.style.display = 'block';
  heroCta.replaceChildren(fullNote, notifyForm());
  const end = document.querySelector('.dawn');
  end.querySelector('.h2').textContent = 'Tester places are full.';
  end.querySelector('.lede').textContent = 'Leave your email and we’ll tell you when it opens to everyone.';
  end.querySelector('.cta').replaceChildren(notifyForm());
  document.documentElement.classList.remove('places-wait');
})();
