// supabase-js for the node tests: the client is globalThis.sbStub, looked up on each use, so a
// test can swap it; missing parts do nothing.
import { stub } from '../app-modules.mjs';
const part = (o) => new Proxy({}, { get: (t, k) => (o() && k in o() ? o()[k] : stub()) });
export const createClient = () => new Proxy({}, {
  get: (t, k) => (k === 'auth' ? part(() => globalThis.sbStub?.auth) : globalThis.sbStub && k in globalThis.sbStub ? globalThis.sbStub[k] : stub()),
});
