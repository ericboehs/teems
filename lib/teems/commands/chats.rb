# frozen_string_literal: true

module Teems
  module Commands
    # Parsing and filtering logic for chats command
    module ChatsParsing
      private

      def render_chats(chats)
        space_names = build_space_names(chats)
        parsed = chats.filter_map { |chat_data| parse_chat(chat_data, space_names) }
        filtered = apply_filters(parsed)
        @options[:json] ? output_json(filtered.map { |chat| chat_to_hash(chat) }) : display_chats(filtered)
      end

      def build_space_names(chats)
        chats.each_with_object({}) do |chat_data, map|
          tp = chat_data['threadProperties'] || {}
          map[chat_data['id']] = tp['spaceThreadTopic'] if tp['threadType'] == 'space'
        end
      end

      def parse_chat(chat_data, space_names)
        return nil if chat_data['id']&.start_with?('48:')

        chat = Models::Chat.from_api(chat_data)
        resolve_channel_name(chat, chat_data, space_names)
      end

      def resolve_channel_name(chat, chat_data, space_names)
        return chat unless chat.channel?

        team_name = space_names[chat_data.dig('threadProperties', 'spaceId')]
        team_name ? chat.with(topic: "#{team_name} -> #{chat.topic}") : chat
      end

      def apply_filters(chats)
        chats = chats.select(&:unread?) if @options[:unread]
        chats = chats.select(&:favorite?) if @options[:favorites]
        chats = chats.select(&:pinned?) if @options[:pinned]
        chats
      end

      def chat_to_hash(chat)
        { id: chat.id, topic: chat.topic, chat_type: chat.chat_type,
          last_updated: chat.last_updated&.iso8601,
          unread: chat.unread?, favorite: chat.favorite?, pinned: chat.pinned? }
      end
    end

    # Display helpers for chats command
    module ChatsDisplay
      CHAT_TYPE_ICONS = {
        'oneOnOne' => "\u{1F464}", 'group' => "\u{1F465}", 'meeting' => "\u{1F4C5}"
      }.freeze

      private

      def display_chats(chats)
        return puts('No chats found') if chats.empty?

        chats.each { |chat| display_single_chat(chat) }
      end

      def display_single_chat(chat)
        time_str = chat.last_updated&.strftime('%Y-%m-%d %H:%M') || ''
        unread_marker = chat.unread? ? output.bold('* ') : '  '
        puts "#{unread_marker}#{CHAT_TYPE_ICONS.fetch(chat.chat_type, "\u{1F4AC}")} #{output.bold(chat.display_name)}"
        puts "      ID: #{chat.id}"
        puts "      Last updated: #{time_str}" unless time_str.empty?
        puts
      end
    end

    # List recent chats
    class Chats < Base
      include ChatsParsing
      include ChatsDisplay

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        list_chats
      end

      protected

      CHATS_OPTIONS = {
        '--unread' => ->(opts, _pending) { opts[:unread] = true },
        '--favorites' => ->(opts, _pending) { opts[:favorites] = true },
        '--pinned' => ->(opts, _pending) { opts[:pinned] = true }
      }.freeze

      def handle_option(arg, pending)
        handler = CHATS_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text
        <<~HELP
          #{output.bold('teems chats')} - List recent chats

          #{output.bold('USAGE:')}
            teems chats [options]

          #{output.bold('OPTIONS:')}
            -n, --limit N    Number of chats to show (default: 20)
            --unread         Show only unread chats
            --favorites      Show only favorite chats
            --pinned         Show only pinned chats
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output
            --json           Output as JSON

          #{output.bold('EXAMPLES:')}
            teems chats              # List recent chats
            teems chats --unread     # Show only unread chats
            teems chats --favorites  # Show only favorites
            teems chats -n 50        # Show 50 chats
            teems chats --json       # Output as JSON
        HELP
      end

      private

      def list_chats
        chats = fetch_chats
        render_chats(chats)
        0
      rescue ApiError => e
        error("Failed to fetch chats: #{e.message}")
        1
      end

      def fetch_chats
        response = with_token_refresh { runner.chats_api.list(limit: @options[:limit]) }
        response['conversations'] || response['value'] || []
      end
    end
  end
end
