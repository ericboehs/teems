# frozen_string_literal: true

module Teems
  module Commands
    # Sync chat history locally as Markdown + JSON files
    class Sync < Base
      DEFAULT_SINCE_DAYS = 180
      API_DELAY_SECONDS = 0.5
      RETRY_DELAY_SECONDS = 2

      # System stream IDs that don't contain fetchable messages
      SKIP_PREFIXES = %w[48:].freeze

      def execute
        result = validate_options
        return result if result

        auth_result = require_auth
        return auth_result if auth_result

        run_sync
      end

      protected

      def handle_option(arg, args, _remaining)
        case arg
        when '--since'
          @options[:since_days] = args.shift.to_i
          true
        when '--chat'
          @options[:chat_id] = args.shift
          true
        when '--dry-run'
          @options[:dry_run] = true
          true
        else
          super
        end
      end

      def help_text
        <<~HELP
          #{output.bold('teems sync')} - Sync chat history locally

          #{output.bold('USAGE:')}
            teems sync [options]

          #{output.bold('OPTIONS:')}
            --since DAYS     Number of days of history to sync (default: 180)
            --chat CHAT_ID   Sync only this chat
            --dry-run        Show what would be synced without writing files
            -v, --verbose    Show debug output
            -q, --quiet      Suppress output

          #{output.bold('EXAMPLES:')}
            teems sync                         # Sync 6 months of all chats
            teems sync --since 30              # Sync last 30 days
            teems sync --chat 19:abc@thread.v2 # Sync a single chat
            teems sync --dry-run               # Preview what would be synced

          #{output.bold('OUTPUT:')}
            Files are stored in ~/.local/share/teems/sync/chats/
            Each chat gets: messages.md, messages.json, chat_metadata.json
        HELP
      end

      private

      def run_sync
        @sync_store = Services::SyncStore.new
        @state = @sync_store.load_state
        @stats = { synced: 0, skipped: 0, errors: 0, messages_total: 0 }

        @sync_store.migrate_directories!(@state)

        setup_api_logging

        chats = fetch_chat_list
        return 1 unless chats

        if @options[:dry_run]
          show_dry_run(chats)
          return 0
        end

        sync_chats(chats)
        save_state_safely
        show_summary

        @stats[:errors].positive? ? 1 : 0
      end

      def fetch_chat_list
        if @options[:chat_id]
          info("Fetching chat info for #{@options[:chat_id]}...")
          # For single chat sync, we need to get chat details
          # Build a minimal chat data entry
          [{ 'id' => @options[:chat_id], 'threadProperties' => {} }]
        else
          info('Fetching chat list...')
          api = runner.chats_api
          response = with_token_refresh { api.list(limit: 200) }
          chats = response['conversations'] || response['value'] || []

          if chats.empty?
            info('No chats found')
            return []
          end

          debug("Found #{chats.length} chats")
          chats
        end
      rescue ApiError => e
        error("Failed to fetch chats: #{e.message}")
        nil
      end

      def show_dry_run(chats)
        since_days = @options[:since_days] || DEFAULT_SINCE_DAYS
        since_time = Time.now - (since_days * 86_400)
        syncable = chats.reject { |c| skip_chat?(c['id']) }

        info("Dry run — would sync #{syncable.length} chat(s) since #{since_time.strftime('%Y-%m-%d')}")
        skipped = chats.length - syncable.length
        info("  (#{skipped} system streams skipped)") if skipped.positive?
        puts

        syncable.each do |chat_data|
          chat = Models::Chat.from_api(chat_data)
          last_sync = @sync_store.last_synced_time(@state, chat.id)
          status = last_sync ? "last synced #{last_sync.strftime('%Y-%m-%d %H:%M')}" : 'never synced'

          puts "  #{chat.display_name}"
          puts "    ID: #{chat.id}"
          puts "    Status: #{status}"
          puts
        end
      end

      def sync_chats(chats)
        since_days = @options[:since_days] || DEFAULT_SINCE_DAYS
        total = chats.length

        chats.each_with_index do |chat_data, index|
          chat = Models::Chat.from_api(chat_data)

          if skip_chat?(chat.id)
            reason = skip_reason(chat.id)
            debug("[#{index + 1}/#{total}] Skipping #{reason}: #{chat.display_name} (#{chat.id})")
            @stats[:skipped] += 1
            next
          end

          info("[#{index + 1}/#{total}] Syncing: #{chat.display_name}")

          sync_single_chat(chat, since_days)
        rescue ApiError => e
          output.flush
          if e.message.include?('404')
            # Retry once — 404s can be transient (stale connection, token refresh needed)
            debug("  Got 404, retrying in #{RETRY_DELAY_SECONDS}s...")
            sleep(RETRY_DELAY_SECONDS)
            begin
              sync_single_chat(chat, since_days)
            rescue ApiError => retry_error
              if retry_error.message.include?('404')
                mark_chat_unavailable(chat.id, chat.display_name)
                warn("  Chat unavailable (404): '#{chat.display_name}' — will skip on future syncs")
              else
                warn("  Failed to sync '#{chat.display_name}': #{retry_error.message}")
              end
              @stats[:errors] += 1
              next
            end
          else
            warn("  Failed to sync '#{chat.display_name}': #{e.message}")
            @stats[:errors] += 1
          end
        rescue StandardError => e
          output.flush
          warn("  Unexpected error syncing '#{chat.display_name}': #{e.message}")
          debug("  #{e.backtrace&.first}")
          @stats[:errors] += 1
        end
      end

      def skip_chat?(chat_id)
        return true if SKIP_PREFIXES.any? { |prefix| chat_id.start_with?(prefix) }
        return true if @sync_store.chat_unavailable?(@state, chat_id)

        false
      end

      def skip_reason(chat_id)
        return 'system stream' if SKIP_PREFIXES.any? { |prefix| chat_id.start_with?(prefix) }
        return 'unavailable chat' if @sync_store.chat_unavailable?(@state, chat_id)

        'unknown'
      end

      def sync_single_chat(chat, since_days)
        # Ensure human-readable directory name is set
        @sync_store.ensure_dir_name(@state, chat.id, chat.display_name)

        # Determine start time: last sync or N days ago
        last_sync = @sync_store.last_synced_time(@state, chat.id)
        since_time = Time.now - (since_days * 86_400)
        start_time = last_sync || since_time

        # Fetch all messages since start_time with pagination
        new_messages = fetch_all_messages(chat.id, start_time)
        debug("  Fetched #{new_messages.length} new message(s)")

        if new_messages.empty? && last_sync
          debug('  No new messages, skipping write')
          @stats[:skipped] += 1
          return
        end

        # Merge with existing messages on disk
        existing = load_existing_messages(chat.id)
        all_messages = merge_messages(existing, new_messages)
        debug("  Total: #{all_messages.length} message(s) after merge")

        # Write files
        write_chat_files(chat, all_messages)

        # Update state
        @sync_store.update_chat_state(
          @state, chat.id,
          last_synced_at: Time.now,
          message_count: all_messages.length,
          display_name: chat.display_name
        )

        @stats[:synced] += 1
        @stats[:messages_total] += all_messages.length
      end

      def fetch_all_messages(chat_id, start_time)
        messages = []
        api = runner.messages_api
        backward_link = nil
        page_count = 0

        loop do
          response = with_token_refresh do
            api.chat_messages_page(
              chat_id: chat_id,
              start_time: page_count.zero? ? start_time : nil,
              backward_link: backward_link
            )
          end

          page_messages = response['messages'] || response['value'] || []
          break if page_messages.empty?

          page_count += 1
          debug("  Page #{page_count}: #{page_messages.length} message(s)")

          # Check if we've gone past our cutoff
          parsed_messages = page_messages.map { |m| Models::Message.from_api(m) }
          oldest_in_page = parsed_messages.min_by { |m| m.created_at || Time.now }

          messages.concat(parsed_messages)

          # Stop if oldest message in this page is before our start time
          if oldest_in_page&.created_at && oldest_in_page.created_at < start_time
            debug("  Reached cutoff date, stopping pagination")
            break
          end

          # Follow pagination
          backward_link = response.dig('_metadata', 'backwardLink')
          break unless backward_link

          # Replace startTime=0 in backward_link with our actual cutoff
          # so the server pre-filters old messages instead of returning everything
          start_time_ms = (start_time.to_f * 1000).to_i
          backward_link = backward_link.gsub(/startTime=\d+/, "startTime=#{start_time_ms}")

          # Rate limiting
          sleep(API_DELAY_SECONDS)
        end

        # Filter to only messages within our time range and non-system
        messages.reject(&:system_message?)
                .select { |m| m.created_at.nil? || m.created_at >= start_time }
                .sort_by { |m| m.created_at || Time.at(0) }
      end

      def load_existing_messages(chat_id)
        raw = @sync_store.read_messages_json(chat_id, state: @state)
        raw.map { |m| message_from_stored(m) }
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
          reactions: (data['reactions'] || []).map { |r| { type: r['type'], count: r['count'] } },
          attachments: data['attachments'] || [],
          importance: data['importance']
        )
      end

      # Merge old and new messages, deduplicating by ID
      def merge_messages(existing, new_messages)
        by_id = {}
        existing.each { |m| by_id[m.id] = m }
        new_messages.each { |m| by_id[m.id] = m } # new overwrites old

        by_id.values.sort_by { |m| m.created_at || Time.at(0) }
      end

      def write_chat_files(chat, messages)
        now = Time.now
        formatter = Formatters::MarkdownFormatter.new(
          chat_name: chat.display_name,
          chat_type: chat.chat_type,
          synced_at: now
        )

        messages_md = formatter.format(messages)
        messages_json = JSON.pretty_generate(messages.map { |m| message_to_hash(m) })

        @sync_store.write_messages(chat.id, messages_md: messages_md, messages_json: messages_json, state: @state)

        @sync_store.write_chat_metadata(chat.id, {
          'id' => chat.id,
          'display_name' => chat.display_name,
          'type' => chat.chat_type,
          'synced_at' => now.iso8601
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

      def save_state_safely
        @sync_store.save_state(@state)
      rescue StandardError => e
        error("Warning: Failed to save sync state: #{e.message}")
      end

      def mark_chat_unavailable(chat_id, display_name)
        @sync_store.mark_unavailable(@state, chat_id, display_name: display_name)
      end

      def setup_api_logging
        out = output
        runner.api_client.on_response = lambda { |path, code|
          out.debug("  API ← #{code} #{path[0..80]}") if out.verbose
        }
      end

      def show_summary
        puts
        success("Sync complete!")
        info("  Chats synced: #{@stats[:synced]}")
        info("  Chats skipped (no new messages): #{@stats[:skipped]}") if @stats[:skipped].positive?
        info("  Total messages: #{@stats[:messages_total]}")
        if @stats[:errors].positive?
          output.flush
          warn("  Errors: #{@stats[:errors]}")
        end
        info("  Output: #{@sync_store.sync_dir}")
      end
    end
  end
end
