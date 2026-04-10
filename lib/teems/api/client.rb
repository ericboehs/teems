# frozen_string_literal: true

module Teems
  module Api
    # Base API client for Teams endpoints
    class Client
      ENDPOINT = :graph

      def initialize(api_client, account)
        @api = api_client
        @account = account
      end

      protected

      def endpoint = self.class::ENDPOINT

      def get(path, params: {}, headers: {})
        @api.get(endpoint, path, account: @account, params: params, headers: headers)
      end

      def post(path, body: nil)
        @api.post(endpoint, path, account: @account, body: body)
      end

      def patch(path, body: nil)
        @api.patch(endpoint, path, account: @account, body: body)
      end

      def post_to(target_endpoint, request)
        @api.post(target_endpoint, request[:path], account: @account, body: request[:body])
      end

      def delete(path)
        base_url = Services::ConnectionPool::DEFAULT_ENDPOINTS[endpoint]
        @api.delete("#{base_url}#{path}", endpoint_key: endpoint, account: @account)
      end
    end
  end
end
