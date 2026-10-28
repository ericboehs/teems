# frozen_string_literal: true

module Teems
  module Services
    # Copies text to the macOS clipboard with pbcopy
    class Clipboard
      def copy(text)
        _out, errors, status = Support::Subprocess.capture3('pbcopy', stdin_data: text)
        raise Error, "Could not copy to the clipboard: #{errors.strip}" unless status.success?

        text
      rescue Errno::ENOENT
        raise Error, 'Copying needs the macOS pbcopy command'
      end
    end
  end
end
