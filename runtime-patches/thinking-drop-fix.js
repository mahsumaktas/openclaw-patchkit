'use strict';

const Module = require('module');
const MARKER = '__thinking_drop_fix_installed';
if (global[MARKER]) return;
global[MARKER] = true;

const originalLoad = Module._load;
let patched = false;

Module._load = function(request, parent, isMain) {
  const exports = originalLoad.call(this, request, parent, isMain);

  if (!patched && exports && typeof exports.assessLastAssistantMessage === 'function') {
    const original = exports.assessLastAssistantMessage;
    exports.assessLastAssistantMessage = function(messages, ...args) {
      const result = original.call(this, messages, ...args);
      if (result === 'incomplete-thinking' && messages && messages.length > 0) {
        const lastMsg = messages[messages.length - 1];
        const content = lastMsg?.content;
        if (Array.isArray(content)) {
          const hasNonThinking = content.some(block =>
            block.type !== 'thinking' && block.type !== 'redacted_thinking'
          );
          if (hasNonThinking) {
            return 'ok';
          }
        }
      }
      return result;
    };
    patched = true;
    console.log('[runtime-patch] thinking-drop-fix: assessLastAssistantMessage patched');
  }

  return exports;
};

console.log('[runtime-patch] thinking-drop-fix: interceptor active');
