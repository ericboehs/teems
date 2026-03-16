# frozen_string_literal: true

require 'test_helper'

# Tests for the activity command
module ActivityCommandTests
  # Shared helpers for building and running activity test scenarios
  module Helpers
    private

    def run_activity(args, conversations)
      exit_code = nil
      result = with_temp_config do
        capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub('48%3Anotifications', { 'messages' => conversations })
          exit_code = Teems::Commands::Activity.new(args, runner: runner).execute
        end
      end
      result.merge(exit_code: exit_code)
    end

    def calendar_activity(overrides = {})
      behalf = overrides.delete(:behalf)
      location = overrides.delete(:location)
      ctx = { 'templateParameters' => behalf ? "{\"behalfOf\":\"#{behalf}\"}" : '{}' }
      ctx['location'] = location if location
      build_activity({ type: 'msGraph', subtype: 'privateMeetingCreated',
                       who: 'Alice', preview: 'Standup', context: ctx }.merge(overrides))
    end

    def mention_activity(overrides = {})
      build_activity({ type: 'mentionInChat', subtype: 'person',
                       who: 'Bob', preview: 'Hey!', topic: 'Chat Group' }.merge(overrides))
    end

    def reaction_activity(overrides = {})
      build_activity({ type: 'reactionInChat', subtype: 'like',
                       who: 'Carol', preview: 'Nice!', topic: 'Chat Group' }.merge(overrides))
    end

    def build_activity(attrs)
      time = attrs.fetch(:time, '2026-01-20T12:00:00Z')
      activity = { 'activityType' => attrs[:type], 'activitySubtype' => attrs[:subtype],
                   'sourceUserImDisplayName' => attrs[:who], 'messagePreview' => attrs[:preview],
                   'sourceThreadTopic' => attrs[:topic], 'activityTimestamp' => time,
                   'activityContext' => attrs.fetch(:context, {}) }
      { 'composetime' => time, 'messagetype' => 'Text', 'type' => 'Message',
        'properties' => { 'isread' => attrs.fetch(:read, true).to_s, 'activity' => activity } }
    end
  end

  # Tests for help, auth, empty activity, and error handling
  class BasicTest < Minitest::Test
    include Helpers

    def test_shows_help
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          Teems::Commands::Activity.new(['--help'], runner: runner).execute
        end
        stdout = result[:stdout]
        assert_match(/teems activity/, stdout)
        assert_match(/--unread/, stdout)
      end
    end

    def test_requires_auth
      with_temp_config do
        result = capture_output do |out|
          store = mock_token_store(configured: false)
          runner = Teems::Runner.new(output: out, token_store: store)
          assert_equal 1, Teems::Commands::Activity.new([], runner: runner).execute
        end
        assert_match(/Not authenticated/, result[:stderr])
      end
    end

    def test_empty_activity
      result = run_activity([], [])
      assert_equal 0, result[:exit_code]
      assert_match(/No activity found/, result[:stdout])
    end

    def test_api_error
      with_temp_config do
        result = capture_output do |out|
          runner = configured_runner(output: out)
          runner.api_client.stub_error('48%3Anotifications', Teems::ApiError.new('Network error'))
          assert_equal 1, Teems::Commands::Activity.new([], runner: runner).execute
        end
        assert_match(/Failed to fetch activity/, result[:stderr])
      end
    end

    def test_skips_messages_without_activity
      msg = { 'composetime' => '2026-01-20T12:00:00Z', 'properties' => {} }
      result = run_activity([], [msg])
      assert_match(/No activity found/, result[:stdout])
    end
  end

  # Tests for activity display formatting and content rendering
  class DisplayTest < Minitest::Test
    include Helpers

    def test_shows_mention
      result = run_activity([], [mention_activity(who: 'Bob Smith', preview: 'Hey there')])
      stdout = result[:stdout]
      assert_match(/Bob Smith/, stdout)
      assert_match(/mentioned you/, stdout)
      assert_match(/Hey there/, stdout)
    end

    def test_shows_reaction
      result = run_activity([], [reaction_activity(who: 'Carol', preview: 'Nice work!')])
      stdout = result[:stdout]
      assert_match(/Carol/, stdout)
      assert_match(/reacted/, stdout)
      assert_match(/Nice work!/, stdout)
    end

    def test_shows_source_topic
      result = run_activity([], [mention_activity(topic: 'My Chat Group')])
      assert_match(/My Chat Group/, result[:stdout])
    end

    def test_shows_calendar_canceled
      result = run_activity([], [calendar_activity(subtype: 'privateMeetingCanceled', preview: 'Standup')])
      stdout = result[:stdout]
      assert_match(/canceled/, stdout)
      assert_match(/Standup/, stdout)
    end

    def test_shows_calendar_invited
      result = run_activity([], [calendar_activity(subtype: 'privateMeetingCreated')])
      assert_match(/invited you/, result[:stdout])
    end

    def test_shows_on_behalf_of
      result = run_activity([], [calendar_activity(behalf: 'Big Boss')])
      assert_match(/on behalf of Big Boss/, result[:stdout])
    end

    def test_shows_everyone_mention
      result = run_activity([], [mention_activity(subtype: 'everyone')])
      assert_match(/mentioned Everyone/, result[:stdout])
    end

    def test_truncates_long_preview
      long = 'A' * 200
      result = run_activity([], [mention_activity(preview: long)])
      stdout = result[:stdout]
      assert_match(/A{120}\.\.\./, stdout)
      refute_match(/A{121}/, stdout)
    end

    def test_unread_marker
      result = run_activity([], [mention_activity(read: false)])
      assert_match(/\*.*mentioned you/, result[:stdout])
    end

    def test_read_no_marker
      result = run_activity([], [mention_activity(read: true)])
      refute_match(/\*.*mentioned you/, result[:stdout])
    end
  end

  # Tests for calendar meeting time display in activity items
  class CalendarTimeTest < Minitest::Test
    include Helpers

    def test_shows_meeting_time_range
      loc = '<DateTimeRange><StartDateTime>2026-01-20T14:00:00Z</StartDateTime>' \
            '<EndDateTime>2026-01-20T15:00:00Z</EndDateTime></DateTimeRange>'
      result = run_activity([], [calendar_activity(location: loc)])
      assert_match(/Jan 20/, result[:stdout])
    end

    def test_shows_multi_day_range
      loc = '<DateTimeRange><StartDateTime>2026-03-16T00:00:00Z</StartDateTime>' \
            '<EndDateTime>2026-03-18T00:00:00Z</EndDateTime></DateTimeRange>'
      result = run_activity([], [calendar_activity(location: loc)])
      assert_match(/Mar 1[56].*Mar 1[78]/, result[:stdout])
    end
  end

  # Tests for unread filtering, ordering, and JSON output
  class FilterTest < Minitest::Test
    include Helpers

    def test_unread_filter
      msgs = [mention_activity(who: 'Unread', read: false),
              mention_activity(who: 'Read', read: true, time: '2026-01-20T11:00:00Z')]
      result = run_activity(['--unread'], msgs)
      stdout = result[:stdout]
      assert_match(/Unread/, stdout)
      refute_match(/\bRead\b/, stdout)
    end

    def test_unread_filter_empty
      result = run_activity(['--unread'], [mention_activity(read: true)])
      assert_match(/No activity found/, result[:stdout])
    end

    def test_reverse_chronological_order
      early = mention_activity(who: 'Early', time: '2026-01-20T08:00:00Z')
      late = mention_activity(who: 'Late', time: '2026-01-20T16:00:00Z')
      result = run_activity([], [early, late])
      stdout = result[:stdout]
      late_pos = stdout.index('Late')
      early_pos = stdout.index('Early')
      assert late_pos < early_pos, 'Expected Late before Early'
    end

    def test_json_output
      result = run_activity(['--json'], [mention_activity(who: 'TestUser')])
      json = JSON.parse(result[:stdout])
      assert_instance_of Array, json
      first_item = json.first
      assert_equal 'TestUser', first_item['who']
      assert_equal 'mentionInChat', first_item['type']
      refute first_item.key?('raw_activity')
    end
  end
end
