# frozen_string_literal: true

require 'test_helper'

# Tests for the messages command
module MessagesCommandTests
  # Shared helpers for running message commands
  module Helpers
    def run_messages(args, stubs: {})
      out = StringIO.new
      err = StringIO.new
      with_temp_config do
        output = Teems::Formatters::Output.new(io: out, err: err, color: false)
        runner = configured_runner(output: output)
        stubs.each { |path, resp| runner.api_client.stub(path, resp) }
        Teems::Commands::Messages.new(args, runner: runner).execute
      end
      { stdout: out.string, stderr: err.string }
    end

    def run_messages_with_url(url)
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        Teems::Commands::Messages.new([url], runner: runner).execute
        runner
      end
    end
  end

  # Tests for auth, target requirement, and help display
  class BasicTest < Minitest::Test
    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          runner = unconfigured_runner(output: output)
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_requires_target
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new([], runner: runner).execute
        end
        assert_match(/Target required/, result[:stderr])
      end
    end

    def test_shows_help_with_help_flag
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new(['--help'], runner: runner).execute
        end
        stdout = result[:stdout]
        assert_match(/teems messages/, stdout)
        assert_match(/USAGE:/, stdout)
      end
    end

    def test_help_includes_url_example
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new(['--help'], runner: runner).execute
        end
        assert_match(%r{https://teams.microsoft.com}, result[:stdout])
      end
    end

    def test_help_includes_team_option
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Messages.new(['--help'], runner: runner).execute
        end
        assert_match(/--team/, result[:stdout])
      end
    end

    def test_parses_team_option_short
      with_temp_config do
        runner = configured_runner
        cmd = Teems::Commands::Messages.new(['-t', 'team-123', '19:abc@thread.v2'], runner: runner)
        assert_equal 'team-123', cmd.options[:team_id]
      end
    end

    def test_parses_team_option_long
      with_temp_config do
        runner = configured_runner
        cmd = Teems::Commands::Messages.new(['--team', 'team-456', '19:abc@thread.v2'], runner: runner)
        assert_equal 'team-456', cmd.options[:team_id]
      end
    end
  end

  # Tests for parsing Teams URLs and extracting conversation IDs
  class UrlParsingTest < Minitest::Test
    include Helpers

    def test_accepts_teams_url
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        cmd = Teems::Commands::Messages.new(
          ['https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'],
          runner: runner
        )
        assert_equal 0, cmd.execute
      end
    end

    def test_extracts_conversation_id_from_url
      url = 'https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'
      runner = run_messages_with_url(url)
      call = runner.api_client.calls.find { |call_entry| call_entry[:path].include?('messages') }
      assert call, 'Expected messages API to be called'
      call_path = call[:path]
      conv_id_present = call_path.include?('19:abc@thread.v2') || call_path.include?('19%3Aabc%40thread.v2')
      assert conv_id_present, "Expected path to contain conversation ID, got: #{call_path}"
    end

    def test_extracts_team_id_from_channel_url
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        url = 'https://teams.microsoft.com/l/message/19:abc@thread.tacv2/123?context=%7B%22contextType%22%3A%22channel%22%2C%22teamId%22%3A%22team-uuid%22%7D'
        cmd = Teems::Commands::Messages.new([url], runner: runner)
        cmd.execute
        assert_equal 'team-uuid', cmd.options[:team_id]
      end
    end

    def test_rejects_invalid_teams_url
      result = run_messages(['https://teams.microsoft.com/l/invalid/path'])
      assert_match(/Invalid Teams URL format/, result[:stderr])
    end

    def test_rejects_non_teams_https_url
      result = run_messages(['https://example.com/l/message/19:abc@thread.v2/123'])
      assert_match(/Invalid Teams URL format/, result[:stderr])
    end

    def test_regular_conversation_id_still_works
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', { 'messages' => [] })
        cmd = Teems::Commands::Messages.new(['19:abc123@thread.v2'], runner: runner)
        assert_equal 0, cmd.execute
      end
    end

    def test_url_with_verbose_shows_debug
      with_temp_config do
        err = StringIO.new
        output = Teems::Formatters::Output.new(io: StringIO.new, err: err, color: false, mode: :verbose)
        runner = configured_runner(output: output)
        runner.api_client.stub('messages', { 'messages' => [] })
        url = 'https://teams.microsoft.com/l/message/19:abc@thread.v2/123?context=%7B%22contextType%22%3A%22chat%22%7D'
        Teems::Commands::Messages.new(['-v', url], runner: runner).execute
        assert_match(/Parsed URL/, err.string)
      end
    end
  end

  # Tests for thread mode triggered by message URLs
  class ThreadModeTest < Minitest::Test
    include Helpers

    URL_WITH_MSG_ID = 'https://teams.microsoft.com/l/message/19:abc@thread.v2/' \
                      '1768935087318?context=%7B%22contextType%22%3A%22chat%22%7D'

    def test_url_fetches_specific_message_and_replies
      runner = run_thread_url(URL_WITH_MSG_ID, parent_msg, [reply_msg])
      paths = runner.api_client.calls.map { |call| call[:path] }

      assert(paths.any? { |path| path.end_with?('/1768935087318') }, 'Expected single-message fetch')
      assert(paths.any? { |path| path.end_with?('/1768935087318/replies') }, 'Expected replies fetch')
    end

    def test_thread_output_shows_parent_and_reply_separator
      result = capture_thread_output(URL_WITH_MSG_ID, parent_msg, [reply_msg])

      assert_match(/Hello parent/, result[:stdout])
      assert_match(/--- 1 reply ---/, result[:stdout])
      assert_match(/Reply text/, result[:stdout])
    end

    def test_thread_with_no_replies_omits_separator
      result = capture_thread_output(URL_WITH_MSG_ID, parent_msg, [])

      assert_match(/Hello parent/, result[:stdout])
      refute_match(/replies ---/, result[:stdout])
    end

    def test_thread_json_output_groups_parent_and_replies
      args = ['--json', URL_WITH_MSG_ID]
      result = run_thread_json(args, parent_msg, [reply_msg])
      json = JSON.parse(result[:stdout])

      assert_equal 'Jane Smith', json['parent']['sender_name']
      assert_equal 1, json['replies'].length
      assert_match(/Reply text/, json['replies'].first['content'])
    end

    def test_thread_api_error_reports_failure
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('1768935087318',
                                       Teems::ApiError.new('boom', status_code: 500))
          Teems::Commands::Messages.new([URL_WITH_MSG_ID], runner: runner).execute
        end
        assert_match(/Failed to fetch message/, result[:stderr])
      end
    end

    private

    def parent_msg
      sample_ng_msg_message.merge('id' => '1768935087318',
                                  'content' => '<p>Hello parent</p>')
    end

    def reply_msg
      sample_ng_msg_message.merge('id' => '1768935087400',
                                  'content' => '<p>Reply text</p>',
                                  'rootMessageId' => '1768935087318')
    end

    def run_thread_url(url, parent, replies)
      with_temp_config do
        runner = configured_runner
        stub_thread(runner, parent, replies)
        Teems::Commands::Messages.new([url], runner: runner).execute
        runner
      end
    end

    def capture_thread_output(url, parent, replies)
      with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_thread(runner, parent, replies)
          Teems::Commands::Messages.new([url], runner: runner).execute
        end
      end
    end

    def run_thread_json(args, parent, replies)
      with_temp_config do
        capture_output do |output|
          runner = configured_runner(output: output)
          stub_thread(runner, parent, replies)
          Teems::Commands::Messages.new(args, runner: runner).execute
        end
      end
    end

    def stub_thread(runner, parent, replies)
      api = runner.api_client
      api.stub('1768935087318/replies', { 'messages' => replies })
      api.stub('1768935087318', parent)
    end
  end

  # Tests for message display formatting and JSON output
  class DisplayTest < Minitest::Test
    include Helpers

    def test_json_output
      result = run_messages(['--json', '19:abc@thread.v2'],
                            stubs: { 'messages' => { 'messages' => [sample_ng_msg_message] } })
      json = JSON.parse(result[:stdout])
      assert_instance_of Array, json
      assert_equal 'Jane Smith', json.first['sender_name']
    end

    def test_json_output_includes_attachments
      msg = sample_ng_msg_message.merge(
        'properties' => { 'files' => '[{"fileName":"report.pdf"}]' }
      )
      result = run_messages(['--json', '19:abc@thread.v2'],
                            stubs: { 'messages' => { 'messages' => [msg] } })
      json = JSON.parse(result[:stdout])
      assert_equal 'report.pdf', json.first['attachments'].first['fileName']
    end

    def test_json_output_includes_edited_and_mentions
      result = run_messages(['--json', '19:abc@thread.v2'],
                            stubs: { 'messages' => { 'messages' => [sample_ng_msg_message] } })
      json = JSON.parse(result[:stdout])
      entry = json.first
      assert_equal false, entry['edited']
      assert_equal [], entry['mentions']
    end

    def test_displays_reactions_with_emoji
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_includes result[:stdout], "\u{1F44D}"
      end
    end

    def test_displays_important_marker
      with_temp_config do
        msg = sample_graph_message.merge('importance' => 'urgent')
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [msg] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_match(/!/, result[:stdout])
      end
    end

    def test_no_messages_found
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [] })
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/No messages found/, result[:stdout])
      end
    end

    def test_response_key_posts
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'posts' => [sample_ng_msg_message] })
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/Jane Smith/, result[:stdout])
      end
    end

    def test_response_key_value
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'value' => [sample_ng_msg_message] })
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/Jane Smith/, result[:stdout])
      end
    end

    def test_unknown_option_shows_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          cmd = Teems::Commands::Messages.new(['--bogus', '19:abc@thread.v2'], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Unknown option/, result[:stderr])
      end
    end
  end

  # Tests for channel messages, API errors, system message filtering, and edge cases
  class DisplayExtendedTest < Minitest::Test
    include Helpers

    def test_fetch_channel_messages_with_team_id
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message] })
          cmd = Teems::Commands::Messages.new(['-t', 'team-123', '19:ch@thread.tacv2'], runner: runner)
          assert_equal 0, cmd.execute
        end
        assert_match(/Jane Smith/, result[:stdout])
      end
    end

    def test_api_error_returns_error_code
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('messages', Teems::ApiError.new('Network error'))
          cmd = Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Failed to fetch/, result[:stderr])
      end
    end

    def test_channel_api_error_returns_error_code
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub_error('messages', Teems::ApiError.new('Network error'))
          cmd = Teems::Commands::Messages.new(['-t', 'team-1', '19:ch@thread.tacv2'], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Failed to fetch channel messages/, result[:stderr])
      end
    end

    def test_filters_system_messages
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_system_message, sample_ng_msg_message] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        stdout = result[:stdout]
        refute_match(/AddMember/, stdout)
        assert_match(/Jane Smith/, stdout)
      end
    end

    def test_message_without_reactions
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          runner.api_client.stub('messages', { 'messages' => [sample_graph_message] })
          Teems::Commands::Messages.new(['19:abc@thread.v2'], runner: runner).execute
        end
        assert_match(/John Doe/, result[:stdout])
      end
    end

    def test_message_nil_created_at_display
      msg = sample_graph_message.dup.tap { |msg_data| msg_data.delete('createdDateTime') }
      result = run_messages(['19:abc@thread.v2'], stubs: { 'messages' => { 'messages' => [msg] } })
      assert_match(/John Doe/, result[:stdout])
    end

    def test_json_output_with_nil_created_at
      msg = sample_graph_message.dup.tap { |msg_data| msg_data.delete('createdDateTime') }
      result = run_messages(['--json', '19:abc@thread.v2'], stubs: { 'messages' => { 'messages' => [msg] } })
      json = JSON.parse(result[:stdout])
      assert_nil json.first['created_at']
    end

    def test_displays_edited_indicator
      msg = sample_ng_msg_message.merge('properties' => { 'edittime' => '1768935090000' })
      result = run_messages(['19:abc@thread.v2'], stubs: { 'messages' => { 'messages' => [msg] } })
      assert_includes result[:stdout], '(edited)'
    end

    def test_displays_attachments
      msg = sample_ng_msg_message.merge(
        'properties' => { 'files' => '[{"fileName":"report.pdf"}]' }
      )
      result = run_messages(['19:abc@thread.v2'], stubs: { 'messages' => { 'messages' => [msg] } })
      stdout = result[:stdout]
      assert_includes stdout, 'report.pdf'
      assert_includes stdout, "\u{1F4CE}"
    end

    def test_displays_mentions_highlighted
      mentions = [{ 'mri' => '8:orgid:abc', 'displayName' => 'Jane' },
                  { 'mri' => '8:orgid:abc', 'displayName' => 'Smith' }]
      msg = sample_ng_msg_message.merge(
        'properties' => { 'mentions' => JSON.generate(mentions) }
      )
      result = run_messages(['19:abc@thread.v2'], stubs: { 'messages' => { 'messages' => [msg] } })
      assert_includes result[:stdout], 'Jane Smith'
    end
  end

  # Tests for short hash display in output and JSON
  class ShortHashTest < Minitest::Test
    include Helpers

    def test_displays_short_hash_in_output
      result = run_messages(['19:abc@thread.v2'],
                            stubs: { 'messages' => { 'messages' => [sample_ng_msg_message] } })
      expected_hash = Digest::SHA256.hexdigest('1768935087318')[0, 6]
      assert_includes result[:stdout], expected_hash
    end

    def test_json_output_includes_short_hash
      result = run_messages(['--json', '19:abc@thread.v2'],
                            stubs: { 'messages' => { 'messages' => [sample_ng_msg_message] } })
      json = JSON.parse(result[:stdout])
      expected_hash = Digest::SHA256.hexdigest('1768935087318')[0, 6]
      assert_equal expected_hash, json.first['short_hash']
    end
  end

  # Shared download test setup helpers
  module DownloadHelpers
    include Helpers

    DRIVE_ITEM_STUB = { '@microsoft.graph.downloadUrl' => 'https://cdn.example.com/report.pdf' }.freeze

    private

    def with_download_dir(&block)
      Dir.mktmpdir('teems-dl-test') { |tmpdir| with_temp_config { block.call(tmpdir) } }
    end

    def msg_with_sharepoint_attachment
      msg_with_filename('report.pdf')
    end

    def msg_with_filename(name)
      files = [{
        'fileName' => name,
        'sharepointIds' => { 'siteId' => 's1', 'listId' => 'l1', 'listItemUniqueId' => 'i1' }
      }]
      sample_ng_msg_message.merge('properties' => { 'files' => JSON.generate(files) })
    end

    def mock_file_downloader_bytes(bytes)
      downloader = Object.new
      downloader.define_singleton_method(:download) do |_url, path|
        File.write(path, 'x' * [bytes, 100].min)
        bytes
      end
      downloader
    end

    def run_download(tmpdir, output:, downloader: nil, msg: nil)
      runner = configured_runner(output: output)
      api = runner.api_client
      api.stub('messages', { 'messages' => [msg || msg_with_sharepoint_attachment] })
      api.stub('driveItem', DRIVE_ITEM_STUB)
      cmd = Teems::Commands::Messages.new(['--download', '-o', tmpdir, '19:abc@thread.v2'], runner: runner)
      cmd.instance_variable_set(:@file_downloader, downloader) if downloader
      cmd.execute
      runner
    end

    def capture_download_in_dir(downloader: nil, msg: nil, setup: nil, &block)
      tmpdir = Dir.mktmpdir('teems-dl-test')
      setup&.call(tmpdir)
      result = with_temp_config do
        capture_output { |out| run_download(tmpdir, output: out, downloader: downloader, msg: msg) }
      end
      block&.call(tmpdir)
      result
    ensure
      FileUtils.remove_entry(tmpdir) if tmpdir
    end
  end

  # Tests for download flag parsing and no-attachment handling
  class DownloadOptionsTest < Minitest::Test
    include DownloadHelpers

    def test_parses_download_flag
      with_temp_config do
        cmd = Teems::Commands::Messages.new(['--download', '19:abc@thread.v2'], runner: configured_runner)
        assert cmd.options[:download]
      end
    end

    def test_parses_output_dir_short
      with_temp_config do
        cmd = Teems::Commands::Messages.new(['-o', '/tmp/out', '19:abc@thread.v2'], runner: configured_runner)
        assert_equal '/tmp/out', cmd.options[:output_dir]
      end
    end

    def test_parses_output_dir_long
      with_temp_config do
        cmd = Teems::Commands::Messages.new(['--output-dir', '/tmp/out', '19:abc@thread.v2'], runner: configured_runner)
        assert_equal '/tmp/out', cmd.options[:output_dir]
      end
    end

    def test_download_with_no_attachments
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message] })
          Teems::Commands::Messages.new(['--download', '19:abc@thread.v2'], runner: runner).execute
        end
        assert_includes result[:stdout], 'No downloadable attachments found'
      end
    end

    def test_download_skips_attachments_without_sharepoint_ids
      with_temp_config do
        msg = sample_ng_msg_message.merge('properties' => { 'files' => '[{"fileName":"inline.png"}]' })
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', { 'messages' => [msg] })
          Teems::Commands::Messages.new(['--download', '19:abc@thread.v2'], runner: runner).execute
        end
        assert_includes result[:stdout], 'No downloadable attachments found'
      end
    end
  end

  # Tests for download execution, size formatting, collisions, and error handling
  class DownloadExecutionTest < Minitest::Test
    include DownloadHelpers

    def test_download_resolves_and_downloads
      dl = mock_file_downloader_bytes(12)
      stdout = capture_download_in_dir(downloader: dl)[:stdout]
      assert_includes stdout, 'Downloading report.pdf'
      assert_includes stdout, 'done'
      assert_includes stdout, 'Downloaded 1 file to'
    end

    def test_download_shows_kb_size
      result = capture_download_in_dir(downloader: mock_file_downloader_bytes(1536))
      assert_includes result[:stdout], '1.5 KB'
    end

    def test_download_shows_mb_size
      result = capture_download_in_dir(downloader: mock_file_downloader_bytes(2_097_152))
      assert_includes result[:stdout], '2.0 MB'
    end

    def test_download_handles_file_collision
      pre = ->(tmpdir) { File.write(File.join(tmpdir, 'report.pdf'), 'existing') }
      capture_download_in_dir(downloader: mock_file_downloader_bytes(12), setup: pre) do |tmpdir|
        assert File.exist?(File.join(tmpdir, 'report-1.pdf'))
      end
    end

    def test_download_handles_multiple_collisions
      pre = lambda do |tmpdir|
        File.write(File.join(tmpdir, 'report.pdf'), 'existing')
        File.write(File.join(tmpdir, 'report-1.pdf'), 'existing')
      end
      capture_download_in_dir(downloader: mock_file_downloader_bytes(12), setup: pre) do |tmpdir|
        assert File.exist?(File.join(tmpdir, 'report-2.pdf'))
      end
    end

    def test_download_sanitizes_path_traversal
      dl = mock_file_downloader_bytes(12)
      evil = msg_with_filename('../../etc/evil.txt')
      capture_download_in_dir(downloader: dl, msg: evil) do |tmpdir|
        assert File.exist?(File.join(tmpdir, 'evil.txt'))
        refute File.exist?(File.join(tmpdir, '..', '..', 'etc', 'evil.txt'))
      end
    end

    def test_download_handles_api_error
      result = run_download_with_error('driveItem', Teems::ApiError.new('Not found', status_code: 404))
      assert_includes result[:stderr], 'failed'
    end

    def test_download_no_summary_when_all_fail
      result = run_download_with_error('driveItem', Teems::ApiError.new('Gone', status_code: 410))
      refute_includes result[:stdout], 'Downloaded'
    end

    def test_download_missing_download_url
      result = run_download_with_stub('driveItem', { 'name' => 'report.pdf' })
      assert_includes result[:stderr], 'failed'
    end

    private

    def run_download_with_error(path, error)
      run_download_scenario { |api| api.stub_error(path, error) }
    end

    def run_download_with_stub(path, response)
      run_download_scenario { |api| api.stub(path, response) }
    end

    def run_download_scenario(&block)
      Dir.mktmpdir('teems-dl-test') do |tmpdir|
        with_temp_config { capture_download_output(tmpdir, &block) }
      end
    end

    def capture_download_output(tmpdir)
      capture_output do |out|
        runner = configured_runner(output: out)
        api = runner.api_client
        api.stub('messages', { 'messages' => [msg_with_sharepoint_attachment] })
        yield api
        Teems::Commands::Messages.new(['--download', '-o', tmpdir, '19:abc@thread.v2'], runner: runner).execute
      end
    end
  end
end
