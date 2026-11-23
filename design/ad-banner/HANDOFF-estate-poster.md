# Handoff: estate newsletter poster and market research

Written 2026-11-23. Repo: `Brynne98/prince-solar-web-app`. Read the repo's CLAUDE.md first.

## Get the files

Everything below is untracked in git (`design/ad-banner/`, `reports/market-viability.md`). It is not on GitHub. Copy the folder from the first Mac, or commit it on main first (needs Brynne's say-so).

## Tickets (Plane, project Prince Solar)

- **SOLAR-635** Market viability research. Done. Report: `reports/market-viability.md`.
- **SOLAR-636** Estate newsletter banner refresh. In Progress. Waiting on Brynne: "final" or another round.

## The poster

Goal: one poster for the Eagle Canyon estate newsletter *Community Chatter* (weekly PDF, local businesses send one poster each). Submit to comms@echoa.co.za, only when Brynne says to.

Current version, chosen by Brynne after 3 directions:

- Source: `design/ad-banner/poster-a2-golden.html`
- Output: `design/ad-banner/poster-a2-golden.png`, 1200x1600 (3:4, like the other posters)
- Assets it loads: `live-card.png`, `qr-estate.svg` (same folder)

Final copy, nothing else on it:

- Prince Solar Hub (brand row)
- "Your SunSynk, live."
- "Know when the power goes, and how long the battery will last."
- "7 days free"
- "Scan the code to start."
- QR + princesolarhub.co.za

QR points to `https://princesolarhub.co.za/?utm_source=estate&utm_medium=newsletter`, made with `qrencode -t SVG -l M -m 0 --foreground=0a0d12`. PostHog (project 321817, admin@ account) splits these visits out.

Look, taken from the showcase so the QR lands on the same scene:

- Sky: late afternoon from `public/sky.js`, `#c4712f` to `#e39a52` to `#f3c486`.
- Far hill `#8f5530`, near hill `#3f2418`. House silhouette from `public/welcome.html`, same colour as the near hill, lit windows `#ffd27a`, standing on the near hill.
- Fonts: Bricolage Grotesque (headline, "7 days free"), Geist (body), JetBrains Mono (URL). Same as the showcase.
- `live-card.png` is the showcase's "Example plant" card, cropped from a 760-wide, 2x headless render of princesolarhub.co.za.

Render:

```bash
cd design/ad-banner && "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --virtual-time-budget=5000 --window-size=1200,1600 --screenshot="$PWD/poster-a2-golden.png" "file://$PWD/poster-a2-golden.html"
```

## Brynne's decisions on the poster (don't undo)

- Direction A (golden sky), not B (dark alert) or C (rooftop photo).
- No price on it. No "made by a resident". No "15 minutes of your thoughts" ask.
- Background must suit the dark card and the hills (hence the deeper late-afternoon sky).
- House sits on the hill, not floating.

## Open items

1. **QR not scanned.** No scanner on the first Mac. Scan it once with a phone before submitting.
2. **Final or another round.** Brynne's call.
3. Possible showcase bug, not confirmed: at 390px wide in headless Chrome, the hero card runs off the right edge. Check on a real phone before filing.

## Other files in the folder

- `poster-a-golden`, `poster-b-alert`, `poster-c-roof` (.html/.png) and `poster-compare.png`: the 3 first directions. Share `poster-base.css`.
- `banner-estate.html` / `estate-banner.png`: first dark remake, superseded.
- `banner*.html`, `newsletter-banner*.png`, `qr.svg`, `site*.png`: the 18 Oct originals (old offer, .com address).
- `roof.jpg` (Pexels 38021376), `alert-card.jpg` (crop of `public/img/email-grid-back.jpg`).

## Market research in short (`reports/market-viability.md`)

- Scope: SunSynk owners in South Africa only.
- Verdict: worth it as a side business (estimate 200-500 payers in 2 years, about R14k-R35k a month net), not as a salary.
- For: 119 showcase visitors gave 23 sign-ups, 22 linked, 3 paying (to 2026-11-21). Sunsynk Connect is 62% 1-2 stars on Google Play (520 reviews read). PVBiz is the only direct rival.
- Against: SunSynk Facebook groups are quiet (16.4k-member SA group, 36 posts a month). All traffic so far is direct, so strangers aren't reached yet. No SunSynk API or permission.
- What decides it: a R1,500 Meta ad test plus 10 calls with owners she doesn't know. Nothing spent.
- Correction in the report: Sunsynk Saver is R109.99 on the ZA App Store, not R250.

## Not done on purpose

- Figma image generation: Figma on the first Mac is signed in to a Ruvos work account. Not used.
- Social media and native apps were discussed only. Leaning: a Facebook Page (needed for ads), no posting schedule; Android Play Store wrapper worth a ticket; no iOS app yet. Nothing filed.
