# SunSynk Live Dashboard

A small local web app that logs into **SunSynk Connect** (the same account you use
at [sunsynk.net](https://www.sunsynk.net) / the mobile app) and shows live data from
**all inverters on your account** on one dashboard — solar generation, battery state
of charge, grid import/export, home load, plus a live energy-flow diagram and a
"today" chart.

It runs entirely on your own machine. Your credentials live in a local `.env` file
and are only ever sent to `api.sunsynk.net` — nowhere else.

> Two inverters? No setup needed — the app discovers every inverter on the account
> automatically and shows a combined summary plus a card per inverter.

---

## Requirements

- [Node.js](https://nodejs.org) **18 or newer** (check with `node --version`)
- Your SunSynk Connect email + password

## Setup

```bash
# 1. install dependencies
npm install

# 2. add your credentials
cp .env.example .env
#   then open .env and fill in SUNSYNK_USERNAME and SUNSYNK_PASSWORD

# 3. start it
npm start
```

Then open **http://localhost:3000** in your browser.

---

## What you'll see

- **Energy Flow** — animated diagram of power moving between solar, battery, grid and home.
- **Summary tiles** — combined solar, battery SoC, grid, and load across both inverters.
- **Today** — a chart of the day's PV / load / grid / battery, pulled from SunSynk.
- **Inverters** — one card per inverter with its own live readings.

Data auto-refreshes every 30 seconds (toggle it off with the **Auto** switch).
Note that SunSynk's cloud itself only updates roughly once a minute, so that's the
real ceiling on how "live" the numbers can be.

---

## Tweaks & troubleshooting

**Battery shows charging when it should be discharging (or vice-versa)**
SunSynk firmware differs on this. In `.env`, set
`BATTERY_POSITIVE_MEANS=charging` (or `discharging`) until it matches your app.

**Login fails / nothing loads**
- Double-check the email and password in `.env` (same as the SunSynk website).
- Make sure your inverters have a working WiFi data-logger reporting to SunSynk Connect.
- If you're in a region with a different endpoint, try setting `API_BASE` in `.env`.

**Want to verify the raw numbers / field names for your hardware**
Visit `http://localhost:3000/api/debug/<your-inverter-serial>` to see the raw API
responses the app is reading from. Useful if a value looks off and you want to map it.

**Change the port**
Set `PORT=8080` (for example) in `.env`.

---

## How it works

```
browser ──> Node/Express server (this app) ──> api.sunsynk.net
            • handles login + token refresh
            • fetches grid/battery/PV/load/output per inverter
            • aggregates totals, serves the dashboard
```

The browser never talks to SunSynk directly — that's deliberate. It avoids the
cross-origin (CORS) block SunSynk puts on browser requests, and keeps your password
out of anything that runs client-side.

## Files

| File | Purpose |
|------|---------|
| `server.js` | Backend: auth, token refresh, data fetch/aggregation, API routes |
| `public/index.html` | Dashboard markup |
| `public/styles.css` | Styling |
| `public/app.js` | Frontend logic, flow diagram, chart, auto-refresh |
| `.env` | Your credentials (you create this; never commit it) |

Unofficial project — not affiliated with or endorsed by SunSynk. Endpoints are the
same ones the SunSynk Connect web/app use and may change without notice.
