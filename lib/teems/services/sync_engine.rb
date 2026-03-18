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
          'attachments' => message.attachments, 'importance' => message.importance,
          'edited' => message.edited, 'mentions' => message.mentions
        }
      end

      def parse_stored_reactions(reactions)
        Array(reactions).map { |reaction| stored_reaction_hash(reaction) }
      end

      def stored_reaction_hash(reaction) = { type: reaction['type'], count: reaction['count'] }

      def stored_msg_attrs(data)
        stored_msg_core(data).merge(stored_msg_extras(data))
      end

      def stored_msg_core(data)
        created_at_raw = data['created_at']
        { id: data['id'], sender_id: data['sender_id'], sender_name: data['sender_name'],
          content: data['content'], created_at: created_at_raw ? Time.parse(created_at_raw) : nil,
          message_type: data['message_type'] }
      end

      def stored_msg_extras(data)
        { reply_to_id: data['reply_to_id'], reactions: parse_stored_reactions(data['reactions']),
          attachments: stored_default(data, 'attachments', []),
          importance: data['importance'],
          edited: stored_default(data, 'edited', false),
          mentions: stored_default(data, 'mentions', []) }
      end

      def stored_default(data, key, fallback) = data[key] || fallback
    end

    # Pagination helpers for fetching chat messages across pages
    module SyncPagination
      API_DELAY_SECONDS = 0.5
      MAX_PAGES = 500

      private

      def paginate_messages(chat_id, start_time)
        @backward_link = nil
        @page_count = 0
        messages = []
        loop do
          page_messages = fetch_next_page(chat_id, start_time)
          break if page_messages.empty? || log_and_check_max(@page_count += 1, page_messages)

          @backward_link = accumulate_page(messages, page_messages, start_time)
          break unless @backward_link
        end
        messages
      end

      def accumulate_page(messages, page_messages, start_time)
        parsed, cutoff = parse_page_messages(page_messages, start_time)
        messages.concat(parsed)
        cutoff ? nil : advance_link(start_time)
      end

      def fetch_next_page(chat_id, start_time)
        response = @runner.messages_api.chat_messages_page(
          chat_id: chat_id, start_time: @page_count.zero? ? start_time : nil, backward_link: @backward_link
        )
        msgs = response['messages'] || response['value'] || []
        @backward_link = response.dig('_metadata', 'backwardLink')
        msgs
      end

      def log_and_check_max(page_count, page_messages)
        debug("  Page #{page_count}: #{page_messages.length} message(s)")
        return false unless page_count >= MAX_PAGES

        debug("  Reached max pages (#{MAX_PAGES}), stopping pagination") || true
      end

      def parse_page_messages(page_messages, start_time)
        parsed = page_messages.map { |msg_data| Models::Message.from_api(msg_data) }
        cutoff = reached_cutoff?(parsed, start_time)
        [parsed, cutoff]
      end

      def reached_cutoff?(parsed, start_time)
        oldest = parsed.min_by { |msg| msg.created_at || Time.now }
        return false unless oldest&.created_at && oldest.created_at < start_time

        debug('  Reached cutoff date, stopping pagination') || true
      end

      def advance_link(start_time)
        return nil unless @backward_link

        sleep(API_DELAY_SECONDS)
        @backward_link.gsub(/startTime=\d+/, "startTime=#{(start_time.to_f * 1000).to_i}")
      end
    end

    # Core sync logic: fetch, merge, and write chat messages.
    # Extracted from Commands::Sync to keep the command thin.
    class SyncEngine
      include SyncSerializer
      include SyncPagination

      def initialize(runner:, sync_store:, state:, output:)
        @runner = runner
        @sync_store = sync_store
        @state = state
        @output = output
      end

      # Fetch all messages from a chat since start_time with pagination
      def fetch_all_messages(chat_id, start_time)
        messages = paginate_messages(chat_id, start_time)
        filter_and_sort_messages(messages, start_time)
      end

      def merge_and_write(chat, existing_raw, new_messages)
        existing = existing_raw.map { |data| message_from_stored(data) }
        all_messages = merge_messages(existing, new_messages)
        write_chat_files(chat, all_messages)
        all_messages
      end

      def message_from_stored(data) = Models::Message.new(**stored_msg_attrs(data))

      private

      def filter_and_sort_messages(messages, start_time)
        messages.reject(&:system_message?)
                .filter_map { |msg| message_with_timestamp(msg, start_time) }
                .sort_by(&:first)
                .map(&:last)
      end

      def message_with_timestamp(msg, start_time)
        created_at = msg.created_at
        timestamp = created_at || Time.at(0)
        [timestamp, msg] if !created_at || timestamp >= start_time
      end

      def merge_messages(existing, new_messages)
        merged = index_by_id(existing).merge(index_by_id(new_messages))
        merged.values.sort_by { |msg| msg.created_at || Time.at(0) }
      end

      def index_by_id(messages) = messages.to_h { |msg| [msg.id, msg] }

      def write_chat_files(chat, messages)
        fmt = Formatters::MarkdownFormatter.new(chat_name: chat.display_name,
                                                chat_type: chat.chat_type, synced_at: Time.now)
        json = JSON.pretty_generate(messages.map { |msg| message_to_hash(msg) })
        @sync_store.write_messages(chat.id, messages_md: fmt.format(messages), messages_json: json, state: @state)
        write_metadata(chat)
      end

      def write_metadata(chat)
        @sync_store.write_chat_metadata(chat.id, chat_metadata_hash(chat), state: @state)
      end

      def chat_metadata_hash(chat)
        { 'id' => chat.id, 'display_name' => chat.display_name,
          'type' => chat.chat_type, 'synced_at' => Time.now.iso8601 }
      end

      def debug(message) = @output&.verbose? && @output.debug(message)
    end
  end
end
