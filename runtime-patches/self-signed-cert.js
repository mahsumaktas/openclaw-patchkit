'use strict';

if (!process.env.NODE_TLS_REJECT_UNAUTHORIZED) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
  console.log('[runtime-patch] self-signed-cert: NODE_TLS_REJECT_UNAUTHORIZED=0');
} else {
  console.log('[runtime-patch] self-signed-cert: already set to', process.env.NODE_TLS_REJECT_UNAUTHORIZED);
}
