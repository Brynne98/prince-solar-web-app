// The app's modules (public/*.jsx) for the node tests, loaded through Vite as the browser gets
// them, with React, react-dom and supabase-js stubbed (scripts/app-stubs/) and a browser made of
// stubs. config.js runs first, as on the page.
//   const app = await loadApp();               every module's exports in one object
//   const app = await loadApp({ fresh: true }); new module state (a new loader)
//   globalThis.sbStub = { rpc, auth: {...} }  what sb answers; globalThis.reactStub = { useState, ... }
import fs from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
export const stub = () => new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => '' : k === 'then' ? undefined : stub()), apply: () => stub(), construct: () => stub() });

// A page's globals, stubs unless set. Replaces what was set before.
export function browser(extra = {}) {
  const g = { React: stub(), document: stub(), localStorage: stub(), sessionStorage: stub(), navigator: stub(), posthog: stub(),
    fetch: () => new Promise(() => {}), addEventListener() {}, removeEventListener() {}, dispatchEvent() {},
    location: { search: '', hash: '', pathname: '/', origin: 'http://localhost', hostname: 'localhost', href: 'http://localhost/' },
    history: { replaceState() {}, pushState() {}, state: null },
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }), ...extra };
  for (const [k, v] of Object.entries(g)) Object.defineProperty(globalThis, k, { value: v, writable: true, configurable: true });
  globalThis.window = globalThis;
  vm.runInThisContext(fs.readFileSync(ROOT + 'public/config.js', 'utf8'), { filename: 'config.js' });
}

const FILES = ['auth.jsx', 'link.jsx', 'data.jsx', 'components.jsx', 'app.jsx', 'flow.jsx', 'chart.jsx', 'tabs.jsx'];
let server = null;
export async function loadApp({ fresh = false, files = FILES } = {}) {
  if (fresh || !server) {
    await server?.close();
    server = await createServer({
      configFile: false, root: ROOT, logLevel: 'error', appType: 'custom', optimizeDeps: { noDiscovery: true, include: [] },
      server: { middlewareMode: true, hmr: false, ws: false, watch: null },
      resolve: { alias: {
        'react-dom/client': ROOT + 'scripts/app-stubs/react-dom-client.mjs',
        react: ROOT + 'scripts/app-stubs/react.mjs',
        '@supabase/supabase-js': ROOT + 'scripts/app-stubs/supabase-js.mjs',
      } },
    });
  }
  // the text catalog's AccountText too, as the screens import it
  const all = { AccountText: (await server.ssrLoadModule('/supabase/functions/_shared/text.ts')).AccountText };
  for (const f of files) Object.assign(all, await server.ssrLoadModule('/public/' + f));
  return all;
}
export const closeApp = () => server?.close();
