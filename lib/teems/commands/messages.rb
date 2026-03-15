# frozen_string_literal: true

module Teems
  module Commands
    MESSAGES_HELP = <<~HELP
      teems messages - Read messages from a channel or chat

      USAGE:
        teems messages <target> [options]

      ARGUMENTS:
        target           Chat ID, channel ID, or Teams message URL

      OPTIONS:
        -t, --team ID    Team ID (required for channel messages)
        -n, --limit N    Number of messages (default: 20)
        -v, --verbose    Show debug output
        -q, --quiet      Suppress output
        --json           Output as JSON

      EXAMPLES:
        teems messages 19:abc123@thread.v2         # Read chat messages
        teems messages 19:abc123@thread.v2 -n 50   # Show 50 messages
        teems messages "https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=..."
    HELP

    # Read messages from a channel or chat
    class Messages < Base
      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        target = resolve_target
        return 1 unless target

        fetch_messages(target)
      end

      protected

      MESSAGES_OPTIONS = {
        '-t' => ->(opts, args) { opts[:team_id] = args.shift },
        '--team' => ->(opts, args) { opts[:team_id] = args.shift }
      }.freeze

      def handle_option(arg, args, _remaining)
        handler = MESSAGES_OPTIONS[arg]
        return super unless handler

        handler.call(@options, args)
      end

      def help_text = MESSAGES_HELP

      private

      def resolve_target
        target = positional_args.first
        return missing_target unless target

        parse_teams_url_if_needed(target)
      end

      def missing_target
        error('Target required. Specify a channel ID, chat ID, or Teams URL.')
        puts
        puts 'Usage: teems messages <channel-id|chat-id|teams-url>'
        puts 'Use "teems channels" or "teems chats" to find IDs.'
        nil
      end

      def parse_teams_url_if_needed(target)
        return target unless target.start_with?('https://')

        result = Services::TeamsUrlParser.parse(target)
        return error('Invalid Teams URL format') || nil unless result

        team_id = result.team_id
        debug("Parsed URL: conversation=#{result.conversation_id}, team=#{team_id}")
        @options[:team_id] = team_id if team_id
        result.conversation_id
      end

      def fetch_messages(target)
        @options[:team_id] ? fetch_channel_messages(target) : fetch_chat_messages(target)
      end

      def fetch_channel_messages(channel_id)
        response = with_token_refresh do
          runner.messages_api.channel_messages(
            team_id: @options[:team_id], channel_id: channel_id, limit: @options[:limit]
          )
        end
        display_messages(extract_messages_data(response))
      rescue ApiError => api_error
        error("Failed to fetch channel messages: #{api_error.message}")
      end

      def fetch_chat_messages(chat_id)
        response = with_token_refresh do
          runner.messages_api.chat_messages(chat_id: chat_id, limit: @options[:limit])
        end
        display_messages(extract_messages_data(response))
      rescue ApiError => api_error
        error("Failed to fetch chat messages: #{api_error.message}")
      end

      def extract_messages_data(response) = response['messages'] || response['posts'] || response['value'] || []

      def display_messages(messages_data)
        return (puts('No messages found') || true) && 0 if messages_data.empty?

        messages = messages_data.map { |msg_data| Models::Message.from_api(msg_data) }.reject(&:system_message?).reverse
        render_messages(messages)
        0
      end

      def render_messages(messages)
        if @options[:json]
          output_json(messages.map { |msg| message_to_hash(msg) })
        else
          messages.each { |msg| display_message(msg) }
        end
      end

      def display_message(message)
        time_str = message.created_at&.strftime('%Y-%m-%d %H:%M') || ''
        importance = message.important? ? output.red('!') : ''
        puts "#{output.blue("[#{time_str}]")} #{importance}#{output.bold(message.sender_name)}:"
        puts "  #{message.content}"
        display_reactions(message)
        puts
      end

      def display_reactions(message)
        return unless message.reactions.any?

        strs = message.reactions.map { |reaction| "#{reaction[:type]}(#{reaction[:count]})" }.join(' ')
        puts "  #{output.gray(strs)}"
      end

      def message_to_hash(message)
        {
          id: message.id, sender_id: message.sender_id,
          sender_name: message.sender_name, content: message.content,
          created_at: message.created_at&.iso8601,
          importance: message.importance, reactions: message.reactions
        }
      end
    end
  end
end
