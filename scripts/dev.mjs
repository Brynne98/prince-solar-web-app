#!/usr/bin/env node
// Local app: rebuilds public/build/ on save and serves public/ (default port 3003).
//   node scripts/dev.mjs [port]
import { build, preview } from 'vite';

const port = Number(process.argv[2]) || 3003;
await build({ build: { watch: {} } });
const server = await preview({ build: { outDir: 'public' }, preview: { port, strictPort: true } });
server.printUrls();
