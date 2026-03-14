# frozen_string_literal: true

module Teems
  module Commands
    # Sync chat history locally as Markdown + JSON files
    class Sync < Base
      DEFAULT_SINCE_DAYS = 180
      RETRY_DELAY_SECONDS = 2

      # System stream IDs that don't contain fetchable messages
      SKIP_PREFIXES = %w[48:].freeze

      def execute
        result = validate_options
        return result if result

        login_result = login_if_requested
        return login_result if login_result

        auth_result = require_auth
        return auth_result if auth_result

        run_sync
      end

      protected

      def handle_option(arg, args, _remaining)
        case arg
        when '--since'  then @options[:since_days] = args.shift.to_i
        when '--chat'   then @options[:chat_id] = args.shift
        when '--dry-run' then @options[:dry_run] = true
        when '--auth'   then @options[:auth] = true
        else super
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
            --auth           Authenticate via Safari before syncing
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

      def login_if_requested
        return unless @options[:auth]

        tokens = runner.token_extractor.extract
        return save_login_tokens(tokens) if tokens&.dig(:auth_token)

        error('Failed to authenticate via Safari')
        1
      end

      def save_login_tokens(tokens)
        saved = token_store.save(
          name: 'default',
          auth_token: tokens[:auth_token],
          skype_token: tokens[:skype_token],
          skype_spaces_token: tokens[:skype_spaces_token],
          chatsvc_token: tokens[:chatsvc_token]
        )
        return (error('Authentication tokens extracted but failed to save') || 1) unless saved

        success('Authentication successful!')
        nil
      end

      def run_sync
        @sync_store = Services::SyncStore.new
        @state = @sync_store.load_state
        @stats = { synced: 0, skipped: 0, errors: 0, messages_total: 0 }
        setup_api_logging

        chats = fetch_chat_list
        return 1 unless chats
        return show_dry_run(chats) if @options[:dry_run]

        sync_chats(chats)
        save_state_safely
        show_summary
        @stats[:errors].positive? ? 1 : 0
      end

      def fetch_chat_list
        return build_single_chat if @options[:chat_id]

        fetch_all_chats
      rescue ApiError => e
        error("Failed to fetch chats: #{e.message}")
        nil
      end

      def build_single_chat
        info("Fetching chat info for #{@options[:chat_id]}...")
        [{ 'id' => @options[:chat_id], 'threadProperties' => {} }]
      end

      def fetch_all_chats
        info('Fetching chat list...')
        response = with_token_refresh { runner.chats_api.list(limit: 200) }
        chats = response['conversations'] || response['value'] || []
        return (info('No chats found') || []) if chats.empty?

        debug("Found #{chats.length} chats")
        chats
      end

      def show_dry_run(chats)
        since = since_time
        syncable = chats.reject { |c| skip_reason(c['id']) }
        skipped = chats.length - syncable.length

        info("Dry run — would sync #{syncable.length} chat(s) since #{since.strftime('%Y-%m-%d')}")
        info("  (#{skipped} system streams skipped)") if skipped.positive?
        puts

        syncable.each { |c| format_dry_run_chat(c) }
        0
      end

      def format_dry_run_chat(chat_data)
        chat = Models::Chat.from_api(chat_data)
        last_sync = @sync_store.last_synced_time(@state, chat.id)
        status = last_sync ? "last synced #{last_sync.strftime('%Y-%m-%d %H:%M')}" : 'never synced'

        puts "  #{chat.display_name}"
        puts "    ID: #{chat.id}"
        puts "    Status: #{status}"
        puts
      end

      def sync_chats(chats)
        total = chats.length
        chats.each_with_index { |chat_data, index| sync_or_skip_chat(chat_data, index, total) }
      end

      def sync_or_skip_chat(chat_data, index, total)
        chat = Models::Chat.from_api(chat_data)

        if (reason = skip_reason(chat.id))
          debug("[#{index + 1}/#{total}] Skipping #{reason}: #{chat.display_name} (#{chat.id})")
          @stats[:skipped] += 1
          return
        end

        info("[#{index + 1}/#{total}] Syncing: #{chat.display_name}")
        with_404_retry(chat) { sync_single_chat(chat) }
      rescue StandardError => e
        output.flush
        warn("  Unexpected error syncing '#{chat.display_name}': #{e.message}")
        debug("  #{e.backtrace&.first}")
        @stats[:errors] += 1
      end

      # Returns nil if the chat should be synced, or a reason string if it should be skipped
      def skip_reason(chat_id)
        return 'system stream' if SKIP_PREFIXES.any? { |prefix| chat_id.start_with?(prefix) }
        return 'unavailable chat' if @sync_store.chat_unavailable?(@state, chat_id)

        nil
      end

      def with_404_retry(chat)
        yield
      rescue ApiError => e
        output.flush
        return handle_non_404_error(chat, e) unless e.not_found?

        retry_after_404(chat) { yield }
      end

      def handle_non_404_error(chat, error)
        warn("  Failed to sync '#{chat.display_name}': #{error.message}")
        @stats[:errors] += 1
      end

      def retry_after_404(chat)
        debug("  Got 404, retrying in #{RETRY_DELAY_SECONDS}s...")
        sleep(RETRY_DELAY_SECONDS)
        yield
      rescue ApiError => e
        handle_persistent_404(chat, e)
      end

      def handle_persistent_404(chat, error)
        if error.not_found?
          @sync_store.mark_unavailable(@state, chat.id, display_name: chat.display_name, chat_type: chat.chat_type)
          warn("  Chat unavailable (404): '#{chat.display_name}' — will skip on future syncs")
        else
          warn("  Failed to sync '#{chat.display_name}': #{error.message}")
        end
        @stats[:errors] += 1
      end

      def sync_single_chat(chat)
        @sync_store.ensure_dir_name(@state, chat.id, chat.display_name, chat_type: chat.chat_type)
        start_time = prepare_sync_time(chat.id)

        new_messages = sync_engine.fetch_all_messages(chat.id, start_time)
        debug("  Fetched #{new_messages.length} new message(s)")

        return skip_unchanged(chat.id) if new_messages.empty? && @sync_store.last_synced_time(@state, chat.id)

        existing_raw = @sync_store.read_messages_json(chat.id, state: @state)
        all_messages = sync_engine.merge_and_write(chat, existing_raw, new_messages)
        update_chat_state(chat, all_messages)
      end

      def prepare_sync_time(chat_id)
        @sync_store.last_synced_time(@state, chat_id) || since_time
      end

      def skip_unchanged(chat_id)
        debug("  No new messages, skipping write (#{chat_id})")
        @stats[:skipped] += 1
      end

      def update_chat_state(chat, all_messages)
        debug("  Total: #{all_messages.length} message(s) after merge")
        @sync_store.update_chat_state(
          @state, chat.id,
          last_synced_at: Time.now,
          message_count: all_messages.length,
          display_name: chat.display_name,
          chat_type: chat.chat_type
        )
        @stats[:synced] += 1
        @stats[:messages_total] += all_messages.length
      end

      def sync_engine
        @sync_engine ||= Services::SyncEngine.new(
          runner: runner, sync_store: @sync_store, state: @state,
          output: output, verbose: @options[:verbose]
        )
      end

      def save_state_safely
        @sync_store.save_state(@state)
      rescue StandardError => e
        @stats[:errors] += 1
        error("Warning: Failed to save sync state: #{e.message}")
      end

      def since_time
        since_days = @options[:since_days] || DEFAULT_SINCE_DAYS
        Time.now - (since_days * 86_400)
      end

      def setup_api_logging
        out = output
        runner.api_client.on_response = lambda { |path, code|
          out.debug("  API ← #{code} #{path[0..80]}") if out.verbose
        }
      end

      def show_summary
        puts
        success('Sync complete!')
        info("  Chats synced: #{@stats[:synced]}")
        info("  Chats skipped (no new messages): #{@stats[:skipped]}") if @stats[:skipped].positive?
        info("  Total messages: #{@stats[:messages_total]}")
        display_error_count
        info("  Output: #{@sync_store.sync_dir}")
      end

      def display_error_count
        return unless @stats[:errors].positive?

        output.flush
        warn("  Errors: #{@stats[:errors]}")
      end
    end
  end
end
