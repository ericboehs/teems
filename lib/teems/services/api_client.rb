# frozen_string_literal: true

module Teems
  module Services
    # HTTP connection pool management for API endpoints
    module ConnectionPool
      DEFAULT_ENDPOINTS = {
        graph: 'https://graph.microsoft.com',
        teams: 'https://teams.microsoft.com',
        msgservice: 'https://amer.ng.msg.teams.microsoft.com',
        presence: 'https://presence.teams.microsoft.com'
      }.freeze

      TIMEOUTS = { open_timeout: 10, read_timeout: 30, keep_alive_timeout: 30 }.freeze

      private

      def get_http_for_endpoint(endpoint_key)
        uri = URI(resolve_endpoint(endpoint_key))
        cache_key = "#{uri.host}:#{uri.port}"
        (http = @http_cache[cache_key])&.started? ? http : @http_cache[cache_key] = start_http(uri)
      end

      def start_http(uri)
        build_http(uri.host, uri.port, ssl_scheme?(uri)).tap(&:start)
      end

      def ssl_scheme?(uri) = uri.scheme == 'https'

      def build_http(host, port, use_ssl)
        http = Net::HTTP.new(host, port)
        apply_timeouts(http)
        http.use_ssl = use_ssl
        configure_ssl(http) if use_ssl
        http
      end

      def apply_timeouts(http)
        TIMEOUTS.each { |attr, val| http.send(:"#{attr}=", val) }
      end

      def configure_ssl(http)
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
      end
    end

    # POST/PATCH request methods, extracted to manage class size
    module WriteRequests
      def post(endpoint_key, path, **options)
        account = options.delete(:account)
        body = options.delete(:body)
        req = Net::HTTP::Post.new(URI("#{resolve_endpoint(endpoint_key)}#{path}"))
        apply_auth(req, account, endpoint_key)
        req.body = JSON.generate(body) if body
        run_request(path, get_http_for_endpoint(endpoint_key)) { |http| http.request(req) }
      end

      def patch(endpoint_key, path, **options)
        account = options.delete(:account)
        body = options.delete(:body)
        req = Net::HTTP::Patch.new(URI("#{resolve_endpoint(endpoint_key)}#{path}"))
        apply_auth(req, account, endpoint_key)
        req.body = JSON.generate(body) if body
        run_request(path, get_http_for_endpoint(endpoint_key)) { |http| http.request(req) }
      end
    end

    # HTTP response handling for API client
    module ResponseHandler
      private

      def handle_response(response)
        return parse_json_body(response) if response.is_a?(Net::HTTPSuccess)

        raise_http_error(response)
      end

      def raise_http_error(response)
        case response
        when Net::HTTPUnauthorized   then raise ApiError.new('Invalid token or session expired', status_code: 401)
        when Net::HTTPForbidden      then raise ApiError.new('Access forbidden', status_code: 403)
        when Net::HTTPTooManyRequests then raise_rate_limit(response)
        else
          code = response.code
          raise ApiError.new("HTTP #{code}: #{response.message}", status_code: code.to_i)
        end
      end

      def raise_rate_limit(response)
        retry_after = response['Retry-After']
        suffix = retry_after ? "retry after #{retry_after} seconds" : 'please wait and try again'
        raise ApiError.new("Rate limited - #{suffix}", status_code: 429)
      end

      def parse_json_body(response)
        body = response.body
        return {} if body.to_s.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        raise ApiError, 'Invalid JSON response from Teams API'
      end
    end

    # HTTP client for Teams API with connection pooling and multi-endpoint support
    class ApiClient
      include ConnectionPool
      include ResponseHandler
      include WriteRequests

      NETWORK_ERRORS = [
        SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
        Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
      ].freeze

      AUTH_HEADERS = {
        msgservice: ->(account) { ['Authentication', account.skype_auth_header] },
        teams: ->(account) { ['Authorization', "Bearer #{account.skype_token}"] },
        presence: ->(account) { ['Authorization', "Bearer #{account.presence_token}"] }
      }.freeze
      DEFAULT_AUTH_HEADER = ->(account) { ['Authorization', account.teams_auth_header] }

      attr_reader :call_count

      def initialize(on_request: nil, on_response: nil, endpoints: {})
        @call_count = 0
        @callbacks = { on_request: on_request, on_response: on_response }
        @http_cache = {}
        @endpoints = DEFAULT_ENDPOINTS.merge(endpoints.transform_keys(&:to_sym))
      end

      def on_request = @callbacks[:on_request]
      def on_response = @callbacks[:on_response]

      def on_request=(callback)
        close_idle_connections
        @callbacks[:on_request] = callback
      end

      def on_response=(callback)
        close_idle_connections
        @callbacks[:on_response] = callback
      end

      def close
        @http_cache.each_value do |http|
          http.finish if http.started?
        rescue IOError
          nil
        end
        @http_cache.clear
      end

      def get(endpoint_key, path, **options)
        account = options.delete(:account)
        base_url = resolve_endpoint(endpoint_key)
        uri = build_request_uri(base_url, path, options.fetch(:params, {}))
        req = Net::HTTP::Get.new(uri)
        apply_headers(req, options.fetch(:headers, {}))
        apply_auth(req, account, endpoint_key)
        run_request(path, get_http_for_endpoint(endpoint_key)) { |http| http.request(req) }
      end

      def delete(endpoint_key, path, account:)
        uri = URI("#{resolve_endpoint(endpoint_key)}#{path}")
        run_request(path, get_http_for_endpoint(endpoint_key)) do |http|
          req = Net::HTTP::Delete.new(uri)
          apply_auth(req, account, endpoint_key)
          http.request(req)
        end
      end

      private

      def close_idle_connections
        @http_cache.select! { |_key, http| http.started? }
      end

      def apply_headers(request, headers)
        headers.each { |key, value| request[key] = value }
      end

      def build_request_uri(base_url, path, params)
        URI(path.start_with?('http') ? path : "#{base_url}#{path}").tap do |uri|
          uri.query = URI.encode_www_form(params) if params&.any?
        end
      end

      def resolve_endpoint(key) = @endpoints[key] || raise(ArgumentError, "Unknown endpoint: #{key}")

      def apply_auth(request, account, endpoint_key)
        request['Content-Type'] = 'application/json'
        header, value = AUTH_HEADERS.fetch(endpoint_key, DEFAULT_AUTH_HEADER).call(account)
        request[header] = value
      end

      def run_request(path, http)
        track_request(path)
        response = yield(http)
        process_response(path, response)
      rescue *NETWORK_ERRORS => e
        raise ApiError, "Network error: #{e.message}"
      end

      def track_request(path)
        @call_count += 1
        @callbacks[:on_request]&.call(path, @call_count)
      end

      def process_response(path, response)
        @callbacks[:on_response]&.call(path, response.code)
        handle_response(response)
      end
    end
  end
end
