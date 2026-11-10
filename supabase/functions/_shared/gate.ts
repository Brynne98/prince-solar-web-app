// The tester accounts: auth user ids, comma-separated. Billing reads PAYSTACK_TEST_USERS (SOLAR-267),
// link-sunsynk reads TESTER_USERS (SOLAR-477). Plain TypeScript so node can test it: scripts/billing-sim/gate.test.mjs.
export const isTestUser = (testUsers: string, userId: string) =>
  testUsers.split(",").map((s) => s.trim()).includes(userId);

// Paystack's public test cards go through as paid on a test key, so the hosted project
// takes no payment on one (SOLAR-214), except from the tester accounts. Local runs still test.
export function payClosed(key: string, supabaseUrl: string, testUsers: string, userId: string) {
  return key.startsWith("sk_test_") && supabaseUrl.endsWith(".supabase.co") && !isTestUser(testUsers, userId);
}

// Fake SunSynk logins (name@mock, SOLAR-270): only a tester may link one on the hosted
// project. Local runs link them freely, as the local tests do.
export const mockClosed = (username: string, supabaseUrl: string, testUsers: string, userId: string) =>
  username.endsWith("@mock") && supabaseUrl.endsWith(".supabase.co") && !isTestUser(testUsers, userId);

// A call to the fake SunSynk (a name@mock login or its "at:"/"rt:" token) when it is not
// also the real address: in production, where the fake plants must not count in SunSynk's
// call totals or failures (SOLAR-477). Locally every call goes to the mock and counts.
export const fakeSunsynk = (loginOrToken: string, apiBase: string, mockBase: string) =>
  loginOrToken.endsWith("@mock") && mockBase !== apiBase;
