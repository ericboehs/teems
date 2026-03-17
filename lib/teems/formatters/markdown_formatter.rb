# frozen_string_literal: true

module Teems
  module Formatters
    # Formats chat messages as a Markdown document for local storage.
    # Groups messages by date with human-readable formatting.
    class MarkdownFormatter
      REACTION_EMOJI = {
        'like' => "\u{1F44D}", 'heart' => "\u{2764}\u{FE0F}",
        'laugh' => "\u{1F602}", 'surprised' => "\u{1F62E}",
        'sad' => "\u{1F622}", 'angry' => "\u{1F620}",
        'yes-tone1' => "\u{1F44D}\u{1F3FB}", 'yes-tone2' => "\u{1F44D}\u{1F3FC}",
        'support' => "\u{1F91D}", 'heartblue' => "\u{1F499}",
        'computer' => "\u{1F4BB}", '1f37f_popcorn' => "\u{1F37F}",
        '1f440_eyes' => "\u{1F440}", 'thumbsdown' => "\u{1F44E}"
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
        lines.push("## #{msg_date || 'Unknown Date'}", '')
        msg_date
      end

      def build_header
        parts = ["# #{@chat_name}"]
        parts << "**Type:** #{@chat_type}" if @chat_type
        parts << "_Synced: #{@synced_at.strftime('%Y-%m-%d %H:%M')}_" if @synced_at
        parts.join("\n\n")
      end

      def format_message(msg)
        [*(msg.reply? ? ['> _Reply to message_'] : []),
         format_message_header(msg), '',
         *message_body_lines(msg)]
      end

      def message_body_lines(msg)
        content = msg.content
        result = content.to_s.empty? ? [] : [content]
        result.concat(format_message_attachments(msg))
        result.concat(format_message_reactions(msg))
      end

      def format_message_header(msg)
        prefix = msg.important? ? '**[!]** ' : ''
        edited = msg.edited? ? ' _(edited)_' : ''
        "### #{msg.created_at&.strftime('%H:%M') || '??:??'} — #{prefix}#{msg.sender_name || 'Unknown'}#{edited}"
      end

      def format_message_attachments(msg)
        Array(msg.attachments).map { |att| format_attachment(att) }
      end

      def format_attachment(att)
        return "\u{1F4CE} #{att}" unless att.is_a?(Hash)

        format_file_attachment(att)
      end

      def format_file_attachment(att)
        name = att['fileName'] || att['name'] || 'file'
        url = att['siteUrl']
        url ? "\u{1F4CE} [#{name}](#{url})" : "\u{1F4CE} #{name}"
      end

      def format_message_reactions(msg)
        reactions = msg.reactions
        return [] unless reactions.is_a?(Array) && reactions.any?

        [format_reactions_line(reactions)]
      end

      def format_reactions_line(reactions)
        "Reactions: #{reactions.map { |reaction| format_single_reaction(reaction) }.join('  ')}"
      end

      def format_single_reaction(reaction)
        type = reaction[:type]
        emoji = REACTION_EMOJI[type] || type
        count = reaction[:count] || 1
        count > 1 ? "#{emoji} \u00d7#{count}" : emoji.to_s
      end
    end
  end
end
