#!/usr/bin/env node
// Fake SunSynk answered in the function, with no network call (SOLAR-637):
// supabase/functions/_shared/mock-fetch.mts. Run by `npm test`; exit 1 on a failure.
import assert from 'node:assert/strict';
import { mockFetch } from '../supabase/functions/_shared/mock-fetch.mts';

globalThis.fetch = () => { throw new Error('network call made'); };
const BASE = 'https://x.supabase.co/functions/v1/mock-sunsynk';
const MOCK_PLANT_OFFSET = 900_000_000;   // _shared/gate.ts
const json = async (p) => { const r = await p; return { status: r.status, body: await r.json() }; };
const post = (body) => mockFetch(BASE, MOCK_PLANT_OFFSET, `${BASE}/oauth/token`, { method: 'POST', body: JSON.stringify(body) });
const get = (path, tok) => mockFetch(BASE, MOCK_PLANT_OFFSET, `${BASE}${path}`, { headers: { Authorization: `Bearer ${tok}` } });

// sign-in and token renewal
let r = await json(post({ username: 'export@mock', password: 'x', grant_type: 'password' }));
assert.equal(r.body.data.access_token, 'at:export@mock');
r = await json(post({ refresh_token: 'rt:export@mock', grant_type: 'refresh_token' }));
assert.equal(r.body.data.access_token, 'at:export@mock');
r = await json(post({ username: 'nobody@mock', password: 'x', grant_type: 'password' }));
assert.equal(r.body.data, null, 'unknown login refused');

// a paged list keeps its query (export@mock: page size 1, two plants), ids moved up
const p1 = (await json(get('/plants?page=1&limit=10', 'at:export@mock'))).body.data;
const p2 = (await json(get('/plants?page=2&limit=10', 'at:export@mock'))).body.data;
const ids = [...p1.infos, ...p2.infos].map((p) => p.id);
assert.deepEqual(ids, [3001 + MOCK_PLANT_OFFSET, 6002 + MOCK_PLANT_OFFSET]);
r = await json(get(`/plant/${ids[0]}`, 'at:export@mock'));
assert.equal(r.status, 200);
assert.equal(r.body.data.id, ids[0]);

// a bad token is a 401, as from the function
assert.equal((await get('/plants', 'at:nobody@mock')).status, 401);

// a dropped read does not answer
const ac = new AbortController(); ac.abort();
await assert.rejects(mockFetch(BASE, MOCK_PLANT_OFFSET, `${BASE}/plants`, { signal: ac.signal }));
console.log('mock-fetch: ok');
