# frozen_string_literal: true

require 'test_helper'

# Tests for the meeting command
module MeetingCommandTests
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

    def embed_html_with_file_info(json) = "<script>var g_fileInfo = #{json};</script>"
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

    def test_filters_control_typing_messages
      typing_msg = { 'id' => '401', 'messagetype' => 'Control/Typing',
                     'composetime' => '2026-01-20T10:00:00.000Z', 'content' => '' }
      result = run_meeting([thread_id, '--chat'],
                           stubs: { 'messages' => meeting_messages_response([typing_msg, sample_chat_message]) })
      assert_match(/Jane Smith/, result[:stdout])
    end

    def test_omits_bot_participants
      content = '<partlist>' \
                '<part identity="8:orgid:u1"><name>u1</name>' \
                '<displayName>Alice</displayName><duration>60</duration></part>' \
                '<part identity="28:bot-uuid"><name>28:bot-uuid</name>' \
                '<displayName>Recording Bot</displayName><duration>60</duration></part></partlist>'
      call_msg = { 'id' => '100', 'messagetype' => 'Event/Call',
                   'composetime' => '2026-01-20T10:00:00.000Z', 'content' => content }
      result = run_meeting([thread_id], stubs: { 'messages' => meeting_messages_response([call_msg]) })
      assert_match(/Alice/, result[:stdout])
      refute_match(/Recording Bot/, result[:stdout])
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

    def test_recording_flag_with_no_recordings
      result = run_meeting([thread_id, '--recording'],
                           stubs: { 'messages' => meeting_messages_response([sample_chat_message]) })
      assert_match(/No recordings found/, result[:stderr])
    end

    def test_recording_flag_without_ffmpeg
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', meeting_messages_response([sample_recording_message]))
          cmd = Teems::Commands::Meeting.new([thread_id, '--recording'], runner: runner)
          cmd.define_singleton_method(:ffmpeg?) { false }
          cmd.execute
        end
        assert_match(/ffmpeg is required/, result[:stderr])
      end
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

    def test_transcript_save_handles_write_error
      result = run_transcript(file_info_js: valid_file_info, transcript_js: valid_transcript,
                              output_dir: '/dev/null/bad')
      assert_match(/Could not save transcript/, result[:stderr])
    end

    private

    def run_transcript(embed_response: :ok, file_info_js: nil, transcript_js: nil, output_dir: nil)
      with_temp_config do
        capture_output do |out|
          runner = build_transcript_runner(out, embed_response)
          args = build_transcript_args(output_dir)
          execute_transcript_cmd(args, runner, file_info_js, transcript_js)
        end
      end
    end

    def build_transcript_args(output_dir)
      args = [recap_url, '--transcript']
      args.push('-o', output_dir) if output_dir
      args
    end

    def execute_transcript_cmd(args, runner, file_info_js, transcript_js)
      embed_html = file_info_js ? "<script>var g_fileInfo = #{file_info_js};</script>" : nil
      cmd = Teems::Commands::Meeting.new(args, runner: runner)
      cmd.define_singleton_method(:fetch_embed_page) { |_url| embed_html }
      cmd.define_singleton_method(:fetch_with_drive_token) { |_url| transcript_js }
      cmd.define_singleton_method(:fetch_transcript_content) { |_url| 'WEBVTT' }
      cmd.execute
    end

    def build_transcript_runner(out, embed_response)
      runner = configured_runner(output: out)
      runner.api_client.stub('messages', meeting_messages_response([]))
      apply_embed_stub(runner, embed_response)
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
      embed_html = file_info_js ? "<script>var g_fileInfo = #{file_info_js};</script>" : nil
      with_temp_config do
        capture_output do |out|
          runner = build_simple_runner(out)
          cmd = Teems::Commands::Meeting.new([recap_url, '--transcript'], runner: runner)
          cmd.define_singleton_method(:fetch_embed_page) { |_url| embed_html }
          cmd.define_singleton_method(:fetch_with_drive_token) { |_url| transcript_js }
          cmd.execute
        end
      end
    end

    def build_simple_runner(out)
      configured_runner(output: out).tap do |runner|
        runner.api_client.stub('messages', meeting_messages_response([]))
        runner.api_client.stub('shares', { 'getUrl' => 'https://embed.example.com' })
      end
    end

    def recap_url
      encoded = URI.encode_www_form_component(thread_id)
      "https://teams.microsoft.com/l/meetingrecap?threadId=#{encoded}&fileUrl=https%3A%2F%2Fsp.example.com%2Ffile"
    end
  end

  # Tests for transcript JSON-to-VTT conversion through the pipeline
  class TranscriptJsonConversionTest < Minitest::Test
    include Helpers

    def test_json_transcript_converts_to_vtt_with_speakers
      Dir.mktmpdir('teems-vtt') do |dir|
        result = run_json_transcript(dir)
        assert_match(/Transcript saved/, result[:stdout])
        assert_includes File.read(File.join(dir, 'meeting.vtt')), '<v Alice>'
      end
    end

    private

    def run_json_transcript(dir)
      embed = "<script>var g_fileInfo = #{valid_file_info};</script>"
      json = json_transcript
      with_temp_config do
        capture_output do |out|
          cmd = Teems::Commands::Meeting.new([recap_url, '--transcript', '-o', dir], runner: build_runner(out))
          stub_json_stubs(cmd, embed, json)
          cmd.execute
        end
      end
    end

    def stub_json_stubs(cmd, embed, json)
      transcript = valid_transcript
      cmd.define_singleton_method(:fetch_embed_page) { |_url| embed }
      cmd.define_singleton_method(:fetch_with_drive_token) { |_url| transcript }
      cmd.define_singleton_method(:fetch_transcript_content) { |_url| json }
    end

    def build_runner(out)
      configured_runner(output: out).tap do |runner|
        runner.api_client.stub('messages', meeting_messages_response([]))
        runner.api_client.stub('shares', { 'getUrl' => 'https://embed.example.com' })
      end
    end

    def json_transcript
      '{"entries":[{"speakerDisplayName":"Alice","text":"Hi","startOffset":"00:00:01.000","endOffset":"00:00:02.000"}]}'
    end

    def valid_file_info = '{"driveId":"d1","itemId":"i1","siteUrl":"https://sp.example.com"}'
    def valid_transcript = '{"value":[{"temporaryDownloadUrl":"https://cdn.example.com/t.vtt","name":"meeting.vtt"}]}'

    def recap_url
      encoded = URI.encode_www_form_component(thread_id)
      "https://teams.microsoft.com/l/meetingrecap?threadId=#{encoded}&fileUrl=https%3A%2F%2Fsp.example.com%2Ffile"
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

    def test_ical_uid_match_filters_events
      msg1 = call_event_with_ical('aaa-111', 'ical-match')
      msg2 = call_event_with_ical('bbb-222', 'ical-other')
      url = build_recap_url_with_ical('ical-match')
      result = run_with_url(url, [msg1, msg2])
      assert_equal 1, result[:stdout].scan('Call Event').length
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

    def call_event_with_ical(call_id, ical_uid)
      ical_xml = "<meetingDetails><instanceDetails><iCalUid>#{ical_uid}</iCalUid></instanceDetails></meetingDetails>"
      call_event_with_call_id(call_id).tap { |msg| msg['content'] += ical_xml }
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

  # Tests for DASH manifest parsing
  class DashManifestParserTest < Minitest::Test
    def test_parses_video_and_audio_tracks
      tracks = Teems::Commands::DashManifestParser.new(sample_mpd).parse
      assert_equal 2, tracks.length
      assert_equal 'video', tracks[0].type
      assert_equal 'audio', tracks[1].type
    end

    def test_parses_segment_template_attributes
      tracks = Teems::Commands::DashManifestParser.new(sample_mpd).parse
      video = tracks.first
      assert_equal 'video_init.mp4', video.init_url
      assert_equal 'video_$Time$.m4s', video.media_template
      assert_equal 10_000_000, video.timescale
    end

    def test_parses_segment_timeline
      tracks = Teems::Commands::DashManifestParser.new(sample_mpd).parse
      video = tracks.first
      assert_equal 3, video.segment_count
      assert_equal 0, video.segments[0].start
      assert_equal 20_000_000, video.segments[0].duration
    end

    def test_handles_repeat_attribute
      mpd = '<MPD><Period><AdaptationSet contentType="video">' \
            '<SegmentTemplate initialization="init.mp4" media="seg_$Time$.m4s" timescale="1000">' \
            '<SegmentTimeline><S t="0" d="2000" r="2"/></SegmentTimeline>' \
            '</SegmentTemplate></AdaptationSet></Period></MPD>'
      segments = Teems::Commands::DashManifestParser.new(mpd).parse.first.segments
      assert_equal 3, segments.length
      assert_equal [0, 2000, 4000], segments.map(&:start)
    end

    def test_segment_with_explicit_start_time
      mpd = '<MPD><Period><AdaptationSet contentType="video">' \
            '<SegmentTemplate initialization="i.mp4" media="s_$Time$.m4s" timescale="1000">' \
            '<SegmentTimeline><S t="0" d="1000"/><S t="5000" d="1000"/></SegmentTimeline>' \
            '</SegmentTemplate></AdaptationSet></Period></MPD>'
      segments = Teems::Commands::DashManifestParser.new(mpd).parse.first.segments
      assert_equal [0, 5000], segments.map(&:start)
    end

    def test_returns_empty_for_invalid_xml
      tracks = Teems::Commands::DashManifestParser.new('not xml').parse
      assert_empty tracks
    end

    def test_skips_adaptation_without_timeline
      mpd = '<MPD><Period><AdaptationSet contentType="video">' \
            '<SegmentTemplate initialization="i.mp4" media="s.m4s"/>' \
            '</AdaptationSet></Period></MPD>'
      tracks = Teems::Commands::DashManifestParser.new(mpd).parse
      assert_empty tracks
    end

    def test_skips_adaptation_without_segment_template
      mpd = '<MPD><Period><AdaptationSet contentType="video">' \
            '<Representation id="1" bandwidth="500000"/>' \
            '</AdaptationSet></Period></MPD>'
      tracks = Teems::Commands::DashManifestParser.new(mpd).parse
      assert_empty tracks
    end

    def test_default_timescale_is_one
      mpd = <<~XML
        <MPD><Period><AdaptationSet contentType="audio">
          <SegmentTemplate initialization="init.mp4" media="seg_$Time$.m4s">
            <SegmentTimeline><S t="0" d="1000"/></SegmentTimeline>
          </SegmentTemplate>
        </AdaptationSet></Period></MPD>
      XML
      tracks = Teems::Commands::DashManifestParser.new(mpd).parse
      assert_equal 1, tracks.first.timescale
    end

    private

    def sample_mpd
      <<~XML
        <MPD><Period>
          <BaseURL>https://cdn.example.com/media/</BaseURL>
          <AdaptationSet contentType="video">
            <SegmentTemplate initialization="video_init.mp4" media="video_$Time$.m4s" timescale="10000000">
              <SegmentTimeline>
                <S t="0" d="20000000"/>
                <S d="20000000"/>
                <S d="20000000"/>
              </SegmentTimeline>
            </SegmentTemplate>
          </AdaptationSet>
          <AdaptationSet contentType="audio">
            <SegmentTemplate initialization="audio_init.mp4" media="audio_$Time$.m4s" timescale="44100">
              <SegmentTimeline>
                <S t="0" d="88200"/>
                <S d="88200"/>
              </SegmentTimeline>
            </SegmentTemplate>
          </AdaptationSet>
        </Period></MPD>
      XML
    end
  end

  # Tests for DASH template decoding and representation handling
  class DashTemplateTest < Minitest::Test
    def test_decodes_xml_entities_and_rep_id_in_templates
      mpd = '<MPD><Period><AdaptationSet contentType="video">' \
            '<SegmentTemplate initialization="t?a=1&amp;q=$RepresentationID$" media="t?a=1&amp;t=$Time$">' \
            '<SegmentTimeline><S t="0" d="1000"/></SegmentTimeline></SegmentTemplate>' \
            '<Representation id="vcopy"/></AdaptationSet></Period></MPD>'
      track = Teems::Commands::DashManifestParser.new(mpd).parse.first
      assert_equal 't?a=1&q=vcopy', track.init_url
      assert_includes track.media_template, 'a=1&t=$Time$'
    end

    def test_adaptation_without_representation_uses_empty_rep_id
      mpd = '<MPD><Period><AdaptationSet contentType="audio">' \
            '<SegmentTemplate initialization="init_$RepresentationID$.mp4" media="s_$Time$.m4s">' \
            '<SegmentTimeline><S t="0" d="1000"/></SegmentTimeline>' \
            '</SegmentTemplate></AdaptationSet></Period></MPD>'
      track = Teems::Commands::DashManifestParser.new(mpd).parse.first
      assert_equal 'init_.mp4', track.init_url
    end

    def test_missing_initialization_attr_returns_empty_string
      mpd = '<MPD><Period><AdaptationSet contentType="video">' \
            '<SegmentTemplate media="s_$Time$.m4s" timescale="1000">' \
            '<SegmentTimeline><S t="0" d="1000"/></SegmentTimeline>' \
            '</SegmentTemplate></AdaptationSet></Period></MPD>'
      track = Teems::Commands::DashManifestParser.new(mpd).parse.first
      assert_equal '', track.init_url
    end
  end

  # Shared helpers for recording pipeline tests
  module RecordingTestHelpers
    include MeetingCommandTests::Helpers

    private

    def run_recording(opts = {})
      defaults = { messages: nil, embed_response: :ok,
                   manifest: nil, output_dir: nil, ffmpeg_success: true }
      opts = defaults.merge(opts)
      messages = opts[:messages] || [sample_recording_message]
      with_temp_config do
        capture_output do |out|
          runner = build_recording_runner(out, opts[:embed_response], messages)
          execute_recording_cmd(build_recording_args(opts[:output_dir]), runner, opts)
        end
      end
    end

    def run_no_link_recording(msg)
      with_temp_config do
        capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', meeting_messages_response([msg]))
          cmd = Teems::Commands::Meeting.new([thread_id, '--recording'], runner: runner)
          cmd.define_singleton_method(:ffmpeg?) { true }
          cmd.execute
        end
      end
    end

    def build_recording_args(output_dir)
      args = [recap_url, '--recording']
      args.push('-o', output_dir) if output_dir
      args
    end

    def execute_recording_cmd(args, runner, opts)
      cmd = Teems::Commands::Meeting.new(args, runner: runner)
      stub_recording_io(cmd, opts)
      cmd.execute
    end

    def stub_recording_io(cmd, opts)
      html = opts.key?(:embed_html) ? opts[:embed_html] : embed_html_with_file_info(valid_recording_file_info)
      manifest = opts[:manifest]
      ffmpeg_success = opts[:ffmpeg_success]
      cmd.define_singleton_method(:ffmpeg?) { true }
      cmd.define_singleton_method(:fetch_embed_page) { |_url| html }
      cmd.define_singleton_method(:fetch_manifest_content) { |_url| manifest }
      cmd.define_singleton_method(:fetch_segment) { |_url| 'FAKEDATA' }
      cmd.define_singleton_method(:run_ffmpeg) { |*a| File.binwrite(a.last, 'MP4DATA') || true if ffmpeg_success }
    end

    def build_recording_runner(out, embed_response, messages)
      configured_runner(output: out).tap do |runner|
        runner.api_client.stub('messages', meeting_messages_response(messages))
        apply_recording_embed_stub(runner, embed_response)
      end
    end

    def apply_recording_embed_stub(runner, response)
      if response == :error
        runner.api_client.stub_error('shares', Teems::ApiError.new('Not found'))
      else
        runner.api_client.stub('shares', { 'getUrl' => 'https://embed.example.com' })
      end
    end

    def recap_url
      encoded = URI.encode_www_form_component(thread_id)
      "https://teams.microsoft.com/l/meetingrecap?threadId=#{encoded}" \
        '&fileUrl=https%3A%2F%2Fsp.example.com%2Frecording'
    end

    def valid_recording_file_info
      '{"driveId":"d1","itemId":"i1","siteUrl":"https://sp.example.com",' \
        '".transformUrl":"https://cdn.example.com/transform/thumbnail?tempauth=xyz","name":"rec.mp4"}'
    end

    def sample_manifest
      <<~XML
        <MPD><Period>
          <BaseURL>https://cdn.example.com/media/</BaseURL>
          <AdaptationSet contentType="video">
            <SegmentTemplate initialization="v_init.mp4" media="v_$Time$.m4s" timescale="1000">
              <SegmentTimeline><S t="0" d="2000"/><S d="2000"/></SegmentTimeline>
            </SegmentTemplate>
          </AdaptationSet>
          <AdaptationSet contentType="audio">
            <SegmentTemplate initialization="a_init.mp4" media="a_$Time$.m4s" timescale="1000">
              <SegmentTimeline><S t="0" d="2000"/><S d="2000"/></SegmentTimeline>
            </SegmentTemplate>
          </AdaptationSet>
        </Period></MPD>
      XML
    end

    def absolute_url_manifest
      <<~XML
        <MPD><Period>
          <AdaptationSet contentType="video">
            <SegmentTemplate initialization="https://cdn.example.com/v_init.mp4" media="https://cdn.example.com/v_$Time$.m4s" timescale="1000">
              <SegmentTimeline><S t="0" d="2000"/></SegmentTimeline>
            </SegmentTemplate>
          </AdaptationSet>
          <AdaptationSet contentType="audio">
            <SegmentTemplate initialization="https://cdn.example.com/a_init.mp4" media="https://cdn.example.com/a_$Time$.m4s" timescale="1000">
              <SegmentTimeline><S t="0" d="2000"/></SegmentTimeline>
            </SegmentTemplate>
          </AdaptationSet>
        </Period></MPD>
      XML
    end
  end

  # Tests for recording download error paths
  class RecordingErrorTest < Minitest::Test
    include RecordingTestHelpers

    def test_recording_no_sharing_link
      msg = { 'id' => '200', 'messagetype' => 'RichText/Media_CallRecording',
              'composetime' => '2026-01-20T11:00:00.000Z',
              'content' => '<div>No link here</div>' }
      result = run_no_link_recording(msg)
      assert_match(/No recordings found/, result[:stderr])
    end

    def test_recording_embed_url_failure
      result = run_recording(embed_response: :error)
      assert_match(/Could not get embed URL/, result[:stderr])
    end

    def test_recording_embed_html_fetch_failure
      result = run_recording(embed_html: nil)
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_recording_file_info_extraction_failure
      result = run_recording(embed_html: '<html>no file info</html>')
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_recording_file_info_without_transform_url
      html = embed_html_with_file_info('{"name":"test.mp4"}')
      result = run_recording(embed_html: html)
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_recording_manifest_fetch_failure
      result = run_recording(manifest: nil)
      assert_match(/Could not fetch DASH manifest/, result[:stderr])
    end

    def test_recording_manifest_missing_tracks
      result = run_recording(manifest: '<MPD></MPD>')
      assert_match(%r{No video/audio tracks found}, result[:stderr])
    end

    def test_recording_file_info_invalid_json
      result = run_recording(embed_html: '<html><script>var g_fileInfo = {broken;</script></html>')
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_recording_file_info_no_transform_url
      html = embed_html_with_file_info('{"name":"test.mp4"}')
      result = run_recording(embed_html: html)
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_recording_with_non_json_file_info
      html = '<html><script>var g_fileInfo = "just a string";</script></html>'
      result = run_recording(embed_html: html)
      assert_match(/Could not extract file info/, result[:stderr])
    end

    def test_recording_returns_error_exit_code_on_failure
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('messages', meeting_messages_response([sample_chat_message]))
          assert_equal 1, Teems::Commands::Meeting.new([thread_id, '--recording'], runner: runner).execute
        end
        assert_match(/No recordings found/, result[:stderr])
      end
    end
  end

  # Tests for recording download success paths
  class RecordingSuccessTest < Minitest::Test
    include RecordingTestHelpers

    def test_recording_full_pipeline_success
      Dir.mktmpdir('teems-rec') do |dir|
        result = run_recording(manifest: sample_manifest, output_dir: dir)
        assert_match(/Recording saved/, result[:stdout])
        assert File.exist?(File.join(dir, 'recording.mp4'))
      end
    end

    def test_recording_ffmpeg_merge_failure
      Dir.mktmpdir('teems-rec') do |dir|
        result = run_recording(manifest: sample_manifest, output_dir: dir, ffmpeg_success: false)
        assert_match(/ffmpeg merge failed/, result[:stderr])
      end
    end

    def test_recording_embeds_subtitle_when_vtt_present
      Dir.mktmpdir('teems-rec') do |dir|
        File.write(File.join(dir, 'transcript.vtt'), "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\nHello")
        result = run_recording(manifest: sample_manifest, output_dir: dir)
        assert_match(/Embedding transcript as subtitle/, result[:stdout])
      end
    end

    def test_recording_with_absolute_segment_urls
      Dir.mktmpdir('teems-rec') do |dir|
        result = run_recording(manifest: absolute_url_manifest, output_dir: dir)
        assert_match(/Recording saved/, result[:stdout])
      end
    end

    def test_recording_manifest_without_base_url
      Dir.mktmpdir('teems-rec') do |dir|
        result = run_recording(manifest: sample_manifest.gsub(%r{<BaseURL>[^<]+</BaseURL>}, ''), output_dir: dir)
        assert_match(/Recording saved/, result[:stdout])
      end
    end
  end

  # Tests for recording edge cases (subtitle embedding, combined mode)
  class RecordingEdgeCaseTest < Minitest::Test
    include RecordingTestHelpers

    def test_recording_subtitle_embed_failure_still_succeeds
      Dir.mktmpdir('teems-rec') do |dir|
        File.write(File.join(dir, 'transcript.vtt'), 'WEBVTT')
        result = run_recording_subtitle_fail(dir)
        assert_match(/Recording saved/, result[:stdout])
      end
    end

    def test_recording_with_transcript_downloads_both
      Dir.mktmpdir('teems-rec') do |dir|
        result = run_combined_recording(dir)
        assert_match(/Transcript saved/, result[:stdout])
        assert_match(/Recording saved/, result[:stdout])
        assert_match(/Embedding transcript/, result[:stdout])
      end
    end

    def test_recording_warns_when_transcript_fails
      Dir.mktmpdir('teems-rec') do |dir|
        result = run_combined_recording(dir, transcript_fail: true)
        assert_match(/Transcript download failed/, result[:stderr])
        assert_match(/Recording saved/, result[:stdout])
      end
    end

    private

    def run_recording_subtitle_fail(dir)
      with_temp_config do
        capture_output do |out|
          runner = build_recording_runner(out, :ok, [sample_recording_message])
          cmd = Teems::Commands::Meeting.new(build_recording_args(dir), runner: runner)
          stub_subtitle_fail(cmd)
          cmd.execute
        end
      end
    end

    def stub_subtitle_fail(cmd)
      stub_combined(cmd)
      call_count = 0
      cmd.define_singleton_method(:run_ffmpeg) do |*a|
        call_count += 1
        call_count == 1 ? File.binwrite(a.last, 'MP4') || true : false
      end
    end

    def run_combined_recording(dir, transcript_fail: false)
      with_temp_config do
        capture_output do |out|
          runner = build_combined_runner(out, transcript_fail)
          cmd = Teems::Commands::Meeting.new([recap_url, '--recording', '--transcript', '-o', dir], runner: runner)
          stub_combined(cmd)
          cmd.execute
        end
      end
    end

    def build_combined_runner(out, transcript_fail)
      build_recording_runner(out, :ok, []).tap do |runner|
        runner.api_client.stub_transient_error('shares', Teems::ApiError.new('fail')) if transcript_fail
      end
    end

    def stub_combined(cmd)
      manifest = sample_manifest
      embed = embed_html_with_file_info(valid_recording_file_info)
      transcript_list = '{"value":[{"temporaryDownloadUrl":"https://cdn.example.com/t.vtt","name":"t.vtt"}]}'
      cmd.define_singleton_method(:ffmpeg?) { true }
      cmd.define_singleton_method(:fetch_embed_page) { |_url| embed }
      cmd.define_singleton_method(:fetch_with_drive_token) { |_url| transcript_list }
      cmd.define_singleton_method(:fetch_manifest_content) { |_url| manifest }
      cmd.define_singleton_method(:fetch_segment) { |_url| 'FAKEDATA' }
      cmd.define_singleton_method(:fetch_transcript_content) { |_url| 'WEBVTT' }
      cmd.define_singleton_method(:run_ffmpeg) { |*a| File.binwrite(a.last, 'MP4DATA') || true }
    end
  end

  # Tests embed page fetch with real HTTP (local server)
  class EmbedPageFetchTest < Minitest::Test
    def test_fetch_embed_page_returns_body_on_success
      with_local_server('200 OK', 'OK') do |port|
        result = parser.send(:fetch_embed_page, "http://127.0.0.1:#{port}/")
        assert_equal 'OK', result
      end
    end

    def test_fetch_embed_page_returns_nil_on_error
      with_local_server('404 Not Found', '') do |port|
        assert_nil parser.send(:fetch_embed_page, "http://127.0.0.1:#{port}/")
      end
    end

    def test_fetch_manifest_content_success
      obj = recording_obj
      with_local_server('200 OK', 'MPD') { |port| assert_equal 'MPD', obj.send(:fetch_manifest_content, "http://127.0.0.1:#{port}/") }
    end

    def test_fetch_manifest_content_failure
      obj = recording_obj
      with_local_server('500 Error', '') { |port| assert_nil obj.send(:fetch_manifest_content, "http://127.0.0.1:#{port}/") }
    end

    def test_fetch_with_drive_token_success
      obj = transcript_obj
      with_local_server('200 OK', '{}') { |port| assert_equal '{}', obj.send(:fetch_with_drive_token, "http://127.0.0.1:#{port}/") }
    end

    def test_fetch_with_drive_token_failure
      obj = transcript_obj
      with_local_server('403 Forbidden', '') { |port| assert_nil obj.send(:fetch_with_drive_token, "http://127.0.0.1:#{port}/") }
    end

    private

    def parser
      build_obj(Teems::Commands::EmbedPageParser)
    end

    def recording_obj
      build_obj(Teems::Commands::MeetingRecording)
    end

    def transcript_obj
      build_obj(Teems::Commands::MeetingTranscript).tap do |o|
        o.instance_variable_set(:@transcript_info, { drive_token: nil })
      end
    end

    def build_obj(mod)
      Object.new.tap { |o| o.extend(mod) }.tap { |o| o.define_singleton_method(:debug) { |_| nil } }
    end

    def with_local_server(status, body)
      server = TCPServer.new('127.0.0.1', 0)
      Thread.new { serve_one(server, status, body) }
      yield server.addr[1]
    ensure
      server&.close
    end

    def serve_one(server, status, body)
      client = server.accept
      client.gets
      client.print "HTTP/1.1 #{status}\r\nContent-Length: #{body.length}\r\n\r\n#{body}"
      client.close
    end
  end

  # Unit tests for EmbedPageParser and SegmentDownloader
  class EmbedParserUnitTest < Minitest::Test
    def test_parse_embed_file_info_extracts_transform_url
      html = '<script>var g_fileInfo = {"driveId":"d1","itemId":"i1","siteUrl":"https://sp.example.com",' \
             '".transformUrl":"https://cdn.example.com/t"};</script>'
      result = parser_instance.send(:parse_embed_file_info, html)
      assert_equal 'https://cdn.example.com/t', result[:transform_url]
    end

    def test_parse_embed_file_info_returns_nil_without_ids
      assert_nil parser_instance.send(:parse_embed_file_info, '<script>var g_fileInfo = {"name":"r"};</script>')
    end

    def test_parse_embed_file_info_returns_nil_for_invalid_json
      assert_nil parser_instance.send(:parse_embed_file_info, '<script>var g_fileInfo = {broken;</script>')
    end

    def test_parse_embed_file_info_returns_nil_without_g_file_info
      assert_nil parser_instance.send(:parse_embed_file_info, '<html>no data</html>')
    end

    def test_parse_embed_file_info_with_sp_item_url
      html = '<script>var g_fileInfo = {".spItemUrl":"https://sp.example.com/s/_api/v2.0/drives/d1/items/i1?t=1"};</script>'
      assert_equal 'd1', parser_instance.send(:parse_embed_file_info, html)[:drive_id]
    end

    def test_resolve_url_returns_absolute_url_unchanged
      obj = Object.new.tap { |o| o.extend(Teems::Commands::SegmentDownloader) }
      assert_equal 'https://other.com/i.mp4', obj.send(:resolve_url, 'https://base.com/d/f', 'https://other.com/i.mp4')
    end

    def test_resolve_url_joins_relative_path
      obj = Object.new.tap { |o| o.extend(Teems::Commands::SegmentDownloader) }
      assert_equal 'https://base.com/dir/seg.m4s', obj.send(:resolve_url, 'https://base.com/dir/file', 'seg.m4s')
    end

    private

    def parser_instance
      Object.new.tap do |o|
        o.extend(Teems::Commands::EmbedPageParser)
        o.define_singleton_method(:debug) { |_| nil }
      end
    end
  end
end
