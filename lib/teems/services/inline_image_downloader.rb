# frozen_string_literal: true

module Teems
  module Services
    # Error responses from AMS, mapped so the caller can fall back or refresh tokens
    module InlineImageErrors
      # The requested AMS view does not exist for this object (try another view)
      class ViewUnavailable < ApiError; end

      MISSING_VIEW_CODES = %w[400 404 410].freeze

      private

      def raise_failure(response)
        code = response.code
        status = code.to_i
        raise ApiError.new('Invalid token or session expired', status_code: 401) if status == 401
        raise ViewUnavailable.new("HTTP #{code}", status_code: status) if MISSING_VIEW_CODES.include?(code)

        raise ApiError.new("HTTP #{code}", status_code: status)
      end

      def untrusted_host!(uri)
        raise Error, "Refusing to send Teams credentials to untrusted image host: #{uri.host}"
      end
    end

    # Identifies image bytes by their magic number
    module ImageSignature
      SIGNATURES = { 'png' => "\x89PNG".b, 'jpg' => "\xFF\xD8\xFF".b, 'gif' => 'GIF8'.b }.freeze

      module_function

      def extension_for(body)
        bytes = body.to_s.b
        found = SIGNATURES.find { |_ext, magic| bytes.start_with?(magic) }&.first
        found || ('webp' if bytes.start_with?('RIFF') && bytes.byteslice(8, 4) == 'WEBP')
      end
    end

    # Fetches inline message images from Teams' AMS object store. AMS accepts the
    # skype token as `Authorization: skype_token <token>` (Bearer tokens get a 401).
    # Credentials are only sent over HTTPS to Microsoft Teams/Skype hosts.
    class InlineImageDownloader
      include InlineImageErrors

      # Downloaded image bytes, the file extension they imply, and the URL that served them
      Result = Data.define(:body, :extension, :url)

      TRUSTED_HOST = /(?:\A|\.)(?:asm\.skype\.com|teams\.microsoft\.com|teams\.microsoft\.us)\z/i
      MAX_REDIRECTS = 3
      TIMEOUTS = { open_timeout: 10, read_timeout: 60 }.freeze

      # token_provider is called per request so a refreshed skype token is picked up
      def initialize(token_provider:, http_client: nil)
        @token_provider = token_provider
        @http_client = http_client
      end

      # Prefers the original upload and falls back to the `src` preview when that view is missing
      def fetch(image)
        full_size = image.full_size_url
        preview = image.url
        fetch_url(full_size)
      rescue ViewUnavailable
        raise if full_size == preview

        fetch_url(preview)
      end

      def self.trusted?(uri) = uri.is_a?(URI::HTTPS) && TRUSTED_HOST.match?(uri.host.to_s)

      private

      def fetch_url(url)
        uri = URI(url)
        untrusted_host!(uri) unless self.class.trusted?(uri)

        follow(uri, MAX_REDIRECTS)
      end

      def follow(uri, redirects_left)
        response = http_get(uri)
        case response
        when Net::HTTPSuccess then build_result(response.body, uri)
        when Net::HTTPRedirection then follow_redirect(uri, response['location'], redirects_left)
        else raise_failure(response)
        end
      end

      def follow_redirect(uri, location, redirects_left)
        raise Error, 'Too many redirects' unless redirects_left.positive? && location

        follow(uri + location, redirects_left - 1)
      end

      def build_result(body, uri)
        extension = ImageSignature.extension_for(body)
        raise Error, 'Response was not an image' unless extension

        Result.new(body: body.to_s, extension: extension, url: uri.to_s)
      end

      # Redirect targets outside Teams/Skype (e.g. a signed CDN URL) get no credentials
      def http_get(uri)
        headers = self.class.trusted?(uri) ? { 'Authorization' => "skype_token #{@token_provider.call}" } : {}
        return @http_client.call(uri, headers) if @http_client

        Net::HTTP.start(uri.host, uri.port, use_ssl: true, **TIMEOUTS) do |http|
          http.request(Net::HTTP::Get.new(uri, headers))
        end
      end
    end
  end
end
