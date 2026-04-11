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
      '<partlist>' \
        '<part identity="8:orgid:user-uuid-1"><name>Alice</name><duration>3600</duration></part>' \
        '<part identity="8:orgid:user-uuid-2"><name>Bob</name><duration>1800</duration></part>' \
        '</partlist>'
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
                     'content' => '<partlist><part identity="8:orgid:u1"><name>Test</name>' \
                                  '<duration>30</duration></part></partlist>' }
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

    def test_transcript_flag_with_no_recordings
      result = run_meeting([thread_id, '--transcript'],
                           stubs: { 'messages' => meeting_messages_response([sample_chat_message]) })
      assert_match(/No recordings found/, result[:stderr])
    end

    def test_transcript_flag_with_recordings
      result = run_meeting([thread_id, '--transcript'],
                           stubs: { 'messages' => meeting_messages_response([sample_recording_message]) })
      assert_match(/Phase 2/, result[:stdout])
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

    def test_transcript_with_invalid_json_properties
      msg = { 'id' => '300', 'messagetype' => 'RichText/Media_CallTranscript',
              'composetime' => '2026-01-20T11:00:00.000Z',
              'content' => '<div>Transcript</div>',
              'properties' => { 'callTranscript' => 'not-valid-json' } }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([msg]) })
      assert_match(/Transcripts: 1/, result[:stdout])
    end

    def test_participant_with_empty_name_resolves_via_api
      result = run_participant_resolution do |api|
        api.stub('/v1.0/users/user-uuid-1', user_profile_response)
      end
      assert_match(/Resolved User/, result[:stdout])
    end

    def test_participant_resolution_api_error_falls_back
      result = run_participant_resolution('bad-uuid') do |api|
        api.stub_error('users/bad-uuid', Teems::ApiError.new('Not found', status_code: 404))
      end
      assert_match(/8:orgid:bad-uuid/, result[:stdout])
    end

    def test_call_event_with_nil_time
      call_msg = { 'id' => '100', 'messagetype' => 'Event/Call',
                   'composetime' => nil,
                   'content' => '<partlist><part identity="8:orgid:u1"><name>Test</name>' \
                                '<duration>60</duration></part></partlist>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([call_msg]) })
      assert_match(/Call Event/, result[:stdout])
    end

    def test_empty_participants_not_displayed
      call_msg = { 'id' => '100', 'messagetype' => 'Event/Call',
                   'composetime' => '2026-01-20T10:00:00.000Z',
                   'content' => '<partlist></partlist>' }
      result = run_meeting([thread_id],
                           stubs: { 'messages' => meeting_messages_response([call_msg]) })
      assert_match(/Call Event/, result[:stdout])
      refute_match(/Participants/, result[:stdout])
    end

    def test_non_meeting_join_url_returns_nil
      url = 'https://teams.microsoft.com/l/meetup-join/19%3Ageneral%40thread.v2/0'
      result = run_meeting([url])
      assert_match(/Could not parse meeting URL/, result[:stderr])
    end

    private

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
                     '<duration>600</duration></part></partlist>' }
    end

    def user_profile_response
      { 'id' => 'user-uuid-1', 'displayName' => 'Resolved User',
        'mail' => 'resolved@example.com', 'userPrincipalName' => 'resolved@example.com' }
    end
  end
end
