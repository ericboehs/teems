# frozen_string_literal: true

require 'open3'

module Teems
  module Services
    # Extracts Teams authentication tokens using Safari automation
    class TokenExtractor
      TEAMS_URL = 'https://teams.microsoft.com'

      DECRYPT_RESULT_KEY = '_teems_decrypt_result'

      # JavaScript to extract tokens from Teams web app localStorage.
      # Supports both Teams v1 (MSAL accesstoken keys with .secret) and
      # Teams v2 (encrypted tmp.auth.v1.*.Token.* keys decrypted via AES-CBC
      # using the ExportedEncryptionKey).
      EXTRACT_TOKENS_JS = <<~JS
        (function() {
          var result = { auth_token: null, skype_spaces_token: null };

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
            }
          } catch(e) {}

          return JSON.stringify(result);
        })()
      JS

      # JavaScript to kick off async decryption of Teams v2 encrypted tokens.
      # Tokens are encrypted with AES-256-CBC using the ExportedEncryptionKey
      # from localStorage. Results are written back to localStorage under a
      # known key since AppleScript do JavaScript is synchronous.
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

      # JavaScript to exchange skype spaces token for skypeToken via authsvc
      EXCHANGE_TOKEN_JS = <<~JS
        (function(skypeSpacesToken) {
          var xhr = new XMLHttpRequest();
          xhr.open('POST', 'https://teams.microsoft.com/api/authsvc/v1.0/authz', false);
          xhr.setRequestHeader('Authorization', 'Bearer ' + skypeSpacesToken);
          xhr.setRequestHeader('Content-Type', 'application/json');
          try {
            xhr.send('{}');
            if (xhr.status === 200) {
              var result = JSON.parse(xhr.responseText);
              return JSON.stringify({
                skype_token: result.tokens.skypeToken,
                region: result.region,
                chat_service: result.regionGtms.chatService
              });
            }
          } catch(e) {}
          return JSON.stringify({error: 'Exchange failed'});
        })(%s)
      JS

      # Maximum seconds to wait for tokens to appear in localStorage after page loads.
      TOKEN_POLL_MAX_SECONDS = 30
      TOKEN_POLL_INTERVAL = 1

      # How many seconds to try v1 extraction before falling back to v2.
      V1_POLL_MAX_SECONDS = 5

      def initialize(output: nil)
        @output = output
      end

      # Opens Safari to Teams and attempts to extract tokens
      def extract
        return log_and_return('Safari is not available') unless safari_available?

        log('Opening Teams in Safari...')
        open_teams_in_safari
        extract_and_close
      end

      # Manual extraction instructions
      def manual_instructions
        <<~INSTRUCTIONS
          To manually extract tokens:

          1. Open https://teams.microsoft.com in your browser
          2. Log in with your credentials (PIV/Entra ID)
          3. Open Developer Tools (F12 or Cmd+Option+I)
          4. Go to Console tab and run:

             // Get Graph token (for teams/channels)
             for (let i = 0; i < localStorage.length; i++) {
               let key = localStorage.key(i);
               if (key.includes('accesstoken') && key.includes('graph.microsoft.com')) {
                 console.log('auth_token:', JSON.parse(localStorage.getItem(key)).secret);
               }
             }

          5. To get the skypeToken (for messages), you need to:
             a. Find the api.spaces.skype.com token in localStorage
             b. Exchange it via POST to /api/authsvc/v1.0/authz
             c. Or capture it from Network tab (Authentication header)

          The skypeToken uses format: Authentication: skypetoken=<token>
          The Graph token uses format: Authorization: Bearer <token>
        INSTRUCTIONS
      end

      private

      def log_and_return(message)
        log(message)
        nil
      end

      def extract_and_close
        log('Waiting for login to complete...')
        wait_for_login

        log('Extracting tokens...')
        tokens = wait_for_tokens
        validate_tokens(tokens)
      ensure
        close_teams_tab
      end

      def validate_tokens(tokens)
        if tokens&.dig(:auth_token)
          log('Tokens extracted successfully')
          tokens
        else
          log('Failed to extract tokens')
          nil
        end
      end

      def safari_available?
        system('which', 'osascript', out: File::NULL, err: File::NULL)
      end

      def open_teams_in_safari
        run_safari_script(<<~APPLESCRIPT)
          tell front window
            set current tab to (make new tab with properties {URL:"#{TEAMS_URL}"})
          end tell
        APPLESCRIPT
      end

      def close_teams_tab
        run_safari_script(<<~APPLESCRIPT)
          if (count of windows) > 0 then
            close current tab of front window
          end if
        APPLESCRIPT
      end

      def wait_for_login
        60.times do |i|
          sleep 1
          break if page_ready?

          log("Waiting... (#{i + 1}s)") if ((i + 1) % 10).zero?
        end
      end

      def page_ready?
        result = run_safari_js('document.readyState', wrap: false)
        return false unless result

        url, ready_state = result.split('|', 2)
        url.to_s.include?('teams.microsoft.com') && !url.to_s.include?('login') && ready_state.to_s == 'complete'
      end

      # Polls Safari for tokens, trying v1 then v2 decryption
      def wait_for_tokens
        v2_attempted = false

        TOKEN_POLL_MAX_SECONDS.times do |attempt|
          tokens = extract_tokens_v1
          return tokens if tokens&.dig(:auth_token)

          tokens, v2_attempted = try_v2_if_needed(attempt, v2_attempted)
          return tokens if tokens&.dig(:auth_token)

          log_poll_progress(attempt)
          sleep TOKEN_POLL_INTERVAL
        end

        nil
      end

      def try_v2_if_needed(attempt, v2_attempted)
        return [nil, v2_attempted] if v2_attempted || attempt < V1_POLL_MAX_SECONDS

        log('V1 tokens not found, trying v2 encrypted token decryption...')
        [extract_tokens_v2, true]
      end

      def log_poll_progress(attempt)
        log("Tokens not yet available, retrying... (#{attempt + 1}s)") if ((attempt + 1) % 5).zero?
      end

      # Teams v1: synchronous extraction of MSAL accesstoken keys
      def extract_tokens_v1
        result = run_safari_js(EXTRACT_TOKENS_JS)
        return nil if result.nil? || result.empty?

        parsed = JSON.parse(result)
        return nil unless parsed['auth_token']

        finalize_tokens(parsed['auth_token'], parsed['skype_spaces_token'])
      rescue JSON::ParserError => e
        log("Failed to parse v1 token extraction result: #{e.message}")
        nil
      end

      # Teams v2: async decryption of AES-CBC encrypted tokens.
      def extract_tokens_v2
        status = kick_off_decryption
        return nil if status == 'no_key'

        poll_decrypt_result
      rescue JSON::ParserError => e
        log("Failed to parse v2 token decryption result: #{e.message}")
        nil
      end

      def kick_off_decryption
        decrypt_js = DECRYPT_TOKENS_JS.gsub('{{result_key}}', DECRYPT_RESULT_KEY)
        status = run_safari_js(decrypt_js).to_s.strip
        log("Decryption kick-off: #{status}")
        status
      end

      def poll_decrypt_result
        read_js = READ_DECRYPT_RESULT_JS.gsub('{{result_key}}', DECRYPT_RESULT_KEY)

        10.times do |attempt|
          sleep 1
          result = run_safari_js(read_js).to_s.strip
          next if result.empty? || result == 'null'

          return parse_decrypt_result(result, attempt)
        end

        log('Timed out waiting for v2 token decryption')
        nil
      end

      def parse_decrypt_result(result, attempt)
        parsed = JSON.parse(result)

        if parsed['error']
          log("Decryption error: #{parsed['error']}")
          return nil
        end

        return nil unless parsed['auth_token']

        log("V2 tokens decrypted after #{attempt + 1}s")
        finalize_tokens(parsed['auth_token'], parsed['skype_spaces_token'])
      end

      def finalize_tokens(auth_token, skype_spaces_token)
        skype_token = exchange_skype_if_available(skype_spaces_token)

        {
          auth_token: auth_token,
          skype_token: skype_token,
          skype_spaces_token: skype_spaces_token,
          chatsvc_token: nil
        }
      end

      def exchange_skype_if_available(skype_spaces_token)
        return nil unless skype_spaces_token

        log('Exchanging skype spaces token via authsvc...')
        result = exchange_skype_token(skype_spaces_token)
        result&.dig(:skype_token)
      end

      def exchange_skype_token(skype_spaces_token)
        exchange_js = build_exchange_script(skype_spaces_token)
        result = run_safari_js(exchange_js)
        return nil if result.nil? || result.empty?

        parsed = JSON.parse(result)
        return nil if parsed['error']

        { skype_token: parsed['skype_token'], region: parsed['region'], chat_service: parsed['chat_service'] }
      rescue JSON::ParserError => e
        log("Failed to parse token exchange result: #{e.message}")
        nil
      end

      def build_exchange_script(skype_spaces_token)
        safe_token = JSON.generate(skype_spaces_token)
        format(EXCHANGE_TOKEN_JS, safe_token)
      end

      def escape_js_for_applescript(js_code)
        js_code.gsub('\\', '\\\\\\\\')
               .gsub('"', '\\"')
               .gsub("\n", '\\n')
      end

      # Run JavaScript in the current Safari tab, returns the result string
      def run_safari_js(js_code, wrap: true)
        escaped = wrap ? escape_js_for_applescript(js_code) : js_code
        script = if wrap
                   safari_js_script(escaped)
                 else
                   safari_readystate_script
                 end
        run_applescript(script)
      end

      def safari_js_script(escaped_js)
        <<~APPLESCRIPT
          tell application "Safari"
            if (count of windows) > 0 then
              return do JavaScript "#{escaped_js}" in current tab of front window
            end if
            return ""
          end tell
        APPLESCRIPT
      end

      def safari_readystate_script
        <<~APPLESCRIPT
          tell application "Safari"
            if (count of windows) > 0 then
              set pageURL to URL of current tab of front window
              try
                set readyState to do JavaScript "document.readyState" in current tab of front window
              on error
                set readyState to "loading"
              end try
              return pageURL & "|" & readyState
            end if
            return ""
          end tell
        APPLESCRIPT
      end

      # Wrap body in a standard `tell application "Safari"` block
      def run_safari_script(body)
        script = <<~APPLESCRIPT
          tell application "Safari"
            #{body}
          end tell
        APPLESCRIPT
        run_applescript(script)
      end

      def run_applescript(script)
        output, status = Open3.capture2('osascript', '-e', script)
        unless status.success?
          log("AppleScript execution failed with status #{status.exitstatus}")
          return nil
        end
        output.strip
      rescue Errno::ENOENT => e
        log("osascript not found: #{e.message}")
        nil
      rescue IOError, SystemCallError => e
        log("AppleScript I/O error: #{e.message}")
        nil
      end

      def log(message)
        @output&.debug(message)
      end
    end
  end
end
