#!/usr/bin/env node
/**
 * Compiles public/*.jsx to public/build/*.js, so browsers no longer download Babel and
 * compile on every visit (SOLAR-131). Same Babel and the same settings that
 * <script type="text/babel"> used, so the output runs exactly as before, including the
 * one shared global scope (see the no-object-rest rule for files after components.jsx).
 *
 *   node scripts/build-jsx.js               build once; exit 1 on a syntax error
 *   node scripts/build-jsx.js --serve 3003  build, rebuild on save, serve public/ on 3003
 *
 * Cloudflare Pages runs `npm ci && npm run build` on every push; public/build/ is not in git.
 */
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const Babel = require('@babel/standalone');

const PUB = path.join(__dirname, '..', 'public');
const OUT = path.join(PUB, 'build');

// @babel/standalone's own defaults for a classic text/babel script (buildBabelOptions)
const options = (filename) => ({
  filename,
  presets: ['react', 'env'],
  plugins: ['transform-class-properties', 'transform-object-rest-spread', 'transform-flow-strip-types'],
  sourceMaps: true,
});

function compile(file) {
  const name = path.basename(file, '.jsx');
  const { code, map } = Babel.transform(fs.readFileSync(file, 'utf8'), options(name + '.jsx'));
  map.sources = ['../' + name + '.jsx'];
  fs.writeFileSync(path.join(OUT, name + '.js'), code + '\n//# sourceMappingURL=' + name + '.js.map\n');
  fs.writeFileSync(path.join(OUT, name + '.js.map'), JSON.stringify(map));
}

const sources = () => fs.readdirSync(PUB).filter(f => f.endsWith('.jsx')).map(f => path.join(PUB, f));

fs.mkdirSync(OUT, { recursive: true });
const serveAt = process.argv.indexOf('--serve');
let failed = false;
for (const file of sources()) {
  try { compile(file); } catch (e) { failed = true; console.error(e.message); }
}

if (serveAt === -1) {
  if (failed) process.exit(1);
  console.log('built', sources().length, 'files into public/build/');
} else {
  fs.watch(PUB, (event, f) => {
    if (!f || !f.endsWith('.jsx') || !fs.existsSync(path.join(PUB, f))) return;
    try { compile(path.join(PUB, f)); console.log('rebuilt', f); } catch (e) { console.error(e.message); }
  });
  const server = spawn('npx', ['serve', 'public', '-l', process.argv[serveAt + 1] || '3003'], { cwd: path.join(PUB, '..'), stdio: 'inherit' });
  const stop = () => { server.kill(); process.exit(0); };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  server.on('exit', (code) => process.exit(code ?? 0));
}
