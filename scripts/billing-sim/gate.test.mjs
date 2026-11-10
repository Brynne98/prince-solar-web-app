// The tester gates: the test-key guard on billing/pay (SOLAR-267), @mock logins (SOLAR-270). Exit 1 on any failure.
//   node scripts/billing-sim/gate.test.mjs
import assert from "node:assert/strict";
import { copyFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// The repo is commonjs, so node reads the .ts as ESM only under .mts (as card-tests.mts does).
const copy = join(mkdtempSync(join(tmpdir(), "gate-")), "gate.mts");
copyFileSync(new URL("../../supabase/functions/_shared/gate.ts", import.meta.url), copy);
const { payClosed, mockClosed, fakeSunsynk } = await import(copy);
const PAT = String.raw`^brynneprince98\+test\d*@gmail\.com$`;

const HOSTED = "https://pmakzojwhouamawgszrc.supabase.co", LOCAL = "http://127.0.0.1:55321";
const A = "11111111-1111-1111-1111-111111111111", B = "22222222-2222-2222-2222-222222222222";

assert.equal(payClosed("sk_test_x", HOSTED, "", A), true, "test key, hosted, no list: refused");
assert.equal(payClosed("sk_test_x", HOSTED, B, A), true, "test key, hosted, not on the list: refused");
assert.equal(payClosed("sk_test_x", HOSTED, `${B}, ${A}`, A), false, "test key, hosted, on the list: passes");
assert.equal(payClosed("sk_test_x", HOSTED, `${A.slice(0, 8)}`, A), true, "part of an id is not a match");
assert.equal(payClosed("sk_test_x", LOCAL, "", A), false, "local stack: passes");
assert.equal(payClosed("sk_live_x", HOSTED, "", A), false, "live key: passes");
assert.equal(mockClosed("installer@mock", HOSTED, B, A), true, "@mock, hosted, not on the list: refused");
assert.equal(mockClosed("x@mock", HOSTED, "", A), true, "@mock, hosted, TESTER_USERS unset: refused");
assert.equal(mockClosed("installer@mock", HOSTED, A, A), false, "@mock, hosted, on the list: passes");
assert.equal(mockClosed("installer@mock", LOCAL, "", A), false, "@mock, local: passes");
assert.equal(mockClosed("me@gmail.com", HOSTED, "", A), false, "real login: never refused here");
const REAL = "https://openapi.sunsynk.net", MOCK = `${HOSTED}/functions/v1/mock-sunsynk`, LOCAL_MOCK = "http://127.0.0.1:4010";
assert.equal(fakeSunsynk("solo@mock", REAL, MOCK), true, "production: a fake login is not counted");
assert.equal(fakeSunsynk("at:solo@mock", REAL, MOCK), true, "production: a fake token is not counted");
assert.equal(fakeSunsynk("me@gmail.com", REAL, MOCK), false, "production: a real login is counted");
assert.equal(fakeSunsynk("eyJreal.token", REAL, MOCK), false, "production: a real token is counted");
assert.equal(fakeSunsynk("solo@mock", LOCAL_MOCK, LOCAL_MOCK), false, "local: every call goes to the mock and counts");
for (const e of ["brynneprince98+test@gmail.com", "brynneprince98+test2@gmail.com", "Brynneprince98+Test17@gmail.com"])
  assert.equal(mockClosed("flat@mock", HOSTED, "", A, PAT, e), false, `${e}: passes`);
for (const e of ["brynneprince98+testx@gmail.com", "someone+test2@gmail.com", "brynneprince98+test2@gmail.com.evil.com", "x.brynneprince98+test2@gmail.com", ""])
  assert.equal(mockClosed("flat@mock", HOSTED, "", A, PAT, e), true, `${e || "unconfirmed"}: refused`);
assert.equal(mockClosed("flat@mock", HOSTED, "", A, "", "brynneprince98+test2@gmail.com"), true, "no pattern set: refused");
console.log("gate: 25 cases ok");
