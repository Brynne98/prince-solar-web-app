// The tester accounts: auth user ids in the PAYSTACK_TEST_USERS secret, comma-separated
// (SOLAR-267). Plain TypeScript so node can test it: scripts/billing-sim/gate.test.mjs.
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
