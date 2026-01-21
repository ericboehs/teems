# frozen_string_literal: true

module Teems
  module Api
    # Base API client for Teams endpoints
    class Client
      def initialize(api_client, account)
        @api = api_client
        @account = account
      end

      protected

      def get(endpoint, path, params: {})
        @api.get(endpoint, path, account: @account, params: params)
      end

      def post(endpoint, path, body: nil)
        @api.post(endpoint, path, account: @account, body: body)
      end
    end
  end
end
