# frozen_string_literal: true

module Teems
  module Services
    # Downloads files from pre-authenticated URLs with redirect following
    class FileDownloader
      MAX_REDIRECTS = 5

      def initialize(http_client: nil)
        @http_client = http_client
      end

      def download(url, output_path)
        response = follow_redirects(URI(url))
        File.binwrite(output_path, response.body)
      end

      private

      def follow_redirects(uri, limit = MAX_REDIRECTS)
        raise Teems::Error, 'Too many redirects' if limit.zero?

        handle_response(http_get(uri), limit)
      end

      def http_get(uri)
        return @http_client.call(uri) if @http_client

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(Net::HTTP::Get.new(uri))
        end
      end

      def handle_response(response, limit)
        case response
        when Net::HTTPSuccess then response
        when Net::HTTPRedirection then follow_redirects(URI(response['location']), limit - 1)
        else raise Teems::Error, "Download failed: HTTP #{response.code}"
        end
      end
    end
  end
end
