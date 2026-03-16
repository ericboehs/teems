# frozen_string_literal: true

require 'test_helper'

module SyncCommandTests
  module SharedFixtures
    private

    def msg_response
      { 'messages' => [sample_ng_msg_message], '_metadata' => {} }
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

  module SharedHelpers
    include SharedFixtures

    private

    def build_sync_runner
      out = StringIO.new
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: out, err: err, color: false)
      [configured_runner(output: output), out, err]
    end

    def sync_result(out, err)
      { stdout: out.string, stderr: err.string }
    end

    def execute_with_no_sleep(args, runner:)
      cmd = Teems::Commands::Sync.new(args, runner: runner)
      cmd.define_singleton_method(:sleep) { |_| nil }
      cmd.execute
    end

    def run_sync(args = [], stubs: {})
      runner, out, err = build_sync_runner
      stubs.each { |path, response| runner.api_client.stub(path, response) }
      Teems::Commands::Sync.new(args, runner: runner).execute
      sync_result(out, err)
    end

    def run_sync_with_chat_list(chats:, msg_stub: nil, error_stubs: {}, args: [])
      runner, out, err = build_sync_runner
      api = runner.api_client
      api.stub('conversations', { 'conversations' => chats })
      api.stub('messages', msg_stub) if msg_stub
      error_stubs.each { |path, error| api.stub_error(path, error) }
      Teems::Commands::Sync.new(args, runner: runner).execute
      sync_result(out, err)
    end

    def run_sync_returning_exit_code(chats:, error_stubs: {})
      runner, out, err = build_sync_runner
      runner.api_client.stub('conversations', { 'conversations' => chats })
      error_stubs.each { |path, error| runner.api_client.stub_error(path, error) }
      exit_code = Teems::Commands::Sync.new([], runner: runner).execute
      [exit_code, sync_result(out, err)]
    end

    def capture_exit_code_with_chat_list(chats:, error_stubs: {})
      runner, _out, _err = build_sync_runner
      runner.api_client.stub('conversations', { 'conversations' => chats })
      error_stubs.each { |path, error| runner.api_client.stub_error(path, error) }
      Teems::Commands::Sync.new([], runner: runner).execute
    end

    def run_sync_with_sleep_stub(chats:, error:)
      runner, out, err = build_sync_runner
      runner.api_client.stub('conversations', { 'conversations' => chats })
      runner.api_client.stub_error('messages', error)
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
        runner.api_client.stub('conversations', { 'conversations' => [sample_ngmsg_chat] })
        runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message], '_metadata' => {} })
        Teems::Commands::Sync.new(['--chat', chat_id], runner: runner).execute
      end
    end

    def build_cmd(args)
      Teems::Commands::Sync.new(args, runner: configured_runner)
    end

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

    def setup_verbose_response_logging(runner, _out)
      runner.api_client.on_response = lambda { |path, code|
        runner.output.debug("  API <- #{code} #{path[0..80]}") if runner.output.verbose?
      }
    end

    def build_auth_runner_with_extractor(output:, extract_result:, save_result:, configured:)
      store = mock_token_store(configured: configured)
      store.save_result = save_result
      runner = Teems::Runner.new(output: output, token_store: store,
                                 api_client: Teems::TestHelpers::MockApiClient.new)
      extractor = Object.new
      extractor.define_singleton_method(:extract) { extract_result }
      runner.instance_variable_set(:@token_extractor, extractor)
      runner
    end

    def build_auth_runner(output:, save_result:)
      store = mock_token_store(configured: true, account: mock_account)
      store.save_result = save_result
      runner = Teems::Runner.new(output: output, token_store: store,
                                 api_client: Teems::TestHelpers::MockApiClient.new)
      extractor = Object.new
      extractor.define_singleton_method(:extract) { { auth_token: 'test-auth', skype_token: 'test-skype' } }
      runner.instance_variable_set(:@token_extractor, extractor)
      runner
    end

    def run_auth_with_expired_tokens
      exit_code = nil
      expired = Teems::ApiError.new('Invalid token', status_code: 401)
      result = capture_output do |output|
        runner = build_auth_runner(output: output, save_result: true)
        runner.api_client.stub_transient_error('conversations', expired, times: 1)
        runner.api_client.stub('conversations', { 'conversations' => [] })
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

  class BasicTest < Minitest::Test
    include SharedHelpers

    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          store = mock_unconfigured_store
          runner = Teems::Runner.new(output: output, token_store: store)
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

  class SyncOperationsTest < Minitest::Test
    include SharedHelpers

    def test_sync_single_chat
      with_temp_config do
        result = run_sync(['--chat', '19:test@thread.v2'], stubs: msg_stub)

        assert_match(/Sync complete/, result[:stdout])
        assert_match(/Chats synced: 1/, result[:stdout])
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

      assert_match(/Sync complete/, result[:stdout])
      assert_match(/Chats synced: 1/, result[:stdout])
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

  class ErrorHandlingTest < Minitest::Test
    include SharedHelpers
    include AuthHelpers

    def test_sync_marks_404_chats_as_unavailable
      with_temp_config do
        result = run_sync_with_sleep_stub(chats: [sample_ngmsg_chat],
                                          error: Teems::ApiError.new('HTTP 404: Not Found', status_code: 404))

        assert_match(/Chat unavailable \(404\)/, result[:stderr])
        assert_match(/will skip on future syncs/, result[:stderr])
        assert Teems::Services::SyncStore.new.chat_unavailable?(
          Teems::Services::SyncStore.new.load_state, '19:chat123@thread.v2'
        )
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

        assert_match(/Sync complete/, result[:stdout])
        assert_match(/Chats synced: 1/, result[:stdout])
        refute_match(/Chat unavailable/, result[:stderr])
        refute Teems::Services::SyncStore.new.chat_unavailable?(
          Teems::Services::SyncStore.new.load_state, '19:chat123@thread.v2'
        )
      end
    end

    def test_sync_non_404_api_error_reports_failure
      error = Teems::ApiError.new('HTTP 500: Internal Server Error', status_code: 500)
      result = with_temp_config do
        run_sync_with_chat_list(chats: [sample_ngmsg_chat], error_stubs: { 'messages' => error })
      end

      assert_match(/Failed to sync/, result[:stderr])
      assert_match(/500/, result[:stderr])
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

      assert_match(/Failed to sync/, result[:stderr])
      refute_match(/Chat unavailable/, result[:stderr])
    end

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

      assert_match(/Failed to sync/, result[:stderr])
      assert_match(/500/, result[:stderr])
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

        assert_equal 1, messages.length
        assert_equal '1768935087318', messages.first['id']
        assert_equal 'Jane Smith', messages.first['sender_name']
      end
    end

    def test_skip_unchanged_when_previously_synced
      with_temp_config do
        chat_id = '19:chat123@thread.v2'
        run_first_sync(chat_id)
        result = run_sync(['--chat', chat_id],
                          stubs: { 'messages' => { 'messages' => [], '_metadata' => {} } })

        assert_match(/Sync complete/, result[:stdout])
        assert_match(/skipped/, result[:stdout])
      end
    end

    def test_dry_run_shows_chats_without_writing
      result = with_temp_config { run_sync_with_chat_list(chats: [sample_ngmsg_chat], args: ['--dry-run']) }

      assert_match(/Dry run/, result[:stdout])
      assert_match(/19:chat123@thread.v2/, result[:stdout])
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

        assert_equal 0, exit_code
        assert_match(/Dry run/, result[:stdout])
        assert_match(/system streams skipped/, result[:stdout])
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
        runner.api_client.stub('conversations', { 'conversations' => [sample_ngmsg_chat] })
        runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message], '_metadata' => {} })
        setup_verbose_response_logging(runner, out)
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

  class SaveStateErrorTest < Minitest::Test
    include SharedHelpers

    class FailingSaveSync < Teems::Commands::Sync
      private

      def init_sync_state
        super
        @sync_store.define_singleton_method(:save_state) { |_| raise 'disk full' }
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
end
