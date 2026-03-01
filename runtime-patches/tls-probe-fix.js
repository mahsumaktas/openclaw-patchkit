'use strict';

const MARKER = '__tls_probe_fix_installed';
if (global[MARKER]) return;
global[MARKER] = true;

const fs = require('fs');
const path = require('path');
const os = require('os');

function isTlsEnabled() {
  try {
    const configPath = path.join(os.homedir(), '.openclaw', 'config.yaml');
    if (!fs.existsSync(configPath)) return false;
    const content = fs.readFileSync(configPath, 'utf8');
    return /gateway:\s*\n(?:.*\n)*?\s+tls:\s*\n(?:.*\n)*?\s+enabled:\s*true/m.test(content);
  } catch {
    return false;
  }
}

if (isTlsEnabled()) {
  try {
    const WS = require('ws');
    const OrigWebSocket = WS.WebSocket || WS;
    const patchedWS = function(url, protocols, options) {
      if (typeof url === 'string' && url.startsWith('ws://127.0.0.1:')) {
        url = url.replace('ws://', 'wss://');
      }
      if (typeof url === 'string' && url.startsWith('ws://localhost:')) {
        url = url.replace('ws://', 'wss://');
      }
      return new OrigWebSocket(url, protocols, options);
    };
    patchedWS.prototype = OrigWebSocket.prototype;
    if (WS.WebSocket) {
      WS.WebSocket = patchedWS;
    }
    console.log('[runtime-patch] tls-probe-fix: active (TLS enabled, ws->wss for localhost)');
  } catch (err) {
    console.error('[runtime-patch] tls-probe-fix: failed to patch WebSocket —', err.message);
  }
} else {
  console.log('[runtime-patch] tls-probe-fix: skipped (TLS not enabled)');
}
