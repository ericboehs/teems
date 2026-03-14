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
        lines = [build_header, '']
        return (lines << '_No messages_').join("\n") if messages.empty?

        format_message_groups(messages, lines)
        lines.join("\n")
      end

      private

      def format_message_groups(messages, lines)
        current_date = nil
        messages.each do |msg|
          next if msg.system_message?

          current_date = append_date_header(lines, msg, current_date)
          lines.concat(format_message(msg))
          lines << ''
        end
      end

      def append_date_header(lines, msg, current_date)
        msg_date = msg.created_at&.strftime('%Y-%m-%d')
        return current_date if msg_date == current_date

        lines << '' if current_date
        lines << "## #{msg_date || 'Unknown Date'}"
        lines << ''
        msg_date
      end

      def build_header
        parts = ["# #{@chat_name}"]
        parts << "**Type:** #{@chat_type}" if @chat_type
        parts << "_Synced: #{@synced_at.strftime('%Y-%m-%d %H:%M')}_" if @synced_at
        parts.join("\n\n")
      end

      def format_message(msg)
        lines = []
        lines << '> _Reply to message_' if msg.reply?
        lines << format_message_header(msg)
        lines << ''
        lines << msg.content unless msg.content.nil? || msg.content.empty?
        lines.concat(format_message_attachments(msg))
        lines.concat(format_message_reactions(msg))
        lines
      end

      def format_message_header(msg)
        time_str = msg.created_at&.strftime('%H:%M') || '??:??'
        sender = msg.sender_name || 'Unknown'
        prefix = msg.important? ? '**[!]** ' : ''
        "### #{time_str} — #{prefix}#{sender}"
      end

      def format_message_attachments(msg)
        return [] unless msg.attachments.is_a?(Array) && msg.attachments.any?

        msg.attachments.map do |att|
          name = att.is_a?(Hash) ? (att['fileName'] || att['name'] || 'file') : att.to_s
          "\u{1F4CE} #{name}"
        end
      end

      def format_message_reactions(msg)
        return [] unless msg.reactions.is_a?(Array) && msg.reactions.any?

        strs = msg.reactions.map { |r| format_single_reaction(r) }
        ["Reactions: #{strs.join('  ')}"]
      end

      def format_single_reaction(reaction)
        emoji = REACTION_EMOJI[reaction[:type]] || reaction[:type]
        count = reaction[:count] || 1
        count > 1 ? "#{emoji} \u00d7#{count}" : emoji.to_s
      end
    end
  end
end
