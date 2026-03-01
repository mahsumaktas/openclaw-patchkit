'use strict';

const Module = require('module');
const MARKER = '__safety_net_28258_installed';
if (global[MARKER]) return;
global[MARKER] = true;

const originalLoad = Module._load;
let patched = false;

Module._load = function(request, parent, isMain) {
  const exports = originalLoad.call(this, request, parent, isMain);

  if (!patched && exports && typeof exports.wrapAnthropicStreamWithRecovery === 'function') {
    exports.wrapAnthropicStreamWithRecovery = function(stream) {
      return stream;
    };
    patched = true;
    console.log('[runtime-patch] safety-net-28258: wrapper neutralized');
  }

  return exports;
};

console.log('[runtime-patch] safety-net-28258: interceptor active');
