# frozen_string_literal: true

module Teems
  module Services
    # Opens a URL in the default browser with macOS's `open`
    class Browser
      def open(url)
        _out, errors, status = Support::Subprocess.capture3('open', url)
        raise Error, "Could not open the browser: #{errors.strip}" unless status.success?

        url
      rescue Errno::ENOENT
        raise Error, 'Opening a browser needs the macOS open command'
      end
    end
  end
end
