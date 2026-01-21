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
        time_str = message.created_at&.strftime('%Y-%m-%d %H:%M') || ''
        importance_marker = message.important? ? @output.red('!') : ''

        header = "#{@output.blue("[#{time_str}]")} #{importance_marker}#{@output.bold(message.sender_name)}:"
        content = "  #{message.content}"

        reactions = if message.reactions.any?
                      reactions_str = message.reactions.map { |r| "#{r[:type]}(#{r[:count]})" }.join(' ')
                      "  #{@output.gray(reactions_str)}"
                    end

        [header, content, reactions].compact.join("\n")
      end
    end
  end
end
