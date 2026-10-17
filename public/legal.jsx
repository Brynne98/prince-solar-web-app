// ============================================================================
// legal.jsx — Terms of Service and Privacy Policy.
//
// Written for the free testing phase, run by one person (SOLAR-103). Before any
// paid plan, SOLAR-104 adds what selling needs: physical address, phone, prices,
// refunds and a PAIA manual.
// Reachable logged-out at ?page=terms and ?page=privacy, and linked from sign-up.
// ============================================================================

const LEGAL = {
  terms: {
    title: 'Terms of Service',
    updated: '17 October 2026',
    sections: [
      ['What this is', 'Prince Solar shows the readings your inverter already sends to SunSynk, keeps a history of them, and explains what they mean. It does not control your inverter.'],
      ['Who runs it', 'Brynne Prince, an individual in South Africa. Contact: brynneprince98@gmail.com.'],
      ['Limits', 'Readings come from your inverter and SunSynk. They can be late, missing or wrong, and the service can be down. Do not make safety, electrical or money decisions on this dashboard alone. As far as the law allows, we are not liable for any loss from using the service, or from it being down or wrong.'],
      ['Free, in testing', 'The service is free and in testing. Features can change, and the service can stop. Before any charge starts, we tell you in the app and by email, and you choose whether to stay.'],
      ['Your account', 'Keep your password safe. You are responsible for what happens under your login.'],
      ['Your SunSynk login', 'When you connect, you allow Prince Solar to read your plant’s data from SunSynk with your own login. We exchange your password once for an access token and do not keep the password. Disconnect in Settings to delete the token.'],
      ['Ending things', 'Delete your account in Settings at any time; this removes your data. We may suspend accounts that abuse the service.'],
      ['Changes', 'We may update these terms. The app shows a notice when we do.'],
      ['Law and disputes', 'South African law applies. If something goes wrong, email us first and we will try to sort it out.'],
    ],
  },
  privacy: {
    title: 'Privacy Policy',
    updated: '17 October 2026',
    sections: [
      ['Who we are', 'Brynne Prince, an individual in South Africa, runs Prince Solar. She is the responsible party and the information officer under POPIA. Contact: brynneprince98@gmail.com.'],
      ['What we collect', 'Your email address. Your password, stored hashed, if you sign up with email. Your name, email and profile picture from Google, if you sign in with Google. Your SunSynk username and an access token, encrypted, never your SunSynk password. Your plant’s name, location, timezone and equipment, as SunSynk reports them. Your inverter’s readings, every minute. Settings you enter, such as your tariff. Error reports from the app: time, page, app version, error text and browser type.'],
      ['Required or optional', 'Your email and a SunSynk login are required; without them there is no dashboard. Settings are optional.'],
      ['Why', 'To show your dashboard, keep your history, detect faults and fix errors in the app. We do not sell your data or use it for advertising.'],
      ['Energy data is personal', 'Minute-level readings can show when a home is occupied. We treat them as personal information and protect them accordingly.'],
      ['Who receives it', 'Supabase stores the database. GitHub Pages serves the app. Google handles Google sign-in. SunSynk sends your readings when we ask with your token. Each gets only what its job needs. No one else receives your data.'],
      ['Outside South Africa', 'The database is in Frankfurt, Germany. EU data protection law (GDPR) protects it there to a standard like POPIA.'],
      ['How long', 'Minute readings are kept 31 days, then as 5-minute averages while you have an account. Deleting your account removes your token, your plant link and, if no one else shares the plant, its readings. Error reports stay, without a link to you.'],
      ['If data leaks', 'We tell you and the Information Regulator as soon as reasonably possible.'],
      ['Your rights', 'You may ask what we hold, correct it, have it deleted, or object to how we use it. Deleting your account deletes it in one step. You may complain to the Information Regulator: inforegulator.org.za, POPIAComplaints@inforegulator.org.za.'],
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
        <div className="legal-meta">Last updated {doc.updated}</div>
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
