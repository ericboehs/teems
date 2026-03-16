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

  PRESENCE_RESPONSE = [{ 'presence' => { 'availability' => 'Available' } }].freeze

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

    def run_who_with_stub(args, stubs)
      run_who(args) do |runner|
        stubs.each { |path, response| runner.api_client.stub(path, response) }
      end
    end

    def search_results(profiles)
      { 'value' => profiles }
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
        store = mock_token_store(configured: false)
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
      result = run_who_with_stub([], { '/v1.0/me' => PROFILE_DATA, 'presence' => PRESENCE_RESPONSE })

      assert_equal 0, result[:exit_code]
      assert_match(/John Doe/, result[:stdout])
      assert_match(/john\.doe@example\.com/, result[:stdout])
    end

    def test_shows_title_and_department
      result = run_who_with_stub([], { '/v1.0/me' => PROFILE_DATA, 'presence' => PRESENCE_RESPONSE })

      assert_match(/Senior Engineer/, result[:stdout])
      assert_match(/Engineering/, result[:stdout])
    end

    def test_shows_office_and_phones
      result = run_who_with_stub([], { '/v1.0/me' => PROFILE_DATA, 'presence' => PRESENCE_RESPONSE })

      assert_match(/Building A, Room 302/, result[:stdout])
      assert_match(/\+1 \(555\) 123-4567/, result[:stdout])
      assert_match(/\+1 \(555\) 987-6543/, result[:stdout])
    end
  end

  class CurrentUserPresenceTest < Minitest::Test
    include Helpers

    def test_shows_presence_when_available
      result = run_who_with_stub([], { '/v1.0/me' => PROFILE_DATA, 'presence' => PRESENCE_RESPONSE })

      assert_match(/Available/, result[:stdout])
    end

    def test_hides_presence_on_api_error
      result = run_who([]) do |runner|
        runner.api_client.stub('/v1.0/me', PROFILE_DATA)
        runner.api_client.stub_error('presence', Teems::ApiError.new('Forbidden', status_code: 403))
      end

      assert_equal 0, result[:exit_code]
      refute_match(/Status:/, result[:stdout])
    end

    def test_hides_empty_fields
      data = { 'id' => 'user-1', 'displayName' => 'Jane', 'businessPhones' => [] }
      result = run_who_with_stub([], { '/v1.0/me' => data, 'presence' => PRESENCE_RESPONSE })

      assert_match(/Jane/, result[:stdout])
      refute_match(/Email:/, result[:stdout])
      refute_match(/Title:/, result[:stdout])
    end

    def test_json_output
      result = run_who_with_stub(['--json'], { '/v1.0/me' => PROFILE_DATA, 'presence' => PRESENCE_RESPONSE })
      json = JSON.parse(result[:stdout])

      assert_equal 'John Doe', json['display_name']
      assert_equal 'Available', json['presence']
    end
  end

  class SearchTest < Minitest::Test
    include Helpers

    def test_single_result_shows_full_profile
      stubs = { '/v1.0/users' => search_results([PROFILE_DATA]), 'presence' => PRESENCE_RESPONSE }
      result = run_who_with_stub(['john'], stubs)

      assert_equal 0, result[:exit_code]
      assert_match(/John Doe/, result[:stdout])
      assert_match(/Senior Engineer/, result[:stdout])
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

    def test_search_by_email
      stubs = { '/v1.0/users' => search_results([PROFILE_DATA]), 'presence' => PRESENCE_RESPONSE }
      result = run_who_with_stub(['john@example.com'], stubs)

      assert_equal 0, result[:exit_code]
      assert_match(/John Doe/, result[:stdout])
    end

    def test_json_multiple_results
      second = PROFILE_DATA.merge('id' => 'u2', 'displayName' => 'Jane')
      result = run_who_with_stub(['--json', 'john'], '/v1.0/users' => search_results([PROFILE_DATA, second]))
      json = JSON.parse(result[:stdout])

      assert_instance_of Array, json
      assert_equal 2, json.length
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
      assert_match(/Failed to look up user/, result[:stderr])
    end
  end
end
