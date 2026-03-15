# frozen_string_literal: true

module Teems
  module Formatters
    # Formats messages for terminal display
    class MessageFormatter
      def initialize(output:, cache_store: nil)
        @output = output
        @cache_store = cache_store
      end

      def format(message)
        [format_header(message), "  #{message.content}", format_reactions(message)].compact.join("\n")
      end

      private

      def format_header(message)
        time_str = message.created_at&.strftime('%Y-%m-%d %H:%M') || ''
        importance = message.important? ? @output.red('!') : ''
        "#{@output.blue("[#{time_str}]")} #{importance}#{@output.bold(message.sender_name)}:"
      end

      def format_reactions(message)
        return unless message.reactions.any?

        str = message.reactions.map { |reaction| "#{reaction[:type]}(#{reaction[:count]})" }.join(' ')
        "  #{@output.gray(str)}"
      end
    end
  end
end
