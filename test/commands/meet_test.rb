# frozen_string_literal: true

require 'test_helper'

# `teems meet`: a Teams meeting on the calendar, now by default, and its join link
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class MeetCommandTest < Minitest::Test
  LINK = 'https://teams.microsoft.com/l/meetup-join/19%3ameeting_test%40thread.v2/0'
  NOW = Time.new(2026, 3, 20, 14, 7, 42)

  # Stands in for a terminal on stdin that answers the confirmation prompt
  FakeTerminal = Struct.new(:answer) do
    def tty? = true
    def gets = answer
  end

  # Records what it is handed instead of touching the clipboard or a browser
  class Recorder
    attr_reader :received

    def initialize = @received = []
    def copy(text) = @received << text
    def open(url) = @received << url
  end

  def setup
    @saved_tz = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Chicago'
    @saved_stdin = $stdin
    $stdin = StringIO.new
  end

  def teardown
    ENV['TZ'] = @saved_tz
    $stdin = @saved_stdin
  end

  def created_event(**overrides)
    sample_event_data.merge('subject' => 'Meet now', 'onlineMeeting' => { 'joinUrl' => LINK }, **overrides)
  end

  def run_meet(args, response: created_event, error: nil)
    @clipboard = Recorder.new
    @browser = Recorder.new
    clipboard = @clipboard
    browser = @browser
    capture = capture_output do |output|
      runner = configured_runner(output: output)
      runner.define_singleton_method(:clipboard) { clipboard }
      runner.define_singleton_method(:browser) { browser }
      @api = runner.api_client
      error ? @api.stub_error('/v1.0/me/events', error) : @api.stub('/v1.0/me/events', response)
      @code = Time.stub(:now, NOW) { Teems::Commands::Meet.new(args, runner: runner).execute }
    end
    capture.merge(code: @code)
  end

  def posted = @api.calls.find { |call| call[:method] == :post }&.dig(:body)

  def test_defaults_to_a_teams_meeting_now_for_thirty_minutes
    with_temp_config do
      result = run_meet([])
      body = posted

      assert_equal 0, result[:code]
      assert_equal "#{LINK}\n", result[:stdout], 'the link alone on stdout, so it pipes'
      assert_includes result[:stderr], 'Meet now, 2:07-2:37 PM'
      assert_equal 'Meet now', body[:subject]
      assert body[:isOnlineMeeting]
      assert_equal 'teamsForBusiness', body[:onlineMeetingProvider]
      assert_equal({ dateTime: '2026-03-20T14:07:00', timeZone: 'America/Chicago' }, body[:start])
      assert_equal '2026-03-20T14:37:00', body[:end][:dateTime]
      assert_empty body[:attendees], 'nobody invited, so nothing is sent'
      assert_equal [LINK], @browser.received, 'joins here, to let outsiders in from the lobby'
    end
  end

  def test_no_open_just_prints_the_link
    with_temp_config do
      result = run_meet(%w[--no-open])

      assert_equal "#{LINK}\n", result[:stdout]
      assert_empty @browser.received
      refute_includes result[:stderr], 'Opened it to join'
    end
  end

  def test_minutes_title_and_start
    with_temp_config do
      run_meet(['60', '--title', 'Pairing', '--at', '2026-03-21 09:30'])
      body = posted

      assert_equal 'Pairing', body[:subject]
      assert_equal '2026-03-21T09:30:00', body[:start][:dateTime]
      assert_equal '2026-03-21T10:30:00', body[:end][:dateTime]
    end
  end

  def test_bad_minutes_or_time_create_nothing
    with_temp_config do
      { %w[0] => 'Minutes must be a whole number from 1 to 1440',
        %w[soon] => 'Minutes must be a whole number',
        %w[1441] => 'Minutes must be a whole number',
        %w[--at later] => 'Unknown time: later' }.each do |args, message|
        result = run_meet(args)

        assert_equal 1, result[:code], args.join(' ')
        assert_includes result[:stderr], message
        assert_nil posted, args.join(' ')
      end
    end
  end

  def test_inviting_people_needs_a_yes
    with_temp_config do
      result = run_meet(['--with', 'alice@example.com, bob@example.com'])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Inviting people sends them email; pass --yes'
      assert_nil posted

      $stdin = FakeTerminal.new("n\n")

      assert_includes run_meet(['--with', 'alice@example.com'])[:stderr], 'Cancelled; no meeting created'
      assert_nil posted

      $stdin = FakeTerminal.new("y\n")
      result = run_meet(['--with', 'alice@example.com'])

      assert_includes result[:stderr], 'Invite alice@example.com (Exchange emails each an invitation)? [y/N]'
      assert_equal 0, result[:code]
    end
  end

  def test_yes_invites_without_asking
    with_temp_config do
      run_meet(['--with', 'alice@example.com,bob@example.com', '-y'])

      assert_equal([{ emailAddress: { address: 'alice@example.com' }, type: 'required' },
                    { emailAddress: { address: 'bob@example.com' }, type: 'required' }], posted[:attendees])
    end
  end

  # --open is the default now, and still accepted
  def test_copy_and_open_hand_off_the_link
    with_temp_config do
      result = run_meet(%w[--copy --open])

      assert_equal [LINK], @clipboard.received
      assert_equal [LINK], @browser.received
      assert_includes result[:stderr], 'Copied the link'
      assert_includes result[:stderr], 'Opened it to join'
    end
  end

  def test_json
    with_temp_config do
      result = run_meet(%w[--json --copy])
      json = JSON.parse(result[:stdout])

      assert_equal({ 'id' => sample_event_data['id'], 'title' => 'Meet now', 'join_url' => LINK },
                   json.slice('id', 'title', 'join_url'))
      assert_equal '2026-03-20T14:07:00-05:00', json['start']
      assert_equal [LINK], @clipboard.received
    end
  end

  def test_quiet_prints_just_the_link
    with_temp_config do
      result = run_meet(%w[-q])

      assert_equal "#{LINK}\n", result[:stdout]
      assert_empty result[:stderr]
    end
  end

  def test_an_event_without_a_link_or_a_failed_request
    with_temp_config do
      result = run_meet([], response: created_event('onlineMeeting' => nil))

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Graph created the event but gave no Teams link'

      result = run_meet([], error: Teems::ApiError.new('Forbidden', status_code: 403))

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Could not create the meeting: Forbidden'
    end
  end

  def test_needs_a_sign_in
    with_temp_config do
      result = capture_output do |output|
        runner = Teems::Runner.new(output: output, token_store: mock_token_store(configured: false),
                                   api_client: MockApiClient.new)
        meet = Teems::Commands::Meet.new([], runner: runner)
        meet.define_singleton_method(:auto_login) { false }
        @code = meet.execute
      end

      assert_equal 1, @code
      assert_includes result[:stderr], 'Not authenticated'
    end
  end

  def test_help_and_unknown_options
    with_temp_config do
      assert_includes run_meet(%w[--help])[:stdout], 'teems meet - Start a Teams meeting'
      assert_includes run_meet(%w[--bogus])[:stderr], 'Unknown option: --bogus'
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
