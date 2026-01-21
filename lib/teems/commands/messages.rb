# frozen_string_literal: true

module Teems
  module Commands
    # Read messages from a channel or chat
    class Messages < Base
      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        target = positional_args.first
        unless target
          error('Target required. Specify a channel ID or chat ID.')
          puts
          puts 'Usage: teems messages <channel-id|chat-id>'
          puts 'Use "teems channels" or "teems chats" to find IDs.'
          return 1
        end

        fetch_messages(target)
      end

      protected

      def handle_option(arg, args, _remaining)
        case arg
        when '-t', '--team'
          @options[:team_id] = args.shift
          true
        else
          super
        end
      end

      def help_text
        <<~HELP
          #{output.bold('teems messages')} - Read messages from a channel or chat

          #{output.bold('USAGE:')}
            teems messages <target> [options]

          #{output.bold('ARGUMENTS:')}
            target           Chat ID (thread.v2 format)

          #{output.bold('OPTIONS:')}
            -n, --limit N    Number of messages (default: 20)
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output
            --json           Output as JSON

          #{output.bold('NOTE:')}
            Currently supports chat messages (thread.v2 format).
            Team channel messages (thread.tacv2) are not yet supported.

          #{output.bold('EXAMPLES:')}
            teems messages 19:abc123@thread.v2         # Read chat messages
            teems messages 19:abc123@thread.v2 -n 50   # Show 50 messages
        HELP
      end

      private

      def fetch_messages(target)
        api = runner.messages_api

        # Determine if this is a channel (requires team_id) or a chat
        if @options[:team_id]
          fetch_channel_messages(api, target)
        else
          fetch_chat_messages(api, target)
        end
      end

      def fetch_channel_messages(api, channel_id)
        response = api.channel_messages(
          team_id: @options[:team_id],
          channel_id: channel_id,
          limit: @options[:limit]
        )

        # ng.msg returns 'messages', Graph API returns 'value', other APIs return 'posts'
        display_messages(response['messages'] || response['posts'] || response['value'] || [])
      rescue ApiError => e
        error("Failed to fetch channel messages: #{e.message}")
        1
      end

      def fetch_chat_messages(api, chat_id)
        response = api.chat_messages(
          chat_id: chat_id,
          limit: @options[:limit]
        )

        # ng.msg returns 'messages', Graph API returns 'value', other APIs return 'posts'
        display_messages(response['messages'] || response['posts'] || response['value'] || [])
      rescue ApiError => e
        error("Failed to fetch chat messages: #{e.message}")
        1
      end

      def display_messages(messages_data)
        if messages_data.empty?
          puts 'No messages found'
          return 0
        end

        messages = messages_data.map { |m| Models::Message.from_api(m) }
                                .reject(&:system_message?)
                                .reverse # Show oldest first

        if @options[:json]
          output_json(messages.map { |m| message_to_hash(m) })
        else
          messages.each { |msg| display_message(msg) }
        end

        0
      end

      def display_message(message)
        time_str = message.created_at&.strftime('%Y-%m-%d %H:%M') || ''
        importance_marker = message.important? ? output.red('!') : ''

        puts "#{output.blue("[#{time_str}]")} #{importance_marker}#{output.bold(message.sender_name)}:"
        puts "  #{message.content}"

        if message.reactions.any?
          reactions_str = message.reactions.map { |r| "#{r[:type]}(#{r[:count]})" }.join(' ')
          puts "  #{output.gray(reactions_str)}"
        end

        puts
      end

      def message_to_hash(message)
        {
          id: message.id,
          sender_id: message.sender_id,
          sender_name: message.sender_name,
          content: message.content,
          created_at: message.created_at&.iso8601,
          importance: message.importance,
          reactions: message.reactions
        }
      end
    end
  end
end
