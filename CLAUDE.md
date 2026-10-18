# Prince Solar web app

## Where this lives

- **Code:** GitHub, account `Brynne98`, repo `Brynne98/prince-solar-web-app`.
- **Remote:** `origin` = `git@github.com:Brynne98/prince-solar-web-app.git`, SSH.
  `ssh -T git@github.com` must answer "Hi Brynne98!" before any push; this machine
  has two GitHub accounts and the wrong key authenticates as the wrong person.
- **Branch:** `main`. No feature branches; commits land on main.
- **Frontend host:** Cloudflare Pages at princesolarhub.com (and www), serving
  `public/`. How Cloudflare builds (from main on push?) is set in its dashboard and
  not yet confirmed (SOLAR-110); check there before trusting a push to ship it.
  There is no build step; the JSX is transpiled in the browser. GitHub Pages only
  forwards old `brynne98.github.io/prince-solar-web-app` links to princesolarhub.com
  (`github-pages-forward/`, SOLAR-110) until it is unpublished.
- **Backend host:** Supabase project `pmakzojwhouamawgszrc` (see `public/config.js`).
  The Supabase CLI login stored on this machine reaches it directly.
- **Issues:** Plane, workspace `brynne98`, project **Prince Solar** (tickets
  `SOLAR-*`; older ones are `BP-*` in Linear).

## Releasing

Two halves that do not ship together. Backend first, frontend second. The full
runbook, including pre-flight checks and the version bump, is in `DEPLOY.md`.

- **Push the code (also ships the frontend):**

  ```bash
  git push origin main
  ```

- **Ship the backend, only what changed:**

  ```bash
  supabase db push
  supabase functions deploy poll
  ```

Nothing here is permission to run those. Commit, push and deploy only on
Brynne's explicit say-so, every time.
