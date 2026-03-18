# frozen_string_literal: true

require 'test_helper'

# Tests for the Users API wrapper
module UsersApiTests
  # Shared setup and sample data for users API tests
  module Helpers
    def setup
      @api_client = Teems::TestHelpers::MockApiClient.new
      @account = mock_account
      @users_api = Teems::Api::Users.new(@api_client, @account)
    end

    private

    def sample_user_profile_data
      { 'id' => 'user-uuid-123', 'displayName' => 'John Doe',
        'mail' => 'john@example.com', 'userPrincipalName' => 'john@example.onmicrosoft.com',
        'jobTitle' => 'Engineer', 'department' => 'Engineering',
        'officeLocation' => 'Building A', 'businessPhones' => ['+1-555-1234'],
        'mobilePhone' => '+1-555-5678' }
    end
  end

  # Tests for fetching the current user's profile
  class MeTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_me_calls_correct_endpoint
      @api_client.stub('/v1.0/me', sample_user_profile_data)
      @users_api.me
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_equal '/v1.0/me', call[:path]
    end

    def test_me_passes_select_param
      @api_client.stub('/v1.0/me', sample_user_profile_data)
      @users_api.me
      select_param = @api_client.calls.first[:params]['$select']

      assert_includes select_param, 'displayName'
      assert_includes select_param, 'jobTitle'
      assert_includes select_param, 'department'
    end

    def test_me_returns_user_profile_model
      @api_client.stub('/v1.0/me', sample_user_profile_data)
      profile = @users_api.me

      assert_instance_of Teems::Models::UserProfile, profile
      assert_equal 'John Doe', profile.display_name
    end
  end

  # Tests for fetching a user profile by ID
  class GetUserTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_get_user_calls_correct_endpoint
      @api_client.stub('users/', sample_user_profile_data)
      @users_api.get_user('user-uuid-123')
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/users/user-uuid-123'
    end

    def test_get_user_encodes_user_id
      @api_client.stub('users/', sample_user_profile_data)
      @users_api.get_user('user+special/chars=')
      call = @api_client.calls.first

      assert_includes call[:path], URI.encode_www_form_component('user+special/chars=')
    end

    def test_get_user_returns_user_profile_model
      @api_client.stub('users/', sample_user_profile_data)
      profile = @users_api.get_user('user-uuid-123')

      assert_instance_of Teems::Models::UserProfile, profile
      assert_equal 'Engineer', profile.job_title
    end
  end

  # Tests for searching users by name or email
  class SearchTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_search_calls_correct_endpoint
      @api_client.stub('/v1.0/users', { 'value' => [sample_user_profile_data] })
      @users_api.search('john')
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_equal '/v1.0/users', call[:path]
    end

    def test_search_sends_consistency_level_header
      @api_client.stub('/v1.0/users', { 'value' => [] })
      @users_api.search('john')
      call = @api_client.calls.first

      assert_equal 'eventual', call[:headers]['ConsistencyLevel']
    end

    def test_search_sends_count_param
      @api_client.stub('/v1.0/users', { 'value' => [] })
      @users_api.search('john')
      call = @api_client.calls.first

      assert_equal 'true', call[:params]['$count']
    end

    def test_search_sends_search_param
      @api_client.stub('/v1.0/users', { 'value' => [] })
      @users_api.search('john')
      search_param = @api_client.calls.first[:params]['$search']

      assert_includes search_param, 'displayName:john'
      assert_includes search_param, 'mail:john'
    end

    def test_search_returns_user_profile_models
      @api_client.stub('/v1.0/users', { 'value' => [sample_user_profile_data] })
      results = @users_api.search('john')

      assert_equal 1, results.length
      assert_instance_of Teems::Models::UserProfile, results.first
    end

    def test_search_returns_empty_for_no_results
      @api_client.stub('/v1.0/users', { 'value' => [] })
      results = @users_api.search('nonexistent')

      assert_empty results
    end
  end

  # Tests for fetching a user's manager
  class ManagerTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_manager_calls_correct_endpoint
      @api_client.stub('manager', sample_user_profile_data)
      @users_api.manager('user-uuid-123')
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/users/user-uuid-123/manager'
    end

    def test_manager_encodes_user_id
      @api_client.stub('manager', sample_user_profile_data)
      @users_api.manager('user+id=')
      call = @api_client.calls.first

      assert_includes call[:path], URI.encode_www_form_component('user+id=')
    end

    def test_manager_returns_user_profile_model
      @api_client.stub('manager', sample_user_profile_data)
      profile = @users_api.manager('user-uuid-123')

      assert_instance_of Teems::Models::UserProfile, profile
    end

    def test_manager_me_calls_correct_endpoint
      @api_client.stub('/v1.0/me/manager', sample_user_profile_data)
      @users_api.manager_me
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_equal '/v1.0/me/manager', call[:path]
    end

    def test_manager_me_returns_user_profile_model
      @api_client.stub('/v1.0/me/manager', sample_user_profile_data)
      profile = @users_api.manager_me

      assert_instance_of Teems::Models::UserProfile, profile
    end
  end

  # Tests for fetching a user's direct reports
  class DirectReportsTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_direct_reports_calls_correct_endpoint
      @api_client.stub('directReports', { 'value' => [] })
      @users_api.direct_reports('user-uuid-123')
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/users/user-uuid-123/directReports'
    end

    def test_direct_reports_returns_user_profile_models
      @api_client.stub('directReports', { 'value' => [sample_user_profile_data] })
      results = @users_api.direct_reports('user-uuid-123')

      assert_equal 1, results.length
      assert_instance_of Teems::Models::UserProfile, results.first
    end

    def test_direct_reports_me_calls_correct_endpoint
      @api_client.stub('/v1.0/me/directReports', { 'value' => [] })
      @users_api.direct_reports_me
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_equal '/v1.0/me/directReports', call[:path]
    end

    def test_direct_reports_me_returns_user_profile_models
      @api_client.stub('/v1.0/me/directReports', { 'value' => [sample_user_profile_data] })
      results = @users_api.direct_reports_me

      assert_equal 1, results.length
      assert_instance_of Teems::Models::UserProfile, results.first
    end
  end

  # Tests for fetching a user's Graph API presence status
  class PresenceTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_presence_calls_correct_endpoint
      @api_client.stub('presence', { 'availability' => 'Available' })
      @users_api.presence('user-uuid-123')
      call = @api_client.calls.first

      assert_equal :get, call[:method]
      assert_includes call[:path], '/v1.0/users/user-uuid-123/presence'
    end

    def test_presence_encodes_user_id
      @api_client.stub('presence', { 'availability' => 'Available' })
      @users_api.presence('user+id=')
      call = @api_client.calls.first

      assert_includes call[:path], URI.encode_www_form_component('user+id=')
    end

    def test_presence_returns_raw_response
      @api_client.stub('presence', { 'availability' => 'Busy', 'activity' => 'InACall' })
      result = @users_api.presence('user-uuid-123')

      assert_equal 'Busy', result['availability']
      assert_equal 'InACall', result['activity']
    end
  end

  # Tests for fetching presence via the Teams chat service API
  class TeamsPresenceTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_teams_presence_posts_to_presence_endpoint
      response = [{ 'presence' => { 'availability' => 'Available' } }]
      @api_client.stub('getpresence', response)
      @users_api.teams_presence('8:orgid:user-uuid-123')
      call = @api_client.calls.first

      assert_equal :post, call[:method]
      assert_includes call[:path], '/v1/presence/getpresence/'
    end

    def test_teams_presence_sends_mri_in_body
      @api_client.stub('getpresence', [])
      @users_api.teams_presence('8:orgid:user-uuid-123')

      assert_equal [{ mri: '8:orgid:user-uuid-123' }], @api_client.calls.first[:body]
    end

    def test_teams_presence_returns_response
      response = [{ 'presence' => { 'availability' => 'Busy' } }]
      @api_client.stub('getpresence', response)
      result = @users_api.teams_presence('8:orgid:user-uuid-123')

      assert_equal 'Busy', result.first.dig('presence', 'availability')
    end
  end

  # Tests for fetching a user's free/busy schedule
  class ScheduleTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_schedule_posts_to_get_schedule
      sched = { 'value' => [{ 'availabilityView' => '0000' }] }
      @api_client.stub('getSchedule', sched)
      @users_api.schedule('john@example.com',
                          time_range: { start_time: '2026-03-16T09:00:00',
                                        end_time: '2026-03-16T17:00:00', timezone: 'UTC' })
      call = @api_client.calls.first

      assert_equal :post, call[:method]
      assert_includes call[:path], '/v1.0/me/calendar/getSchedule'
    end

    def test_schedule_sends_correct_body
      sched = { 'value' => [{ 'availabilityView' => '0000' }] }
      @api_client.stub('getSchedule', sched)
      @users_api.schedule('john@example.com',
                          time_range: { start_time: '2026-03-16T09:00:00',
                                        end_time: '2026-03-16T17:00:00', timezone: 'America/Chicago' })
      body = @api_client.calls.first[:body]

      assert_equal ['john@example.com'], body[:schedules]
      assert_equal 'America/Chicago', body[:startTime][:timeZone]
      assert_equal 15, body[:availabilityViewInterval]
    end

    def test_schedule_returns_first_value
      sched = { 'value' => [{ 'availabilityView' => '00112233' }] }
      @api_client.stub('getSchedule', sched)
      result = @users_api.schedule('j@ex.com',
                                   time_range: { start_time: 'a', end_time: 'b', timezone: 'UTC' })

      assert_equal '00112233', result['availabilityView']
    end

    def test_schedule_returns_nil_for_empty_value
      @api_client.stub('getSchedule', { 'value' => [] })
      result = @users_api.schedule('j@ex.com',
                                   time_range: { start_time: 'a', end_time: 'b', timezone: 'UTC' })

      assert_nil result
    end
  end

  # Tests for sanitizing special characters in search queries
  class SearchSanitizationTest < Minitest::Test
    include Helpers

    def initialize(*)
      @api_client = nil
      @users_api = nil
      super
    end

    def test_search_strips_quotes_from_query
      @api_client.stub('/v1.0/users', { 'value' => [] })
      @users_api.search('john"doe')
      search_param = @api_client.calls.first[:params]['$search']

      refute_includes search_param, 'john"doe'
      assert_includes search_param, 'johndoe'
    end

    def test_search_strips_backslashes
      @api_client.stub('/v1.0/users', { 'value' => [] })
      @users_api.search('john\\doe')

      assert_includes @api_client.calls.first[:params]['$search'], 'johndoe'
    end
  end
end
