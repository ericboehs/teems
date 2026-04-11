# frozen_string_literal: true

require 'test_helper'

# Tests for the meeting command
module MeetingCommandTests
  # Mock Safari JS runner for tests
  class MockSafari
    attr_reader :navigated_urls, :executed_js

    def initialize(available: true, js_results: {})
      @available = available
      @js_results = js_results
      @navigated_urls = []
      @executed_js = []
    end

    def available? = @available

    def navigate(url)
      @navigated_urls << url
    end

    def wait_for_load(**) = nil

    def execute_js(code)
      @executed_js << code
      @js_results[code] || @js_results[:default]
    end
  end

  # Shared helpers for running meeting commands
  module Helpers
    def run_meeting(args, stubs: {})
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          stubs.each { |path, resp| runner.api_client.stub(path, resp) }
          Teems::Commands::Meeting.new(args, runner: runner).execute
        end
        result
      end
    end

    def sample_call_event_message
      { 'id' => '100', 'messagetype' => 'Event/Call',
        'composetime' => '2026-01-20T10:00:00.000Z',
        'content' => call_event_content }
    end

    def call_event_content
      '<ended/><partlist alt="" count="2">' \
        '<part identity="8:orgid:user-uuid-1"><name>8:orgid:user-uuid-1</name>' \
        '<displayName>Alice</displayName><duration>3600</duration></part>' \
        '<part identity="8:orgid:user-uuid-2"><name>8:orgid:user-uuid-2</name>' \
        '<displayName>Bob</displayName><duration>1800</duration></part>' \
        '</partlist><callId>abc-123</callId>'
    end

    def sample_recording_message
      { 'id' => '200', 'messagetype' => 'RichText/Media_CallRecording',
        'composetime' => '2026-01-20T11:00:00.000Z',
        'content' => '<a href="https://example.sharepoint.com/recording">Play</a>' }
    end

    def sample_transcript_message
      { 'id' => '300', 'messagetype' => 'RichText/Media_CallTranscript',
        'composetime' => '2026-01-20T11:00:00.000Z',
        'content' => '<div>Transcript available</div>',
        'properties' => { 'callTranscript' => '{"callId":"call-1"}' } }
    end

    def sample_chat_message
      sample_ng_msg_message
    end

    def meeting_messages_response(messages)
      { 'messages' => messages }
    end

    def thread_id
      '19:meeting_abc123@thread.v2'
    end
  end

  # Tests for auth, target requirement, and help display
  class BasicTest < Minitest::Test
    include Helpers

    def test_requires_auth
      with_temp_config do
        result = capture_output do |output|
          runner = unconfigured_runner(output: output)
          Teems::Commands::Meeting.new([thread_id], runner: runner).execute
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_requires_target
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Meeting.new([], runner: runner).execute
        end
        assert_match(/Target required/, result[:stderr])
      end
    end

    def test_shows_help_with_help_flag
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          Teems::Commands::Meeting.new(['--help'], runner: runner).execute
        end
        assert_match(/teems meeting/, result[:stdout])
        assert_match(/USAGE:/, result[:stdout])
      end
    end

    def test_unknown_option_shows_error
      with_temp_config do
        result = capture_output do |output|
          runner = configured_runner(output: output)
          cmd = Teems::Commands::Meeting.new(['--bogus', thread_id], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Unknown option/, result[:stderr])
      end
    end

    def test_parses_output_dir_short
      with_temp_config do
        runner = configured_runner
        cmd = Teems::Commands::Meeting.new(['-o', '/tmp/out', thread_id], runner: runner)
        assert_equal '/tmp/out', cmd.options[:output_dir]
      end
    end

    def test_parses_output_dir_long
      with_temp_config do
        runner = configured_runner
        cmd = Teems::Commands::Meeting.new(['--output-dir', '/tmp/out', thread_id], runner: runner)
        assert_equal '/tmp/out', cmd.options[:output_dir]
      end
    end
  end

  # Tests for target resolution (thread ID, event ID, URL)
  class TargetResolutionTest < Minitest::Test
    include Helpers

    def test_resolves_thread_id_directly
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([]) })
      assert_match(/Meeting Details/, result[:stdout])
      assert_includes result[:stdout], thread_id
    end

    def test_resolves_join_url
      url = "https://teams.microsoft.com/l/meetup-join/#{URI.encode_www_form_component(thread_id)}/0"
      result = run_meeting([url],
                           stubs: { 'messages' => meeting_messages_response([]) })
      assert_match(/Meeting Details/, result[:stdout])
    end

    def test_resolves_message_url_fallback
      url = "https://teams.microsoft.com/l/message/#{URI.encode_www_form_component(thread_id)}/123" \
            '?context=%7B%22contextType%22%3A%22chat%22%7D'
      result = run_meeting([url],
                           stubs: { 'messages' => meeting_messages_response([]) })
      assert_match(/Meeting Details/, result[:stdout])
    end

    def test_resolves_chat_url
      url = "https://teams.microsoft.com/l/chat/#{URI.encode_www_form_component(thread_id)}/conversations" \
            '?context=%7B%22contextType%22%3A%22chat%22%7D'
      result = run_meeting([url],
                           stubs: { 'messages' => meeting_messages_response([]) })
      assert_match(/Meeting Details/, result[:stdout])
    end

    def test_resolves_recap_url
      url = "https://teams.microsoft.com/l/meetingrecap?threadId=#{URI.encode_www_form_component(thread_id)}" \
            '&driveId=b%21abc&driveItemId=01XYZ'
      result = run_meeting([url],
                           stubs: { 'messages' => meeting_messages_response([]) })
      assert_match(/Meeting Details/, result[:stdout])
    end

    def test_rejects_invalid_url
      result = run_meeting(['https://example.com/invalid'])
      assert_match(/Could not parse meeting URL/, result[:stderr])
    end

    def test_resolves_event_id
      event_data = event_data_with_meeting_url
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('events', event_data)
          runner.api_client.stub('messages', meeting_messages_response([]))
          Teems::Commands::Meeting.new(['AAMkAGVmMDEzMTM4'], runner: runner).execute
        end
        assert_match(/Meeting Details/, result[:stdout])
      end
    end

    def event_data_with_meeting_url
      join_url = "https://teams.microsoft.com/l/meetup-join/#{URI.encode_www_form_component(thread_id)}/0"
      sample_event_data.merge('onlineMeeting' => { 'joinUrl' => join_url })
    end

    def test_event_without_meeting_link_errors
      event_data = sample_event_base.merge('onlineMeeting' => nil)
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('events', event_data)
          Teems::Commands::Meeting.new(['AAMkAGVmMDEzMTM4'], runner: runner).execute
        end
        assert_match(/no Teams meeting link/, result[:stderr])
      end
    end
  end

  # Tests for message classification and XML/JSON parsing
  class MessageParsingTest < Minitest::Test
    include Helpers

    def test_classifies_call_event
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([sample_call_event_message]) })
      assert_match(/Call Event/, result[:stdout])
      assert_match(/Alice/, result[:stdout])
      assert_match(/Bob/, result[:stdout])
    end

    def test_parses_participant_duration
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([sample_call_event_message]) })
      assert_match(/60 min/, result[:stdout])
      assert_match(/30 min/, result[:stdout])
    end

    def test_shows_assets_summary_with_recording
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([sample_recording_message]) })
      assert_match(/Recordings: 1/, result[:stdout])
    end

    def test_shows_assets_summary_with_transcript
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([sample_transcript_message]) })
      assert_match(/Transcripts: 1/, result[:stdout])
    end

    def test_no_call_events_shows_message
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([sample_chat_message]) })
      assert_match(/No call events found/, result[:stdout])
    end

    def test_filters_system_activity_messages
      system_msg = { 'id' => '400', 'messagetype' => 'ThreadActivity/AddMember',
                     'composetime' => '2026-01-20T10:00:00.000Z',
                     'content' => '<addmember/>' }
      result = run_meeting([thread_id, '--chat'],
                           stubs: { 'messages' => meeting_messages_response([system_msg, sample_chat_message]) })
      refute_match(/AddMember/, result[:stdout])
    end

    def test_short_duration_shows_less_than_one_min
      short_call = { 'id' => '500', 'messagetype' => 'Event/Call',
                     'composetime' => '2026-01-20T10:00:00.000Z',
                     'content' => '<partlist><part identity="8:orgid:u1"><name>8:orgid:u1</name>' \
                                  '<displayName>Test</displayName><duration>30</duration></part></partlist>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([short_call]) })
      assert_match(/< 1 min/, result[:stdout])
    end
  end

  # Tests for chat mode display
  class ChatModeTest < Minitest::Test
    include Helpers

    def test_chat_flag_shows_chat_messages
      result = run_meeting([thread_id, '--chat'],
                           stubs: { 'messages' => meeting_messages_response([sample_chat_message]) })
      assert_match(/Jane Smith/, result[:stdout])
    end

    def test_chat_flag_no_messages
      result = run_meeting([thread_id, '--chat'],
                           stubs: { 'messages' => meeting_messages_response([]) })
      assert_match(/No chat messages found/, result[:stdout])
    end
  end

  # Tests for transcript and recording stub modes
  class AssetDownloadTest < Minitest::Test
    include Helpers

    def test_transcript_flag_with_no_sharing_link
      result = run_meeting([thread_id, '--transcript'],
                           stubs: { 'messages' => meeting_messages_response([sample_chat_message]) })
      assert_match(/No recording sharing link/, result[:stderr])
    end

    def test_transcript_flag_requires_safari
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', meeting_messages_response([sample_recording_message]))
          runner.define_singleton_method(:safari_js_runner) { MockSafari.new(available: false) }
          Teems::Commands::Meeting.new([thread_id, '--transcript'], runner: runner).execute
        end
        assert_match(/Safari is required/, result[:stderr])
      end
    end

    def test_recording_flag_with_no_recordings
      result = run_meeting([thread_id, '--recording'],
                           stubs: { 'messages' => meeting_messages_response([sample_chat_message]) })
      assert_match(/No recordings found/, result[:stderr])
    end

    def test_recording_flag_with_recordings
      result = run_meeting([thread_id, '--recording'],
                           stubs: { 'messages' => meeting_messages_response([sample_recording_message]) })
      assert_match(/Phase 3/, result[:stdout])
    end
  end

  # Tests for transcript download pipeline
  class TranscriptPipelineTest < Minitest::Test
    include Helpers

    def test_transcript_embed_url_failure
      result = run_transcript(embed_response: :error)
      assert_match(/Could not get embed URL/, result[:stderr])
    end

    def test_transcript_file_info_extraction_failure
      result = run_transcript(file_info_js: 'null')
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_transcript_no_transcripts_found
      result = run_transcript(file_info_js: valid_file_info, transcript_js: '{"error":"x"}')
      assert_match(/No transcripts found/, result[:stderr])
    end

    def test_transcript_saves_file
      Dir.mktmpdir('teems-vtt') do |dir|
        result = run_transcript(file_info_js: valid_file_info, transcript_js: valid_transcript, output_dir: dir)
        assert_match(/Transcript saved/, result[:stdout])
      end
    end

    def test_transcript_uses_download_url_fallback
      transcript = '{"value":[{"downloadUrl":"https://cdn.example.com/t.vtt","name":"f.vtt"}]}'
      Dir.mktmpdir('teems-vtt') do |dir|
        result = run_transcript(file_info_js: valid_file_info, transcript_js: transcript, output_dir: dir)
        assert_match(/Transcript saved/, result[:stdout])
      end
    end

    def test_file_info_with_library_id_format
      fi = '{"libraryId":{"siteId":"d1","siteUrl":"https://sp.example.com"},"itemId":"i1"}'
      Dir.mktmpdir('teems-vtt') do |dir|
        result = run_transcript(file_info_js: fi, transcript_js: valid_transcript, output_dir: dir)
        assert_match(/Transcript saved/, result[:stdout])
      end
    end

    def test_file_info_with_sp_item_url
      fi = JSON.generate('.spItemUrl' => 'https://example.com:443/personal/user/_api/v2.0/drives/drv1/items/itm1?v=1')
      Dir.mktmpdir('teems-vtt') do |dir|
        result = run_transcript(file_info_js: fi, transcript_js: valid_transcript, output_dir: dir)
        assert_match(/Transcript saved/, result[:stdout])
      end
    end

    private

    def run_transcript(embed_response: :ok, file_info_js: nil, transcript_js: nil, output_dir: nil)
      safari = TranscriptMockSafari.new(file_info: file_info_js, transcript: transcript_js)
      with_temp_config do
        capture_output do |out|
          runner = build_transcript_runner(out, safari, embed_response)
          args = build_transcript_args(output_dir)
          execute_transcript_cmd(args, runner)
        end
      end
    end

    def build_transcript_args(output_dir)
      args = [recap_url, '--transcript']
      args.push('-o', output_dir) if output_dir
      args
    end

    def execute_transcript_cmd(args, runner)
      cmd = Teems::Commands::Meeting.new(args, runner: runner)
      cmd.define_singleton_method(:fetch_transcript_content) { |_url| 'WEBVTT' }
      cmd.execute
    end

    def build_transcript_runner(out, safari, embed_response)
      runner = configured_runner(output: out)
      runner.api_client.stub('messages', meeting_messages_response([]))
      apply_embed_stub(runner, embed_response)
      runner.define_singleton_method(:safari_js_runner) { safari }
      runner
    end

    def apply_embed_stub(runner, response)
      if response == :error
        runner.api_client.stub_error('shares', Teems::ApiError.new('Not found'))
      else
        runner.api_client.stub('shares', { 'getUrl' => 'https://embed.example.com' })
      end
    end

    def recap_url
      encoded = URI.encode_www_form_component(thread_id)
      "https://teams.microsoft.com/l/meetingrecap?threadId=#{encoded}&fileUrl=https%3A%2F%2Fsp.example.com%2Ffile"
    end

    def valid_file_info
      '{"driveId":"d1","itemId":"i1","siteUrl":"https://sp.example.com"}'
    end

    def valid_transcript
      '{"value":[{"temporaryDownloadUrl":"https://cdn.example.com/t.vtt","name":"meeting.vtt"}]}'
    end
  end

  # Tests for transcript edge cases (parsing, error paths)
  class TranscriptParsingTest < Minitest::Test
    include Helpers

    def test_parse_file_info_with_invalid_json
      result = run_transcript(file_info_js: '{invalid')
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_parse_file_info_with_missing_fields
      result = run_transcript(file_info_js: '{"driveId":"d1"}')
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_parse_file_info_with_empty_response
      result = run_transcript(file_info_js: nil)
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_parse_file_info_with_invalid_sp_item_url
      fi = JSON.generate('.spItemUrl' => 'https://example.com/not-an-api-url')
      result = run_transcript(file_info_js: fi)
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_file_info_extraction_timeout
      safari = TranscriptMockSafari.new(file_info: nil, transcript: nil, raise_on_load: true)
      with_temp_config do
        result = capture_output do |out|
          runner = build_transcript_runner(out, safari)
          Teems::Commands::Meeting.new([recap_url, '--transcript'], runner: runner).execute
        end
        assert_match(/Could not extract file info/, result[:stderr])
      end
    end

    def test_transcript_empty_fetch_result
      file_info = '{"driveId":"d1","itemId":"i1","siteUrl":"https://sp.example.com"}'
      result = run_transcript(file_info_js: file_info, transcript_js: '')
      assert_match(/No transcripts found/, result[:stderr])
    end

    def test_transcript_invalid_json_fetch
      file_info = '{"driveId":"d1","itemId":"i1","siteUrl":"https://sp.example.com"}'
      result = run_transcript(file_info_js: file_info, transcript_js: '{broken')
      assert_match(/No transcripts found/, result[:stderr])
    end

    def test_transcript_response_without_download_url
      file_info = '{"driveId":"d1","itemId":"i1","siteUrl":"https://sp.example.com"}'
      result = run_transcript(file_info_js: file_info, transcript_js: '{"value":[{"name":"t.vtt"}]}')
      assert_match(/No transcripts found/, result[:stderr])
    end

    private

    def run_transcript(file_info_js: nil, transcript_js: nil)
      safari = TranscriptMockSafari.new(file_info: file_info_js, transcript: transcript_js)
      with_temp_config do
        capture_output do |out|
          runner = build_transcript_runner(out, safari)
          Teems::Commands::Meeting.new([recap_url, '--transcript'], runner: runner).execute
        end
      end
    end

    def build_transcript_runner(out, safari)
      runner = configured_runner(output: out)
      runner.api_client.stub('messages', meeting_messages_response([]))
      runner.api_client.stub('shares', { 'getUrl' => 'https://embed.example.com' })
      runner.define_singleton_method(:safari_js_runner) { safari }
      runner
    end

    def recap_url
      encoded = URI.encode_www_form_component(thread_id)
      "https://teams.microsoft.com/l/meetingrecap?threadId=#{encoded}&fileUrl=https%3A%2F%2Fsp.example.com%2Ffile"
    end
  end

  # Safari mock with separate responses for file info and transcript fetch
  class TranscriptMockSafari < MockSafari
    def initialize(file_info: nil, transcript: nil, raise_on_load: false)
      super(js_results: {})
      @file_info = file_info
      @transcript = transcript
      @raise_on_load = raise_on_load
      @title = nil
    end

    def wait_for_load(**)
      raise Teems::Error, 'Timed out' if @raise_on_load
    end

    def execute_js(code)
      @executed_js << code
      return @file_info if code.include?('g_fileInfo')

      handle_fetch_or_title(code)
    end

    private

    def handle_fetch_or_title(code)
      if code.include?('fetch(')
        @title = @transcript
      elsif code.include?('document.title')
        code.include?('TEEMS_LOADING') ? @title = nil : @title
      end
    end
  end

  # Tests for TranscriptFormatter VTT conversion
  class TranscriptFormatterTest < Minitest::Test
    def test_converts_entries_to_vtt
      entries = [{ 'speakerDisplayName' => 'Alice', 'text' => 'Hello',
                   'startOffset' => '00:00:03.305', 'endOffset' => '00:00:05.971' }]
      vtt = Teems::Commands::TranscriptFormatter.new(entries).to_vtt
      assert_includes vtt, 'WEBVTT'
      assert_includes vtt, '<v Alice>Hello</v>'
      assert_includes vtt, '00:00:03.305 --> 00:00:05.971'
    end

    def test_multiple_entries_numbered
      entries = [
        { 'speakerDisplayName' => 'A', 'text' => 'Hi', 'startOffset' => '00:00:00.000', 'endOffset' => '00:00:01.000' },
        { 'speakerDisplayName' => 'B', 'text' => 'Hey', 'startOffset' => '00:00:01.000', 'endOffset' => '00:00:02.000' }
      ]
      vtt = Teems::Commands::TranscriptFormatter.new(entries).to_vtt
      assert_includes vtt, "1\n00:00:00.000"
      assert_includes vtt, "2\n00:00:01.000"
    end

    def test_empty_entries
      vtt = Teems::Commands::TranscriptFormatter.new([]).to_vtt
      assert_equal "WEBVTT\n\n", vtt
    end

    def test_nil_offset_defaults_to_zero
      entries = [{ 'speakerDisplayName' => 'X', 'text' => 'Y', 'startOffset' => nil, 'endOffset' => nil }]
      vtt = Teems::Commands::TranscriptFormatter.new(entries).to_vtt
      assert_includes vtt, '00:00:00.000 --> 00:00:00.000'
    end

    def test_long_offset_truncated_to_12_chars
      entries = [{ 'speakerDisplayName' => 'X', 'text' => 'Y',
                   'startOffset' => '01:00:00.0000000', 'endOffset' => '01:00:01.0000000' }]
      vtt = Teems::Commands::TranscriptFormatter.new(entries).to_vtt
      assert_includes vtt, '01:00:00.000 --> 01:00:01.000'
    end
  end

  # Tests for API error handling
  class ErrorHandlingTest < Minitest::Test
    include Helpers

    def test_api_error_fetching_messages
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub_error('messages', Teems::ApiError.new('Network error'))
          cmd = Teems::Commands::Meeting.new([thread_id], runner: runner)
          assert_equal 1, cmd.execute
        end
        assert_match(/Failed to fetch meeting messages/, result[:stderr])
      end
    end

    def test_api_error_fetching_event
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub_error('events', Teems::ApiError.new('Not found', status_code: 404))
          Teems::Commands::Meeting.new(['AAMkAGVmTest'], runner: runner).execute
        end
        assert_match(/Failed to fetch event/, result[:stderr])
      end
    end

    def test_event_with_non_meeting_join_url
      event_data = event_data_with_general_url
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('events', event_data)
          Teems::Commands::Meeting.new(['AAMkAGVmTest'], runner: runner).execute
        end
        assert_match(/Could not extract thread ID/, result[:stderr])
      end
    end

    def event_data_with_general_url
      url = 'https://teams.microsoft.com/l/meetup-join/19%3Ageneral%40thread.v2/0'
      sample_event_data.merge('onlineMeeting' => { 'joinUrl' => url })
    end

    def test_returns_zero_on_success
      with_temp_config do
        runner = configured_runner
        runner.api_client.stub('messages', meeting_messages_response([]))
        cmd = Teems::Commands::Meeting.new([thread_id], runner: runner)
        assert_equal 0, cmd.execute
      end
    end
  end

  # Tests for edge cases in parsing and display
  class EdgeCaseTest < Minitest::Test
    include Helpers

    def test_recording_without_href
      msg = { 'id' => '200', 'messagetype' => 'RichText/Media_CallRecording',
              'composetime' => '2026-01-20T11:00:00.000Z',
              'content' => '<div>No link here</div>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([msg]) })
      assert_match(/Recordings: 1/, result[:stdout])
    end

    def test_transcript_with_nil_properties
      msg = { 'id' => '300', 'messagetype' => 'RichText/Media_CallTranscript',
              'composetime' => '2026-01-20T11:00:00.000Z',
              'content' => '<div>Transcript</div>',
              'properties' => {} }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([msg]) })
      assert_match(/Transcripts: 1/, result[:stdout])
    end

    def test_transcript_with_numeric_properties
      msg = { 'id' => '300', 'messagetype' => 'RichText/Media_CallTranscript',
              'composetime' => '2026-01-20T11:00:00.000Z',
              'content' => '<div>Transcript</div>',
              'properties' => { 'callTranscript' => 42 } }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([msg]) })
      assert_match(/Transcripts: 1/, result[:stdout])
    end

    def test_transcript_with_invalid_json_properties
      msg = { 'id' => '300', 'messagetype' => 'RichText/Media_CallTranscript',
              'composetime' => '2026-01-20T11:00:00.000Z',
              'content' => '<div>Transcript</div>',
              'properties' => { 'callTranscript' => 'not-valid-json' } }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([msg]) })
      assert_match(/Transcripts: 1/, result[:stdout])
    end

    def test_call_event_with_nil_time
      call_msg = { 'id' => '100', 'messagetype' => 'Event/Call',
                   'composetime' => nil,
                   'content' => '<partlist><part identity="8:orgid:u1"><name>8:orgid:u1</name>' \
                                '<displayName>Test</displayName><duration>60</duration></part></partlist>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([call_msg]) })
      assert_match(/Call Event/, result[:stdout])
    end

    def test_empty_participants_call_event_filtered_out
      call_msg = { 'id' => '100', 'messagetype' => 'Event/Call',
                   'composetime' => '2026-01-20T10:00:00.000Z',
                   'content' => '<partlist></partlist>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([call_msg]) })
      assert_match(/No call events found/, result[:stdout])
    end

    def test_recording_without_call_id_in_content
      msg = { 'id' => '200', 'messagetype' => 'RichText/Media_CallRecording',
              'composetime' => '2026-01-20T11:00:00.000Z',
              'content' => '<a href="https://example.com/play">Play</a>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([msg]) })
      assert_match(/Recordings: 1/, result[:stdout])
    end

    def test_call_event_without_ical_uid
      call_msg = { 'id' => '100', 'messagetype' => 'Event/Call',
                   'composetime' => '2026-01-20T10:00:00.000Z',
                   'content' => '<partlist><part identity="8:orgid:u1"><name>u1</name>' \
                                '<displayName>Alice</displayName><duration>60</duration></part></partlist>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([call_msg]) })
      assert_match(/Alice/, result[:stdout])
    end

    def test_recap_url_with_non_meeting_thread_id_in_query
      url = 'https://teams.microsoft.com/l/meetingrecap?threadId=19%3Ageneral%40thread.v2'
      result = run_meeting([url])
      assert_match(/Could not parse meeting URL/, result[:stderr])
    end

    def test_non_meeting_join_url_returns_nil
      url = 'https://teams.microsoft.com/l/meetup-join/19%3Ageneral%40thread.v2/0'
      result = run_meeting([url])
      assert_match(/Could not parse meeting URL/, result[:stderr])
    end
  end

  # Tests for participant name resolution and display
  class ParticipantDisplayTest < Minitest::Test
    include Helpers

    def test_displayname_used_for_visitors
      result = run_with_participant('8:teamsvisitor:abc', 'Guest User')
      assert_match(/Guest User/, result[:stdout])
    end

    def test_displayname_preferred_over_identity_name
      result = run_with_participant('8:orgid:u1', 'Real Name')
      assert_match(/Real Name/, result[:stdout])
      refute_match(/8:orgid/, result[:stdout])
    end

    def test_empty_displayname_resolves_via_api
      result = run_participant_resolution do |api|
        api.stub('/v1.0/users/user-uuid-1', user_profile_response)
      end
      assert_match(/Resolved User/, result[:stdout])
    end

    def test_api_error_falls_back_to_identity
      result = run_participant_resolution('bad-uuid') do |api|
        api.stub_error('users/bad-uuid', Teems::ApiError.new('Not found', status_code: 404))
      end
      assert_match(/8:orgid:bad-uuid/, result[:stdout])
    end

    def test_visitor_with_empty_displayname_shows_identity
      result = run_with_participant('8:teamsvisitor:xyz', '')
      assert_match(/8:teamsvisitor:xyz/, result[:stdout])
    end

    private

    def run_with_participant(identity, display_name)
      call_msg = { 'id' => '100', 'messagetype' => 'Event/Call',
                   'composetime' => '2026-01-20T10:00:00.000Z',
                   'content' => "<partlist><part identity=\"#{identity}\">" \
                                "<name>#{identity}</name><displayName>#{display_name}</displayName>" \
                                '<duration>300</duration></part></partlist>' }
      run_meeting([thread_id], stubs: { 'messages' => meeting_messages_response([call_msg]) })
    end

    def run_participant_resolution(uuid = 'user-uuid-1')
      call_msg = empty_name_call_msg(uuid)
      with_temp_config do
        capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', meeting_messages_response([call_msg]))
          yield runner.api_client
          Teems::Commands::Meeting.new([thread_id], runner: runner).execute
        end
      end
    end

    def empty_name_call_msg(uuid)
      { 'id' => '100', 'messagetype' => 'Event/Call',
        'composetime' => '2026-01-20T10:00:00.000Z',
        'content' => "<partlist><part identity=\"8:orgid:#{uuid}\"><name></name>" \
                     '<displayName></displayName><duration>600</duration></part></partlist>' }
    end

    def user_profile_response
      { 'id' => 'user-uuid-1', 'displayName' => 'Resolved User',
        'mail' => 'resolved@example.com', 'userPrincipalName' => 'resolved@example.com' }
    end
  end

  # Tests for recap URL metadata extraction and callId filtering
  class RecapAndFilterTest < Minitest::Test
    include Helpers

    def test_recap_url_extracts_organizer
      result = run_recap_meeting do |api|
        api.stub('/v1.0/users/org-uuid', organizer_profile)
      end
      assert_match(/Organizer: Tori Compton/, result[:stdout])
    end

    def test_organizer_api_error_is_silent
      result = run_recap_meeting do |api|
        api.stub_error('users/org-uuid', Teems::ApiError.new('Not found'))
      end
      refute_match(/Organizer/, result[:stdout])
      assert_match(/Meeting Details/, result[:stdout])
    end

    def test_call_id_filters_call_events
      msgs = [call_event_with_call_id('aaa-111'), call_event_with_call_id('bbb-222')]
      result = run_recap_meeting(messages: msgs, call_id: 'aaa-111')
      assert_match(/Call Event/, result[:stdout])
      assert_equal 1, result[:stdout].scan('Call Event').length
    end

    def test_call_id_no_match_shows_all
      msgs = [call_event_with_call_id('aaa-111')]
      result = run_recap_meeting(messages: msgs, call_id: 'zzz-999')
      assert_match(/Call Event/, result[:stdout])
    end

    def test_ical_uid_no_match_shows_all
      msgs = [call_event_with_call_id('aaa-111')]
      url = build_recap_url_with_ical('no-match-ical')
      result = run_with_url(url, msgs)
      assert_match(/Call Event/, result[:stdout])
    end

    private

    def run_with_url(url, messages)
      with_temp_config do
        capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', meeting_messages_response(messages))
          Teems::Commands::Meeting.new([url], runner: runner).execute
        end
      end
    end

    def run_recap_meeting(messages: [], call_id: 'call-1')
      url = build_recap_url(call_id: call_id, organizer_id: 'org-uuid')
      with_temp_config do
        capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', meeting_messages_response(messages))
          yield runner.api_client if block_given?
          Teems::Commands::Meeting.new([url], runner: runner).execute
        end
      end
    end

    def build_recap_url(call_id:, organizer_id:)
      encoded = URI.encode_www_form_component(thread_id)
      "https://teams.microsoft.com/l/meetingrecap?threadId=#{encoded}&organizerId=#{organizer_id}&callId=#{call_id}"
    end

    def call_event_with_call_id(call_id)
      { 'id' => "evt-#{call_id}", 'messagetype' => 'Event/Call',
        'composetime' => '2026-01-20T10:00:00.000Z',
        'content' => '<partlist><part identity="8:orgid:u1"><name>8:orgid:u1</name>' \
                     '<displayName>Alice</displayName><duration>600</duration></part></partlist>' \
                     "<callId>#{call_id}</callId>" }
    end

    def build_recap_url_with_ical(ical_uid)
      encoded = URI.encode_www_form_component(thread_id)
      "https://teams.microsoft.com/l/meetingrecap?threadId=#{encoded}&iCalUid=#{ical_uid}"
    end

    def organizer_profile
      { 'id' => 'org-uuid', 'displayName' => 'Tori Compton',
        'mail' => 'tori@example.com', 'userPrincipalName' => 'tori@example.com' }
    end
  end
end
