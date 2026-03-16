# frozen_string_literal: true

require 'open3'
require_relative 'token_extractor_scripts'
require_relative 'token_exchange_scripts'
require_relative 'headless_extract'

module Teems
  module Services
    # Safari automation: AppleScript execution and JS injection
    module SafariAutomation
      private

      def run_safari_js(js_code)
        run_applescript(safari_js_script(escape_js_for_applescript(js_code)))
      end

      def run_safari_readystate
        run_applescript(safari_readystate_script)
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

      def run_safari_script(body)
        run_applescript(<<~APPLESCRIPT)
          tell application "Safari"
            #{body}
          end tell
        APPLESCRIPT
      end

      def escape_js_for_applescript(js_code)
        js_code.gsub('\\', '\\\\\\\\')
               .gsub('"', '\\"')
               .gsub("\n", '\\n')
      end

      def run_applescript(script)
        output, status = Open3.capture2('osascript', '-e', script)
        return applescript_failure(status) unless status.success?

        output.strip
      rescue IOError, SystemCallError => err
        log_applescript_error(err)
      end

      def applescript_failure(status)
        log("AppleScript execution failed with status #{status.exitstatus}")
        nil
      end

      def log_applescript_error(run_error)
        log(applescript_error_message(run_error))
        nil
      end

      def applescript_error_message(run_error)
        label = run_error.is_a?(Errno::ENOENT) ? 'osascript not found' : 'AppleScript I/O error'
        "#{label}: #{run_error.message}"
      end
    end

    # V2 token decryption via AES-CBC encrypted localStorage keys
    module TokenV2Decryptor
      include TokenExtractorScripts

      DECRYPT_RESULT_KEY = '_teems_decrypt_result'

      private

      def extract_tokens_v2
        status = kick_off_decryption
        return nil if status == 'no_key'

        poll_decrypt_result
      rescue JSON::ParserError => err
        log("Failed to parse v2 token decryption result: #{err.message}")
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
          result = check_decrypt_result(read_js, attempt)
          return result if result
        end
        log('Timed out waiting for v2 token decryption')
        nil
      end

      def check_decrypt_result(read_js, attempt)
        sleep 1
        result = run_safari_js(read_js).to_s.strip
        return nil if result.empty? || result == 'null'

        parse_decrypt_result(result, attempt)
      end

      def parse_decrypt_result(result, attempt)
        parsed = JSON.parse(result)
        error = parsed['error']
        return log_decrypt_error(error) if error

        auth_token = parsed['auth_token']
        return nil unless auth_token

        log("V2 tokens decrypted after #{attempt + 1}s")
        finalize_tokens(auth_token, parsed['skype_spaces_token'], **extract_v1_refresh_data)
      end

      def log_decrypt_error(message)
        log("Decryption error: #{message}")
        nil
      end
    end

    # Token exchange: converting skype spaces token to skype token
    module TokenExchanger
      include TokenExchangeScripts

      private

      def exchange_skype_if_available(skype_spaces_token)
        return nil unless skype_spaces_token

        log('Exchanging skype spaces token via authsvc...')
        result = exchange_skype_token(skype_spaces_token)
        result&.dig(:skype_token)
      end

      def exchange_skype_token(skype_spaces_token)
        result = run_safari_js(build_exchange_script(skype_spaces_token))
        return nil if result.to_s.empty?

        parse_exchange_result(result)
      rescue JSON::ParserError => err
        log("Failed to parse token exchange result: #{err.message}")
        nil
      end

      def parse_exchange_result(result)
        parsed = JSON.parse(result)
        return nil if parsed['error']

        { skype_token: parsed['skype_token'], region: parsed['region'], chat_service: parsed['chat_service'] }
      end

      def build_exchange_script(skype_spaces_token)
        format(EXCHANGE_TOKEN_JS, JSON.generate(skype_spaces_token))
      end
    end

    # Token polling: v1/v2 extraction loop and finalization
    module TokenPolling
      include TokenExtractorScripts

      TOKEN_POLL_MAX_SECONDS = 30
      TOKEN_POLL_INTERVAL = 1
      V1_POLL_MAX_SECONDS = 5

      private

      def wait_for_tokens
        v2_attempted = false
        TOKEN_POLL_MAX_SECONDS.times do |attempt|
          tokens, v2_attempted = poll_once(attempt, v2_attempted)
          return tokens if tokens&.dig(:auth_token)

          log_poll_progress(attempt)
          sleep TOKEN_POLL_INTERVAL
        end
        nil
      end

      def poll_once(attempt, v2_attempted)
        tokens = extract_tokens_v1
        return [tokens, v2_attempted] if tokens&.dig(:auth_token)

        try_v2_if_needed(attempt, v2_attempted)
      end

      def try_v2_if_needed(attempt, v2_attempted)
        return [nil, v2_attempted] if v2_attempted || attempt < V1_POLL_MAX_SECONDS

        log('V1 tokens not found, trying v2 encrypted token decryption...')
        [extract_tokens_v2, true]
      end

      def log_poll_progress(attempt)
        elapsed = attempt + 1
        log("Tokens not yet available, retrying... (#{elapsed}s)") if (elapsed % 5).zero?
      end

      def extract_tokens_v1
        parsed = parse_safari_json(EXTRACT_TOKENS_JS)
        return nil unless parsed&.dig('auth_token')

        finalize_tokens(parsed['auth_token'], parsed['skype_spaces_token'],
                        **v1_extras(parsed))
      rescue JSON::ParserError => err
        log("Failed to parse v1 token extraction result: #{err.message}")
        nil
      end

      def parse_safari_json(js_code)
        result = run_safari_js(js_code)
        return nil if result.to_s.empty?

        JSON.parse(result)
      end

      # Extract refresh token data from V1 localStorage (always unencrypted)
      def extract_v1_refresh_data
        parsed = parse_safari_json(EXTRACT_TOKENS_JS)
        return {} unless parsed&.dig('refresh_token')

        v1_extras(parsed)
      rescue JSON::ParserError
        {}
      end

      def v1_extras(parsed)
        { refresh_token: parsed['refresh_token'],
          client_id: parsed['client_id'],
          tenant_id: parsed['tenant_id'] }
      end

      def finalize_tokens(auth_token, skype_spaces_token, **extras)
        skype_token = exchange_skype_if_available(skype_spaces_token)
        { auth_token: auth_token, skype_token: skype_token,
          skype_spaces_token: skype_spaces_token, chatsvc_token: nil,
          refresh_token: nil, client_id: nil, tenant_id: nil, **extras }
      end
    end

    # Extracts Teams authentication tokens using Safari automation
    class TokenExtractor
      include TokenExtractorScripts
      include TokenExchangeScripts
      include SafariAutomation
      include TokenV2Decryptor
      include TokenExchanger
      include TokenPolling
      include HeadlessExtract

      TEAMS_URL = 'https://teams.microsoft.com'

      def initialize(output: nil)
        @output = output
      end

      def extract
        tokens = try_headless_extract
        return tokens if tokens&.dig(:auth_token) && tokens[:skype_token]

        safari_extract
      end

      def safari_extract
        return log_and_return('Safari is not available') unless safari_available?

        log('Opening Teams in Safari...')
        open_teams_in_safari
        extract_and_close
      end

      def manual_instructions = MANUAL_TOKEN_INSTRUCTIONS

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

      def safari_available? = system('which', 'osascript', out: File::NULL, err: File::NULL)

      def open_teams_in_safari
        run_applescript(open_teams_script)
      end

      def open_teams_script
        <<~APPLESCRIPT
          tell application "Safari"
            activate
            if (count of windows) = 0 then
              make new document with properties {URL:"#{TEAMS_URL}"}
            else
              tell front window
                set current tab to (make new tab with properties {URL:"#{TEAMS_URL}"})
              end tell
            end if
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
        consecutive_ready = 0
        60.times do |second|
          sleep 1
          consecutive_ready = page_ready? ? consecutive_ready + 1 : 0
          break if consecutive_ready >= 3

          elapsed = second + 1
          log("Waiting... (#{elapsed}s)") if (elapsed % 10).zero?
        end
      end

      def page_ready?
        result = run_safari_readystate
        return false unless result

        url, ready_state = result.split('|', 2)
        teams_page_loaded?(url.to_s, ready_state.to_s)
      end

      def teams_page_loaded?(url, ready_state)
        url.include?('teams.microsoft.com') && !url.include?('login') && ready_state == 'complete'
      end

      def log(message) = @output&.debug(message)
    end
  end
end
