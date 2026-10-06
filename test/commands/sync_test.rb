# frozen_string_literal: true

require 'test_helper'

# Tests for the sync command
module SyncCommandTests
  # Shared fixture data for sync test scenarios
  module SharedFixtures
    private

    def msg_response
      { 'messages' => [recent_ng_msg_message], '_metadata' => {} }
    end

    # sample_ng_msg_message is pinned to 2026-01-20, but sync applies a rolling
    # DEFAULT_SINCE_DAYS cutoff, so the shared fixture ages out of the window and these
    # tests silently stop exercising merge/dedup. Keep the API payload inside the window.
    def recent_ng_msg_message
      sample_ng_msg_message.merge(
        'composetime' => (Time.now - 3600).utc.strftime('%Y-%m-%dT%H:%M:%S.000Z')
      )
    end

    def msg_stub
      { 'messages' => msg_response }
    end

    def old_message_fixture
      { 'id' => 'old-msg-1', 'sender_id' => 'user-1', 'sender_name' => 'Alice',
        'content' => 'Old message', 'created_at' => '2026-01-19T10:00:00+00:00',
        'message_type' => 'RichText/Html', 'reactions' => [], 'attachments' => [] }
    end

    def duplicate_message_fixture
      { 'id' => '1768935087318', 'sender_id' => 'user-1', 'sender_name' => 'Old Name',
        'content' => 'Old content', 'created_at' => '2026-01-20T12:00:00+00:00',
        'message_type' => 'RichText/Html', 'reactions' => [], 'attachments' => [] }
    end

    def sample_ngmsg_chat
      { 'id' => '19:chat123@thread.v2',
        'threadProperties' => { 'topic' => 'Test Group Chat', 'threadType' => 'chat',
                                'createdat' => '2026-01-15T10:00:00Z' },
        'properties' => { 'lastimreceivedtime' => '2026-01-20T12:00:00Z' } }
    end
  end

  # Shared helpers for building sync runners and verifying sync results
  module SharedHelpers
    include SharedFixtures

    module_function

    def build_sync_runner
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)
      [configured_runner(output: output), out, err]
    end

    def build_sync_runner_with_chats(chats, error_stubs: {})
      runner, out, err = build_sync_runner
      api = runner.api_client
      api.stub('conversations', { 'conversations' => chats })
      error_stubs.each { |path, error| api.stub_error(path, error) }
      [runner, out, err]
    end

    def sync_result(out, err) = { stdout: out.string, stderr: err.string }

    def execute_with_no_sleep(args, runner:)
      cmd = Teems::Commands::Sync.new(args, runner: runner)
      cmd.define_singleton_method(:sleep) { |_duration| nil }
      cmd.execute
    end

    def run_sync(args = [], stubs: {})
      runner, out, err = build_sync_runner
      stubs.each { |path, response| runner.api_client.stub(path, response) }
      Teems::Commands::Sync.new(args, runner: runner).execute
      sync_result(out, err)
    end

    def run_sync_with_chat_list(chats:, msg_stub: nil, error_stubs: {}, args: [])
      runner, out, err = build_sync_runner_with_chats(chats, error_stubs: error_stubs)
      runner.api_client.stub('messages', msg_stub) if msg_stub
      Teems::Commands::Sync.new(args, runner: runner).execute
      sync_result(out, err)
    end

    def run_sync_returning_exit_code(chats:, error_stubs: {})
      runner, out, err = build_sync_runner_with_chats(chats, error_stubs: error_stubs)
      exit_code = Teems::Commands::Sync.new([], runner: runner).execute
      [exit_code, sync_result(out, err)]
    end

    def capture_exit_code_with_chat_list(chats:, error_stubs: {})
      runner, _out, _err = build_sync_runner_with_chats(chats, error_stubs: error_stubs)
      Teems::Commands::Sync.new([], runner: runner).execute
    end

    def run_sync_with_sleep_stub(chats:, error:)
      runner, out, err = build_sync_runner_with_chats(chats, error_stubs: { 'messages' => error })
      execute_with_no_sleep([], runner: runner)
      sync_result(out, err)
    end

    def run_transient_404_sync(error:)
      runner, out, err = build_sync_runner
      api = runner.api_client
      api.stub('conversations', { 'conversations' => [sample_ngmsg_chat] })
      api.stub_transient_error('messages', error, times: 1)
      api.stub('messages', { 'messages' => [sample_ng_msg_message], '_metadata' => {} })
      execute_with_no_sleep([], runner: runner)
      sync_result(out, err)
    end

    def run_first_sync(chat_id)
      capture_output do |output|
        runner = configured_runner(output: output)
        api = runner.api_client
        api.stub('conversations', { 'conversations' => [sample_ngmsg_chat] })
        api.stub('messages', { 'messages' => [sample_ng_msg_message], '_metadata' => {} })
        Teems::Commands::Sync.new(['--chat', chat_id], runner: runner).execute
      end
    end

    def build_cmd(args) = Teems::Commands::Sync.new(args, runner: configured_runner)

    def mark_chat_unavailable(chat_id, display_name:)
      store = Teems::Services::SyncStore.new
      state = {}
      store.mark_unavailable(state, chat_id, display_name: display_name)
      store.save_state(state)
    end

    def assert_sync_files_exist(chat_id)
      store = Teems::Services::SyncStore.new
      dir = store.chat_dir(chat_id, state: store.load_state)
      assert File.exist?(File.join(dir, 'messages.md')), 'messages.md should exist'
      assert File.exist?(File.join(dir, 'messages.json')), 'messages.json should exist'
      assert File.exist?(File.join(dir, 'chat_metadata.json')), 'chat_metadata.json should exist'
    end

    def preseed_messages(chat_id, messages)
      Teems::Services::SyncStore.new.write_messages(chat_id, messages_md: '# old',
                                                             messages_json: JSON.generate(messages))
    end

    def load_synced_messages(chat_id)
      store = Teems::Services::SyncStore.new
      dir = store.chat_dir(chat_id, state: store.load_state)
      JSON.parse(File.read(File.join(dir, 'messages.json')))
    end

    def load_synced_markdown(chat_id)
      store = Teems::Services::SyncStore.new
      dir = store.chat_dir(chat_id, state: store.load_state)
      File.read(File.join(dir, 'messages.md'))
    end
  end

  # Helpers for testing sync authentication and token refresh flows
  module AuthHelpers
    private

    def run_auth_cmd(args, extract_result:, save_result:, configured:)
      exit_code = nil
      result = capture_output do |output|
        runner = build_auth_runner_with_extractor(output: output, extract_result: extract_result,
                                                  save_result: save_result, configured: configured)
        exit_code = Teems::Commands::Sync.new(args, runner: runner).execute
      end
      [exit_code, result]
    end

    def run_dry_run_with_chats(chats)
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'conversations' => chats })
        exit_code = Teems::Commands::Sync.new(['--dry-run'], runner: runner).execute
      end
      [exit_code, result]
    end

    def run_retry_not_found_then_server_error
      runner, out, err = build_sync_runner
      setup_retry_404_api_client(runner)
      execute_with_no_sleep([], runner: runner)
      sync_result(out, err)
    end

    def build_verbose_runner
      out = StringIO.new
      verbose_output = Teems::Formatters::Output.new(io: out, err: StringIO.new, color: false, mode: :verbose)
      [out, configured_runner(output: verbose_output)]
    end

    def setup_verbose_response_logging(api, output)
      api.on_response = lambda { |path, code|
        output.debug("  API <- #{code} #{path[0..80]}") if output.verbose?
      }
    end

    def build_auth_runner_with_extractor(output:, extract_result:, save_result:, configured:)
      store = mock_token_store(configured: configured)
      store.save_result = save_result
      runner = Teems::Runner.new(output: output, token_store: store,
                                 api_client: Teems::TestHelpers::MockApiClient.new)
      extractor = Object.new
      extractor.define_singleton_method(:extract) { extract_result }
      runner.define_singleton_method(:token_extractor) { extractor }
      runner
    end

    def build_auth_runner(output:, save_result:)
      store = mock_token_store(configured: true, account: mock_account)
      store.save_result = save_result
      runner = Teems::Runner.new(output: output, token_store: store,
                                 api_client: Teems::TestHelpers::MockApiClient.new)
      extractor = Object.new
      extractor.define_singleton_method(:extract) { { auth_token: 'test-auth', skype_token: 'test-skype' } }
      runner.define_singleton_method(:token_extractor) { extractor }
      runner
    end

    def run_auth_with_expired_tokens
      exit_code = nil
      expired = Teems::ApiError.new('Invalid token', status_code: 401)
      result = capture_output do |output|
        runner = build_auth_runner(output: output, save_result: true)
        api = runner.api_client
        api.stub_transient_error('conversations', expired, times: 1)
        api.stub('conversations', { 'conversations' => [] })
        exit_code = Teems::Commands::Sync.new(['--auth'], runner: runner).execute
      end
      [exit_code, result]
    end

    def setup_retry_404_api_client(runner)
      call_count = 0
      runner.api_client.define_singleton_method(:get) do |_endpoint, path, **_opts|
        if path.include?('messages')
          call_count += 1
          raise Teems::ApiError.new('HTTP 404: Not Found', status_code: 404) if call_count == 1

          raise Teems::ApiError.new('HTTP 500: Server Error', status_code: 500)
        end
        { 'conversations' => [{ 'id' => '19:chat123@thread.v2',
                                'threadProperties' => { 'threadType' => 'chat' } }] }
      end
    end
  end

  # Tests for auth, help, option parsing, and basic sync behavior
  class BasicTest < Minitest::Test
    include SharedHelpers

    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          runner = unconfigured_runner(output: output)
          Teems::Commands::Sync.new([], runner: runner).execute
        end

        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_shows_help
      stdout = with_temp_config { run_sync(['--help']) }[:stdout]

      assert_match(/teems sync/, stdout)
      assert_match(/USAGE:/, stdout)
      assert_match(/--since/, stdout)
      assert_match(/--chat/, stdout)
      assert_match(/--dry-run/, stdout)
    end

    def test_parses_since_option
      with_temp_config do
        assert_equal 30, build_cmd(['--since', '30']).options[:since_days]
      end
    end

    def test_parses_chat_option
      with_temp_config do
        assert_equal '19:abc@thread.v2', build_cmd(['--chat', '19:abc@thread.v2']).options[:chat_id]
      end
    end

    def test_parses_dry_run_option
      with_temp_config { assert build_cmd(['--dry-run']).options[:dry_run] }
    end

    def test_auth_flag_parses
      with_temp_config { assert build_cmd(['--auth']).options[:auth] }
    end

    def test_since_time_default_180_days
      with_temp_config { refute build_cmd([]).options[:since_days] }
    end

    def test_since_time_custom
      with_temp_config { assert_equal 30, build_cmd(['--since', '30']).options[:since_days] }
    end

    def test_unknown_option_shows_error
      with_temp_config do
        exit_code = nil
        result = capture_output do |output|
          runner = configured_runner(output: output)
          exit_code = Teems::Commands::Sync.new(['--bogus'], runner: runner).execute
        end

        assert_equal 1, exit_code
        assert_match(/Unknown option/, result[:stderr])
      end
    end

    def test_since_days_with_custom_value
      with_temp_config do
        cmd = nil
        capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('conversations', { 'conversations' => [] })
          cmd = Teems::Commands::Sync.new(['--since', '7'], runner: runner)
          assert_equal 0, cmd.execute
        end

        assert_equal 7, cmd.options[:since_days]
      end
    end
  end

  # Tests for single chat sync, file creation, and state updates
  class SyncOperationsTest < Minitest::Test
    include SharedHelpers

    def test_sync_single_chat
      with_temp_config do
        result = run_sync(['--chat', '19:test@thread.v2'], stubs: msg_stub)
        stdout = result[:stdout]

        assert_match(/Sync complete/, stdout)
        assert_match(/Chats synced: 1/, stdout)
        assert_sync_files_exist('19:test@thread.v2')
      end
    end

    def test_sync_creates_valid_json
      with_temp_config do
        run_sync(['--chat', '19:test@thread.v2'], stubs: msg_stub)
        messages = load_synced_messages('19:test@thread.v2')

        assert_instance_of Array, messages
        assert messages.any?
        assert_equal 'Jane Smith', messages.first['sender_name']
      end
    end

    def test_sync_creates_valid_markdown
      with_temp_config do
        run_sync(['--chat', '19:test@thread.v2'], stubs: msg_stub)
        md = load_synced_markdown('19:test@thread.v2')

        assert_includes md, 'Jane Smith'
        assert_includes md, 'Hello from ng.msg'
      end
    end

    def test_sync_updates_state
      with_temp_config do
        run_sync(['--chat', '19:test@thread.v2'], stubs: msg_stub)
        chat_state = Teems::Services::SyncStore.new.load_state.dig('chats', '19:test@thread.v2')

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
          assert_equal 0, Teems::Commands::Sync.new([], runner: runner).execute
        end

        assert_match(/No chats found/, result[:stdout])
      end
    end

    def test_sync_handles_api_error_per_chat
      result = with_temp_config { run_sync_with_chat_list(chats: [sample_ngmsg_chat]) }

      assert_match(/Sync complete/, result[:stdout])
    end

    def test_sync_skips_system_streams
      chats = [sample_ngmsg_chat,
               { 'id' => '48:notifications', 'threadProperties' => { 'threadType' => 'chat' } }]
      result = with_temp_config { run_sync_with_chat_list(chats: chats, msg_stub: msg_response, args: ['-v']) }
      stdout = result[:stdout]

      assert_match(/Sync complete/, stdout)
      assert_match(/Chats synced: 1/, stdout)
    end

    def test_summary_shows_skipped_count
      result = with_temp_config do
        run_sync_with_chat_list(chats: [sample_ngmsg_chat], msg_stub: { 'messages' => [], '_metadata' => {} })
      end

      assert_match(/Sync complete/, result[:stdout])
    end

    def test_since_time_uses_default_when_not_set
      result = with_temp_config { run_sync_with_chat_list(chats: [sample_ngmsg_chat], msg_stub: msg_response) }

      assert_match(/Sync complete/, result[:stdout])
      with_temp_config { refute build_cmd([]).options[:since_days] }
    end

    def test_non_verbose_sync_api_logging
      result = with_temp_config { run_sync_with_chat_list(chats: [sample_ngmsg_chat], msg_stub: msg_response) }

      assert_match(/Sync complete/, result[:stdout])
    end
  end

  # Tests for 404 handling, retry logic, and API error reporting
  class ErrorHandlingTest < Minitest::Test
    include SharedHelpers
    include AuthHelpers

    def test_sync_marks_404_chats_as_unavailable
      with_temp_config do
        result = run_sync_with_sleep_stub(chats: [sample_ngmsg_chat],
                                          error: Teems::ApiError.new('HTTP 404: Not Found', status_code: 404))
        stderr = result[:stderr]
        assert_match(/Chat unavailable \(404\)/, stderr)
        assert_match(/will skip on future syncs/, stderr)
        store = Teems::Services::SyncStore.new
        assert store.chat_unavailable?(store.load_state, '19:chat123@thread.v2')
      end
    end

    def test_sync_skips_previously_unavailable_chats
      with_temp_config do
        mark_chat_unavailable('19:chat123@thread.v2', display_name: 'Dead Chat')
        error = Teems::ApiError.new('HTTP 404: Not Found', status_code: 404)
        exit_code, result = run_sync_returning_exit_code(chats: [sample_ngmsg_chat],
                                                         error_stubs: { 'messages' => error })

        assert_equal 0, exit_code
        assert_match(/Sync complete/, result[:stdout])
        refute_match(/Chat unavailable/, result[:stderr])
      end
    end

    def test_sync_retries_transient_not_found
      with_temp_config do
        error = Teems::ApiError.new('HTTP 404: Not Found', status_code: 404)
        result = run_transient_404_sync(error: error)
        assert_transient_404_recovered(result)
      end
    end

    def test_sync_non_404_api_error_reports_failure
      error = Teems::ApiError.new('HTTP 500: Internal Server Error', status_code: 500)
      result = with_temp_config do
        run_sync_with_chat_list(chats: [sample_ngmsg_chat], error_stubs: { 'messages' => error })
      end
      stderr = result[:stderr]
      assert_match(/Failed to sync/, stderr)
      assert_match(/500/, stderr)
      assert_match(/Sync complete/, result[:stdout])
    end

    def test_sync_returns_nonzero_exit_code_on_errors
      error = Teems::ApiError.new('HTTP 500: Internal Server Error', status_code: 500)
      exit_code = with_temp_config do
        capture_exit_code_with_chat_list(chats: [sample_ngmsg_chat], error_stubs: { 'messages' => error })
      end
      assert_equal 1, exit_code
    end

    def test_fetch_chat_list_failure_returns_exit_code_one
      with_temp_config do
        exit_code = nil
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('conversations', Teems::ApiError.new('Network error: connection refused'))
          exit_code = Teems::Commands::Sync.new([], runner: runner).execute
        end
        assert_equal 1, exit_code
        assert_match(/Failed to fetch chats/, result[:stderr])
      end
    end

    def test_api_error_status_code_used_for_404_detection
      error = Teems::ApiError.new('Error 404 in URL path', status_code: 500)
      result = with_temp_config do
        run_sync_with_chat_list(chats: [sample_ngmsg_chat], error_stubs: { 'messages' => error })
      end
      stderr = result[:stderr]
      assert_match(/Failed to sync/, stderr)
      refute_match(/Chat unavailable/, stderr)
    end

    private

    def assert_transient_404_recovered(result)
      stdout = result[:stdout]
      assert_match(/Sync complete/, stdout)
      assert_match(/Chats synced: 1/, stdout)
      refute_match(/Chat unavailable/, result[:stderr])
      store = Teems::Services::SyncStore.new
      refute store.chat_unavailable?(store.load_state, '19:chat123@thread.v2')
    end
  end

  # Tests for unexpected errors, retry edge cases, and error summary reporting
  class ErrorReportingTest < Minitest::Test
    include SharedHelpers
    include AuthHelpers

    def test_sync_unexpected_error_in_chat_reports_and_continues
      error = RuntimeError.new('unexpected disk error')
      result = with_temp_config do
        run_sync_with_chat_list(chats: [sample_ngmsg_chat], error_stubs: { 'messages' => error })
      end
      assert_match(/Unexpected error syncing/, result[:stderr])
      assert_match(/Sync complete/, result[:stdout])
    end

    def test_retry_404_then_non_404_error
      result = with_temp_config { run_retry_not_found_then_server_error }
      stderr = result[:stderr]
      assert_match(/Failed to sync/, stderr)
      assert_match(/500/, stderr)
    end

    def test_sync_error_without_backtrace
      error = RuntimeError.new('no backtrace error')
      result = with_temp_config do
        run_sync_with_chat_list(chats: [sample_ngmsg_chat], error_stubs: { 'messages' => error }, args: ['-v'])
      end
      assert_match(/Unexpected error syncing/, result[:stderr])
    end

    def test_summary_shows_error_count
      error = RuntimeError.new('unexpected')
      result = with_temp_config do
        run_sync_with_chat_list(chats: [sample_ngmsg_chat], error_stubs: { 'messages' => error })
      end
      assert_match(/Errors:/, result[:stderr])
    end
  end

  # Tests for incremental sync, deduplication, dry-run, and state management
  class IncrementalAndStateTest < Minitest::Test
    include SharedHelpers

    def test_incremental_sync_merges_messages
      with_temp_config do
        chat_id = '19:test@thread.v2'
        preseed_messages(chat_id, [old_message_fixture])
        run_sync(['--chat', chat_id], stubs: msg_stub)
        ids = load_synced_messages(chat_id).map { |msg| msg['id'] }

        assert_includes ids, 'old-msg-1'
        assert_includes ids, '1768935087318'
      end
    end

    def test_merge_deduplicates_by_message_id
      with_temp_config do
        chat_id = '19:test@thread.v2'
        preseed_messages(chat_id, [duplicate_message_fixture])
        run_sync(['--chat', chat_id], stubs: msg_stub)
        messages = load_synced_messages(chat_id)
        first_message = messages.first

        assert_equal 1, messages.length
        assert_equal '1768935087318', first_message['id']
        assert_equal 'Jane Smith', first_message['sender_name']
      end
    end

    def test_skip_unchanged_when_previously_synced
      with_temp_config do
        chat_id = '19:chat123@thread.v2'
        run_first_sync(chat_id)
        result = run_sync(['--chat', chat_id],
                          stubs: { 'messages' => { 'messages' => [], '_metadata' => {} } })
        stdout = result[:stdout]

        assert_match(/Sync complete/, stdout)
        assert_match(/skipped/, stdout)
      end
    end

    def test_dry_run_shows_chats_without_writing
      result = with_temp_config { run_sync_with_chat_list(chats: [sample_ngmsg_chat], args: ['--dry-run']) }
      stdout = result[:stdout]

      assert_match(/Dry run/, stdout)
      assert_match(/19:chat123@thread.v2/, stdout)
    end

    def test_dry_run_shows_never_synced_status
      result = with_temp_config { run_sync_with_chat_list(chats: [sample_ngmsg_chat], args: ['--dry-run']) }

      assert_match(/never synced/, result[:stdout])
    end

    def test_dry_run_with_previously_synced_chat
      with_temp_config do
        chat_id = '19:chat123@thread.v2'
        run_sync(['--chat', chat_id], stubs: msg_stub)
        result = run_sync_with_chat_list(chats: [sample_ngmsg_chat], args: ['--dry-run'])

        assert_match(/last synced/, result[:stdout])
      end
    end

    def test_dry_run_with_system_chats_skipped
      system_chat = { 'id' => '48:notifications', 'threadProperties' => { 'threadType' => 'chat' } }
      chats = [sample_ngmsg_chat, system_chat]
      with_temp_config do
        exit_code, result = run_dry_run_with_chats(chats)
        stdout = result[:stdout]

        assert_equal 0, exit_code
        assert_match(/Dry run/, stdout)
        assert_match(/system streams skipped/, stdout)
      end
    end

    private

    def run_dry_run_with_chats(chats)
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub('conversations', { 'conversations' => chats })
        exit_code = Teems::Commands::Sync.new(['--dry-run'], runner: runner).execute
      end
      [exit_code, result]
    end
  end

  # Tests for verbose API logging and Safari auth token refresh
  class VerboseAndAuthTest < Minitest::Test
    include SharedHelpers
    include AuthHelpers

    def test_verbose_api_logging
      with_temp_config do
        out, runner = build_verbose_runner
        runner.api_client.stub('conversations', { 'conversations' => [] })
        Teems::Commands::Sync.new(['-v'], runner: runner).execute

        assert_match(/No chats found/, out.string)
      end
    end

    def test_verbose_sync_with_api_calls
      with_temp_config do
        out, runner = build_verbose_runner
        api = runner.api_client
        api.stub('conversations', { 'conversations' => [sample_ngmsg_chat] })
        api.stub('messages', { 'messages' => [sample_ng_msg_message], '_metadata' => {} })
        setup_verbose_response_logging(api, runner.output)
        Teems::Commands::Sync.new(['-v'], runner: runner).execute

        assert_match(/Sync complete/, out.string)
      end
    end

    def test_auth_flag_returns_error_when_extraction_fails
      with_temp_config do
        exit_code, result = run_auth_cmd(['--auth'], extract_result: nil, save_result: false, configured: false)

        assert_equal 1, exit_code
        assert_match(/Failed to authenticate via Safari/, result[:stderr])
      end
    end

    def test_auth_flag_returns_error_when_save_fails
      with_temp_config do
        tokens = { auth_token: 'test-auth', skype_token: 'test-skype' }
        exit_code, result = run_auth_cmd(['--auth'],
                                         extract_result: tokens, save_result: false, configured: false)

        assert_equal 1, exit_code
        assert_match(/failed to save/, result[:stderr])
      end
    end

    def test_auth_flag_succeeds_when_tokens_saved
      with_temp_config do
        exit_code, result = run_auth_with_expired_tokens
        assert_equal 0, exit_code
        assert_match(/Authentication successful/, result[:stdout])
      end
    end

    def test_auth_flag_skips_browser_when_tokens_valid
      with_temp_config do
        exit_code = nil
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('conversations', { 'conversations' => [] })
          exit_code = Teems::Commands::Sync.new(['--auth'], runner: runner).execute
        end

        assert_equal 0, exit_code
        assert_match(/tokens still valid/, result[:stdout])
      end
    end

    def test_auth_flag_opens_browser_when_tokens_expired
      with_temp_config do
        exit_code, result = run_auth_cmd(['--auth'],
                                         extract_result: nil, save_result: false,
                                         configured: true)

        assert_equal 1, exit_code
        assert_match(/Failed to authenticate via Safari/, result[:stderr])
      end
    end

    def test_auth_flag_fails_when_only_auth_token_extracted
      with_temp_config do
        tokens = { auth_token: 'test-auth', skype_token: nil }
        exit_code, result = run_auth_cmd(['--auth'],
                                         extract_result: tokens, save_result: false,
                                         configured: false)

        assert_equal 1, exit_code
        assert_match(/Failed to authenticate via Safari/, result[:stderr])
      end
    end
  end

  # Tests for handling errors when saving sync state to disk
  class SaveStateErrorTest < Minitest::Test
    include SharedHelpers

    # Sync subclass that simulates disk write failures during state save
    class FailingSaveSync < Teems::Commands::Sync
      def initialize(args, runner:)
        @sync_store = nil
        super
      end

      private

      def init_sync_state
        super
        @sync_store.define_singleton_method(:save_state) { |_state| raise 'disk full' }
      end
    end

    def test_save_state_safely_catches_error_and_increments_errors
      with_temp_config do
        exit_code = nil
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('conversations', { 'conversations' => [] })
          exit_code = FailingSaveSync.new([], runner: runner).execute
        end

        assert_equal 1, exit_code
        assert_match(/Failed to save sync state/, result[:stderr])
      end
    end
  end

  # Tests opt-in inline image downloads (--images)
  class ImagesTest < Minitest::Test
    include SharedHelpers

    CHAT_ID = '19:chat123@thread.v2'

    def test_images_option_downloads_and_links_images
      with_temp_config do
        result = run_image_sync
        markdown = load_synced_markdown(CHAT_ID)

        assert_includes result[:stdout], 'Images downloaded: 1'
        assert_includes markdown, "](images/#{SAMPLE_AMS_OBJECT_ID}.png)"
        assert_equal SAMPLE_AMS_OBJECT_ID, load_synced_messages(CHAT_ID).first['images'].first['id']
      end
    end

    def test_without_images_option_keeps_placeholder
      with_temp_config do
        result = run_sync(['--chat', CHAT_ID], stubs: { 'messages' => image_response })

        refute_includes result[:stdout], 'Images downloaded'
        assert_includes load_synced_markdown(CHAT_ID), '[image: image (640x120)]'
      end
    end

    def test_images_option_backfills_unchanged_chats
      with_temp_config do
        run_sync(['--chat', CHAT_ID], stubs: { 'messages' => image_response })
        result = run_image_sync(response: { 'messages' => [], '_metadata' => {} })

        refute_match(/skipped/, result[:stdout])
        assert_includes result[:stdout], 'Images downloaded: 1'
      end
    end

    def test_help_mentions_images_option
      result = capture_output { |out| Teems::Commands::Sync.new(['--help'], runner: configured_runner(output: out)).execute }
      assert_includes result[:stdout], '--images'
    end

    private

    def image_response
      message = sample_image_message.merge('composetime' => (Time.now - 3600).utc.strftime('%Y-%m-%dT%H:%M:%S.000Z'))
      { 'messages' => [message], '_metadata' => {} }
    end

    def run_image_sync(response: image_response)
      runner, out, err = build_sync_runner
      runner.api_client.stub('messages', response)
      runner.define_singleton_method(:inline_image_downloader) { FakeImageDownloader.new }
      Teems::Commands::Sync.new(['--images', '--chat', CHAT_ID], runner: runner).execute
      sync_result(out, err)
    end

    # Returns a synthetic PNG for any image
    class FakeImageDownloader
      def fetch(image)
        body = "\x89PNG-synthetic".b
        Teems::Services::InlineImageDownloader::Result.new(body: body, extension: 'png', url: image.url)
      end
    end
  end

  # Chats must never share a sync folder (older versions merged 1:1 chats and same-titled chats)
  class SeparateFoldersTest < Minitest::Test
    include SharedHelpers

    ME = '11111111-2222-3333-4444-555555555555'
    DM_A = "19:#{ME}_aaaaaaaa-0000-0000-0000-000000000001@unq.gbl.spaces".freeze
    DM_B = "19:#{ME}_bbbbbbbb-0000-0000-0000-000000000002@unq.gbl.spaces".freeze
    # The folder older versions gave both chats: "Group Chat" plus a 20-character ID prefix
    LEGACY_DIR = 'Group Chat (19_11111111-2222-333)'

    def test_one_on_one_chats_with_a_common_id_prefix_sync_to_separate_folders
      with_temp_config do
        run_dm_sync
        assert_equal ['msg-a'], synced_ids(DM_A)
        assert_equal ['msg-b'], synced_ids(DM_B)
        assert_includes chat_dir(DM_A), '/chats/dms/'
      end
    end

    def test_existing_shared_folder_is_left_untouched_and_each_chat_resyncs
      with_temp_config do
        legacy_dir, snapshot = seed_legacy_folder
        result = run_dm_sync
        assert_equal snapshot, dir_snapshot(legacy_dir)
        assert_equal [['msg-a'], ['msg-b']], [synced_ids(DM_A), synced_ids(DM_B)]
        assert_includes result[:stderr], "groups/#{LEGACY_DIR} (2 chats)"
        legacy = Teems::Services::SyncStore.new.load_state.dig('chats', DM_A, 'legacy_shared_dir')
        assert_equal "groups/#{LEGACY_DIR}", legacy
      end
    end

    def test_dry_run_reports_shared_folders_without_changing_state
      with_temp_config do
        seed_legacy_folder
        state_before = Teems::Services::SyncStore.new.load_state
        result = run_dm_sync(['--dry-run'])
        assert_includes result[:stdout], "Shared folders that would be detached (1):\n  groups/#{LEGACY_DIR} (2 chats)"
        assert_equal state_before, Teems::Services::SyncStore.new.load_state
      end
    end

    private

    def run_dm_sync(args = [])
      runner, out, err = build_sync_runner
      api = runner.api_client
      # Stubs match by substring in insertion order, so the per-chat paths go before the list path
      { DM_A => 'msg-a', DM_B => 'msg-b' }.each do |chat_id, message_id|
        api.stub("#{URI.encode_www_form_component(chat_id)}/messages", dm_messages(message_id))
      end
      api.stub('/v1/users/ME/conversations', { 'conversations' => [dm_chat(DM_A), dm_chat(DM_B)] })
      Teems::Commands::Sync.new(args, runner: runner).execute
      sync_result(out, err)
    end

    def dm_chat(chat_id)
      { 'id' => chat_id, 'properties' => {},
        'threadProperties' => { 'threadType' => 'chat', 'productThreadType' => 'OneToOneChat' } }
    end

    def dm_messages(message_id)
      { 'messages' => [recent_ng_msg_message.merge('id' => message_id)], '_metadata' => {} }
    end

    def seed_legacy_folder
      store = Teems::Services::SyncStore.new
      entry = { 'dir_name' => LEGACY_DIR, 'chat_type' => 'group', 'last_synced_at' => Time.now.utc.iso8601 }
      store.save_state({ 'chats' => { DM_A => entry, DM_B => entry.dup } })
      dir = File.join(store.sync_dir, 'chats', 'groups', LEGACY_DIR)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'messages.json'), JSON.generate([old_message_fixture]))
      File.write(File.join(dir, 'messages.md'), '# legacy')
      [dir, dir_snapshot(dir)]
    end

    def dir_snapshot(dir)
      Dir.children(dir).sort.to_h { |name| [name, File.binread(File.join(dir, name))] }
    end

    def synced_ids(chat_id) = load_synced_messages(chat_id).map { |message| message['id'] }

    def chat_dir(chat_id)
      store = Teems::Services::SyncStore.new
      store.chat_dir(chat_id, state: store.load_state)
    end
  end

  # Upgrading from a version that named folders by title or ID prefix. Fixture: two 1:1s sharing a
  # legacy folder, a 1:1 that owns its legacy folder under groups/, and a group chat that owns
  # "Planning"; every folder holds synthetic messages.
  module FolderUpgradeHelpers
    include SharedHelpers

    ME = SeparateFoldersTest::ME
    DM_A = SeparateFoldersTest::DM_A
    DM_B = SeparateFoldersTest::DM_B
    DM_SOLO = "19:99999999-8888-7777-6666-555555555555_#{ME}@unq.gbl.spaces".freeze
    GROUP = '19:planning@thread.v2'
    SHARED_DIR = 'groups/Group Chat (19_11111111-2222-333)'
    SOLO_DIR = 'groups/Group Chat (19_99999999-8888-777)'
    GROUP_DIR = 'groups/Planning'
    DAY = 86_400

    private

    def seed_upgrade(extra: {})
      Teems::Services::SyncStore.new.save_state('chats' => legacy_chats.merge(extra))
      seed_folder(SHARED_DIR, [stored_message('shared-oldest', 400), stored_message('shared-recent', 10)])
      seed_folder(SOLO_DIR, [stored_message('solo-old', 30)])
      seed_folder(GROUP_DIR, [stored_message('plan-old', 30)])
    end

    def legacy_chats
      synced = { 'chat_type' => 'group', 'display_name' => 'Group Chat', 'message_count' => 1,
                 'last_synced_at' => (Time.now - DAY).utc.iso8601 }
      { DM_A => synced.merge('dir_name' => File.basename(SHARED_DIR)),
        DM_B => synced.merge('dir_name' => File.basename(SHARED_DIR)),
        DM_SOLO => synced.merge('dir_name' => File.basename(SOLO_DIR)),
        GROUP => synced.merge('dir_name' => 'Planning', 'display_name' => 'Planning') }
    end

    def seed_folder(path, messages)
      FileUtils.mkdir_p(chats_path(path))
      File.write(File.join(chats_path(path), 'messages.json'), JSON.generate(messages))
      File.write(File.join(chats_path(path), 'messages.md'), '# synthetic')
    end

    def stored_message(id, days_ago)
      old_message_fixture.merge('id' => id, 'created_at' => (Time.now - (days_ago * DAY)).utc.iso8601)
    end

    def run_upgrade_sync(args = [], interrupt: nil)
      runner, out, err = build_sync_runner
      api = runner.api_client
      api.stub_error(messages_path(interrupt), Interrupt.new) if interrupt
      chat_messages.each { |id, messages| api.stub(messages_path(id), { 'messages' => messages, '_metadata' => {} }) }
      api.stub('/v1/users/ME/conversations', { 'conversations' => chat_list })
      Teems::Commands::Sync.new(args, runner: runner).execute
      sync_result(out, err).merge(api: api)
    end

    def chat_messages
      { DM_SOLO => [api_message('solo-new')], DM_A => [api_message('a-old', 300), api_message('a-new')],
        DM_B => [api_message('b-new')], GROUP => [api_message('plan-new')] }
    end

    def chat_list
      dms = [DM_SOLO, DM_A, DM_B].map do |id|
        { 'id' => id, 'properties' => {},
          'threadProperties' => { 'threadType' => 'chat', 'productThreadType' => 'OneToOneChat' } }
      end
      dms << { 'id' => GROUP, 'properties' => {},
               'threadProperties' => { 'threadType' => 'chat', 'topic' => 'Planning' } }
    end

    def api_message(id, days_ago = 0)
      composed = Time.now - 3600 - (days_ago * DAY)
      sample_ng_msg_message.merge('id' => id, 'composetime' => composed.utc.strftime('%Y-%m-%dT%H:%M:%S.000Z'))
    end

    def messages_path(chat_id) = "#{URI.encode_www_form_component(chat_id)}/messages"

    def load_state = Teems::Services::SyncStore.new.load_state

    def chat_entry(chat_id) = load_state.dig('chats', chat_id)

    def chats_path(path) = File.join(Teems::Services::SyncStore.new.sync_dir, 'chats', path)

    def relative_chat_dir(chat_id)
      entry = chat_entry(chat_id)
      File.join(Teems::Services::SyncDirNaming.type_dir(entry['chat_type']), entry['dir_name'])
    end

    def synced_ids(chat_id) = load_synced_messages(chat_id).map { |message| message['id'] }

    def synced_ids_for(*chat_ids) = chat_ids.map { |chat_id| synced_ids(chat_id) }

    def stored_ids(path) = JSON.parse(File.read(File.join(chats_path(path), 'messages.json'))).map { |msg| msg['id'] }

    # Every file and directory under root, with file contents and modification times
    def tree_snapshot(root)
      Dir.glob('**/*', File::FNM_DOTMATCH, base: root).reject { |rel| File.basename(rel) == '.' }.sort.to_h do |rel|
        path = File.join(root, rel)
        [rel, File.directory?(path) ? :dir : [File.binread(path), File.mtime(path)]]
      end
    end
  end

  # Folders one chat owns keep their names; changed and migrated chats get full-ID folders
  class FolderUpgradeRenameTest < Minitest::Test
    include FolderUpgradeHelpers

    def test_a_misfiled_dm_moves_to_dms_with_its_history
      with_temp_config do
        seed_upgrade
        result = run_upgrade_sync
        solo_dir = relative_chat_dir(DM_SOLO)
        assert_match(%r{\Adms/1-1 Chat \(19_99999999-.*_unq\.gbl\.spaces\)\z}, solo_dir)
        refute File.exist?(chats_path(SOLO_DIR))
        assert_equal %w[solo-old solo-new], synced_ids(DM_SOLO)
        assert_includes result[:stdout], "Folder: #{SOLO_DIR} → #{solo_dir}\n"
      end
    end

    def test_a_folder_one_chat_owns_keeps_its_name
      with_temp_config do
        seed_upgrade
        result = run_upgrade_sync
        assert_equal [GROUP_DIR, %w[plan-old plan-new]], [relative_chat_dir(GROUP), synced_ids(GROUP)]
        refute_includes result[:stdout], "Folder: #{GROUP_DIR}"
      end
    end

    def test_sync_chat_keeps_the_stored_name_and_type
      with_temp_config do
        seed_upgrade
        run_upgrade_sync(['--chat', GROUP])
        assert_equal GROUP_DIR, relative_chat_dir(GROUP)
        assert_equal %w[Planning group], chat_entry(GROUP).values_at('display_name', 'chat_type')
      end
    end

    def test_warns_when_a_move_leaves_the_old_folder_behind
      with_temp_config do
        seed_upgrade
        planned = Teems::Services::SyncStore.new.plan_chat_dir(load_state, chat_id: DM_SOLO, display_name: '1:1 Chat',
                                                                           chat_type: 'oneOnOne')
        FileUtils.mkdir_p(chats_path(planned.to))
        assert_includes run_upgrade_sync[:stderr], "Folder: #{planned} (the new folder already exists: switching " \
                                                   'to it, the old folder is left in place)'
        assert_equal ['solo-old'], stored_ids(SOLO_DIR)
      end
    end

    def test_migrate_dirs_dry_run_previews_without_writing
      with_temp_config do |root|
        seed_upgrade
        before = tree_snapshot(root)
        result = run_upgrade_sync(%w[--dry-run --migrate-dirs])
        assert_includes result[:stdout], "  #{GROUP_DIR} → groups/Planning (19_planning_thread.v2)\n"
        assert_equal before, tree_snapshot(root)
      end
    end

    def test_migrate_dirs_renames_kept_folders_and_writes_a_map
      with_temp_config do
        seed_upgrade
        result = run_upgrade_sync(['--migrate-dirs'])
        new_dir = 'groups/Planning (19_planning_thread.v2)'
        assert_equal [new_dir, %w[plan-old plan-new]], [relative_chat_dir(GROUP), synced_ids(GROUP)]
        moves = JSON.parse(File.read(result[:stdout][/Folder map: (\S+)/, 1]))['moves']
        assert_includes moves, { 'chat_id' => GROUP, 'from' => GROUP_DIR, 'to' => new_dir, 'kind' => 'move' }
      end
    end

    def test_help_mentions_migrate_dirs
      result = capture_output { |out| Teems::Commands::Sync.new(['--help'], runner: configured_runner(output: out)).execute }
      assert_includes result[:stdout], '--migrate-dirs'
    end
  end

  # Upgrading never loses history: interrupted runs resume, and split chats re-fetch far enough back
  class FolderUpgradeSafetyTest < Minitest::Test
    include FolderUpgradeHelpers

    def test_resumes_after_an_interrupted_run
      with_temp_config do
        seed_upgrade
        state_before = load_state
        assert_raises(Interrupt) { run_upgrade_sync(interrupt: GROUP) }
        assert_equal state_before, load_state, 'state is only saved at the end of a run'
        refute_includes run_upgrade_sync[:stderr], 'left in place'
        assert_equal [%w[solo-old solo-new], %w[a-old a-new], %w[plan-old plan-new]],
                     synced_ids_for(DM_SOLO, DM_A, GROUP)
        assert_equal %w[shared-oldest shared-recent], stored_ids(SHARED_DIR)
      end
    end

    def test_a_never_synced_chat_does_not_make_a_folder_shared
      with_temp_config do
        dead = { 'dir_name' => 'Planning', 'chat_type' => 'group', 'display_name' => 'Planning', 'unavailable' => true }
        seed_upgrade(extra: { '19:gone@thread.v2' => dead })
        refute_includes run_upgrade_sync[:stderr], GROUP_DIR
        assert_equal [GROUP_DIR, %w[plan-old plan-new]], [relative_chat_dir(GROUP), synced_ids(GROUP)]
        assert_nil chat_entry(GROUP)['legacy_shared_dir']
      end
    end

    def test_a_chat_with_a_cleared_cursor_still_owns_its_folder
      with_temp_config do
        seed_upgrade(extra: { DM_B => legacy_chats[DM_B].except('last_synced_at') })
        assert_includes run_upgrade_sync[:stderr], "#{SHARED_DIR} (2 chats)"
      end
    end

    def test_split_chats_refetch_back_to_the_oldest_legacy_message
      with_temp_config do
        seed_upgrade
        result = run_upgrade_sync
        oldest = Time.now - (400 * DAY)
        assert_equal %w[a-old a-new], synced_ids(DM_A), 'a 300-day-old message is older than --since 180'
        assert_includes result[:stdout], "re-fetching from #{oldest.strftime('%Y-%m-%d')}"
        assert_in_delta oldest, start_time(result[:api], DM_A), 5
      end
    end

    private

    def start_time(api, chat_id)
      Time.at(api.calls.find { |call| call[:path].include?(messages_path(chat_id)) }.dig(:params, :startTime) / 1000.0)
    end

    def test_shared_folder_warning_says_to_keep_the_old_folders
      with_temp_config do
        seed_upgrade
        stderr = run_upgrade_sync[:stderr]
        assert_includes stderr,
                        "Older history may still exist only in the old folders, so keep them until you've checked"
        refute_match(/delete/i, stderr)
      end
    end
  end

  # --dry-run previews every folder change; --chat only splits that chat; old folders stay listed
  class FolderUpgradeReportTest < Minitest::Test
    include FolderUpgradeHelpers

    def test_dry_run_touches_nothing
      with_temp_config do |root|
        seed_upgrade
        before = tree_snapshot(root)
        run_upgrade_sync(['--dry-run'])
        assert_equal before, tree_snapshot(root)
      end
    end

    def test_dry_run_lists_every_folder_change
      with_temp_config do
        seed_upgrade
        stdout = run_upgrade_sync(['--dry-run'])[:stdout]
        assert_match(%r{Folder changes \(3\):\n  #{Regexp.escape(SOLO_DIR)} → dms/1-1 Chat \(19_99999999-[^)]+\)\n},
                     stdout)
        splits = [DM_A, DM_B].map { |id| "  #{SHARED_DIR} → dms/1-1 Chat (#{id.tr(':@', '__')}) (split from a shared" }
        splits.each { |line| assert_includes stdout, line }
        assert_includes stdout, "Shared folders that would be detached (1):\n  #{SHARED_DIR} (2 chats)"
        refute_includes stdout, "#{GROUP_DIR} →"
      end
    end

    def test_dry_run_without_changes
      with_temp_config do
        run_upgrade_sync
        assert_includes run_upgrade_sync(['--dry-run'])[:stdout], 'Folder changes: none'
      end
    end

    def test_sync_chat_splits_only_that_chat
      with_temp_config do
        seed_upgrade
        assert_includes run_upgrade_sync(['--chat', DM_A])[:stderr], "#{SHARED_DIR} (1 chat)\n"
        assert_equal SHARED_DIR, chat_entry(DM_A)['legacy_shared_dir']
        assert_equal File.basename(SHARED_DIR), chat_entry(DM_B)['dir_name']
        assert chat_entry(DM_B)['last_synced_at'], 'other chats keep their cursors'
      end
    end

    def test_the_rest_of_a_shared_folder_splits_when_it_syncs
      with_temp_config do
        seed_upgrade
        run_upgrade_sync(['--chat', DM_A])
        assert_includes run_upgrade_sync[:stderr], "#{SHARED_DIR} (1 chat)\n"
        assert_equal SHARED_DIR, chat_entry(DM_B)['legacy_shared_dir']
      end
    end

    def test_old_shared_folders_are_listed_while_they_exist
      with_temp_config do
        seed_upgrade
        listing = "Old shared folders still on disk (they may hold history the new folders don't):\n  " \
                  "#{SHARED_DIR} (2 chats)"
        refute_includes run_upgrade_sync[:stdout], listing, 'the first run already warned about them'
        assert_includes run_upgrade_sync[:stdout], listing
        assert_includes run_upgrade_sync(['--dry-run'])[:stdout], listing
        FileUtils.rm_rf(chats_path(SHARED_DIR))
        refute_includes run_upgrade_sync[:stdout], 'Old shared folders'
      end
    end
  end
end
