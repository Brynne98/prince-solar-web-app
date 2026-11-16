// unsubscribe.html's button (SOLAR-552): posts the email's token to the unsubscribe function.
(function () {
  var q = new URLSearchParams(location.search), go = document.getElementById('go');
  var say = function (title, text) {
    document.getElementById('title').textContent = title;
    document.getElementById('text').textContent = text;
  };
  go.addEventListener('click', function () {
    go.disabled = true;
    fetch(window.SUNSYNK_CONFIG.url + '/functions/v1/unsubscribe?t=' + encodeURIComponent(q.get('t') || '') + '&k=' + encodeURIComponent(q.get('k') || ''), { method: 'POST' })
      .then(function (r) {
        if (!r.ok) throw new Error(String(r.status));
        go.remove();
        say('Unsubscribed', 'You get no more of these emails.');
        document.getElementById('back').hidden = false;
        if (window.track) window.track('email_unsubscribe_done', { kind: q.get('k') || '' });
      })
      .catch(function () {
        go.disabled = false;
        say('That did not work', 'Try again, or email ' + (window.SUPPORT_EMAIL || 'us') + '.');
      });
  });
})();
