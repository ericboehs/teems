# frozen_string_literal: true

require 'open3'

module Teems
  module Services
    # Runs JavaScript in Safari's current tab via AppleScript
    class SafariJsRunner
      def initialize(output: nil)
        @output = output
      end

      def available? = system('which', 'osascript', out: File::NULL, err: File::NULL)

      def execute_js(js_code)
        escaped = escape_js(js_code)
        run_applescript(safari_js_script(escaped))
      end

      def navigate(url)
        run_applescript(navigate_script(url))
      end

      def wait_for_load(timeout: 15)
        timeout.times do
          sleep 1
          return if execute_js('document.readyState') == 'complete'
        end
        raise Teems::Error, 'Timed out waiting for page to load'
      end

      def page_url
        run_applescript(page_url_script)
      end

      private

      def escape_js(js_code)
        js_code.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')
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

      def navigate_script(url)
        <<~APPLESCRIPT
          tell application "Safari"
            activate
            if (count of windows) = 0 then
              make new document with properties {URL:"#{url}"}
            else
              set URL of current tab of front window to "#{url}"
            end if
          end tell
        APPLESCRIPT
      end

      def page_url_script
        <<~APPLESCRIPT
          tell application "Safari"
            if (count of windows) > 0 then
              return URL of current tab of front window
            end if
            return ""
          end tell
        APPLESCRIPT
      end

      def run_applescript(script)
        out, _err, status = Open3.capture3('osascript', '-e', script)
        return nil unless status.success?

        out.strip
      rescue IOError, SystemCallError
        nil
      end

      def log(message) = @output&.debug(message)
    end
  end
end
