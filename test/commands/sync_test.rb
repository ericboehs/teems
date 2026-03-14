# frozen_string_literal: true

require 'test_helper'

class SyncCommandTest < Minitest::Test
  def test_requires_auth
    with_temp_config do
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store)
        cmd = Teems::Commands::Sync.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Not authenticated/, result[:stderr])
    end
  end

  def test_shows_help
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        cmd = Teems::Commands::Sync.new(['--help'], runner: runner)
        cmd.execute
      end

      assert_match(/teems sync/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
      assert_match(/--since/, result[:stdout])
      assert_match(/--chat/, result[:stdout])
      assert_match(/--dry-run/, result[:stdout])
    end
  end

  def test_parses_since_option
    with_temp_config do
      runner = configured_runner
      cmd = Teems::Commands::Sync.new(['--since', '30'], runner: runner)

      assert_equal 30, cmd.options[:since_days]
    end
  end

  def test_parses_chat_option
    with_temp_config do
      runner = configured_runner
      cmd = Teems::Commands::Sync.new(['--chat', '19:abc@thread.v2'], runner: runner)

      assert_equal '19:abc@thread.v2', cmd.options[:chat_id]
    end
  end

  def test_parses_dry_run_option
    with_temp_config do
      runner = configured_runner
      cmd = Teems::Commands::Sync.new(['--dry-run'], runner: runner)

      assert cmd.options[:dry_run]
    end
  end

  def test_dry_run_shows_chats_without_writing
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })

        cmd = Teems::Commands::Sync.new(['--dry-run'], runner: runner)
        cmd.execute
      end

      assert_match(/Dry run/, result[:stdout])
      assert_match(/19:chat123@thread.v2/, result[:stdout])
    end
  end

  def test_sync_single_chat
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new(['--chat', '19:test@thread.v2'], runner: runner)
        cmd.execute
      end

      assert_match(/Sync complete/, result[:stdout])
      assert_match(/Chats synced: 1/, result[:stdout])

      # Verify files were created (use state to resolve human-readable dir)
      store = Teems::Services::SyncStore.new
      state = store.load_state
      dir = store.chat_dir('19:test@thread.v2', state: state)
      assert File.exist?(File.join(dir, 'messages.md')), 'messages.md should exist'
      assert File.exist?(File.join(dir, 'messages.json')), 'messages.json should exist'
      assert File.exist?(File.join(dir, 'chat_metadata.json')), 'chat_metadata.json should exist'
    end
  end

  def test_sync_creates_valid_json
    with_temp_config do
      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new(['--chat', '19:test@thread.v2'], runner: runner)
        cmd.execute
      end

      store = Teems::Services::SyncStore.new
      state = store.load_state
      dir = store.chat_dir('19:test@thread.v2', state: state)
      messages = JSON.parse(File.read(File.join(dir, 'messages.json')))

      assert_instance_of Array, messages
      assert messages.any?
      assert_equal 'Jane Smith', messages.first['sender_name']
    end
  end

  def test_sync_creates_valid_markdown
    with_temp_config do
      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new(['--chat', '19:test@thread.v2'], runner: runner)
        cmd.execute
      end

      store = Teems::Services::SyncStore.new
      state = store.load_state
      dir = store.chat_dir('19:test@thread.v2', state: state)
      md = File.read(File.join(dir, 'messages.md'))

      assert_includes md, 'Jane Smith'
      assert_includes md, 'Hello from ng.msg'
    end
  end

  def test_sync_updates_state
    with_temp_config do
      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new(['--chat', '19:test@thread.v2'], runner: runner)
        cmd.execute
      end

      store = Teems::Services::SyncStore.new
      state = store.load_state
      chat_state = state.dig('chats', '19:test@thread.v2')

      assert chat_state, 'State should have entry for synced chat'
      assert chat_state['last_synced_at']
      assert_equal 1, chat_state['message_count']
    end
  end

  def test_sync_empty_chat_list
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'conversations' => [] })

        cmd = Teems::Commands::Sync.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      assert_match(/No chats found/, result[:stdout])
    end
  end

  def test_sync_handles_api_error_per_chat
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        # First call for chat list succeeds, message calls will get default empty response
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })
        # Messages call returns empty (default behavior of MockApiClient)

        cmd = Teems::Commands::Sync.new([], runner: runner)
        cmd.execute
      end

      # Should still complete (not crash) even with potentially difficult responses
      assert_match(/Sync complete/, result[:stdout])
    end
  end

  def test_incremental_sync_merges_messages
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'

      # Pre-populate with an existing message (uses legacy sanitized-ID dir)
      existing = [{
        'id' => 'old-msg-1',
        'sender_id' => 'user-1',
        'sender_name' => 'Alice',
        'content' => 'Old message',
        'created_at' => '2026-01-19T10:00:00+00:00',
        'message_type' => 'RichText/Html',
        'reactions' => [],
        'attachments' => []
      }]
      store.write_messages(chat_id,
                           messages_md: '# old',
                           messages_json: JSON.generate(existing))

      # Now sync with a new message
      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new(['--chat', chat_id], runner: runner)
        cmd.execute
      end

      # Verify both messages are present (use state to find the renamed dir)
      state = store.load_state
      messages = store.read_messages_json(chat_id, state: state)
      ids = messages.map { |m| m['id'] }

      assert_includes ids, 'old-msg-1'
      assert_includes ids, '1768935087318' # from sample_ng_msg_message
    end
  end

  def test_sync_marks_404_chats_as_unavailable
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })
        runner.api_client.stub_error('messages', Teems::ApiError.new('HTTP 404: Not Found', status_code: 404))

        cmd = Teems::Commands::Sync.new([], runner: runner)
        # Stub sleep to avoid 2s retry delay in tests
        cmd.define_singleton_method(:sleep) { |_| nil }
        cmd.execute
      end

      assert_match(/Chat unavailable \(404\)/, result[:stderr])
      assert_match(/will skip on future syncs/, result[:stderr])

      # Verify the chat was marked as unavailable in state
      store = Teems::Services::SyncStore.new
      state = store.load_state
      assert store.chat_unavailable?(state, '19:chat123@thread.v2')
    end
  end

  def test_sync_skips_previously_unavailable_chats
    with_temp_config do
      store = Teems::Services::SyncStore.new
      state = {}
      store.mark_unavailable(state, '19:chat123@thread.v2', display_name: 'Dead Chat')
      store.save_state(state)

      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })
        # Stub messages to raise 404 — but it should never be called
        runner.api_client.stub_error('messages', Teems::ApiError.new('HTTP 404: Not Found', status_code: 404))

        cmd = Teems::Commands::Sync.new([], runner: runner)
        exit_code = cmd.execute

        assert_equal 0, exit_code
      end

      # Should complete without any warnings about 404 since it was skipped
      assert_match(/Sync complete/, result[:stdout])
      refute_match(/Chat unavailable/, result[:stderr])
    end
  end

  def test_sync_retries_transient_404
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })
        # First messages call raises 404, second succeeds
        runner.api_client.stub_transient_error('messages', Teems::ApiError.new('HTTP 404: Not Found', status_code: 404), times: 1)
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new([], runner: runner)
        cmd.define_singleton_method(:sleep) { |_| nil }
        cmd.execute
      end

      # Should succeed after retry — no unavailable warning
      assert_match(/Sync complete/, result[:stdout])
      assert_match(/Chats synced: 1/, result[:stdout])
      refute_match(/Chat unavailable/, result[:stderr])

      # Should NOT be marked as unavailable
      store = Teems::Services::SyncStore.new
      state = store.load_state
      refute store.chat_unavailable?(state, '19:chat123@thread.v2')
    end
  end

  def test_sync_non_404_api_error_reports_failure
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })
        runner.api_client.stub_error('messages', Teems::ApiError.new('HTTP 500: Internal Server Error', status_code: 500))

        cmd = Teems::Commands::Sync.new([], runner: runner)
        cmd.execute
      end

      assert_match(/Failed to sync/, result[:stderr])
      assert_match(/500/, result[:stderr])
      # Should still complete
      assert_match(/Sync complete/, result[:stdout])
    end
  end

  def test_sync_returns_nonzero_exit_code_on_errors
    with_temp_config do
      exit_code = nil
      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })
        runner.api_client.stub_error('messages', Teems::ApiError.new('HTTP 500: Internal Server Error', status_code: 500))

        cmd = Teems::Commands::Sync.new([], runner: runner)
        exit_code = cmd.execute
      end

      assert_equal 1, exit_code
    end
  end

  def test_fetch_chat_list_failure_returns_exit_code_1
    with_temp_config do
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error('conversations', Teems::ApiError.new('Network error: connection refused'))

        cmd = Teems::Commands::Sync.new([], runner: runner)
        exit_code = cmd.execute
      end

      assert_equal 1, exit_code
      assert_match(/Failed to fetch chats/, result[:stderr])
    end
  end

  def test_sync_skips_system_streams
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [
            sample_ngmsg_chat,
            { 'id' => '48:notifications', 'threadProperties' => { 'threadType' => 'chat' } }
          ]
        })
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new(['-v'], runner: runner)
        cmd.execute
      end

      assert_match(/Sync complete/, result[:stdout])
      assert_match(/Chats synced: 1/, result[:stdout])
    end
  end

  def test_merge_deduplicates_by_message_id
    with_temp_config do
      store = Teems::Services::SyncStore.new
      chat_id = '19:test@thread.v2'

      # Pre-populate with a message that has the same ID as the one from the API
      existing = [{
        'id' => '1768935087318', # Same ID as sample_ng_msg_message
        'sender_id' => 'user-1',
        'sender_name' => 'Old Name',
        'content' => 'Old content',
        'created_at' => '2026-01-20T12:00:00+00:00',
        'message_type' => 'RichText/Html',
        'reactions' => [],
        'attachments' => []
      }]
      store.write_messages(chat_id,
                           messages_md: '# old',
                           messages_json: JSON.generate(existing))

      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', {
          'messages' => [sample_ng_msg_message],
          '_metadata' => {}
        })

        cmd = Teems::Commands::Sync.new(['--chat', chat_id], runner: runner)
        cmd.execute
      end

      state = store.load_state
      messages = store.read_messages_json(chat_id, state: state)

      # Should have exactly 1 message (deduplicated), with new content overwriting old
      assert_equal 1, messages.length
      assert_equal '1768935087318', messages.first['id']
      assert_equal 'Jane Smith', messages.first['sender_name']
    end
  end

  def test_auth_flag_returns_error_when_extraction_fails
    with_temp_config do
      exit_code = nil
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        # Mock the token extractor to return nil (failed extraction)
        extractor = Object.new
        extractor.define_singleton_method(:extract) { nil }
        runner.instance_variable_set(:@token_extractor, extractor)

        cmd = Teems::Commands::Sync.new(['--auth'], runner: runner)
        exit_code = cmd.execute
      end

      assert_equal 1, exit_code
      assert_match(/Failed to authenticate via Safari/, result[:stderr])
    end
  end

  def test_auth_flag_returns_error_when_save_fails
    with_temp_config do
      exit_code = nil
      result = capture_output do |output|
        store = mock_token_store(configured: false)
        store.save_result = false
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        # Mock the token extractor to return valid tokens
        extractor = Object.new
        extractor.define_singleton_method(:extract) do
          { auth_token: 'test-auth', skype_token: 'test-skype' }
        end
        runner.instance_variable_set(:@token_extractor, extractor)

        cmd = Teems::Commands::Sync.new(['--auth'], runner: runner)
        exit_code = cmd.execute
      end

      assert_equal 1, exit_code
      assert_match(/failed to save/, result[:stderr])
    end
  end

  def test_auth_flag_succeeds_when_tokens_saved
    with_temp_config do
      exit_code = nil
      result = capture_output do |output|
        store = mock_token_store(configured: true, account: mock_account)
        store.save_result = true
        runner = Teems::Runner.new(output: output, token_store: store, api_client: Teems::TestHelpers::MockApiClient.new)
        # Mock the token extractor to return valid tokens
        extractor = Object.new
        extractor.define_singleton_method(:extract) do
          { auth_token: 'test-auth', skype_token: 'test-skype' }
        end
        runner.instance_variable_set(:@token_extractor, extractor)

        # Stub the messages API call for sync
        runner.api_client.stub('conversations', { 'conversations' => [] })

        cmd = Teems::Commands::Sync.new(['--auth'], runner: runner)
        exit_code = cmd.execute
      end

      assert_equal 0, exit_code
      assert_match(/Authentication successful/, result[:stdout])
    end
  end

  def test_api_error_status_code_used_for_404_detection
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', {
          'conversations' => [sample_ngmsg_chat]
        })
        # Use an error with "404" in message but non-404 status code
        runner.api_client.stub_error('messages', Teems::ApiError.new('Error 404 in URL path', status_code: 500))

        cmd = Teems::Commands::Sync.new([], runner: runner)
        cmd.execute
      end

      # Should NOT trigger 404 retry logic — should be treated as a regular error
      assert_match(/Failed to sync/, result[:stderr])
      refute_match(/Chat unavailable/, result[:stderr])
    end
  end

  private

  def sample_ngmsg_chat
    {
      'id' => '19:chat123@thread.v2',
      'threadProperties' => {
        'topic' => 'Test Group Chat',
        'threadType' => 'chat',
        'createdat' => '2026-01-15T10:00:00Z'
      },
      'properties' => {
        'lastimreceivedtime' => '2026-01-20T12:00:00Z'
      }
    }
  end
end
