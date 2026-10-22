# frozen_string_literal: true

module Teems
  module Commands
    # Asking before a bulk or irreversible change. Without a terminal there is nobody to ask,
    # so the caller has to pass --yes instead.
    module Confirmation
      private

      # question: "Archive 3 messages"; refusal: the error when there is no terminal
      def confirm?(question, refusal:)
        raise Error, refusal unless $stdin.tty?

        output.prompt("#{question}? [y/N] ")
        $stdin.gets.to_s.strip.downcase.start_with?('y')
      end
    end
  end
end
