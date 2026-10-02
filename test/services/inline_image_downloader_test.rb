# frozen_string_literal: true

require 'test_helper'

# Tests for fetching inline images from Teams' AMS object store
module InlineImageDownloaderTests
  PNG = "\x89PNG\r\n\x1A\n-synthetic-png".b
  FULL_SIZE_URL = Teems::SampleData::SAMPLE_AMS_IMAGE_URL.sub('/views/imgo', '/views/imgpsh_fullsize_anim')

  # Records requests and replays canned responses
  class MockHttp
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def call(uri, headers)
      @requests << { url: uri.to_s, headers: headers }
      @responses.shift or raise 'unexpected request'
    end
  end

  # Canned Net::HTTP responses
  module Responses
    module_function

    def ok(body)
      Net::HTTPResponse::CODE_TO_OBJ['200'].new('1.1', '200', 'OK').tap do |response|
        response.instance_variable_set(:@body, body)
        response.instance_variable_set(:@read, true)
      end
    end

    def status(code)
      Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, 'Status')
    end

    def redirect(location)
      status('302').tap { |response| response['location'] = location if location }
    end
  end

  # Shared setup
  module Helpers
    include Responses

    private

    def downloader(http, token: 'skype-test-token')
      Teems::Services::InlineImageDownloader.new(token_provider: -> { token }, http_client: http)
    end

    def image(url = Teems::SampleData::SAMPLE_AMS_IMAGE_URL) = Teems::Models::InlineImage.new(url: url)
  end

  # Successful fetches and view fallback
  class FetchTest < Minitest::Test
    include Helpers

    def test_fetches_full_size_view_with_skype_token
      http = MockHttp.new(ok(PNG))
      result = downloader(http).fetch(image)

      assert_equal PNG, result.body
      assert_equal 'png', result.extension
      assert_equal FULL_SIZE_URL, result.url
      assert_equal({ 'Authorization' => 'skype_token skype-test-token' }, http.requests.first[:headers])
    end

    def test_falls_back_to_src_when_full_size_view_missing
      http = MockHttp.new(status('404'), ok("\xFF\xD8\xFF\xE0jpeg".b))
      result = downloader(http).fetch(image)

      assert_equal 'jpg', result.extension
      assert_equal([FULL_SIZE_URL, Teems::SampleData::SAMPLE_AMS_IMAGE_URL], http.requests.map { |req| req[:url] })
    end

    def test_raises_when_every_view_is_missing
      http = MockHttp.new(status('400'), status('410'))
      error = assert_raises(Teems::Services::InlineImageErrors::ViewUnavailable) { downloader(http).fetch(image) }
      assert_equal 410, error.status_code
    end

    def test_no_fallback_when_src_is_already_full_size
      http = MockHttp.new(status('404'))
      assert_raises(Teems::Services::InlineImageErrors::ViewUnavailable) { downloader(http).fetch(image(FULL_SIZE_URL)) }
      assert_equal 1, http.requests.length
    end

    def test_detects_gif_and_webp
      assert_equal 'gif', downloader(MockHttp.new(ok('GIF89a-synthetic'))).fetch(image).extension
      assert_equal 'webp', downloader(MockHttp.new(ok('RIFF0000WEBPVP8 '))).fetch(image).extension
    end

    def test_rejects_non_image_bodies
      error = assert_raises(Teems::Error) { downloader(MockHttp.new(ok('<html>sign in</html>'))).fetch(image) }
      assert_includes error.message, 'not an image'
    end
  end

  # Auth failures, server errors, redirects, and credential safety
  class SafetyTest < Minitest::Test
    include Helpers

    def test_unauthorized_raises_refreshable_api_error
      error = assert_raises(Teems::ApiError) { downloader(MockHttp.new(status('401'))).fetch(image) }
      assert_predicate error, :unauthorized?
    end

    def test_server_error_raises_api_error
      error = assert_raises(Teems::ApiError) { downloader(MockHttp.new(status('503'))).fetch(image) }
      assert_equal 'HTTP 503', error.message
    end

    def test_refuses_untrusted_hosts_without_requesting
      http = MockHttp.new
      %w[https://evil.example.com/v1/objects/x/views/imgo http://api.ams.test.teams.microsoft.com/v1/objects/x/views/imgo]
        .each { |url| assert_raises(Teems::Error) { downloader(http).fetch(image(url)) } }
      assert_empty http.requests
    end

    def test_redirect_to_untrusted_host_drops_credentials
      http = MockHttp.new(redirect('https://blob.example.net/signed'), ok(PNG))
      downloader(http).fetch(image)

      assert_equal 'https://blob.example.net/signed', http.requests.last[:url]
      assert_empty http.requests.last[:headers]
    end

    def test_relative_redirect_keeps_credentials_on_same_host
      http = MockHttp.new(redirect('/v1/objects/other/views/imgo'), ok(PNG))
      downloader(http).fetch(image)

      assert_includes http.requests.last[:headers]['Authorization'], 'skype_token'
    end

    def test_too_many_or_empty_redirects_raise
      looping = MockHttp.new(redirect(FULL_SIZE_URL), redirect(FULL_SIZE_URL), redirect(FULL_SIZE_URL),
                             redirect(FULL_SIZE_URL))
      assert_raises(Teems::Error) { downloader(looping).fetch(image) }
      assert_raises(Teems::Error) { downloader(MockHttp.new(redirect(nil))).fetch(image) }
    end

    def test_reads_token_for_each_request
      tokens = %w[first second]
      http = MockHttp.new(status('404'), ok(PNG))
      Teems::Services::InlineImageDownloader.new(token_provider: -> { tokens.shift }, http_client: http).fetch(image)

      sent = http.requests.map { |req| req[:headers]['Authorization'] }
      assert_equal ['skype_token first', 'skype_token second'], sent
    end
  end

  # The default transport uses Net::HTTP over TLS
  class NetHttpTest < Minitest::Test
    include Responses

    # Stands in for a started Net::HTTP session
    FakeSession = Struct.new(:response, :sent) do
      def request(req)
        self.sent = req['Authorization']
        response
      end
    end

    def test_uses_net_http_when_no_client_injected
      session = FakeSession.new(ok(PNG))
      captured = {}
      result = with_stubbed_start(capturing_start(captured, session)) do
        Teems::Services::InlineImageDownloader.new(token_provider: -> { 'tok' })
                                              .fetch(Teems::Models::InlineImage.new(url: FULL_SIZE_URL))
      end

      assert_equal({ host: 'api.ams.test.teams.microsoft.com', port: 443, ssl: true }, captured)
      assert_equal ['png', 'skype_token tok'], [result.extension, session.sent]
    end

    private

    def capturing_start(captured, session)
      lambda do |host, port, **opts, &block|
        captured.merge!(host: host, port: port, ssl: opts[:use_ssl])
        block.call(session)
      end
    end

    def with_stubbed_start(replacement)
      original = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start, &replacement)
      yield
    ensure
      Net::HTTP.define_singleton_method(:start, original)
    end
  end
end
