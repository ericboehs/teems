# frozen_string_literal: true

require_relative '../test_helper'

# Logins after a token refresh: when the refreshed token is still rejected, and the silent
# login that mail and cal ics use under --no-login
class LoginFallbackTest < Minitest::Test
  # Exposes with_token_refresh; silent: true logs in like --no-login does
  class LoginCommand < Teems::Commands::Base
    def initialize(args, runner:, silent: false)
      super(args, runner: runner)
      @options[:no_login] = silent
    end

    def execute = 0
    def run(&) = with_token_refresh(&)
  end

  TOKENS = { auth_token: 'fresh-auth', skype_token: 'fresh-skype' }.freeze

  def test_logs_in_when_the_refreshed_token_is_still_rejected
    calls = 0
    result = command(refreshes: true).run { (calls += 1) < 3 ? reject : 'recovered' }

    assert_equal 'recovered', result
    assert_equal 3, calls
  end

  def test_gives_up_when_rejected_after_logging_in
    calls = 0
    assert_raises(Teems::ApiError) { command(refreshes: true).run { (calls += 1) && reject } }
    assert_equal 3, calls
  end

  def test_silent_login_renews_tokens_without_safari
    extractor = Teems::TestHelpers::SilentOnlyExtractor.new(TOKENS)
    calls = 0
    silent = command(refreshes: false, extractor: extractor, silent: true)
    result = silent.run { (calls += 1) == 1 ? reject : 'renewed' }

    assert_equal 'renewed', result
    assert_equal 1, extractor.silent_calls
  end

  def test_a_login_whose_tokens_cannot_be_saved_counts_as_failed
    runner_store = MockTokenStore.new
    runner_store.define_singleton_method(:save) { |**| raise Teems::TokenStoreError, 'disk full' }
    cmd = command(refreshes: false, store: runner_store)

    error = assert_raises(Teems::ApiError) { cmd.run { reject } }
    assert_equal 'Re-authentication failed', error.message
  end

  private

  def reject = raise(Teems::ApiError.new('Invalid token', status_code: 401))

  def command(refreshes:, extractor: full_extractor, silent: false, store: MockTokenStore.new)
    runner = test_runner
    runner.define_singleton_method(:refresh_tokens) { refreshes }
    runner.define_singleton_method(:token_extractor) { |**| extractor }
    runner.define_singleton_method(:token_store) { store }
    LoginCommand.new([], runner: runner, silent: silent)
  end

  def full_extractor
    Object.new.tap { |extractor| extractor.define_singleton_method(:extract) { TOKENS } }
  end
end
