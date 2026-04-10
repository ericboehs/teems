# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  enable_coverage :branch
  minimum_coverage line: 95, branch: 95
end

require 'minitest/autorun'
require_relative '../lib/teems'
require 'stringio'
require 'tmpdir'
require 'json'
require 'fileutils'

# Root namespace for all teems test support code
module Teems
  # Sample API response data used across test suites
  module SampleData
    def sample_graph_message
      { 'id' => '1234567890', 'body' => { 'content' => '<p>Hello world</p>' },
        'from' => { 'user' => { 'id' => 'user123', 'displayName' => 'John Doe' } },
        'createdDateTime' => '2026-01-20T12:00:00Z',
        'messageType' => 'message', 'importance' => 'normal' }
    end

    def sample_ng_msg_message
      { 'id' => '1768935087318', 'content' => '<p>Hello from ng.msg</p>',
        'imdisplayname' => 'Jane Smith',
        'from' => 'https://ng.msg.gcc.teams.microsoft.com/v1/users/ME/contacts/8:orgid:abc123',
        'composetime' => '2026-01-20T12:00:00.000Z', 'messagetype' => 'RichText/Html',
        'properties' => { 'emotions' => [{ 'key' => 'like', 'users' => [{ 'mri' => 'user1' }] }] } }
    end

    def sample_system_message
      { 'id' => '1768935087319',
        'content' => '<addmember><target>8:orgid:abc</target></addmember>',
        'composetime' => '2026-01-20T12:00:00.000Z',
        'messagetype' => 'ThreadActivity/AddMember' }
    end

    def sample_team
      { 'id' => 'team-uuid-123', 'displayName' => 'Engineering Team',
        'description' => 'The engineering team' }
    end

    def sample_channel
      { 'id' => '19:channel123@thread.tacv2', 'displayName' => 'General',
        'description' => 'General discussions', 'membershipType' => 'standard' }
    end

    def sample_chat
      { 'id' => '19:chat123@thread.v2', 'topic' => 'Project Discussion', 'chatType' => 'group',
        'createdDateTime' => '2026-01-15T10:00:00Z', 'lastUpdatedDateTime' => '2026-01-20T12:00:00Z' }
    end

    def sample_event_data
      sample_event_base.merge(sample_event_details)
    end

    def sample_event_base
      { 'id' => 'AAMkAGVmMDEzMTM4LTZmYWUtNDdkNC1hMDZe', 'subject' => 'Weekly Standup',
        'start' => { 'dateTime' => '2026-01-20T09:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'end' => { 'dateTime' => '2026-01-20T10:00:00.0000000', 'timeZone' => 'America/Chicago' },
        'location' => { 'displayName' => 'Conference Room A' }, 'isAllDay' => false,
        'organizer' => { 'emailAddress' => { 'name' => 'Alice Manager', 'address' => 'alice@example.com' } },
        'attendees' => sample_attendees }
    end

    def sample_event_details
      { 'bodyPreview' => 'Discuss sprint progress and blockers.',
        'onlineMeeting' => { 'joinUrl' => 'https://teams.microsoft.com/l/meetup-join/123' },
        'showAs' => 'busy', 'importance' => 'normal', 'isCancelled' => false,
        'responseStatus' => { 'response' => 'accepted', 'time' => '2026-01-18T10:00:00Z' },
        'sensitivity' => 'normal' }
    end

    def sample_attendees
      [sample_attendee_data('Bob Dev', 'bob@example.com', 'required', 'accepted'),
       sample_attendee_data('Carol QA', 'carol@example.com', 'required', 'declined'),
       sample_attendee_data('Dave PM', 'dave@example.com', 'optional', 'tentativelyAccepted'),
       sample_attendee_data('Eve Intern', 'eve@example.com', 'optional', 'none')]
    end

    def sample_attendee_data(name, email, type, response)
      { 'emailAddress' => { 'name' => name, 'address' => email },
        'type' => type,
        'status' => { 'response' => response, 'time' => '0001-01-01T00:00:00Z' } }
    end
  end

  # Shared test utilities for temp config dirs, mock objects, and output capture
  module TestHelpers
    include SampleData

    XDG_ENV_KEYS = %w[XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME].freeze

    private

    def test_output
      Formatters::Output.new(io: StringIO.new, err: StringIO.new, color: false)
    end

    def test_runner(output: test_output, config: nil, token_store: nil, api_client: nil)
      Runner.new(**{ output: output, config: config,
                     token_store: token_store, api_client: api_client }.compact)
    end

    def with_temp_config
      Dir.mktmpdir('teems-test') do |dir|
        saved = save_xdg_env
        apply_xdg_env(dir)
        yield dir
      ensure
        restore_xdg_env(saved)
      end
    end

    def write_tokens_file(dir, tokens)
      config_dir = "#{dir}/teems"
      FileUtils.mkdir_p(config_dir)
      File.write("#{config_dir}/tokens.json", JSON.generate(tokens))
    end

    def write_config_file(dir, config)
      config_dir = "#{dir}/teems"
      FileUtils.mkdir_p(config_dir)
      File.write("#{config_dir}/config.json", JSON.generate(config))
    end

    def fixture(name)
      JSON.parse(File.read(File.join(File.dirname(__FILE__), 'fixtures', "#{name}.json")))
    end

    def mock_account(name: 'default', auth_token: 'eyJ0eXAtest123', skype_token: 'eyJhbGcitest456')
      Models::Account.new(name: name, auth_token: auth_token, skype_token: skype_token)
    end

    def with_fake_stdin(content)
      original = $stdin
      $stdin = StringIO.new(content)
      yield
    ensure
      $stdin = original
    end

    def capture_output
      out = StringIO.new
      err = StringIO.new
      output = Formatters::Output.new(io: out, err: err, color: false)
      yield output
      { stdout: out.string, stderr: err.string }
    end

    def configured_runner(output: test_output, account: mock_account)
      store = mock_token_store(account: account)
      Runner.new(output: output, token_store: store, api_client: MockApiClient.new)
    end

    def save_xdg_env
      XDG_ENV_KEYS.map { |key| ENV.fetch(key, nil) }
    end

    def apply_xdg_env(dir)
      ENV['XDG_CONFIG_HOME'] = dir
      ENV['XDG_CACHE_HOME'] = "#{dir}/cache"
      ENV['XDG_DATA_HOME'] = "#{dir}/data"
    end

    def restore_xdg_env(saved)
      XDG_ENV_KEYS.zip(saved).each { |key, val| ENV[key] = val }
    end

    def mock_token_store(account: nil, configured: true, **extra)
      MockTokenStore.new(account: account, configured: configured).tap do |store|
        extra.each { |key, val| store.public_send(:"#{key}=", val) }
      end
    end

    def mock_unconfigured_store
      MockTokenStore.new(configured: false)
    end

    # Mock token store class
    class MockTokenStore
      attr_accessor :save_result
      attr_reader :account, :extra_tokens

      def initialize(account: nil, configured: true)
        @account = account
        @configured = configured
        @extra_tokens = { skype_spaces: nil, refresh: nil, client_id: nil, tenant_id: nil }
        @save_result = true
      end

      def configured? = @configured

      def skype_spaces_token = @extra_tokens[:skype_spaces]
      def refresh_token = @extra_tokens[:refresh]
      def client_id = @extra_tokens[:client_id]
      def tenant_id = @extra_tokens[:tenant_id]

      def skype_spaces_token=(val)
        @extra_tokens[:skype_spaces] = val
      end

      def refresh_token=(val)
        @extra_tokens[:refresh] = val
      end

      def client_id=(val)
        @extra_tokens[:client_id] = val
      end

      def tenant_id=(val)
        @extra_tokens[:tenant_id] = val
      end

      def save(**_kwargs) = @save_result
      def clear = nil
      def token_age = nil
      def update_skype_token(_token) = :ok
      def update_all_tokens(**_kwargs) = :ok
    end

    # Mock API client for testing
    class MockApiClient
      attr_accessor :on_request, :on_response
      attr_reader :calls, :call_count

      def initialize
        @calls = []
        @call_count = 0
        @stubs = { responses: {}, errors: {}, transient: {} }
        @on_request = nil
        @on_response = nil
      end

      def stub(path, response)
        @stubs[:responses][path] = response
      end

      def stub_error(path, error)
        @stubs[:errors][path] = error
      end

      # Raise error only for the first N calls matching this path, then succeed
      def stub_transient_error(path, error, times: 1)
        @stubs[:transient][path] = TransientError.new(error, times)
      end

      def get(_endpoint, path, account:, **)
        @calls << { method: :get, path: path, account: account, ** }
        record_and_respond(path, { 'value' => [] })
      end

      def post(_endpoint, path, account:, body: nil)
        @calls << { method: :post, path: path, body: body, account: account }
        record_and_respond(path, {})
      end

      def patch(_endpoint, path, account:, body: nil)
        @calls << { method: :patch, path: path, body: body, account: account }
        record_and_respond(path, {})
      end

      def delete(url, endpoint_key:, account:)
        path = URI(url).path
        @calls << { method: :delete, path: path, account: account, endpoint_key: endpoint_key }
        @call_count += 1
        check_errors(path)
        nil
      end

      def close
        # no-op for tests
      end

      private

      def record_and_respond(path, default)
        @call_count += 1
        @on_request&.call(path, @call_count)
        check_errors(path)
        result = find_response(path) || default
        @on_response&.call(path, '200')
        result
      end

      def check_errors(path)
        check_transient_errors(path)
        check_permanent_errors(path)
      end

      def check_transient_errors(path)
        @stubs[:transient].each do |pattern, transient|
          next unless path.include?(pattern)

          transient.attempt
        end
      end

      def check_permanent_errors(path)
        @stubs[:errors].each do |pattern, error|
          raise error if path.include?(pattern)
        end
      end

      def find_response(path)
        return @stubs[:responses][path] if @stubs[:responses].key?(path)

        @stubs[:responses].each do |pattern, response|
          return response if path.include?(pattern)
        end
        nil
      end

      # Tracks a transient error that fires a limited number of times
      class TransientError
        def initialize(error, remaining)
          @error = error
          @remaining = remaining
        end

        def attempt
          return unless @remaining.positive?

          @remaining -= 1
          raise @error
        end
      end
    end
  end
end

Minitest::Test.include Teems::TestHelpers
