# frozen_string_literal: true

require 'test_helper'

# CLI scenarios keep stubbed Graph responses, output and request assertions together.
# rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
class MailCommandTest < Minitest::Test
  def setup
    @saved_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Chicago'
  end

  def teardown
    ENV['TZ'] = @saved_tz
  end

  # Runs `teems mail ARGS` against stubbed Graph responses; returns stdout, stderr, exit code, and the runner
  def run_mail(args, stubs: {}, runner: nil)
    capture = capture_output do |output|
      runner ||= configured_runner(output: output)
      stubs.each { |path, response| runner.api_client.stub(path, response) }
      @code = Teems::Commands::Mail.new(args, runner: runner).execute
    end
    capture.merge(code: @code, calls: runner.api_client.calls)
  end

  def messages(*ids) = { 'value' => ids.map { |id| sample_mail_message('id' => id) } }

  def test_help_and_usage
    with_temp_config do
      assert_includes run_mail(['--help'])[:stdout], 'teems mail list [folder] [count]'
      result = run_mail(['bogus'])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Usage: teems mail <list|recent|read|folders|search|sync>'
      assert_equal 1, run_mail(%w[list --bogus])[:code]
    end
  end

  def test_list_defaults_to_twenty_inbox_messages
    with_temp_config do
      result = run_mail(['list'], stubs: { '/messages' => messages('m1') })

      assert_equal 0, result[:code]
      assert_match(/\A\h{8}  2026-10-20 09:05  Alice Smith\s+Quarterly report: Q3  unread\n\z/, result[:stdout])
      call = result[:calls].first

      assert_equal '/v1.0/me/mailFolders/inbox/messages', call[:path]
      assert_equal 20, call[:params]['$top']
    end
  end

  def test_list_folder_count_unread_and_alias
    with_temp_config do
      result = run_mail(%w[recent Archive 5 --unread], stubs: { '/messages' => messages('m1') })
      call = result[:calls].first

      assert_equal '/v1.0/me/mailFolders/archive/messages', call[:path]
      assert_equal 5, call[:params]['$top']
      assert_equal 'isRead eq false', call[:params]['$filter']
      assert_equal 3, run_mail(%w[list 3], stubs: { '/messages' => messages })[:calls].first[:params]['$top']
      assert_equal 7, run_mail(%w[list -n 7], stubs: { '/messages' => messages })[:calls].first[:params]['$top']
    end
  end

  def test_list_rejects_bad_count
    with_temp_config do
      result = run_mail(%w[list Inbox zero])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Count must be a positive number'
    end
  end

  def test_list_tsv_json_and_empty
    with_temp_config do
      tsv = run_mail(%w[list --tsv], stubs: { '/messages' => messages('m1') })[:stdout]

      assert_equal "m1\t2026-10-20T09:05:09-05:00\talice@example.com\tQuarterly report: Q3\tUnread\n", tsv
      json = JSON.parse(run_mail(%w[list --json], stubs: { '/messages' => messages('m1') })[:stdout])

      assert_equal 'm1', json.first['id']
      assert_includes run_mail(%w[list], stubs: { '/messages' => messages })[:stdout], 'No messages found'
    end
  end

  def test_list_unknown_folder
    with_temp_config do
      result = run_mail(%w[list Nowhere], stubs: { '/v1.0/me/mailFolders' => { 'value' => [sample_mail_folder] } })

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Mail folder not found: Nowhere'
    end
  end

  def test_api_errors_propagate_to_the_cli
    with_temp_config do
      capture_output do |output|
        runner = configured_runner(output: output)
        runner.api_client.stub_error('/messages', Teems::ApiError.new('HTTP 500', status_code: 500))

        assert_raises(Teems::ApiError) { Teems::Commands::Mail.new(%w[list], runner: runner).execute }
      end
    end
  end

  def test_read_by_short_id_after_list
    with_temp_config do
      run_mail(%w[list], stubs: { '/messages' => messages(MAIL_ID) })
      short = Teems::Models::MailMessage.short_id(MAIL_ID)
      attachments = { 'value' => [{ 'name' => 'a.pdf' }, { 'name' => 'logo.png', 'isInline' => true }] }
      stubs = { '/attachments' => attachments, '/v1.0/me/messages/' => sample_mail_message('hasAttachments' => true) }
      result = run_mail(['read', short], stubs: stubs)

      assert_equal 0, result[:code]
      assert_equal "/v1.0/me/messages/#{MAIL_ID}", result[:calls].first[:path]
      assert_includes result[:stdout], "Subject: Quarterly report: Q3\n"
      assert_includes result[:stdout], "Attachments: a.pdf\n"
      assert_includes result[:stdout], "Links:\n[1] the report <https://example.com/r>"
    end
  end

  def test_read_html_and_json
    with_temp_config do
      stubs = { '/v1.0/me/messages/' => sample_mail_message }
      html = run_mail(['read', MAIL_ID, '--html'], stubs: stubs)[:stdout]

      assert_equal "#{sample_mail_message.dig('body', 'content')}\n", html
      json = JSON.parse(run_mail(['read', MAIL_ID, '--json'], stubs: stubs)[:stdout])

      assert_equal 'Hello the report [1]', json['body']
      assert_includes json['links'], 'https://example.com/r'
      assert_equal [], json['attachments']
    end
  end

  def test_read_errors
    with_temp_config do
      assert_includes run_mail(%w[read])[:stderr], 'Usage: teems mail read <id>'
      result = run_mail(%w[read abcd1234])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Unknown message ID: abcd1234'
    end
  end

  def test_folders_table_tsv_json
    with_temp_config do
      stubs = { '/v1.0/me/mailFolders' => { 'value' => [sample_mail_folder, sample_mail_folder('Archive')] } }

      assert_match(/FOLDER\s+UNREAD\s+TOTAL\nInbox\s+2\s+10\nArchive/, run_mail(%w[folders], stubs: stubs)[:stdout])
      assert_equal "Inbox\t2\t10\nArchive\t2\t10\n", run_mail(%w[folders --tsv], stubs: stubs)[:stdout]
      assert_equal 'Archive', JSON.parse(run_mail(%w[folders --json], stubs: stubs)[:stdout]).last['path']
    end
  end

  def test_search
    with_temp_config do
      assert_includes run_mail(%w[search])[:stderr], 'Usage: teems mail search <query> [folder]'
      result = run_mail(['search', 'from:alice', 'inbox'], stubs: { '/messages' => messages('m1') })

      assert_equal '/v1.0/me/mailFolders/inbox/messages', result[:calls].first[:path]
      assert_equal '"from:alice"', result[:calls].first[:params]['$search']
      assert_includes result[:stdout], 'Quarterly report: Q3'
      other = run_mail(%w[search report --folder sent -n 5000], stubs: { '/messages' => messages })

      assert_equal '/v1.0/me/mailFolders/sentitems/messages', other[:calls].first[:path]
      assert_equal 250, other[:calls].first[:params]['$top']
      assert_equal '/v1.0/me/messages',
                   run_mail(%w[search report], stubs: { '/messages' => messages })[:calls].first[:path]
    end
  end

  def test_requires_auth_and_no_login_never_extracts
    with_temp_config do
      capture_output do |output|
        runner = Teems::Runner.new(output: output, token_store: mock_token_store(configured: false),
                                   api_client: MockApiClient.new)
        extractor = Teems::TestHelpers::SilentOnlyExtractor.new
        runner.define_singleton_method(:token_extractor) { |**| extractor }

        assert_equal 1, Teems::Commands::Mail.new(%w[list --no-login], runner: runner).execute
        assert_includes output.instance_variable_get(:@err).string, 'Not authenticated'
        assert_equal 1, extractor.silent_calls
      end
    end
  end

  def test_without_no_login_tries_auto_login
    with_temp_config do
      capture_output do |output|
        runner = Teems::Runner.new(output: output, token_store: mock_token_store(configured: false),
                                   api_client: MockApiClient.new)
        extracted = []
        runner.define_singleton_method(:token_extractor) do |**|
          extracted << true
          Teems::TestHelpers::NullExtractor.new
        end

        assert_equal 1, Teems::Commands::Mail.new(%w[list], runner: runner).execute
        assert_equal [true], extracted
      end
    end
  end

  def sync_stubs
    { '/mailFolders/inbox' => sample_mail_folder,
      '/messages/delta' => { 'value' => [sample_mail_message('id' => 'm1')],
                             '@odata.deltaLink' => 'https://g/delta?$deltatoken=d1' } }
  end

  def test_sync_default_store
    with_temp_config do |dir|
      result = run_mail(%w[sync --no-login], stubs: sync_stubs)

      assert_equal 0, result[:code]
      root = File.join(dir, 'data', 'teems', 'sync', 'mail', 'Inbox')

      assert_includes result[:stdout], "Syncing Inbox -> #{root}"
      assert_includes result[:stdout], '1 new, 0 updated, 0 unchanged, 0 existing files adopted, 0 removed from folder'
      assert_equal 2, Dir.children(root).length
      assert_match(/receivedDateTime ge /, result[:calls].find do |call|
        call[:path].end_with?('delta')
      end[:params]['$filter'])
      assert_equal '700', format('%o', File.stat(root).mode & 0o777)
    end
  end

  def test_sync_dir_folders_since_all_and_json
    with_temp_config do |dir|
      target = File.join(dir, 'Mail')
      stubs = sync_stubs.merge('/mailFolders/archive' => sample_mail_folder('Archive'))
      result = run_mail(['sync', 'Inbox', '--folder', 'archive', '--dir', target, '--since', 'all', '--json',
                         '--attachments', '-q'], stubs: stubs)

      assert_equal 0, result[:code]
      assert_equal %w[Archive Inbox], Dir.children(target).sort
      assert_equal %w[Archive Inbox], JSON.parse(result[:stdout]).keys.sort
      refute(result[:calls].any? { |call| call.dig(:params, '$filter') })
    end
  end

  def test_sync_json_prints_only_json
    with_temp_config do
      result = run_mail(%w[sync --json], stubs: sync_stubs)

      assert_equal 0, result[:code]
      assert_equal ['Inbox'], JSON.parse(result[:stdout]).keys
    end
  end

  def test_sync_reports_a_failed_folder_and_syncs_the_rest
    with_temp_config do
      result = capture_output do |output|
        runner = configured_runner(output: output)
        sync_stubs.each { |path, response| runner.api_client.stub(path, response) }
        unavailable = Teems::ApiError.new('HTTP 503: Unavailable', status_code: 503)
        runner.api_client.stub_error('/mailFolders/archive', unavailable)
        @code = Teems::Commands::Mail.new(%w[sync archive Inbox --json], runner: runner).execute
      end

      assert_equal 1, @code
      assert_equal ['Inbox'], JSON.parse(result[:stdout]).keys
      assert_includes result[:stderr], 'archive: HTTP 503: Unavailable'
    end
  end

  def test_sync_leaves_expired_tokens_to_the_login_retry
    with_temp_config do
      capture_output do |output|
        runner = configured_runner(output: output)
        extractor = Teems::TestHelpers::SilentOnlyExtractor.new
        runner.define_singleton_method(:token_extractor) { |**| extractor }
        runner.api_client.stub('/mailFolders/inbox', sample_mail_folder)
        runner.api_client.stub_error('/messages/delta', Teems::ApiError.new('Invalid token', status_code: 401))

        error = assert_raises(Teems::ApiError) { Teems::Commands::Mail.new(%w[sync --no-login], runner: runner).execute }
        assert_equal 'Re-authentication failed', error.message
        assert_equal 1, extractor.silent_calls
      end
    end
  end

  def test_sync_rejects_bad_since
    with_temp_config do
      result = run_mail(%w[sync --since soon])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], '--since must be a number of days or "all"'
    end
  end

  def test_sync_skips_when_locked
    with_temp_config do |dir|
      state = File.join(dir, 'state', 'teems')
      FileUtils.mkdir_p(state)
      File.open(File.join(state, 'mail-sync.lock'), File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        result = run_mail(%w[sync], stubs: sync_stubs)

        assert_equal 0, result[:code]
        assert_includes result[:stdout], 'Another teems mail sync is running'
      end
    end
  end

  MAIL_ID = Teems::SampleData::MAIL_ID
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/ClassLength
