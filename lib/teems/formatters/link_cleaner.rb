# frozen_string_literal: true

module Teems
  module Formatters
    # Cleans the hrefs listed in a mail links footer. SafeLinks wrappers are unwrapped and
    # click tracking is dropped (utm_* everywhere, plus SharePoint and Teams noise on
    # SharePoint hosts). Every other query parameter is kept with its original encoding.
    module LinkCleaner
      SAFELINKS_HOSTS = %w[.safelinks.protection.outlook.com .safelinks.protection.office365.us].freeze
      SHAREPOINT_HOSTS = %w[.sharepoint.com .sharepoint.us].freeze
      # ASP.NET reads query keys case-insensitively, so these are matched that way too
      SHAREPOINT_NOISE = %w[xsdata sdata ovuser clickparams teamscid ct linkopentime or].freeze
      # Not web pages: mail and phone links, inline images, scripts
      SKIP_SCHEMES = %w[mailto: tel: cid: javascript: data: sms: callto: about:].freeze
      URL_PARTS = %r{\A(?<head>[a-z][a-z0-9+.-]*://(?<host>[^/?#]*)[^?#]*)(?:\?(?<query>[^#]*))?(?<frag>#.*)?\z}im

      module_function

      def skip?(href)
        href.empty? || href.start_with?('#') || href.downcase.start_with?(*SKIP_SCHEMES)
      end

      def clean(href)
        url = unwrap_safelinks(href.gsub(/[\t\r\n]/, '').strip)
        drop_tracking(url).gsub(' ', '%20')
      end

      # SafeLinks wraps the real URL in its url param, sometimes more than once when a
      # message has been forwarded around
      def unwrap_safelinks(url)
        5.times do
          inner = safelinks_target(url)
          break unless inner

          url = inner
        end
        url
      end

      def safelinks_target(url)
        parts = URL_PARTS.match(url)
        return unless parts && host_of(parts).end_with?(*SAFELINKS_HOSTS)

        URI.decode_www_form(parts[:query].to_s).assoc('url')&.last&.strip
      rescue ArgumentError
        nil
      end

      def drop_tracking(url)
        parts = URL_PARTS.match(url)
        query = parts&.[](:query)
        return url if query.to_s.empty?

        pairs = query.split('&', -1)
        noise = host_of(parts).end_with?(*SHAREPOINT_HOSTS) ? SHAREPOINT_NOISE : []
        kept = pairs.reject { |pair| tracking_param?(pair, noise) }
        kept.length == pairs.length ? url : rebuild(parts, kept)
      end

      def tracking_param?(pair, noise)
        name = unescape(pair.split('=', 2).first.to_s).downcase
        pair.empty? || name.start_with?('utm_') || noise.include?(name)
      end

      def rebuild(parts, kept)
        query = kept.empty? ? '' : "?#{kept.join('&')}"
        "#{parts[:head]}#{query}#{parts[:frag]}"
      end

      # Link text that is a URL, or just repeats the start of this one, adds nothing.
      # Compared without scheme, leading www. and trailing slashes.
      def label(text, url, max:)
        text = text.delete("\u200b\ufeff").gsub(/[[:space:]]+/, ' ').strip
        return '' if text.empty? || text.match?(%r{\A(https?://|www\.)}i) || prefix_of_url?(text, url)

        text.length > max ? "#{text[0, max - 3].rstrip}..." : text
      end

      def prefix_of_url?(text, url)
        bare_text = bare(text)
        bare_text.match?(%r{[./]}) && bare(url).start_with?(bare_text)
      end

      def bare(text) = text.downcase.sub(%r{\A([a-z][a-z0-9+.-]*://)?(www\.)?}, '').sub(%r{/+\z}, '')

      def host_of(parts) = parts[:host].sub(/\A.*@/, '').sub(/:\d*\z/, '').downcase

      def unescape(text) = text.gsub(/%(\h\h)/) { Regexp.last_match(1).hex.chr }
    end
  end
end
