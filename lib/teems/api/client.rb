# frozen_string_literal: true

module Teems
  module Api
    # Base API client for Teams endpoints
    class Client
      ENDPOINT = :graph
      ENDPOINT_URLS = {
        graph: 'https://graph.microsoft.com',
        teams: 'https://teams.microsoft.com',
        msgservice: 'https://ng.msg.gcc.teams.microsoft.com',
        presence: 'https://presence.gcc.teams.microsoft.com'
      }.freeze

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

      def post_to(target_endpoint, path, body: nil)
        @api.post(target_endpoint, path, account: @account, body: body)
      end

      def delete(path)
        @api.delete("#{ENDPOINT_URLS[endpoint]}#{path}", endpoint_key: endpoint, account: @account)
      end
    end
  end
end
