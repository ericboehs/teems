# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  enable_coverage :branch
end

require 'minitest/autorun'
require_relative '../lib/teems'
require 'stringio'
require 'tmpdir'
require 'json'
require 'fileutils'

module Teems
  module TestHelpers
    def test_output(color: false)
      io = StringIO.new
      err = StringIO.new
      Formatters::Output.new(io: io, err: err, color: color)
    end

    def test_runner(output: nil, config: nil, token_store: nil, api_client: nil)
      Runner.new(
        output: output || test_output,
        config: config,
        token_store: token_store,
        api_client: api_client
      )
    end

    def with_temp_config
      Dir.mktmpdir('teems-test') do |dir|
        old_config = ENV.fetch('XDG_CONFIG_HOME', nil)
        old_cache = ENV.fetch('XDG_CACHE_HOME', nil)
        old_data = ENV.fetch('XDG_DATA_HOME', nil)
        ENV['XDG_CONFIG_HOME'] = dir
        ENV['XDG_CACHE_HOME'] = "#{dir}/cache"
        ENV['XDG_DATA_HOME'] = "#{dir}/data"
        yield dir
      ensure
        ENV['XDG_CONFIG_HOME'] = old_config
        ENV['XDG_CACHE_HOME'] = old_cache
        ENV['XDG_DATA_HOME'] = old_data
      end
    end

    # Write a tokens file to the temp config directory
    def write_tokens_file(dir, tokens)
      config_dir = "#{dir}/teems"
      FileUtils.mkdir_p(config_dir)
      File.write("#{config_dir}/tokens.json", JSON.generate(tokens))
    end

    # Write a config file to the temp config directory
    def write_config_file(dir, config)
      config_dir = "#{dir}/teems"
      FileUtils.mkdir_p(config_dir)
      File.write("#{config_dir}/config.json", JSON.generate(config))
    end

    # Load fixture JSON
    def fixture(name)
      file = File.join(File.dirname(__FILE__), 'fixtures', "#{name}.json")
      JSON.parse(File.read(file))
    end

    # Mock account for testing
    def mock_account(name: 'default', auth_token: 'eyJ0eXAtest123', skype_token: 'eyJhbGcitest456')
      Models::Account.new(name: name, auth_token: auth_token, skype_token: skype_token)
    end

    # Sample API response data
    def sample_graph_message
      {
        'id' => '1234567890',
        'body' => { 'content' => '<p>Hello world</p>' },
        'from' => {
          'user' => {
            'id' => 'user123',
            'displayName' => 'John Doe'
          }
        },
        'createdDateTime' => '2026-01-20T12:00:00Z',
        'messageType' => 'message',
        'importance' => 'normal'
      }
    end

    def sample_ng_msg_message
      {
        'id' => '1768935087318',
        'content' => '<p>Hello from ng.msg</p>',
        'imdisplayname' => 'Jane Smith',
        'from' => 'https://ng.msg.gcc.teams.microsoft.com/v1/users/ME/contacts/8:orgid:abc123',
        'composetime' => '2026-01-20T12:00:00.000Z',
        'messagetype' => 'RichText/Html',
        'properties' => {
          'emotions' => [
            { 'key' => 'like', 'users' => [{ 'mri' => 'user1' }] }
          ]
        }
      }
    end

    def sample_system_message
      {
        'id' => '1768935087319',
        'content' => '<addmember><target>8:orgid:abc</target></addmember>',
        'composetime' => '2026-01-20T12:00:00.000Z',
        'messagetype' => 'ThreadActivity/AddMember'
      }
    end

    def sample_team
      {
        'id' => 'team-uuid-123',
        'displayName' => 'Engineering Team',
        'description' => 'The engineering team'
      }
    end

    def sample_channel
      {
        'id' => '19:channel123@thread.tacv2',
        'displayName' => 'General',
        'description' => 'General discussions',
        'membershipType' => 'standard'
      }
    end

    def sample_chat
      {
        'id' => '19:chat123@thread.v2',
        'topic' => 'Project Discussion',
        'chatType' => 'group',
        'createdDateTime' => '2026-01-15T10:00:00Z',
        'lastUpdatedDateTime' => '2026-01-20T12:00:00Z'
      }
    end

    def sample_event_data
      {
        'id' => 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe',
        'subject' => 'Weekly Standup',
        'start' => { 'dateTime' => '2026-01-20T09:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'end' => { 'dateTime' => '2026-01-20T10:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'location' => { 'displayName' => 'Conference Room A' },
        'isAllDay' => false,
        'organizer' => {
          'emailAddress' => { 'name' => 'Alice Manager', 'address' => 'alice@example.com' }
        },
        'attendees' => [
          sample_attendee_data('Bob Dev', 'bob@example.com', 'required', 'accepted'),
          sample_attendee_data('Carol QA', 'carol@example.com', 'required', 'declined'),
          sample_attendee_data('Dave PM', 'dave@example.com', 'optional', 'tentativelyAccepted'),
          sample_attendee_data('Eve Intern', 'eve@example.com', 'optional', 'none')
        ],
        'bodyPreview' => 'Discuss sprint progress and blockers.',
        'onlineMeeting' => { 'joinUrl' => 'https://teams.microsoft.com/l/meetup-join/123' },
        'showAs' => 'busy',
        'importance' => 'normal',
        'isCancelled' => false,
        'responseStatus' => { 'response' => 'accepted', 'time' => '2026-01-18T10:00:00Z' },
        'sensitivity' => 'normal'
      }
    end

    def sample_attendee_data(name, email, type, response)
      {
        'emailAddress' => { 'name' => name, 'address' => email },
        'type' => type,
        'status' => { 'response' => response, 'time' => '0001-01-01T00:00:00Z' }
      }
    end

    # Capture output for command tests
    def capture_output
      out = StringIO.new
      err = StringIO.new
      output = Formatters::Output.new(io: out, err: err, color: false)
      yield output
      { stdout: out.string, stderr: err.string }
    end

    # Create a runner with mock token store that is configured
    def configured_runner(output: nil, account: nil)
      output ||= test_output
      store = mock_token_store(account: account || mock_account)
      Runner.new(output: output, token_store: store, api_client: MockApiClient.new)
    end

    # Mock token store for testing
    def mock_token_store(account: nil, configured: true)
      MockTokenStore.new(account: account, configured: configured)
    end

    # Mock token store class
    class MockTokenStore
      attr_accessor :skype_spaces_token, :save_result

      def initialize(account: nil, configured: true)
        @account = account
        @configured = configured
        @skype_spaces_token = nil
        @save_result = true
      end

      def configured? = @configured
      attr_reader :account

      def save(**_kwargs) = @save_result
      def clear = nil
      def token_age = nil
      def update_skype_token(_token) = true
    end

    # Mock API client for testing
    class MockApiClient
      attr_reader :calls, :call_count
      attr_accessor :on_request, :on_response

      def initialize
        @calls = []
        @call_count = 0
        @responses = {}
        @errors = {}
        @transient_errors = {}
      end

      def stub(path, response)
        @responses[path] = response
      end

      def stub_error(path, error)
        @errors[path] = error
      end

      # Raise error only for the first N calls matching this path, then succeed
      def stub_transient_error(path, error, times: 1)
        @transient_errors[path] = { error: error, remaining: times }
      end

      def get(_endpoint, path, account:, params: {}, headers: {})
        @calls << { method: :get, path: path, params: params, headers: headers }
        @call_count += 1
        check_errors(path)
        find_response(path) || { 'value' => [] }
      end

      def post(_endpoint, path, account:, body: nil)
        @calls << { method: :post, path: path, body: body }
        @call_count += 1
        check_errors(path)
        find_response(path) || {}
      end

      def close
        # no-op for tests
      end

      private

      def check_errors(path)
        # Check transient errors first (they expire after N calls)
        @transient_errors.each do |pattern, info|
          next unless path.include?(pattern)
          next unless info[:remaining].positive?

          info[:remaining] -= 1
          raise info[:error]
        end

        # Permanent errors
        @errors.each do |pattern, error|
          raise error if path.include?(pattern)
        end
      end

      def find_response(path)
        # Try exact match first
        return @responses[path] if @responses.key?(path)

        # Try partial match
        @responses.each do |pattern, response|
          return response if path.include?(pattern)
        end
        nil
      end
    end
  end
end

module Minitest
  class Test
    include Teems::TestHelpers
  end
end
