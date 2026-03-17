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
        --download       Download file attachments
        -o, --output-dir Directory for downloads (default: ./teems-downloads)
        -v, --verbose    Show debug output
        -q, --quiet      Suppress output
        --json           Output as JSON

      EXAMPLES:
        teems messages 19:abc123@thread.v2         # Read chat messages
        teems messages 19:abc123@thread.v2 -n 50   # Show 50 messages
        teems messages "https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=..."
    HELP

    # Display formatting for messages command
    module MessagesDisplay
      REACTION_EMOJI = {
        'like' => "\u{1F44D}", 'heart' => "\u{2764}\u{FE0F}",
        'laugh' => "\u{1F602}", 'surprised' => "\u{1F62E}",
        'sad' => "\u{1F622}", 'angry' => "\u{1F620}",
        'yes-tone1' => "\u{1F44D}\u{1F3FB}", 'yes-tone2' => "\u{1F44D}\u{1F3FC}",
        'support' => "\u{1F91D}", 'heartblue' => "\u{1F499}",
        'computer' => "\u{1F4BB}", '1f37f_popcorn' => "\u{1F37F}",
        '1f440_eyes' => "\u{1F440}", 'thumbsdown' => "\u{1F44E}"
      }.freeze

      private

      def display_message(message)
        puts format_message_header(message)
        puts "  #{highlight_mentions(message.content, message.mentions)}"
        display_attachments(message)
        display_reactions(message)
        puts
      end

      def format_message_header(message)
        importance = message.important? ? output.red('!') : ''
        time = output.blue("[#{message.created_at&.strftime('%Y-%m-%d %H:%M')}]")
        hash = output.gray(message.short_hash)
        "#{time} #{hash} #{importance}#{output.bold(message.sender_name)}:#{edited_tag(message)}"
      end

      def edited_tag(message) = message.edited? ? " #{output.gray('(edited)')}" : ''

      def display_attachments(message)
        attachments = message.attachments
        return unless attachments.any?

        names = attachments.map do |att|
          att.is_a?(Hash) ? (att['fileName'] || att['name'] || 'file') : att.to_s
        end
        puts "  #{output.gray("\u{1F4CE} #{names.join(', ')}")}"
      end

      def display_reactions(message)
        reactions = message.reactions
        return unless reactions.any?

        summary = reactions.map do |reaction|
          type = reaction[:type]
          "#{REACTION_EMOJI[type] || type}(#{reaction[:count]})"
        end.join(' ')
        puts "  #{output.gray(summary)}"
      end

      def highlight_mentions(content, mentions)
        return content if mentions.empty?

        mentions.inject(content) { |text, name| text.gsub(name, output.bold(name)) }
      end

      def message_to_hash(message)
        { id: message.id, short_hash: message.short_hash,
          sender_id: message.sender_id,
          sender_name: message.sender_name, content: message.content,
          created_at: message.created_at&.iso8601,
          importance: message.importance, reactions: message.reactions,
          attachments: message.attachments, edited: message.edited,
          mentions: message.mentions }
      end
    end

    # Download logic for file attachments in messages
    module AttachmentDownload
      private

      def download_attachments(messages)
        attachments = find_downloadable(messages)
        return puts('No downloadable attachments found') if attachments.empty?

        execute_downloads(attachments)
      end

      def execute_downloads(attachments)
        dir = prepare_output_dir
        count = attachments.sum { |att| download_one(att, dir) }
        puts "Downloaded #{count} file#{'s' if count != 1} to #{dir}" if count.positive?
      end

      def find_downloadable(messages)
        messages.flat_map { |msg| downloadable_from(msg) }
      end

      def downloadable_from(msg)
        Array(msg.attachments).select { |att| att.is_a?(Hash) && att['sharepointIds'] }
      end

      def download_one(att, dir)
        name = att['fileName'] || att['name'] || 'file'
        print "\u{1F4CE} Downloading #{name}..."
        perform_download(att, dir, name)
      rescue StandardError => e
        warn " failed (#{e.message})"
        0
      end

      def perform_download(att, dir, name)
        url = resolve_download_url(att['sharepointIds'])
        bytes = file_downloader.download(url, unique_path(dir, name))
        puts " done (#{format_bytes(bytes)})"
        1
      end

      def resolve_download_url(sp_ids)
        result = with_token_refresh do
          runner.files_api.drive_item(
            site_id: sp_ids['siteId'], list_id: sp_ids['listId'],
            item_id: sp_ids['listItemUniqueId']
          )
        end
        result['@microsoft.graph.downloadUrl'] or raise Error, 'No download URL in response'
      end

      def file_downloader
        @file_downloader ||= Services::FileDownloader.new
      end

      def prepare_output_dir
        dir = @options[:output_dir] || './teems-downloads'
        FileUtils.mkdir_p(dir)
        dir
      end

      def unique_path(dir, name)
        path = File.join(dir, name)
        return path unless File.exist?(path)

        File.join(dir, "#{Time.now.strftime('%Y%m%d-%H%M')}-#{name}")
      end

      def format_bytes(bytes)
        if bytes >= 1_048_576 then "#{(bytes / 1_048_576.0).round(1)} MB"
        elsif bytes >= 1024 then "#{(bytes / 1024.0).round(1)} KB"
        else "#{bytes} B"
        end
      end
    end

    # Read messages from a channel or chat
    class Messages < Base
      include MessagesDisplay
      include AttachmentDownload

      def initialize(args, runner:)
        @options = {}
        super
      end

      def execute
        result = validate_options || require_auth
        return result if result

        target = resolve_target
        target ? fetch_messages(target) : 1
      end

      protected

      MESSAGES_OPTIONS = {
        '-t' => ->(opts, args) { opts[:team_id] = args.shift },
        '--team' => ->(opts, args) { opts[:team_id] = args.shift },
        '--download' => ->(opts, _args) { opts[:download] = true },
        '-o' => ->(opts, args) { opts[:output_dir] = args.shift },
        '--output-dir' => ->(opts, args) { opts[:output_dir] = args.shift }
      }.freeze

      def handle_option(arg, pending)
        handler = MESSAGES_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
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
        result ? apply_parsed_url(result) : (error('Invalid Teams URL format') || nil)
      end

      def apply_parsed_url(result)
        conversation_id = result.conversation_id
        team_id = result.team_id
        debug("Parsed URL: conversation=#{conversation_id}, team=#{team_id}")
        @options[:team_id] = team_id if team_id
        conversation_id
      end

      def fetch_messages(target)
        @options[:team_id] ? fetch_channel_messages(target) : fetch_chat_messages(target)
      end

      def fetch_channel_messages(channel_id)
        response = with_token_refresh do
          runner.messages_api.channel_messages(
            channel_id: channel_id, limit: @options[:limit]
          )
        end
        display_messages(extract_messages_data(response))
      rescue ApiError => e
        error("Failed to fetch channel messages: #{e.message}")
      end

      def fetch_chat_messages(chat_id)
        response = with_token_refresh do
          runner.messages_api.chat_messages(chat_id: chat_id, limit: @options[:limit])
        end
        display_messages(extract_messages_data(response))
      rescue ApiError => e
        error("Failed to fetch chat messages: #{e.message}")
      end

      def extract_messages_data(response) = response['messages'] || response['posts'] || response['value'] || []

      def display_messages(messages_data)
        return (puts('No messages found') || true) && 0 if messages_data.empty?

        messages = messages_data.map { |msg_data| Models::Message.from_api(msg_data) }.reject(&:system_message?).reverse
        render_messages(messages)
        0
      end

      def render_messages(messages)
        return output_json(messages.map { |msg| message_to_hash(msg) }) if @options[:json]

        messages.each { |msg| display_message(msg) }
        download_attachments(messages) if @options[:download]
      end
    end
  end
end
