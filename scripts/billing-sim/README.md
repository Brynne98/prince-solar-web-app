# Billing simulator (SOLAR-264)
Local database only (`SIM_DB_URL` to change; default is the local Supabase on 55322). Needs `psql` from libpq.
- `node scripts/billing-sim/sim.mjs [--seed N]` runs the fixed cases (`regress.mjs`), then ~1,450 households (~2,000 users)
  over 3 years each (`--households N`, `--years N`). 15% of users switch plants or plans every day or two for weeks.
  Every household is one transaction that is rolled back. Exit 0 = all invariants held, 1 = findings, 2 = simulator error.
  One seed takes about 70 minutes; seeds use their own ids, so 5 can run at once.
- `--regress` runs only the fixed cases: every bug found so far (F1–F11, P1, P3, G-cases). They open charges with named
  arguments, so they also run against older code, where they fail.
- `--only H --trace` replays one household with every step printed.
- `oracle.mjs` is the price oracle, written from the rules text (0110 header, 0127 header), not from the SQL.
- `abuse.mjs [--seed N] [ids]` attacks as signed-in users through the REST API and link-sunsynk, with the mock SunSynk server.
  The C attacks fire many requests at once, in an order set by the seed.
- `node scripts/billing-sim/samples.mjs` builds 13 committed `ui-sample-N@sim.test` users at real today and writes
  `ui-samples.json`. `--remove` deletes them. No sign-in links are made.
Time travel: `private.billing_today()` is redefined inside each rolled-back transaction only.
- `node scripts/billing-sim/scale.mjs [--users 3000]` loads N Home renewals due today and calls `/billing/run` as pg_cron does
  until nothing is due, against `mock-paystack.mjs` (slow answers, declines, hangs, cut connections, 503s; `--verifybusy`
  makes verify fail too, so charges carry to the next call). The edge runtime must be served with `PAYSTACK_URL` pointing at
  the mock (`http://host.docker.internal:4500`) and any `PAYSTACK_SECRET_KEY`; serve with `mock.env` alone afterwards.
  Checks every charge against what the mock charged; deletes its users.
