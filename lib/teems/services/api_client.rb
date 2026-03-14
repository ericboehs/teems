# frozen_string_literal: true

module Teems
  module Services
    # HTTP client for Teams API with connection pooling and multi-endpoint support
    class ApiClient
      # Teams uses multiple API endpoints
      # Graph API for listing teams/channels
      # Messages API (ng.msg.gcc) for reading messages
      ENDPOINTS = {
        graph: 'https://graph.microsoft.com',
        teams: 'https://teams.microsoft.com',
        msgservice: 'https://ng.msg.gcc.teams.microsoft.com'
      }.freeze

      # Network errors that should be wrapped in ApiError
      NETWORK_ERRORS = [
        SocketError,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::ETIMEDOUT,
        Errno::EHOSTUNREACH,
        Net::OpenTimeout,
        Net::ReadTimeout,
        OpenSSL::SSL::SSLError
      ].freeze

      attr_reader :call_count
      attr_accessor :on_request, :on_response

      def initialize
        @call_count = 0
        @on_request = nil
        @on_response = nil
        @http_cache = {}
      end

      def close
        @http_cache.each_value { |http| safe_close(http) }
        @http_cache.clear
      end

      # GET request to a specific endpoint
      # path can be a relative path or a full URL (e.g., from pagination links)
      def get(endpoint_key, path, account:, params: {}, headers: {})
        base_url = ENDPOINTS[endpoint_key] or raise ArgumentError, "Unknown endpoint: #{endpoint_key}"
        full_url = path.start_with?('http') ? path : "#{base_url}#{path}"
        uri = build_uri(full_url, params)

        execute_request(path, endpoint_key) do |http|
          request = Net::HTTP::Get.new(uri)
          apply_auth_headers(request, account, endpoint_key)
          headers.each { |k, v| request[k] = v }
          http.request(request)
        end
      end

      # POST request to a specific endpoint
      def post(endpoint_key, path, account:, body: nil)
        base_url = ENDPOINTS[endpoint_key] or raise ArgumentError, "Unknown endpoint: #{endpoint_key}"
        uri = URI("#{base_url}#{path}")

        execute_request(path, endpoint_key) do |http|
          request = Net::HTTP::Post.new(uri)
          apply_auth_headers(request, account, endpoint_key)
          request.body = JSON.generate(body) if body
          http.request(request)
        end
      end

      private

      def safe_close(http)
        http.finish if http.started?
      rescue IOError
        # Connection already closed
      end

      def execute_request(path, endpoint_key)
        log_request(path)
        response = yield(get_http_for_endpoint(endpoint_key))
        log_response(path, response)
        handle_response(response, path)
      rescue *NETWORK_ERRORS => e
        raise ApiError, "Network error: #{e.message}"
      end

      def build_uri(base_path, params)
        uri = URI(base_path)
        uri.query = URI.encode_www_form(params) if params&.any?
        uri
      end

      def apply_auth_headers(request, account, endpoint_key)
        request['Content-Type'] = 'application/json'
        # Use different tokens and header formats for different endpoints
        # Graph API uses auth_token with Authorization header
        # Message service uses skype_token with Authentication header
        case endpoint_key
        when :msgservice
          # Message service uses Authentication: skypetoken=... format
          request['Authentication'] = account.skype_auth_header
        when :teams
          request['Authorization'] = "Bearer #{account.skype_token}"
        else
          request['Authorization'] = account.teams_auth_header
        end
      end

      def log_request(path)
        @call_count += 1
        @on_request&.call(path, @call_count)
      end

      def log_response(path, response)
        @on_response&.call(path, response.code)
      end

      def get_http_for_endpoint(endpoint_key)
        base_url = ENDPOINTS[endpoint_key]
        uri = URI(base_url)
        key = "#{uri.host}:#{uri.port}"

        cached = @http_cache[key]
        return cached if cached&.started?

        http = Net::HTTP.new(uri.host, uri.port)
        configure_ssl(http, uri)
        http.start

        @http_cache[key] = http
        http
      end

      def configure_ssl(http, uri)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 30
        http.keep_alive_timeout = 30

        return unless http.use_ssl?

        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.cert_store = OpenSSL::X509::Store.new
        http.cert_store.set_default_paths
      end

      def handle_response(response, _path)
        case response
        when Net::HTTPSuccess then parse_success_response(response)
        when Net::HTTPUnauthorized then raise ApiError.new('Invalid token or session expired', status_code: 401)
        when Net::HTTPForbidden then raise ApiError.new('Access forbidden', status_code: 403)
        when Net::HTTPTooManyRequests then handle_rate_limit(response)
        else raise ApiError.new("HTTP #{response.code}: #{response.message}", status_code: response.code.to_i)
        end
      end

      def handle_rate_limit(response)
        retry_after = response['Retry-After']
        raise ApiError.new("Rate limited - retry after #{retry_after} seconds", status_code: 429) if retry_after

        raise ApiError.new('Rate limited - please wait and try again', status_code: 429)
      end

      def parse_success_response(response)
        return {} if response.body.nil? || response.body.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        raise ApiError, 'Invalid JSON response from Teams API'
      end
    end
  end
end
