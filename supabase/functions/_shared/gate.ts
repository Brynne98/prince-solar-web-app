// Paystack's public test cards go through as paid on a test key, so the hosted project
// takes no payment on one (SOLAR-214), except from the tester accounts in testUsers
// (comma-separated auth user ids, SOLAR-267). Local runs still test.
// Plain TypeScript so node can test it: scripts/billing-sim/gate.test.mjs.
export function payClosed(key: string, supabaseUrl: string, testUsers: string, userId: string) {
  return key.startsWith("sk_test_") && supabaseUrl.endsWith(".supabase.co") &&
    !testUsers.split(",").map((s) => s.trim()).includes(userId);
}
