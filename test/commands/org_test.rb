# frozen_string_literal: true

require 'test_helper'

module OrgCommandTests
  module Helpers
    private

    def run_org(args = [])
      exit_code = nil
      result = capture_output do |output|
        runner = configured_runner(output: output)
        yield runner if block_given?
        exit_code = Teems::Commands::Org.new(args, runner: runner).execute
      end
      result.merge(exit_code: exit_code)
    end

    def profile_data(id:, name:, title: nil)
      { 'id' => id, 'displayName' => name, 'mail' => "#{id}@example.com",
        'jobTitle' => title, 'businessPhones' => [] }
    end

    def stub_not_found(runner, pattern)
      runner.api_client.stub_error(pattern, Teems::ApiError.new('Not found', status_code: 404))
    end

    def stub_me_with_no_chain(runner, user)
      runner.api_client.stub('/v1.0/me', user)
      stub_not_found(runner, '/v1.0/me/manager')
      runner.api_client.stub('/v1.0/me/directReports', { 'value' => [] })
    end

    def stub_me_with_manager_chain(runner, user, chain)
      api = runner.api_client
      api.stub('/v1.0/me', user)
      api.stub('/v1.0/me/manager', chain.last)
      api.stub('/v1.0/me/directReports', { 'value' => [] })
      stub_chain_managers(runner, chain)
    end

    def stub_chain_managers(runner, chain)
      chain.each_with_index do |mgr, idx|
        path = "users/#{mgr['id']}/manager"
        idx.zero? ? stub_not_found(runner, path) : runner.api_client.stub(path, chain[idx - 1])
      end
    end

    def stub_me_with_reports(runner, user, reports)
      runner.api_client.stub('/v1.0/me', user)
      stub_not_found(runner, '/v1.0/me/manager')
      runner.api_client.stub('/v1.0/me/directReports', { 'value' => reports })
      stub_empty_subreports(runner, reports)
    end

    def stub_empty_subreports(runner, reports)
      reports.each do |rep|
        runner.api_client.stub("users/#{rep['id']}/directReports", { 'value' => [] })
      end
    end
  end

  class BasicTest < Minitest::Test
    include Helpers

    def test_shows_help_with_help_flag
      result = run_org(['--help'])

      assert_match(/teems org/, result[:stdout])
      assert_match(/--depth/, result[:stdout])
    end

    def test_requires_auth
      result = capture_output do |output|
        store = mock_unconfigured_store
        runner = Teems::Runner.new(output: output, token_store: store)
        assert_equal 1, Teems::Commands::Org.new([], runner: runner).execute
      end
      assert_match(/Not authenticated/, result[:stderr])
    end

    def test_unknown_option_returns_error
      result = run_org(['--bogus'])

      assert_equal 1, result[:exit_code]
      assert_match(/Unknown option/, result[:stderr])
    end
  end

  class CurrentUserOrgTest < Minitest::Test
    include Helpers

    def test_shows_current_user_with_arrow
      user = profile_data(id: 'me-1', name: 'John Doe', title: 'Engineer')
      result = run_org { |runner| stub_me_with_no_chain(runner, user) }

      assert_equal 0, result[:exit_code]
      assert_match(/--> John Doe \(Engineer\)/, result[:stdout])
    end

    def test_shows_direct_reports
      user = profile_data(id: 'me-1', name: 'Manager')
      rep = profile_data(id: 'rep-1', name: 'Alice', title: 'Staff')
      result = run_org { |runner| stub_me_with_reports(runner, user, [rep]) }

      assert_match(/Alice \(Staff\)/, result[:stdout])
    end

    def test_person_without_title
      user = profile_data(id: 'me-1', name: 'John Doe')
      result = run_org { |runner| stub_me_with_no_chain(runner, user) }

      assert_match(/--> John Doe$/, result[:stdout])
    end
  end

  class ManagerChainTest < Minitest::Test
    include Helpers

    def test_shows_manager_chain
      ceo = profile_data(id: 'ceo', name: 'CEO', title: 'CEO')
      dir = profile_data(id: 'dir', name: 'Dir', title: 'Dir')
      user = profile_data(id: 'me-1', name: 'Me', title: 'Eng')
      stdout = run_org { |runner| stub_me_with_manager_chain(runner, user, [ceo, dir]) }[:stdout]

      assert_match(/CEO/, stdout)
      assert_match(/Dir/, stdout)
      assert_match(/--> Me/, stdout)
    end

    def test_manager_chain_ordering
      ceo = profile_data(id: 'ceo', name: 'TopBoss')
      dir = profile_data(id: 'dir', name: 'MidBoss')
      user = profile_data(id: 'me-1', name: 'Worker')
      lines = run_org { |runner| stub_me_with_manager_chain(runner, user, [ceo, dir]) }[:stdout].lines

      assert_operator line_index(lines, 'TopBoss'), :<, line_index(lines, 'MidBoss'),
                      'CEO should come before Director'
    end

    private

    def line_index(lines, text)
      lines.index { |line| line.include?(text) }
    end
  end

  class SearchedUserOrgTest < Minitest::Test
    include Helpers

    def test_search_resolves_first_result
      target = profile_data(id: 'target-1', name: 'Jane', title: 'Lead')
      result = run_org(['jane']) do |runner|
        runner.api_client.stub('/v1.0/users', { 'value' => [target] })
        stub_not_found(runner, 'users/target-1/manager')
        runner.api_client.stub('users/target-1/directReports', { 'value' => [] })
      end

      assert_equal 0, result[:exit_code]
      assert_match(/--> Jane \(Lead\)/, result[:stdout])
    end

    def test_search_no_results
      result = run_org(['nonexistent']) do |runner|
        runner.api_client.stub('/v1.0/users', { 'value' => [] })
      end

      assert_equal 1, result[:exit_code]
      assert_match(/No users found/, result[:stderr])
    end
  end

  class DepthTest < Minitest::Test
    include Helpers

    def test_depth_zero_skips_reports
      user = profile_data(id: 'me-1', name: 'John Doe')
      result = run_org(['--depth', '0']) do |runner|
        runner.api_client.stub('/v1.0/me', user)
        stub_not_found(runner, '/v1.0/me/manager')
      end

      assert_equal 0, result[:exit_code]
      assert_match(/--> John Doe/, result[:stdout])
    end

    def test_default_depth_is_one
      user = profile_data(id: 'me-1', name: 'Boss')
      rep = profile_data(id: 'rep-1', name: 'Report')

      result = run_org { |runner| stub_me_with_reports(runner, user, [rep]) }

      assert_match(/Report/, result[:stdout])
    end
  end

  class JsonOutputTest < Minitest::Test
    include Helpers

    def test_json_structure
      user = profile_data(id: 'me-1', name: 'John', title: 'Eng')
      result = run_org(['--json']) { |runner| stub_me_with_no_chain(runner, user) }
      json = JSON.parse(result[:stdout])

      assert_equal 0, result[:exit_code]
      assert_equal 'John', json['target']['display_name']
      assert_instance_of Array, json['direct_reports']
    end

    def test_json_includes_managers
      user = profile_data(id: 'me-1', name: 'John')
      mgr = profile_data(id: 'mgr-1', name: 'Boss')
      result = run_org(['--json']) { |runner| stub_me_with_manager_chain(runner, user, [mgr]) }
      json = JSON.parse(result[:stdout])

      assert_equal 1, json['managers'].length
      assert_equal 'Boss', json['managers'].first['display_name']
    end
  end

  class ErrorHandlingTest < Minitest::Test
    include Helpers

    def test_api_error_returns_exit_code_one
      result = run_org do |runner|
        runner.api_client.stub_error('/v1.0/me', Teems::ApiError.new('Server error'))
      end

      assert_equal 1, result[:exit_code]
      assert_match(/Failed to fetch org chart/, result[:stderr])
    end

    def test_report_403_returns_empty_gracefully
      user = profile_data(id: 'me-1', name: 'John')
      result = run_org do |runner|
        runner.api_client.stub('/v1.0/me', user)
        stub_not_found(runner, '/v1.0/me/manager')
        runner.api_client.stub_error('/v1.0/me/directReports',
                                     Teems::ApiError.new('Forbidden', status_code: 403))
      end

      assert_equal 0, result[:exit_code]
      assert_match(/--> John/, result[:stdout])
    end

    def test_report_500_raises_to_top_level
      user = profile_data(id: 'me-1', name: 'John')
      result = run_org do |runner|
        runner.api_client.stub('/v1.0/me', user)
        stub_not_found(runner, '/v1.0/me/manager')
        runner.api_client.stub_error('/v1.0/me/directReports',
                                     Teems::ApiError.new('Server error', status_code: 500))
      end

      assert_equal 1, result[:exit_code]
      assert_match(/Failed to fetch org chart/, result[:stderr])
    end

    def test_depth_without_value_defaults
      user = profile_data(id: 'me-1', name: 'John')
      result = run_org(['--depth']) { |runner| stub_me_with_no_chain(runner, user) }

      assert_equal 0, result[:exit_code]
    end

    def test_negative_depth_defaults_to_one
      user = profile_data(id: 'me-1', name: 'John')
      rep = profile_data(id: 'rep-1', name: 'Alice')
      result = run_org(['--depth', '-1']) { |runner| stub_me_with_reports(runner, user, [rep]) }

      assert_equal 0, result[:exit_code]
      assert_match(/Alice/, result[:stdout])
    end

    def test_manager_non_404_error_raises
      user = profile_data(id: 'me-1', name: 'John')
      result = run_org do |runner|
        runner.api_client.stub('/v1.0/me', user)
        runner.api_client.stub_error('/v1.0/me/manager',
                                     Teems::ApiError.new('Server error', status_code: 500))
      end

      assert_equal 1, result[:exit_code]
      assert_match(/Failed to fetch org chart/, result[:stderr])
    end

    def test_searched_user_manager_500_raises
      target = profile_data(id: 'target-1', name: 'Jane')
      result = run_org(['jane']) do |runner|
        runner.api_client.stub('/v1.0/users', { 'value' => [target] })
        runner.api_client.stub_error('users/target-1/manager',
                                     Teems::ApiError.new('Server error', status_code: 500))
      end

      assert_equal 1, result[:exit_code]
    end

    def test_user_report_404_returns_empty
      target = profile_data(id: 'target-1', name: 'Jane')
      result = run_org(['jane']) do |runner|
        runner.api_client.stub('/v1.0/users', { 'value' => [target] })
        stub_not_found(runner, 'users/target-1/manager')
        stub_not_found(runner, 'users/target-1/directReports')
      end

      assert_equal 0, result[:exit_code]
      assert_match(/--> Jane/, result[:stdout])
    end
  end

  class JsonWithReportsTest < Minitest::Test
    include Helpers

    def test_json_includes_direct_reports_data
      user = profile_data(id: 'me-1', name: 'Boss')
      rep = profile_data(id: 'rep-1', name: 'Worker')
      result = run_org(['--json']) { |runner| stub_me_with_reports(runner, user, [rep]) }
      json = JSON.parse(result[:stdout])

      assert_equal 1, json['direct_reports'].length
      assert_equal 'Worker', json['direct_reports'].first['display_name']
    end
  end

  class SubReportErrorTest < Minitest::Test
    include Helpers

    def test_user_report_500_raises_through
      user = profile_data(id: 'me-1', name: 'Boss')
      rep = profile_data(id: 'rep-1', name: 'Worker')
      result = run_org(['--depth', '2']) do |runner|
        stub_boss_with_report(runner, user, rep)
        runner.api_client.stub_error('users/rep-1/directReports',
                                     Teems::ApiError.new('Server error', status_code: 500))
      end

      assert_equal 1, result[:exit_code]
      assert_match(/Failed to fetch org chart/, result[:stderr])
    end

    private

    def stub_boss_with_report(runner, user, rep)
      runner.api_client.stub('/v1.0/me', user)
      stub_not_found(runner, '/v1.0/me/manager')
      runner.api_client.stub('/v1.0/me/directReports', { 'value' => [rep] })
    end
  end
end
