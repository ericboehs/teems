# frozen_string_literal: true

module Teems
  module Commands
    SYNC_HELP = <<~HELP
      teems sync - Sync chat history locally

      USAGE:
        teems sync [options]

      OPTIONS:
        --since DAYS     Number of days of history to sync (default: 180)
        --chat CHAT_ID   Sync only this chat
        --auth           Authenticate via Safari before syncing
        --dry-run        Show what would be synced without writing files
        -v, --verbose    Show debug output
        -q, --quiet      Suppress output

      EXAMPLES:
        teems sync                         # Sync 6 months of all chats
        teems sync --since 30              # Sync last 30 days
        teems sync --chat 19:abc@thread.v2 # Sync a single chat
        teems sync --dry-run               # Preview what would be synced

      OUTPUT:
        Files are stored in ~/.local/share/teems/sync/chats/
        Each chat gets: messages.md, messages.json, chat_metadata.json
    HELP

    # Handles syncing individual chats: fetch, merge, retry on 404
    module SyncChatHandler
      RETRY_DELAY_SECONDS = 2

      private

      def sync_or_skip_chat(chat_data, index, total)
        chat = Models::Chat.from_api(chat_data)
        return skip_chat(chat, index, total) if skip_reason(chat.id)

        info("[#{index + 1}/#{total}] Syncing: #{chat.display_name}")
        with_404_retry(chat) { sync_single_chat(chat) }
      rescue StandardError => e
        handle_sync_error(chat, e)
      end

      def skip_chat(chat, index, total)
        debug("[#{index + 1}/#{total}] Skipping #{skip_reason(chat.id)}: #{chat.display_name} (#{chat.id})")
        @stats[:skipped] += 1
      end

      def handle_sync_error(chat, err)
        output.flush
        warn("  Unexpected error syncing '#{chat.display_name}': #{err.message}")
        debug("  #{err.backtrace&.first}")
        @stats[:errors] += 1
      end

      def sync_single_chat(chat)
        chat_id = chat.id
        @sync_store.ensure_dir_name(@state, chat_id, chat.display_name, chat_type: chat.chat_type)
        new_messages = fetch_new_messages(chat)
        debug("  Fetched #{new_messages.length} new message(s)")
        return skip_unchanged(chat_id) if new_messages.empty? && @sync_store.last_synced_time(@state, chat_id)

        merge_and_update(chat, new_messages)
      end

      def fetch_new_messages(chat)
        start_time = @sync_store.last_synced_time(@state, chat.id) || since_time
        with_token_refresh { sync_engine.fetch_all_messages(chat.id, start_time) }
      end

      def merge_and_update(chat, new_messages)
        existing_raw = @sync_store.read_messages_json(chat.id, state: @state)
        all_messages = sync_engine.merge_and_write(chat, existing_raw, new_messages)
        update_chat_state(chat, all_messages)
      end

      def skip_unchanged(chat_id)
        debug("  No new messages, skipping write (#{chat_id})")
        @stats[:skipped] += 1
      end

      def update_chat_state(chat, all_messages)
        count = all_messages.length
        debug("  Total: #{count} message(s) after merge")
        @sync_store.update_chat_state(
          @state, chat.id,
          attrs: { last_synced_at: Time.now, message_count: count,
                   display_name: chat.display_name, chat_type: chat.chat_type }
        )
        @stats[:synced] += 1
        @stats[:messages_total] += count
      end

      def with_404_retry(chat, &)
        yield
      rescue ApiError => e
        output.flush
        return handle_non_404_error(chat, e) unless e.not_found?

        retry_after_not_found(chat, &)
      end

      def handle_non_404_error(chat, error)
        warn("  Failed to sync '#{chat.display_name}': #{error.message}")
        @stats[:errors] += 1
      end

      def retry_after_not_found(chat)
        debug("  Got 404, retrying in #{RETRY_DELAY_SECONDS}s...")
        sleep(RETRY_DELAY_SECONDS)
        yield
      rescue ApiError => e
        handle_persistent_not_found(chat, e)
      end

      def handle_persistent_not_found(chat, error)
        display_name = chat.display_name
        if error.not_found?
          @sync_store.mark_unavailable(@state, chat.id, display_name: display_name, chat_type: chat.chat_type)
          warn("  Chat unavailable (404): '#{display_name}' — will skip on future syncs")
        else
          warn("  Failed to sync '#{display_name}': #{error.message}")
        end
        @stats[:errors] += 1
      end
    end

    # Chat list fetching, dry-run display, and summary reporting
    module SyncDisplay
      private

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
        return info('No chats found') || [] if chats.empty?

        debug("Found #{chats.length} chats")
        chats
      end

      def show_dry_run(chats)
        syncable = chats.reject { |chat| skip_reason(chat['id']) }
        display_dry_run_header(chats.length - syncable.length, syncable.length)
        syncable.each { |chat| format_dry_run_chat(chat) }
        0
      end

      def display_dry_run_header(skipped, syncable_count)
        info("Dry run — would sync #{syncable_count} chat(s) since #{since_time.strftime('%Y-%m-%d')}")
        info("  (#{skipped} system streams skipped)") if skipped.positive?
        puts
      end

      def format_dry_run_chat(chat_data)
        chat = Models::Chat.from_api(chat_data)
        last_sync = @sync_store.last_synced_time(@state, chat.id)
        status = last_sync ? "last synced #{last_sync.strftime('%Y-%m-%d %H:%M')}" : 'never synced'
        puts "  #{chat.display_name}\n    ID: #{chat.id}\n    Status: #{status}\n"
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

    # Sync chat history locally as Markdown + JSON files
    class Sync < Base
      include SyncChatHandler
      include SyncDisplay

      DEFAULT_SINCE_DAYS = 180
      SKIP_PREFIXES = %w[48:].freeze

      def initialize(args, runner:)
        @options = {}
        @sync_store = nil
        @state = nil
        @stats = nil
        super
      end

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

      SYNC_OPTIONS = {
        '--since' => ->(opts, args) { opts[:since_days] = args.shift.to_i },
        '--chat' => ->(opts, args) { opts[:chat_id] = args.shift },
        '--dry-run' => ->(opts, _args) { opts[:dry_run] = true },
        '--auth' => ->(opts, _args) { opts[:auth] = true }
      }.freeze

      def handle_option(arg, pending)
        handler = SYNC_OPTIONS[arg]
        return super unless handler

        handler.call(@options, pending)
      end

      def help_text = SYNC_HELP

      private

      def login_if_requested
        return unless @options[:auth]

        tokens = runner.token_extractor.extract
        return save_login_tokens(tokens) if tokens&.dig(:auth_token)

        error('Failed to authenticate via Safari')
        1
      end

      def save_login_tokens(tokens)
        saved = token_store.save(name: 'default', **tokens.slice(:auth_token, :skype_token,
                                                                 :skype_spaces_token, :chatsvc_token))
        return error('Authentication tokens extracted but failed to save') || 1 unless saved

        success('Authentication successful!')
        nil
      end

      def run_sync
        init_sync_state
        chats = fetch_chat_list
        return 1 unless chats
        return show_dry_run(chats) if @options[:dry_run]

        sync_all_chats(chats)
      end

      def sync_all_chats(chats)
        chats.each_with_index { |chat_data, index| sync_or_skip_chat(chat_data, index, chats.length) }
        save_state_safely
        show_summary
        @stats[:errors].positive? ? 1 : 0
      end

      def init_sync_state
        @sync_store = Services::SyncStore.new
        @state = @sync_store.load_state
        @stats = { synced: 0, skipped: 0, errors: 0, messages_total: 0 }
        setup_api_logging
      end

      def skip_reason(chat_id)
        return 'system stream' if SKIP_PREFIXES.any? { |prefix| chat_id.start_with?(prefix) }
        return 'unavailable chat' if @sync_store.chat_unavailable?(@state, chat_id)

        nil
      end

      def sync_engine
        @sync_engine ||= Services::SyncEngine.new(
          runner: runner, sync_store: @sync_store, state: @state, output: output
        )
      end

      def save_state_safely
        @sync_store.save_state(@state)
      rescue StandardError => e
        @stats[:errors] += 1
        error("Warning: Failed to save sync state: #{e.message}")
      end

      def since_time = Time.now - ((@options[:since_days] || DEFAULT_SINCE_DAYS) * 86_400)

      def setup_api_logging
        out = output
        runner.api_client.on_response = lambda { |path, code|
          out.debug("  API ← #{code} #{path[0..80]}") if out.verbose?
        }
      end
    end
  end
end
