# frozen_string_literal: true

module Teems
  module Services
    # Message serialization helpers for sync storage
    module SyncSerializer
      private

      def message_to_hash(message) = msg_core_hash(message).merge(msg_extras_hash(message))

      def msg_core_hash(message)
        {
          'id' => message.id, 'sender_id' => message.sender_id,
          'sender_name' => message.sender_name, 'content' => message.content,
          'created_at' => message.created_at&.iso8601, 'message_type' => message.message_type
        }
      end

      def msg_extras_hash(message)
        {
          'reply_to_id' => message.reply_to_id,
          'reactions' => message.reactions.map do |reaction|
            { 'type' => reaction[:type], 'count' => reaction[:count] }
          end,
          'attachments' => message.attachments, 'importance' => message.importance
        }
      end

      def parse_stored_reactions(reactions)
        (reactions || []).map { |reaction| { type: reaction['type'], count: reaction['count'] } }
      end

      def stored_msg_attrs(data)
        {
          id: data['id'], sender_id: data['sender_id'], sender_name: data['sender_name'],
          content: data['content'], created_at: data['created_at'] ? Time.parse(data['created_at']) : nil,
          message_type: data['message_type'], reply_to_id: data['reply_to_id'],
          reactions: parse_stored_reactions(data['reactions']),
          attachments: data['attachments'] || [], importance: data['importance']
        }
      end
    end

    # Core sync logic: fetch, merge, and write chat messages.
    # Extracted from Commands::Sync to keep the command thin.
    class SyncEngine
      include SyncSerializer

      API_DELAY_SECONDS = 0.5
      MAX_PAGES = 500

      def initialize(runner:, sync_store:, state:, output:, verbose: false)
        @runner = runner
        @sync_store = sync_store
        @state = state
        @output = output
        @verbose = verbose
      end

      # Fetch all messages from a chat since start_time with pagination
      def fetch_all_messages(chat_id, start_time)
        messages, backward_link, page_count = [], nil, 0 # rubocop:disable Style/ParallelAssignment
        loop do
          page_messages, backward_link = fetch_messages_page(chat_id, start_time, backward_link, page_count)
          break if page_messages.empty? || log_and_check_max(page_count += 1, page_messages)

          backward_link = accumulate_page(messages, page_messages, backward_link, start_time)
          break unless backward_link
        end
        filter_and_sort_messages(messages, start_time)
      end

      def accumulate_page(messages, page_messages, backward_link, start_time)
        parsed, cutoff = parse_page_messages(page_messages, start_time)
        messages.concat(parsed)
        cutoff ? nil : advance_link(backward_link, start_time)
      end

      def merge_and_write(chat, existing_raw, new_messages)
        existing = existing_raw.map { |data| message_from_stored(data) }
        all_messages = merge_messages(existing, new_messages)
        write_chat_files(chat, all_messages)
        all_messages
      end

      def message_from_stored(data) = Models::Message.new(**stored_msg_attrs(data))

      private

      def fetch_messages_page(chat_id, start_time, backward_link, page_count)
        response = @runner.messages_api.chat_messages_page(
          chat_id: chat_id, start_time: page_count.zero? ? start_time : nil, backward_link: backward_link
        )
        [response['messages'] || response['value'] || [], response.dig('_metadata', 'backwardLink')]
      end

      def log_and_check_max(page_count, page_messages)
        debug("  Page #{page_count}: #{page_messages.length} message(s)")
        return false unless page_count >= MAX_PAGES

        debug("  Reached max pages (#{MAX_PAGES}), stopping pagination") || true
      end

      def parse_page_messages(page_messages, start_time)
        parsed = page_messages.map { |msg_data| Models::Message.from_api(msg_data) }
        oldest = parsed.min_by { |msg| msg.created_at || Time.now }
        cutoff = oldest&.created_at && oldest.created_at < start_time
        debug('  Reached cutoff date, stopping pagination') if cutoff
        [parsed, cutoff]
      end

      def rewrite_start_time(link, start_time)
        link.gsub(/startTime=\d+/, "startTime=#{(start_time.to_f * 1000).to_i}")
      end

      def advance_link(backward_link, start_time)
        return nil unless backward_link

        sleep(API_DELAY_SECONDS)
        rewrite_start_time(backward_link, start_time)
      end

      def filter_and_sort_messages(messages, start_time)
        messages.reject(&:system_message?)
                .filter_map { |msg| message_with_timestamp(msg, start_time) }
                .sort_by(&:first)
                .map(&:last)
      end

      def message_with_timestamp(msg, start_time)
        timestamp = msg.created_at || Time.at(0)
        [timestamp, msg] if !msg.created_at || timestamp >= start_time
      end

      def merge_messages(existing, new_messages)
        by_id = existing.to_h { |msg| [msg.id, msg] }
        new_messages.each { |msg| by_id[msg.id] = msg }
        by_id.values.sort_by { |msg| msg.created_at || Time.at(0) }
      end

      def write_chat_files(chat, messages)
        fmt = Formatters::MarkdownFormatter.new(chat_name: chat.display_name,
                                                chat_type: chat.chat_type, synced_at: Time.now)
        json = JSON.pretty_generate(messages.map { |msg| message_to_hash(msg) })
        @sync_store.write_messages(chat.id, messages_md: fmt.format(messages), messages_json: json, state: @state)
        write_metadata(chat)
      end

      def write_metadata(chat)
        @sync_store.write_chat_metadata(chat.id, { 'id' => chat.id, 'display_name' => chat.display_name,
                                                   'type' => chat.chat_type, 'synced_at' => Time.now.iso8601 },
                                        state: @state)
      end

      def debug(message) = @verbose && @output&.debug(message)
    end
  end
end
