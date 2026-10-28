# frozen_string_literal: true

require 'test_helper'

# `teems mail open`: a message's Outlook on the web address, opened in the browser or printed
class MailOpenCommandTest < Minitest::Test
  LINK = 'https://outlook.office365.com/owa/?ItemID=AAMk-1'

  # Records what it was asked to open instead of starting a browser
  class FakeBrowser
    attr_reader :opened

    def initialize = @opened = []
    def open(url) = @opened << url
  end

  def run_mail(args, stubs: { '/v1.0/me/messages/AAMk-1' => { 'webLink' => LINK } })
    @browser = FakeBrowser.new
    browser = @browser
    capture = capture_output do |output|
      runner = configured_runner(output: output)
      runner.define_singleton_method(:browser) { browser }
      @api = runner.api_client
      stubs.each { |path, response| @api.stub(path, response) }
      @code = Teems::Commands::Mail.new(args, runner: runner).execute
    end
    capture.merge(code: @code)
  end

  def test_opens_the_web_link_in_the_browser
    with_temp_config do
      result = run_mail(%w[open AAMk-1])

      assert_equal 0, result[:code]
      assert_equal [LINK], @browser.opened
      assert_includes result[:stdout], 'Opened in Outlook on the web'
    end
  end

  # Only the link is fetched, not the message and its body
  def test_asks_graph_for_the_link_alone
    with_temp_config do
      run_mail(%w[open AAMk-1])
      call = @api.calls.first

      assert_equal({ '$select' => 'webLink' }, call[:params])
      assert_equal 'IdType="ImmutableId"', call[:headers]['Prefer']
    end
  end

  def test_print_prints_the_link_instead
    with_temp_config do
      result = run_mail(%w[open AAMk-1 --print])

      assert_equal "#{LINK}\n", result[:stdout]
      assert_empty @browser.opened
    end
  end

  def test_takes_a_short_id
    with_temp_config do
      message = Teems::Models::MailMessage.from_api(sample_mail_message('id' => 'AAMk-1'))
      Teems::Services::MailIdCache.new.remember([message])
      run_mail(['open', message.short_id])

      assert_equal [LINK], @browser.opened
    end
  end

  def test_needs_an_id_and_a_link
    with_temp_config do
      result = run_mail(%w[open])

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Usage: teems mail open <id> [--print]'

      result = run_mail(%w[open AAMk-1], stubs: { '/v1.0/me/messages/AAMk-1' => {} })

      assert_equal 1, result[:code]
      assert_includes result[:stderr], 'Graph gave no web link for that message'
      assert_empty @browser.opened
    end
  end
end
