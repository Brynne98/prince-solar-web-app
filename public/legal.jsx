// ============================================================================
// legal.jsx — Terms of Service and Privacy Policy.
//
// PLACEHOLDER COPY. Every paragraph below is a stand-in to be replaced by the real
// text before paying customers. It is deliberately plain about the one thing that
// matters most: what we hold about a user's SunSynk account and what we don't.
// Reachable logged-out at ?page=terms and ?page=privacy, and linked from sign-up.
// ============================================================================

const LEGAL = {
  terms: {
    title: 'Terms of Service',
    updated: 'September 2026',
    sections: [
      ['What this is', 'SynSynk is a monitoring dashboard for solar installations. It reads data that your inverter already reports to its manufacturer’s cloud, keeps a permanent history of it, and shows you what it means. It does not control your inverter.'],
      ['Your account', 'You need an account to use the service. You are responsible for keeping your password safe and for what happens under your login.'],
      ['Connecting your inverter', 'To read your data you connect your SunSynk Connect login. We exchange it once for an access token and do not keep the password. You can disconnect at any time from Settings, which deletes the token.'],
      ['What we promise, and what we don’t', 'We will do our best to keep the service running and the data accurate. We cannot guarantee either: the data comes from your inverter and its manufacturer, and we rely on their systems being available and correct. Do not make safety or financial decisions on this dashboard alone.'],
      ['Free service', 'The service is currently free. We may introduce paid plans; anything you use today will remain available on a free plan or we will give you notice.'],
      ['Ending things', 'You can delete your account from Settings at any time, which removes your data. We may suspend accounts that abuse the service.'],
      ['Changes', 'We may update these terms. We will show you a notice in the app when we do.'],
      ['Contact', 'Questions: support@example.com (placeholder).'],
    ],
  },
  privacy: {
    title: 'Privacy Policy',
    updated: 'September 2026',
    sections: [
      ['Who we are', 'Theron and Prince Solutions (Pty) Ltd, South Africa, operating the SynSynk dashboard. We are the responsible party under POPIA and the controller under GDPR for the personal information described here.'],
      ['What we collect', 'Your email address and password (stored hashed). Your SunSynk Connect username. An access token for your SunSynk account, encrypted at rest — never your SunSynk password. Your plant’s location, timezone and equipment details as reported by SunSynk. Minute-by-minute energy readings from your inverter. Settings you enter, such as your tariff.'],
      ['Why', 'To show you your dashboard, keep your history, and detect faults. We do not sell or share your data with anyone, and we do not use it for advertising.'],
      ['Energy data is personal', 'Minute-level energy readings can reveal when a home is occupied. We treat them as personal information and protect them accordingly.'],
      ['Where it lives', 'Our database is hosted by Supabase in Frankfurt, Germany. Access tokens are held in an encrypted vault. Only the service itself can read them; no person can retrieve your token from our systems.'],
      ['How long', 'For as long as you have an account. Deleting your account from Settings removes your token, your plant mapping and, if no one else shares the plant, its readings.'],
      ['Your rights', 'You may ask what we hold, correct it, or have it deleted. Deleting your account does this in one step. For anything else, contact us. You may also complain to the Information Regulator (South Africa) or your local data protection authority.'],
      ['Contact', 'privacy@example.com (placeholder).'],
    ],
  },
};

window.LegalPage = function LegalPage({ which }) {
  const doc = LEGAL[which] || LEGAL.terms;
  return (
    <div className="legal-wrap">
      <div className="legal">
        <window.AuthBrand />
        <h1>{doc.title}</h1>
        <div className="legal-meta">Last updated {doc.updated} · <span className="legal-flag">placeholder text — not yet reviewed</span></div>
        {doc.sections.map(([h, p]) => (
          <section key={h}><h2>{h}</h2><p>{p}</p></section>
        ))}
        <div className="legal-links">
          <a href="?page=terms">Terms</a> · <a href="?page=privacy">Privacy</a> · <a href="./">Back to the app</a>
        </div>
      </div>
    </div>
  );
};
