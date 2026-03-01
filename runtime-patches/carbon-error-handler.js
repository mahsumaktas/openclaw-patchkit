'use strict';

const MARKER = '__carbon_error_handler_installed';
if (global[MARKER]) return;
global[MARKER] = true;

const EventEmitter = require('events');
const originalEmit = EventEmitter.prototype.emit;

EventEmitter.prototype.emit = function (event, ...args) {
  if (event === 'error' && this.listenerCount('error') === 0) {
    const stack = new Error().stack || '';
    if (stack.includes('GatewayPlugin') || stack.includes('@buape/carbon')) {
      console.error('[runtime-patch:carbon] Caught unhandled Carbon error:', args[0]?.message || args[0]);
      return true;
    }
  }
  return originalEmit.call(this, event, ...args);
};

console.log('[runtime-patch] carbon-error-handler: active');
