'use strict';

const path = require('path');
const fs = require('fs');

const PATCHES_DIR = __dirname;
const LOG_PREFIX = '[runtime-patch]';

const PATCHES = [
  'carbon-error-handler.js',
  'tls-probe-fix.js',
  'self-signed-cert.js',
  'safety-net-28258.js',
  'thinking-drop-fix.js',
];

let loaded = 0;
let failed = 0;

for (const patch of PATCHES) {
  const patchPath = path.join(PATCHES_DIR, patch);
  if (!fs.existsSync(patchPath)) {
    console.error(`${LOG_PREFIX} SKIP (not found): ${patch}`);
    continue;
  }
  try {
    require(patchPath);
    loaded++;
  } catch (err) {
    console.error(`${LOG_PREFIX} FAILED: ${patch} — ${err.message}`);
    failed++;
  }
}

console.log(`${LOG_PREFIX} Loaded ${loaded}/${PATCHES.length} patches (${failed} failed)`);
