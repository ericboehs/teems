# frozen_string_literal: true

require 'test_helper'

module UsersApiTests
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

  class MeTest < Minitest::Test
    include Helpers

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
      call = @api_client.calls.first

      assert_includes call[:params]['$select'], 'displayName'
      assert_includes call[:params]['$select'], 'jobTitle'
      assert_includes call[:params]['$select'], 'department'
    end

    def test_me_returns_user_profile_model
      @api_client.stub('/v1.0/me', sample_user_profile_data)
      profile = @users_api.me

      assert_instance_of Teems::Models::UserProfile, profile
      assert_equal 'John Doe', profile.display_name
    end
  end

  class GetUserTest < Minitest::Test
    include Helpers

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

  class SearchTest < Minitest::Test
    include Helpers

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
      call = @api_client.calls.first

      assert_includes call[:params]['$search'], 'displayName:john'
      assert_includes call[:params]['$search'], 'mail:john'
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

  class ManagerTest < Minitest::Test
    include Helpers

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

  class DirectReportsTest < Minitest::Test
    include Helpers

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

  class PresenceTest < Minitest::Test
    include Helpers

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
end
