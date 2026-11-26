// The web app's build (SOLAR-679 F15). public/ stays the folder that ships: Vite bundles
// public/app.jsx (and every module it imports, React and supabase-js from npm) into
// public/build/, next to the HTML that loads it. The signed-in pages (tabs.jsx with flow.jsx
// and chart.jsx) are a chunk of their own, loaded by app.jsx once someone is signed in.
//
//   npm run build        once
//   npm run dev [port]   rebuild on save and serve public/ (default port 3003)
//
// PostHog's browser script (posthog-js's dist/array.js, the same file the pages loaded from
// jsDelivr before) is copied to build/posthog.js: config.js, a plain script every page loads,
// needs window.posthog before it runs.
//
// Cloudflare (CF_PAGES) and GitHub Actions (CI) name each file after its content, app.<hash>.js,
// and the pages in public/ are rewritten to match, so public/_headers can let browsers keep
// build/* for a year (SOLAR-143). Local builds keep the plain names and leave the HTML alone.
// Source maps only with SOURCEMAPS=1, for the release to send to PostHog (F19); they are
// never left in public/.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { defineConfig } from 'vite';

const ROOT = path.dirname(new URL(import.meta.url).pathname);
const PUB = path.join(ROOT, 'public');
const HASHED = !!(process.env.CF_PAGES || process.env.CI);
const hash = (s) => crypto.createHash('sha256').update(s).digest('hex').slice(0, 10);

function pages() {
  let names = {};
  return {
    name: 'prince-pages',
    generateBundle(_, bundle) {
      const src = fs.readFileSync(path.join(ROOT, 'node_modules/posthog-js/dist/array.js'));
      const fileName = HASHED ? `posthog.${hash(src)}.js` : 'posthog.js';
      this.emitFile({ type: 'asset', fileName, source: src });
      names = { posthog: fileName };
      for (const c of Object.values(bundle)) if (c.type === 'chunk' && c.isEntry) names[c.name] = c.fileName;
    },
    writeBundle() {
      if (!HASHED) return;
      for (const page of fs.readdirSync(PUB).filter(f => f.endsWith('.html'))) {
        const file = path.join(PUB, page);
        const html = fs.readFileSync(file, 'utf8');
        const next = html.replace(/build\/([\w-]+)\.js/g, (m, name) => {
          if (!names[name]) throw new Error(`${page} names build/${name}.js, which was not built`);
          return 'build/' + names[name];
        });
        if (next !== html) fs.writeFileSync(file, next);
      }
      // sw.js's kept offline page is named after its three files (SOLAR-592), so a change to
      // any of them is a new worker, and the old copy goes.
      const sw = path.join(PUB, 'sw.js');
      const swSrc = fs.readFileSync(sw, 'utf8');
      if (!swSrc.includes("const OFFLINE = 'offline-dev';")) throw new Error('sw.js has no offline-dev name to stamp');
      const h = hash(['offline.html', 'offline.js', 'theme.js'].map(f => fs.readFileSync(path.join(PUB, f), 'utf8')).join(''));
      fs.writeFileSync(sw, swSrc.replace("const OFFLINE = 'offline-dev';", `const OFFLINE = 'offline-${h}';`));
    },
  };
}

export default defineConfig({
  publicDir: false,
  plugins: [pages()],
  build: {
    outDir: 'public/build',
    emptyOutDir: true,
    target: 'es2020',
    chunkSizeWarningLimit: 600, // app.js is ~500 KB: React and supabase-js, as the CDN scripts were
    sourcemap: process.env.SOURCEMAPS === '1' ? 'hidden' : false,
    rolldownOptions: {
      input: { app: 'public/app.jsx' },
      output: {
        entryFileNames: HASHED ? '[name].[hash].js' : '[name].js',
        chunkFileNames: '[name].[hash].js',
      },
    },
  },
});
