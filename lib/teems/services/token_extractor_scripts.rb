# frozen_string_literal: true

module Teems
  module Services
    # JavaScript constants used by TokenExtractor for v1 token extraction
    # and v2 AES-CBC decryption. Separated to keep modules under line limits.
    module TokenExtractorScripts
      # JavaScript to extract tokens from Teams web app localStorage.
      EXTRACT_TOKENS_JS = <<~JS
        (function() {
          var result = { auth_token: null, skype_spaces_token: null,
                         refresh_token: null, client_id: null, tenant_id: null };

          try {
            for (var i = 0; i < localStorage.length; i++) {
              var key = localStorage.key(i);

              // Teams v1 / MSAL format: accesstoken keys with secret field
              if (key.includes('accesstoken')) {
                var value = localStorage.getItem(key);
                var parsed = JSON.parse(value);
                if (parsed.secret) {
                  if (key.includes('graph.microsoft.com')) {
                    result.auth_token = parsed.secret;
                  }
                  if (key.includes('api.spaces.skype.com')) {
                    result.skype_spaces_token = parsed.secret;
                  }
                }
              }

              // MSAL refresh token (always v1/unencrypted)
              if (key.includes('refreshtoken')) {
                var rtVal = localStorage.getItem(key);
                var rt = JSON.parse(rtVal);
                if (rt.secret) {
                  result.refresh_token = rt.secret;
                  result.client_id = rt.clientId;
                  if (rt.homeAccountId && rt.homeAccountId.indexOf('.') !== -1) {
                    result.tenant_id = rt.homeAccountId.split('.')[1];
                  }
                }
              }
            }
          } catch(e) {}

          return JSON.stringify(result);
        })()
      JS

      # JavaScript to kick off async decryption of Teams v2 encrypted tokens.
      DECRYPT_TOKENS_JS = <<~JS
        (function() {
          var RESULT_KEY = '{{result_key}}';
          localStorage.removeItem(RESULT_KEY);

          var keyDataRaw = localStorage.getItem('tmp.auth.v1.GLOBAL.ExportedEncryptionKey.ExportedEncryptionKey');
          if (!keyDataRaw) {
            localStorage.setItem(RESULT_KEY, JSON.stringify({error: 'no_encryption_key'}));
            return 'no_key';
          }

          var keyData = JSON.parse(keyDataRaw);
          var exportedKey = keyData.item.exportedKey;
          var keyBytes = Uint8Array.from(atob(exportedKey), function(c) { return c.charCodeAt(0); });

          function getEncItem(keyPart) {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k.includes(keyPart)) {
                var val = JSON.parse(localStorage.getItem(k));
                return val.item || val;
              }
            }
            return null;
          }

          function decryptToken(item) {
            if (!item || !item.encryptedToken || !item.iv) return Promise.resolve(null);
            var iv = Uint8Array.from(atob(item.iv), function(c) { return c.charCodeAt(0); });
            var enc = Uint8Array.from(atob(item.encryptedToken), function(c) { return c.charCodeAt(0); });
            return crypto.subtle.importKey('raw', keyBytes, {name: 'AES-CBC'}, false, ['decrypt'])
              .then(function(ck) { return crypto.subtle.decrypt({name: 'AES-CBC', iv: iv}, ck, enc); })
              .then(function(d) {
                var text = new TextDecoder().decode(d);
                var padLen = text.charCodeAt(text.length - 1);
                if (padLen > 0 && padLen <= 16) text = text.substring(0, text.length - padLen);
                return text;
              })
              .catch(function() { return null; });
          }

          var graph = getEncItem('Token.HTTPS://GRAPH.MICROSOFT.COM');
          var skype = getEncItem('Token.HTTPS://API.SPACES.SKYPE.COM');

          Promise.all([decryptToken(graph), decryptToken(skype)])
            .then(function(results) {
              var r = { auth_token: results[0], skype_spaces_token: results[1] };
              localStorage.setItem(RESULT_KEY, JSON.stringify(r));
            })
            .catch(function(e) {
              localStorage.setItem(RESULT_KEY, JSON.stringify({error: e.message}));
            });

          return 'started';
        })()
      JS

      READ_DECRYPT_RESULT_JS = <<~JS
        (function() {
          return localStorage.getItem('{{result_key}}');
        })()
      JS
    end
  end
end
