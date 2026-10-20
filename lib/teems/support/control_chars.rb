# frozen_string_literal: true

module Teems
  module Support
    # Removes C0 and C1 control characters, other than tab and newline, from text a sender
    # controls. Printed to a terminal they are escape sequences: ESC ]52 sets the clipboard
    # on terminals that allow OSC 52, and others move the cursor or rewrite the screen.
    module ControlChars
      CONTROLS = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/

      module_function

      def strip(text)
        string = text.to_s
        string.match?(CONTROLS) ? string.gsub(CONTROLS, '') : string
      end
    end
  end
end
