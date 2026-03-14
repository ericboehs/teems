# frozen_string_literal: true

module Teems
  module Services
    # Core sync logic: fetch, merge, and write chat messages.
    # Extracted from Commands::Sync to keep the command thin.
    class SyncEngine
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
        messages = []
        backward_link = nil
        page_count = 0

        loop do
          page_messages, backward_link = fetch_messages_page(chat_id, start_time, backward_link, page_count)
          break if page_messages.empty?

          page_count += 1
          debug("  Page #{page_count}: #{page_messages.length} message(s)")
          break if reached_max_pages?(page_count)

          parsed, cutoff_reached = parse_page_messages(page_messages, start_time)
          messages.concat(parsed)

          break if cutoff_reached
          break unless backward_link

          backward_link = rewrite_start_time(backward_link, start_time)
          sleep(API_DELAY_SECONDS)
        end

        filter_and_sort_messages(messages, start_time)
      end

      # Load existing messages from disk, merge with new, and write files
      def merge_and_write(chat, existing_raw, new_messages)
        existing = existing_raw.map { |m| message_from_stored(m) }
        all_messages = merge_messages(existing, new_messages)
        write_chat_files(chat, all_messages)
        all_messages
      end

      # Reconstruct a Message from stored JSON hash
      def message_from_stored(data)
        Models::Message.new(
          id: data['id'],
          sender_id: data['sender_id'],
          sender_name: data['sender_name'],
          content: data['content'],
          created_at: data['created_at'] ? Time.parse(data['created_at']) : nil,
          message_type: data['message_type'],
          reply_to_id: data['reply_to_id'],
          reactions: parse_stored_reactions(data['reactions']),
          attachments: data['attachments'] || [],
          importance: data['importance']
        )
      end

      private

      def fetch_messages_page(chat_id, start_time, backward_link, page_count)
        api = @runner.messages_api
        response = api.chat_messages_page(
          chat_id: chat_id,
          start_time: page_count.zero? ? start_time : nil,
          backward_link: backward_link
        )

        page_messages = response['messages'] || response['value'] || []
        new_link = response.dig('_metadata', 'backwardLink')
        [page_messages, new_link]
      end

      def reached_max_pages?(page_count)
        return false unless page_count >= MAX_PAGES

        debug("  Reached max pages (#{MAX_PAGES}), stopping pagination")
        true
      end

      def parse_page_messages(page_messages, start_time)
        parsed = page_messages.map { |m| Models::Message.from_api(m) }
        oldest = parsed.min_by { |m| m.created_at || Time.now }
        cutoff = oldest&.created_at && oldest.created_at < start_time

        debug('  Reached cutoff date, stopping pagination') if cutoff
        [parsed, cutoff]
      end

      def rewrite_start_time(backward_link, start_time)
        start_time_ms = (start_time.to_f * 1000).to_i
        backward_link.gsub(/startTime=\d+/, "startTime=#{start_time_ms}")
      end

      def filter_and_sort_messages(messages, start_time)
        messages.reject(&:system_message?)
                .select { |m| m.created_at.nil? || m.created_at >= start_time }
                .sort_by { |m| m.created_at || Time.at(0) }
      end

      def merge_messages(existing, new_messages)
        by_id = {}
        existing.each { |m| by_id[m.id] = m }
        new_messages.each { |m| by_id[m.id] = m }
        by_id.values.sort_by { |m| m.created_at || Time.at(0) }
      end

      def write_chat_files(chat, messages)
        formatter = Formatters::MarkdownFormatter.new(
          chat_name: chat.display_name,
          chat_type: chat.chat_type,
          synced_at: Time.now
        )

        messages_md = formatter.format(messages)
        messages_json = JSON.pretty_generate(messages.map { |m| message_to_hash(m) })

        @sync_store.write_messages(chat.id, messages_md: messages_md, messages_json: messages_json, state: @state)
        write_metadata(chat)
      end

      def write_metadata(chat)
        @sync_store.write_chat_metadata(chat.id, {
          'id' => chat.id,
          'display_name' => chat.display_name,
          'type' => chat.chat_type,
          'synced_at' => Time.now.iso8601
        }, state: @state)
      end

      def message_to_hash(message)
        {
          'id' => message.id,
          'sender_id' => message.sender_id,
          'sender_name' => message.sender_name,
          'content' => message.content,
          'created_at' => message.created_at&.iso8601,
          'message_type' => message.message_type,
          'reply_to_id' => message.reply_to_id,
          'reactions' => message.reactions.map { |r| { 'type' => r[:type], 'count' => r[:count] } },
          'attachments' => message.attachments,
          'importance' => message.importance
        }
      end

      def parse_stored_reactions(reactions)
        (reactions || []).map { |r| { type: r['type'], count: r['count'] } }
      end

      def debug(message)
        @output&.debug(message) if @verbose
      end
    end
  end
end
