// Packages the watcher into a single self-contained RPHelper.exe (no Node needed).
// Uses Bun's compiler (embeds the runtime — no external binary cache required).
// Usage: node scripts/build-exe.mjs
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = path.join(ROOT, 'dist');
const ENTRY = path.join(ROOT, 'server', 'server.js');
const EXE = path.join(OUT_DIR, 'RPHelper.exe');

fs.mkdirSync(OUT_DIR, { recursive: true });

console.log('[1/2] compiling RPHelper.exe (bun build --compile)…');
execSync(
  `npx --yes bun build "${ENTRY}" --compile --outfile "${EXE}"`,
  { stdio: 'inherit', cwd: ROOT }
);

console.log('[2/2] done →', EXE);
console.log('Friend layout: RPHelper.exe + config.json + public\\ in one folder, run RPHelper.exe.');