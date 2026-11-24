# SOLAR-649: shared plants at scale (design v2, 2026-11-24)

v1 spread one company login's plants over every shard. Neon and Sol both said revise; Neon:
build several company logins first. Their claims were checked against the code (below).

## Problem

Owners can share a plant with the company SunSynk login (visitor share, SOLAR-310) instead of
giving us their password. Every shared plant is read through that one login:
- SunSynk's rate limit is per login, one inverter read = 5 requests, number never given.
- All of them land in one shard (`poll_jobs_v2` places by login, 0246 ~170), read at once
  (`Promise.all`, poll/index.ts ~432) and saved in one transaction.
- The plant and inverter lists stop at 2,000 (`MAX_PAGES` 40 × 50, sunsynk.ts ~426).
- A claim walks the login's whole plant list, and the inverter list when given a serial
  (`claimShared`, sunsynk.ts ~851): 60–120 calls one after another at 3,000 plants.
- History fetches run one at a time per login (`history_take`, 0246 ~699).
- One login down stops every shared plant.

Today: 0 shared plants, 23 on owners' own logins.

## Checked claims from the council

- Refresh tokens do not rotate (sunsynk.ts:18). v1's token race was wrong. The real one:
  `poll_commit` writes back the access token the shard started with (0227 ~109), so a shard
  that slept 20 s can overwrite a newer token.
- `share_sync` marks every plant not in the list as missing and, after 50 minutes, releases
  the claim and emails the owner (0247 ~519–535). Sending it in chunks would release plants.
- Only one share login is allowed (`sunsynk_accounts_one_share`, 0172:25).
- `poll_shards` counts logins, not plants (0030 ~163): 3,000 shared plants + 20 logins = 3 shards.

## Design

### Part A: small fixes, independent of the pool
1. **The save keeps the newer token.** It still writes the token, but only when its expiry is
   later than the stored one, so a late shard can't put back an older token (0250).
2. **Calls counted per login kind** (own / company) in `private.sunsynk_calls`, so 429s on a
   company login show.
3. **At most 10 requests in flight per login**, for both SunSynk hosts, instead of all at once.
4. ~~Shard count by workload~~ dropped (code review, 24 Nov): shards split by login, so more
   shards would not split one big login, only add empty ones. Part B's several logins do it.
5. (added) **The token is read once a call has its place**, and a call that waits 15 s for a
   place gives up, so a shard still saves what it read inside pg_net's 55 s.

### Part B: several company logins
5. **More than one company login.** Drop the one-share rule; each claim records which company
   login it was shared with (`lane` on the claim; `reading_routes` uses it).
6. **A cap per company login** (a setting, start 100 plants). The claim screen shows the
   address with room, before the owner shares. A full pool: the screen says so and we add a login.
7. **Each company login stays small**, so the lists, claims, history and the hourly share check
   work as they do now. The share check reads the whole list before changing anything; a list
   that fails part way changes nothing.
8. **Ask SunSynk for the per-login number** (draft only, sent on your word) to set the cap.

Not changed: carry and skip (SOLAR-612), owners' own logins, the poll start times (SOLAR-650).

## Decisions for Brynne

- New company SunSynk logins are new accounts with their own email addresses (e.g.
  share2@princesolarhub.co.za). You create them; we store each password as a secret.
- The claim screen gains the address to share with. The screen design comes to you first.
- The first cap: 100 plants per company login until SunSynk answers.

## Tests

- Part A: token not overwritten by a late shard; at most N requests in flight; shard count
  with 0 owner logins and 3,000 shared plants.
- Part B: claims spread across logins under the cap; a failed list leaves every claim alone;
  claim time at a full login; the fake SunSynk (SOLAR-477) with several company logins.

## Effort and risk

Part A: small, low risk, can ship on its own. Part B: medium; touches claims and billing's
reading routes, so it ships after the old billing is removed (~25 Nov).
