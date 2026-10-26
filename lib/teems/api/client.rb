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

      # options: body: (sent as JSON) and headers:
      def post(path, **)
        @api.post(endpoint, path, account: @account, **)
      end

      def patch(path, **)
        @api.patch(endpoint, path, account: @account, **)
      end

      def post_to(target_endpoint, request)
        @api.post(target_endpoint, request[:path], account: @account, body: request[:body])
      end

      def delete(path)
        @api.delete(endpoint, path, account: @account)
      end

      # The items of a Graph collection from its first response, following @odata.nextLink
      # (sent with the same headers) until the last page, or until limit items are in hand
      # (no page is fetched past them)
      def collect_pages(response, headers: {}, limit: nil)
        items = Enumerator.new do |yielder|
          loop do
            Array(response['value']).each(&yielder)
            link = response['@odata.nextLink'] or break
            response = get(link, headers: headers)
          end
        end
        limit ? items.first(limit) : items.to_a
      end
    end
  end
end
