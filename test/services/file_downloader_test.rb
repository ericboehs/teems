# frozen_string_literal: true

require 'test_helper'

# Tests for the FileDownloader service
module FileDownloaderTests
  # Mock HTTP client that returns pre-configured responses
  class MockHttp
    attr_accessor :responses

    def initialize
      @responses = []
      @call_index = 0
    end

    def call(_uri)
      response = @responses[@call_index]
      @call_index += 1
      response
    end
  end

  # Helper to build mock HTTP responses
  module ResponseBuilder
    def success_response(body)
      response = Net::HTTPResponse::CODE_TO_OBJ['200'].new('1.1', '200', 'OK')
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      response
    end

    def redirect_response(location)
      response = Net::HTTPResponse::CODE_TO_OBJ['302'].new('1.1', '302', 'Found')
      response['location'] = location
      response
    end

    def error_response(code)
      response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, 'Error')
      response.instance_variable_set(:@body, '')
      response.instance_variable_set(:@read, true)
      response
    end
  end

  # Tests for successful downloads, redirects, and error handling
  class DownloadTest < Minitest::Test
    include ResponseBuilder

    def setup
      @mock_http = MockHttp.new
      @downloader = Teems::Services::FileDownloader.new(http_client: @mock_http)
      @tmpdir = Dir.mktmpdir('teems-dl-test')
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_download_writes_file
      @mock_http.responses = [success_response('file content here')]
      path = File.join(@tmpdir, 'test.txt')
      bytes = @downloader.download('https://example.com/file.txt', path)
      assert_equal 'file content here', File.read(path)
      assert_equal 17, bytes
    end

    def test_download_follows_redirect
      @mock_http.responses = [
        redirect_response('https://cdn.example.com/file.txt'),
        success_response('redirected content')
      ]
      path = File.join(@tmpdir, 'redirected.txt')
      @downloader.download('https://example.com/file.txt', path)
      assert_equal 'redirected content', File.read(path)
    end

    def test_download_follows_multiple_redirects
      @mock_http.responses = [
        redirect_response('https://step1.example.com/file'),
        redirect_response('https://step2.example.com/file'),
        success_response('final content')
      ]
      path = File.join(@tmpdir, 'multi.txt')
      @downloader.download('https://example.com/file', path)
      assert_equal 'final content', File.read(path)
    end

    def test_download_raises_on_too_many_redirects
      @mock_http.responses = Array.new(6) { redirect_response('https://loop.example.com/file') }
      assert_raises(Teems::Error) do
        @downloader.download('https://example.com/file', File.join(@tmpdir, 'loop.txt'))
      end
    end

    def test_download_raises_on_http_error
      @mock_http.responses = [error_response('404')]
      assert_raises(Teems::Error) do
        @downloader.download('https://example.com/missing', File.join(@tmpdir, 'missing.txt'))
      end
    end

    def test_download_raises_on_server_error
      @mock_http.responses = [error_response('500')]
      error = assert_raises(Teems::Error) do
        @downloader.download('https://example.com/broken', File.join(@tmpdir, 'broken.txt'))
      end
      assert_includes error.message, 'HTTP 500'
    end

    def test_download_binary_content
      binary = "\x00\x01\x02\xFF\xFE".b
      @mock_http.responses = [success_response(binary)]
      path = File.join(@tmpdir, 'binary.bin')
      @downloader.download('https://example.com/binary', path)
      assert_equal binary, File.binread(path)
    end
  end
end
