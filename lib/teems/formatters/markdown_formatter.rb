# frozen_string_literal: true

module Teems
  module Formatters
    # Formats chat messages as a Markdown document for local storage.
    # Groups messages by date with human-readable formatting.
    class MarkdownFormatter
      REACTION_EMOJI = {
        'like' => "\u{1F44D}",
        'heart' => "\u{2764}\u{FE0F}",
        'laugh' => "\u{1F602}",
        'surprised' => "\u{1F62E}",
        'sad' => "\u{1F622}",
        'angry' => "\u{1F620}"
      }.freeze

      def initialize(chat_name:, chat_type: nil, synced_at: nil)
        @chat_name = chat_name
        @chat_type = chat_type
        @synced_at = synced_at
      end

      # Format an array of Message objects into a Markdown string.
      # Messages should be in chronological order (oldest first).
      def format(messages)
        lines = []
        lines << build_header
        lines << ''

        if messages.empty?
          lines << '_No messages_'
          return lines.join("\n")
        end

        current_date = nil
        messages.each do |msg|
          next if msg.system_message?

          msg_date = msg.created_at&.strftime('%Y-%m-%d')
          if msg_date != current_date
            lines << '' if current_date # blank line between date sections
            lines << "## #{msg_date || 'Unknown Date'}"
            lines << ''
            current_date = msg_date
          end

          lines.concat(format_message(msg))
          lines << ''
        end

        lines.join("\n")
      end

      private

      def build_header
        parts = ["# #{@chat_name}"]
        parts << "**Type:** #{@chat_type}" if @chat_type
        parts << "_Synced: #{@synced_at.strftime('%Y-%m-%d %H:%M')}_" if @synced_at
        parts.join("\n\n")
      end

      def format_message(msg)
        lines = []
        time_str = msg.created_at&.strftime('%H:%M') || '??:??'
        sender = msg.sender_name || 'Unknown'

        # Reply marker
        lines << "> _Reply to message_" if msg.reply?

        # Importance marker
        prefix = msg.important? ? '**[!]** ' : ''

        lines << "### #{time_str} — #{prefix}#{sender}"
        lines << ''
        lines << msg.content unless msg.content.nil? || msg.content.empty?

        # Attachments
        if msg.attachments.is_a?(Array) && msg.attachments.any?
          msg.attachments.each do |att|
            name = att.is_a?(Hash) ? (att['fileName'] || att['name'] || 'file') : att.to_s
            lines << "\u{1F4CE} #{name}"
          end
        end

        # Reactions
        if msg.reactions.is_a?(Array) && msg.reactions.any?
          reaction_strs = msg.reactions.map do |r|
            emoji = REACTION_EMOJI[r[:type]] || r[:type]
            count = r[:count] || 1
            count > 1 ? "#{emoji} ×#{count}" : emoji.to_s
          end
          lines << "Reactions: #{reaction_strs.join('  ')}"
        end

        lines
      end
    end
  end
end
