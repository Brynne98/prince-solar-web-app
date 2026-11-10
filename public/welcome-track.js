// Showcase visits (princesolarhub.co.za, SOLAR-472): the page seen, each section reached
// once (when it crosses the middle of the screen), and taps on the sign-in, sign-up, pricing and plan buttons. window.track comes from
// config.js; nothing about the visitor is sent.
(() => {
  window.track('screen_viewed', { stage: 'website', screen: 'welcome' });
  // Top-level sections only: some sit inside wrapper divs, and the opening one holds
  // smaller sections of its own.
  const top = (el) => { let s = el.closest('main section'); while (s?.parentElement.closest('main section')) s = s.parentElement.closest('main section'); return s; };
  const sections = [...document.querySelectorAll('main section')].filter((s) => top(s) === s);
  const nameOf = (s) => s.id || s.querySelector('.wrap[id]')?.id || s.className.split(' ')[0];
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((seen) => seen.forEach((x) => {
      if (!x.isIntersecting) return;
      io.unobserve(x.target);
      window.track('website_section_viewed', { section: nameOf(x.target) });
    }), { rootMargin: '-45% 0px -45% 0px' }); // reached = crosses the middle of the screen, however tall
    sections.forEach((s) => io.observe(s));
  }
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a.btn, a.signin');
    if (!a) return;
    const button = a.dataset.plan ? 'get_' + a.dataset.plan
      : a.classList.contains('signin') ? 'sign_in'
      : a.getAttribute('href') === '#pricing' ? 'see_pricing'
      : /[?&]signup/.test(a.href) ? 'try_free' : null;
    if (!button) return;
    const at = top(a);
    window.track('website_button_tapped', { button, section: at ? nameOf(at) : 'header' });
  }, true);
})();
