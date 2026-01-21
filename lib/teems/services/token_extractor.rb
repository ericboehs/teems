# frozen_string_literal: true

require 'open3'

module Teems
  module Services
    # Extracts Teams authentication tokens using Safari automation
    class TokenExtractor
      TEAMS_URL = 'https://teams.microsoft.com'

      # JavaScript to extract tokens from Teams web app localStorage
      # Graph token is used for listing teams/channels
      # Skype spaces token is exchanged for skypeToken used for reading messages
      EXTRACT_TOKENS_JS = <<~JS.freeze
        (function() {
          var result = { auth_token: null, skype_spaces_token: null };

          try {
            for (var i = 0; i < localStorage.length; i++) {
              var key = localStorage.key(i);
              if (key.includes('accesstoken')) {
                var value = localStorage.getItem(key);
                var parsed = JSON.parse(value);
                if (parsed.secret) {
                  // Graph API token for listing teams/channels
                  if (key.includes('graph.microsoft.com')) {
                    result.auth_token = parsed.secret;
                  }
                  // Skype spaces token for authsvc exchange
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

      # JavaScript to exchange skype spaces token for skypeToken via authsvc
      EXCHANGE_TOKEN_JS = <<~JS.freeze
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

      def initialize(output: nil)
        @output = output
      end

      # Opens Safari to Teams and attempts to extract tokens
      # Returns a hash with :auth_token, :skype_token, :chatsvc_token or nil if failed
      def extract
        unless safari_available?
          log('Safari is not available')
          return nil
        end

        log('Opening Teams in Safari...')
        open_teams_in_safari

        log('Waiting for login to complete...')
        wait_for_login

        log('Extracting tokens...')
        tokens = extract_tokens_from_safari

        if tokens && tokens[:auth_token]
          log('Tokens extracted successfully')
          tokens
        else
          log('Failed to extract tokens')
          nil
        end
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

      def safari_available?
        system('which', 'osascript', out: File::NULL, err: File::NULL)
      end

      def open_teams_in_safari
        script = <<~APPLESCRIPT
          tell application "Safari"
            activate
            if (count of windows) = 0 then
              make new document
            end if
            set URL of current tab of front window to "#{TEAMS_URL}"
          end tell
        APPLESCRIPT

        run_applescript(script)
      end

      def wait_for_login
        # Wait for user to complete login
        # We poll until we detect the page has loaded with auth
        max_attempts = 60 # 60 seconds max
        attempts = 0

        loop do
          sleep 1
          attempts += 1

          break if page_ready?
          break if attempts >= max_attempts

          log("Waiting... (#{attempts}s)") if (attempts % 10).zero?
        end
      end

      def page_ready?
        # Check if Teams has loaded (URL contains teams.microsoft.com and not login)
        script = <<~APPLESCRIPT
          tell application "Safari"
            if (count of windows) > 0 then
              return URL of current tab of front window
            end if
            return ""
          end tell
        APPLESCRIPT

        url = run_applescript(script).to_s.strip
        url.include?('teams.microsoft.com') && !url.include?('login')
      end

      def extract_tokens_from_safari
        script = <<~APPLESCRIPT
          tell application "Safari"
            if (count of windows) > 0 then
              return do JavaScript "#{escape_js_for_applescript(EXTRACT_TOKENS_JS)}" in current tab of front window
            end if
            return "{}"
          end tell
        APPLESCRIPT

        result = run_applescript(script)
        return nil if result.nil? || result.empty?

        parsed = JSON.parse(result)
        auth_token = parsed['auth_token']
        skype_spaces_token = parsed['skype_spaces_token']

        return nil unless auth_token

        # Exchange skype spaces token for the actual skypeToken
        skype_token = nil
        if skype_spaces_token
          log('Exchanging skype spaces token via authsvc...')
          exchange_result = exchange_skype_token(skype_spaces_token)
          skype_token = exchange_result[:skype_token] if exchange_result
        end

        {
          auth_token: auth_token,
          skype_token: skype_token,
          chatsvc_token: nil
        }
      rescue JSON::ParserError => e
        log("Failed to parse token extraction result: #{e.message}")
        nil
      end

      def exchange_skype_token(skype_spaces_token)
        # JSON-encode token to safely embed in JavaScript (prevents injection)
        safe_token = JSON.generate(skype_spaces_token)
        exchange_js = format(EXCHANGE_TOKEN_JS, safe_token)
        script = <<~APPLESCRIPT
          tell application "Safari"
            if (count of windows) > 0 then
              return do JavaScript "#{escape_js_for_applescript(exchange_js)}" in current tab of front window
            end if
            return "{}"
          end tell
        APPLESCRIPT

        result = run_applescript(script)
        return nil if result.nil? || result.empty?

        parsed = JSON.parse(result)
        return nil if parsed['error']

        {
          skype_token: parsed['skype_token'],
          region: parsed['region'],
          chat_service: parsed['chat_service']
        }
      rescue JSON::ParserError => e
        log("Failed to parse token exchange result: #{e.message}")
        nil
      end

      def escape_js_for_applescript(js)
        # Escape for embedding in AppleScript string
        js.gsub('\\', '\\\\\\\\')
          .gsub('"', '\\"')
          .gsub("\n", '\\n')
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
