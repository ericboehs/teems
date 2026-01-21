# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/teems'
require 'stringio'

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
        ENV['XDG_CONFIG_HOME'] = dir
        ENV['XDG_CACHE_HOME'] = "#{dir}/cache"
        yield dir
      ensure
        ENV['XDG_CONFIG_HOME'] = old_config
        ENV['XDG_CACHE_HOME'] = old_cache
      end
    end

    # Mock API client for testing
    class MockApiClient
      attr_reader :calls, :call_count
      attr_accessor :on_request, :on_response

      def initialize
        @calls = []
        @call_count = 0
        @responses = {}
      end

      def stub(path, response)
        @responses[path] = response
      end

      def get(_endpoint, path, account:, params: {})
        @calls << { method: :get, path: path, params: params }
        @call_count += 1
        @responses[path] || { 'value' => [] }
      end

      def post(_endpoint, path, account:, body: nil)
        @calls << { method: :post, path: path, body: body }
        @call_count += 1
        @responses[path] || {}
      end

      def close
        # no-op for tests
      end
    end
  end
end
