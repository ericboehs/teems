# frozen_string_literal: true

module Teems
  module Services
    # HTTP connection pool management for API endpoints
    module ConnectionPool
      ENDPOINTS = {
        graph: 'https://graph.microsoft.com',
        teams: 'https://teams.microsoft.com',
        msgservice: 'https://ng.msg.gcc.teams.microsoft.com'
      }.freeze

      private

      def get_http_for_endpoint(endpoint_key)
        uri = URI(ENDPOINTS[endpoint_key])
        cache_key = "#{uri.host}:#{uri.port}"
        (http = @http_cache[cache_key])&.started? ? http : @http_cache[cache_key] = start_http(uri)
      end

      def start_http(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = (uri.scheme == 'https')
          http.open_timeout = 10
          http.read_timeout = 30
          http.keep_alive_timeout = 30
          configure_ssl(http) if http.use_ssl?
          http.start
        end
      end

      def configure_ssl(http)
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
      end
    end

    # HTTP client for Teams API with connection pooling and multi-endpoint support
    class ApiClient
      include ConnectionPool

      NETWORK_ERRORS = [
        SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
        Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
      ].freeze

      attr_reader :call_count
      attr_accessor :on_request, :on_response

      def initialize
        @call_count = 0
        @on_request = @on_response = nil
        @http_cache = {}
      end

      def close
        @http_cache.each_value do |http|
          http.finish if http.started?
        rescue IOError
          nil
        end
        @http_cache.clear
      end

      def get(endpoint_key, path, account:, params: {}, headers: {})
        uri = resolve_uri(endpoint_key, path, params)
        execute_request(path, endpoint_key) do |http|
          req = Net::HTTP::Get.new(uri)
          apply_auth(req, account, endpoint_key)
          headers.each { |k, v| req[k] = v }
          http.request(req)
        end
      end

      def post(endpoint_key, path, account:, body: nil)
        uri = URI("#{resolve_endpoint(endpoint_key)}#{path}")
        execute_request(path, endpoint_key) do |http|
          req = Net::HTTP::Post.new(uri)
          apply_auth(req, account, endpoint_key)
          req.body = JSON.generate(body) if body
          http.request(req)
        end
      end

      private

      def resolve_uri(endpoint_key, path, params)
        URI(path.start_with?('http') ? path : "#{resolve_endpoint(endpoint_key)}#{path}").tap do |uri|
          uri.query = URI.encode_www_form(params) if params&.any?
        end
      end

      def resolve_endpoint(key) = ENDPOINTS[key] || raise(ArgumentError, "Unknown endpoint: #{key}")

      def apply_auth(request, account, endpoint_key)
        request['Content-Type'] = 'application/json'
        case endpoint_key
        when :msgservice then request['Authentication'] = account.skype_auth_header
        when :teams      then request['Authorization'] = "Bearer #{account.skype_token}"
        else                  request['Authorization'] = account.teams_auth_header
        end
      end

      def execute_request(path, endpoint_key)
        @call_count += 1
        @on_request&.call(path, @call_count)
        response = yield(get_http_for_endpoint(endpoint_key))
        @on_response&.call(path, response.code)
        handle_response(response)
      rescue *NETWORK_ERRORS => e
        raise ApiError, "Network error: #{e.message}"
      end

      def handle_response(response)
        case response
        when Net::HTTPSuccess        then parse_json_body(response)
        when Net::HTTPUnauthorized   then raise ApiError.new('Invalid token or session expired', status_code: 401)
        when Net::HTTPForbidden      then raise ApiError.new('Access forbidden', status_code: 403)
        when Net::HTTPTooManyRequests then raise_rate_limit(response)
        else raise ApiError.new("HTTP #{response.code}: #{response.message}", status_code: response.code.to_i)
        end
      end

      def raise_rate_limit(response)
        retry_after = response['Retry-After']
        suffix = retry_after ? "retry after #{retry_after} seconds" : 'please wait and try again'
        raise ApiError.new("Rate limited - #{suffix}", status_code: 429)
      end

      def parse_json_body(response)
        return {} if response.body.nil? || response.body.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        raise ApiError, 'Invalid JSON response from Teams API'
      end
    end
  end
end
