# frozen_string_literal: true

module Teems
  module Commands
    # List recent chats
    class Chats < Base
      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        list_chats
      end

      protected

      def help_text
        <<~HELP
          #{output.bold('teems chats')} - List recent chats

          #{output.bold('USAGE:')}
            teems chats [options]

          #{output.bold('OPTIONS:')}
            -n, --limit N    Number of chats to show (default: 20)
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output
            --json           Output as JSON

          #{output.bold('EXAMPLES:')}
            teems chats              # List recent chats
            teems chats -n 50        # Show 50 chats
            teems chats --json       # Output as JSON
        HELP
      end

      private

      def list_chats
        chats = fetch_chats
        return 0 if chats.empty? && (puts('No chats found') || true)

        render_chats(chats)
        0
      rescue ApiError => api_error
        error("Failed to fetch chats: #{api_error.message}")
        1
      end

      def fetch_chats
        response = with_token_refresh { runner.chats_api.list(limit: @options[:limit]) }
        response['conversations'] || response['value'] || []
      end

      def render_chats(chats)
        if @options[:json]
          output_json(chats.map { |chat_data| chat_to_hash(chat_data) })
        else
          display_chats(chats)
        end
      end

      def display_chats(chats)
        chats.each do |chat_data|
          chat = Models::Chat.from_api(chat_data)
          type_icon = chat_type_icon(chat)
          time_str = chat.last_updated&.strftime('%Y-%m-%d %H:%M') || ''

          puts "#{type_icon} #{output.bold(chat.display_name)}"
          puts "    ID: #{chat.id}"
          puts "    Last updated: #{time_str}" unless time_str.empty?
          puts
        end
      end

      def chat_type_icon(chat)
        case chat.chat_type
        when 'oneOnOne' then '👤'
        when 'group' then '👥'
        when 'meeting' then '📅'
        else '💬'
        end
      end

      def chat_to_hash(chat_data)
        chat = Models::Chat.from_api(chat_data)
        {
          id: chat.id,
          topic: chat.topic,
          chat_type: chat.chat_type,
          last_updated: chat.last_updated&.iso8601
        }
      end
    end
  end
end
