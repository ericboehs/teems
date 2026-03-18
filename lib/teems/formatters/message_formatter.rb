# frozen_string_literal: true

module Teems
  module Formatters
    # Formats messages for terminal display
    class MessageFormatter
      REACTION_EMOJI = {
        'like' => "\u{1F44D}", 'heart' => "\u{2764}\u{FE0F}",
        'laugh' => "\u{1F602}", 'surprised' => "\u{1F62E}",
        'sad' => "\u{1F622}", 'angry' => "\u{1F620}",
        'yes-tone1' => "\u{1F44D}\u{1F3FB}", 'yes-tone2' => "\u{1F44D}\u{1F3FC}",
        'support' => "\u{1F91D}", 'heartblue' => "\u{1F499}",
        'computer' => "\u{1F4BB}", '1f37f_popcorn' => "\u{1F37F}",
        '1f440_eyes' => "\u{1F440}", 'thumbsdown' => "\u{1F44E}"
      }.freeze

      def initialize(output:, cache_store: nil)
        @output = output
        @cache_store = cache_store
      end

      def format(message)
        content = highlight_mentions(message.content, message.mentions)
        [format_header(message), "  #{content}", format_attachments(message), format_reactions(message)]
          .compact.join("\n")
      end

      private

      def format_header(message)
        importance = message.important? ? @output.red('!') : ''
        hash = @output.gray(message.short_hash)
        "#{format_timestamp(message)} #{hash} #{importance}#{@output.bold(message.sender_name)}:#{edited_tag(message)}"
      end

      def format_timestamp(message) = @output.blue("[#{message.created_at&.strftime('%Y-%m-%d %H:%M')}]")

      def edited_tag(message) = message.edited? ? " #{@output.gray('(edited)')}" : ''

      def format_attachments(message)
        attachments = message.attachments
        return unless attachments.any?

        names = attachments.map { |att| attachment_name(att) }
        "  #{@output.gray("\u{1F4CE} #{names.join(', ')}")}"
      end

      def attachment_name(att)
        att.is_a?(Hash) ? (att['fileName'] || att['name'] || 'file') : att.to_s
      end

      def format_reactions(message)
        reactions = message.reactions
        return unless reactions.any?

        parts = reactions.map { |reaction| format_single_reaction(reaction) }
        "  #{@output.gray(parts.join(' '))}"
      end

      def format_single_reaction(reaction)
        type = reaction[:type]
        "#{REACTION_EMOJI[type] || type}(#{reaction[:count]})"
      end

      def highlight_mentions(content, mentions)
        mentions.inject(content) { |text, name| text.gsub(name, @output.bold(name)) }
      end
    end
  end
end
