# frozen_string_literal: true

require 'test_helper'

module WhoCommandTests
  PROFILE_DATA = {
    'id' => 'user-uuid-123', 'displayName' => 'John Doe',
    'mail' => 'john.doe@example.com', 'userPrincipalName' => 'john.doe@example.onmicrosoft.com',
    'jobTitle' => 'Senior Engineer', 'department' => 'Engineering',
    'officeLocation' => 'Building A, Room 302',
    'businessPhones' => ['+1 (555) 123-4567'], 'mobilePhone' => '+1 (555) 987-6543'
  }.freeze

  PRESENCE_AVAILABLE = [{ 'presence' => { 'availability' => 'Available' } }].freeze

  SCHEDULE_RESPONSE = {
    'value' => [{
      'availabilityView' => '00002222000011110000000000000000',
      'workingHours' => {
        'startTime' => '09:00:00.0000000', 'endTime' => '17:00:00.0000000',
        'timeZone' => { 'name' => 'Central Standard Time' },
        'daysOfWeek' => %w[monday tuesday wednesday thursday friday]
      }
    }]
  }.freeze

  NOON_TODAY = Time.new(2026, 3, 16, 12, 0, 0).freeze

  module Helpers
    private

    def run_who(args = [])
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        yield runner if block_given?
        exit_code = Teems::Commands::Who.new(args, runner: runner).execute
      end
      result.merge(exit_code: exit_code)
    end

    def run_who_at_noon(args, stubs)
      Time.stub(:now, NOON_TODAY) do
        run_who_with_stub(args, stubs)
      end
    end

    def run_who_with_stub(args, stubs)
      run_who(args) { |runner| stub_api(runner, stubs) }
    end

    def stub_api(runner, stubs)
      stubs.each { |path, response| runner.api_client.stub(path, response) }
    end

    def search_results(profiles)
      { 'value' => profiles }
    end

    def full_stubs
      { 'calendar/getSchedule' => SCHEDULE_RESPONSE, '/v1.0/me' => PROFILE_DATA,
        'presence' => PRESENCE_AVAILABLE }
    end

    def early_start_schedule
      { 'value' => [{
        'availabilityView' => '0000222200001111000000000000000000000000',
        'workingHours' => { 'startTime' => '08:00:00.0000000', 'endTime' => '17:00:00.0000000',
                            'timeZone' => { 'name' => 'Central Standard Time' } }
      }] }
    end
  end

  class BasicTest < Minitest::Test
    include Helpers

    def test_shows_help_with_help_flag
      result = run_who(['--help'])

      assert_match(/teems who/, result[:stdout])
      assert_match(/USAGE:/, result[:stdout])
    end

    def test_requires_auth
      result = capture_output do |output|
        store = mock_unconfigured_store
        runner = Teems::Runner.new(output: output, token_store: store)
        assert_equal 1, Teems::Commands::Who.new([], runner: runner).execute
      end
      assert_match(/Not authenticated/, result[:stderr])
    end

    def test_unknown_option_returns_error
      result = run_who(['--bogus'])

      assert_equal 1, result[:exit_code]
      assert_match(/Unknown option/, result[:stderr])
    end
  end

  class CurrentUserIdentityTest < Minitest::Test
    include Helpers

    def test_shows_name_and_email
      result = run_who_with_stub([], full_stubs)

      assert_equal 0, result[:exit_code]
      assert_match(/John Doe/, result[:stdout])
      assert_match(/john\.doe@example\.com/, result[:stdout])
    end

    def test_shows_title_and_department
      result = run_who_with_stub([], full_stubs)

      assert_match(/Senior Engineer/, result[:stdout])
      assert_match(/Engineering/, result[:stdout])
    end

    def test_shows_office_and_phones
      stdout = run_who_with_stub([], full_stubs)[:stdout]

      assert_match(/Building A, Room 302/, stdout)
      assert_match(/\+1 \(555\) 123-4567/, stdout)
      assert_match(/\+1 \(555\) 987-6543/, stdout)
    end
  end

  class PresenceDisplayTest < Minitest::Test
    include Helpers

    def test_shows_available_status
      result = run_who_with_stub([], full_stubs)

      assert_match(/Status\s+Available/, result[:stdout])
    end

    def test_shows_dnd_status_label
      presence = [{ 'presence' => { 'availability' => 'DoNotDisturb' } }]
      result = run_who_with_stub([], full_stubs.merge('presence' => presence))

      assert_match(/Do Not Disturb/, result[:stdout])
    end

    def test_shows_status_with_expiry
      presence = [{
        'presence' => {
          'availability' => 'DoNotDisturb',
          'forcedAvailability' => { 'expiry' => '2026-03-20T23:00:00Z' }
        }
      }]
      result = run_who_with_stub([], full_stubs.merge('presence' => presence))

      assert_match(/Do Not Disturb \(until Mar 20\)/, result[:stdout])
    end

    def test_shows_oof_with_both_lines
      presence = [{
        'presence' => {
          'availability' => 'DoNotDisturb',
          'calendarData' => { 'isOutOfOffice' => true },
          'forcedAvailability' => { 'expiry' => '2026-03-20T23:00:00Z' }
        }
      }]
      result = run_who_with_stub([], full_stubs.merge('presence' => presence))

      assert_match(/Status\s+Do Not Disturb/, result[:stdout])
      assert_match(/OOF\s+Out of office/, result[:stdout])
    end

    def test_hides_presence_on_api_error
      result = run_who([]) do |runner|
        api = runner.api_client
        api.stub('/v1.0/me', PROFILE_DATA)
        api.stub('calendar/getSchedule', SCHEDULE_RESPONSE)
        api.stub_error('presence', Teems::ApiError.new('Forbidden', status_code: 403))
      end

      assert_equal 0, result[:exit_code]
      refute_match(/Status/, result[:stdout])
    end

    def test_handles_malformed_expiry
      presence = [{
        'presence' => {
          'availability' => 'Busy',
          'forcedAvailability' => { 'expiry' => 'not-a-date' }
        }
      }]
      result = run_who_with_stub([], full_stubs.merge('presence' => presence))

      assert_match(/Status\s+Busy$/, result[:stdout])
    end

    def test_hides_empty_fields
      data = { 'id' => 'user-1', 'displayName' => 'Jane', 'businessPhones' => [] }
      stdout = run_who_with_stub([], { '/v1.0/me' => data, 'presence' => PRESENCE_AVAILABLE,
                                       'calendar/getSchedule' => SCHEDULE_RESPONSE })[:stdout]

      assert_match(/Jane/, stdout)
      refute_match(/Email:/, stdout)
      refute_match(/Title:/, stdout)
    end
  end

  class ScheduleDisplayTest < Minitest::Test
    include Helpers

    def test_shows_calendar_line
      result = run_who_at_noon([], full_stubs)

      assert_match(/Calendar/, result[:stdout])
    end

    def test_shows_bitmap_with_block_chars
      result = run_who_with_stub([], full_stubs)

      assert_match(/Today/, result[:stdout])
      assert_match(/[\u2591\u2592\u2588\u2593]/, result[:stdout])
    end

    def test_shows_hour_labels
      result = run_who_with_stub([], full_stubs)

      assert_match(/9\s+10\s+11\s+12/, result[:stdout])
    end

    def test_shows_now_marker
      result = run_who_at_noon([], full_stubs)

      assert_match(/\^ now/, result[:stdout])
    end

    def test_hides_schedule_on_api_error
      result = run_who([]) do |runner|
        api = runner.api_client
        api.stub('/v1.0/me', PROFILE_DATA)
        api.stub('presence', PRESENCE_AVAILABLE)
        api.stub_error('calendar/getSchedule', Teems::ApiError.new('Error'))
      end

      assert_equal 0, result[:exit_code]
      refute_match(/Today/, result[:stdout])
      refute_match(/Calendar/, result[:stdout])
    end

    def test_refetches_with_actual_work_hours
      sched = early_start_schedule
      result = run_who_with_stub([], full_stubs.merge('calendar/getSchedule' => sched))

      assert_match(/8\s+9\s+10/, result[:stdout])
    end

    def test_empty_availability_view_skips_schedule
      empty_sched = { 'value' => [{ 'availabilityView' => '', 'workingHours' => {} }] }
      result = run_who_with_stub([], full_stubs.merge('calendar/getSchedule' => empty_sched))

      refute_match(/Today/, result[:stdout])
    end

    def test_json_includes_schedule_data
      result = run_who_with_stub(['--json'], full_stubs)
      json = JSON.parse(result[:stdout])

      assert_equal 'Available', json['presence']
      assert json.key?('availability_view')
      assert json.key?('working_hours')
    end

    def test_json_multi_result_skips_enrichment
      second = PROFILE_DATA.merge('id' => 'u2', 'displayName' => 'Jane')
      result = run_who_with_stub(['--json', 'john'], '/v1.0/users' => search_results([PROFILE_DATA, second]))
      json = JSON.parse(result[:stdout])

      assert_equal 2, json.length
      refute json.first.key?('presence')
      refute json.first.key?('availability_view')
    end
  end

  class PresenceEdgeCasesTest < Minitest::Test
    include Helpers

    def test_oof_without_expiry
      presence = [{ 'presence' => {
        'availability' => 'Offline',
        'calendarData' => { 'isOutOfOffice' => true }
      } }]
      result = run_who_with_stub([], full_stubs.merge('presence' => presence))

      assert_match(/OOF\s+Out of office$/, result[:stdout])
    end

    def test_nil_user_id_skips_presence
      data = { 'displayName' => 'Ghost', 'businessPhones' => [] }
      result = run_who_with_stub([], { 'calendar/getSchedule' => SCHEDULE_RESPONSE,
                                       '/v1.0/me' => data })

      assert_equal 0, result[:exit_code]
      refute_match(/Status/, result[:stdout])
    end

    def test_search_result_without_title
      no_title = PROFILE_DATA.merge('jobTitle' => nil)
      second = PROFILE_DATA.merge('id' => 'u2', 'displayName' => 'Jane')
      result = run_who_with_stub(['john'], '/v1.0/users' => search_results([no_title, second]))

      assert_match(/1\. John Doe\n/, result[:stdout])
      refute_match(/1\. John Doe \(/, result[:stdout])
    end

    def test_search_result_without_email
      no_email = PROFILE_DATA.merge('mail' => nil, 'email' => nil)
      second = PROFILE_DATA.merge('id' => 'u2', 'displayName' => 'Jane')
      result = run_who_with_stub(['john'], '/v1.0/users' => search_results([no_email, second]))

      assert_equal 0, result[:exit_code]
    end
  end

  class ScheduleEdgeCasesTest < Minitest::Test
    include Helpers

    def test_all_busy_no_next_change
      busy_sched = {
        'value' => [{
          'availabilityView' => '22222222222222222222222222222222',
          'workingHours' => { 'startTime' => '09:00:00', 'endTime' => '17:00:00',
                              'timeZone' => { 'name' => 'Central Standard Time' } }
        }]
      }
      result = run_who_at_noon([], full_stubs.merge('calendar/getSchedule' => busy_sched))

      assert_match(/Calendar\s+Busy$/, result[:stdout])
    end

    def test_nil_schedule_response_skips_display
      empty = { 'value' => [] }
      result = run_who_with_stub([], full_stubs.merge('calendar/getSchedule' => empty))

      refute_match(/Calendar/, result[:stdout])
    end

    def test_phone_field_hidden_when_empty
      data = PROFILE_DATA.merge('businessPhones' => [], 'mobilePhone' => nil)
      result = run_who_with_stub([], full_stubs.merge('/v1.0/me' => data))

      refute_match(/Phone/, result[:stdout])
      refute_match(/Mobile/, result[:stdout])
    end

    def test_no_email_skips_schedule
      data = { 'id' => 'u1', 'displayName' => 'NoEmail', 'businessPhones' => [] }
      result = run_who_with_stub([], { '/v1.0/me' => data, 'presence' => PRESENCE_AVAILABLE })

      refute_match(/Today/, result[:stdout])
    end

    def test_json_without_schedule
      empty = { 'value' => [] }
      result = run_who_with_stub(['--json'], full_stubs.merge('calendar/getSchedule' => empty))
      json = JSON.parse(result[:stdout])

      refute json.key?('availability_view')
    end

    def test_json_without_presence
      result = run_who(['--json']) do |runner|
        api = runner.api_client
        api.stub('calendar/getSchedule', SCHEDULE_RESPONSE)
        api.stub('/v1.0/me', PROFILE_DATA)
        api.stub_error('presence', Teems::ApiError.new('Error', status_code: 500))
      end
      json = JSON.parse(result[:stdout])

      assert_nil json['presence']
      assert_nil json['out_of_office']
    end
  end

  class SearchTest < Minitest::Test
    include Helpers

    def test_single_result_shows_full_profile
      stubs = { '/v1.0/users' => search_results([PROFILE_DATA]), 'presence' => PRESENCE_AVAILABLE,
                'calendar/getSchedule' => SCHEDULE_RESPONSE }
      result = run_who_with_stub(['john'], stubs)

      assert_equal 0, result[:exit_code]
      assert_match(/John Doe/, result[:stdout])
    end

    def test_multiple_results_shows_numbered_list
      second = PROFILE_DATA.merge('id' => 'u2', 'displayName' => 'Jane', 'jobTitle' => 'Staff')
      result = run_who_with_stub(['john'], '/v1.0/users' => search_results([PROFILE_DATA, second]))

      assert_equal 0, result[:exit_code]
      assert_match(/1\. John Doe \(Senior Engineer\)/, result[:stdout])
      assert_match(/2\. Jane \(Staff\)/, result[:stdout])
    end

    def test_no_results
      result = run_who_with_stub(['nonexistent'], '/v1.0/users' => search_results([]))

      assert_equal 0, result[:exit_code]
      assert_match(/No users found matching 'nonexistent'/, result[:stdout])
    end
  end

  class ErrorHandlingTest < Minitest::Test
    include Helpers

    def test_api_error_returns_exit_code_one
      result = run_who([]) do |runner|
        runner.api_client.stub_error('/v1.0/me', Teems::ApiError.new('Network error'))
      end

      assert_equal 1, result[:exit_code]
      assert_match(/Failed to look up user/, result[:stderr])
    end

    def test_search_api_error_returns_exit_code_one
      result = run_who(['john']) do |runner|
        runner.api_client.stub_error('/v1.0/users', Teems::ApiError.new('Server error'))
      end

      assert_equal 1, result[:exit_code]
    end
  end

  class MoreEdgeCasesTest < Minitest::Test
    include Helpers

    def test_oof_with_expiry_shows_oof_line
      presence = [{ 'presence' => {
        'availability' => 'Away',
        'calendarData' => { 'isOutOfOffice' => true },
        'forcedAvailability' => { 'expiry' => '2026-03-20T23:00:00Z' }
      } }]
      result = run_who_with_stub([], full_stubs.merge('presence' => presence))

      assert_match(/OOF\s+Out of office \(until Mar 20\)/, result[:stdout])
    end

    def test_single_search_result_shows_enriched_profile
      stubs = { '/v1.0/users' => search_results([PROFILE_DATA]),
                'presence' => PRESENCE_AVAILABLE,
                'calendar/getSchedule' => SCHEDULE_RESPONSE }
      result = run_who_with_stub(['john'], stubs)

      assert_match(/Status\s+Available/, result[:stdout])
    end

    def test_json_search_single_result_includes_enrichment
      stubs = { '/v1.0/users' => search_results([PROFILE_DATA]),
                'presence' => PRESENCE_AVAILABLE,
                'calendar/getSchedule' => SCHEDULE_RESPONSE }
      result = run_who_with_stub(['--json', 'john'], stubs)
      json = JSON.parse(result[:stdout])

      assert_equal 'Available', json['presence']
    end

    def test_presence_without_calendar_data_skips_oof
      presence = [{ 'presence' => { 'availability' => 'Busy' } }]
      result = run_who_with_stub([], full_stubs.merge('presence' => presence))

      assert_match(/Status\s+Busy/, result[:stdout])
      refute_match(/OOF/, result[:stdout])
    end
  end
end
