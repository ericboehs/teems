# frozen_string_literal: true

module Teems
  module Support
    # Header fields with parameters, e.g. `text/plain; charset="utf-8"` (RFC 2045), including
    # RFC 2231 (filename*=utf-8''...) and RFC 2047 encoded words (=?utf-8?B?...?=)
    module MimeHeader
      ENCODED_WORD = /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/
      # Parameters split on ";" outside quotes
      PARAMS = /(?:"(?:\\.|[^"\\])*"|[^;"])+/

      module_function

      # [lowercased value, { lowercased name => value }]
      def field(text)
        value, *params = text.to_s.scan(PARAMS)
        [value.to_s.strip.downcase, params.to_h { |param| parameter(param) }]
      end

      def parameter(text)
        name, value = text.split('=', 2)
        value = value.to_s.strip
        value = value[1...-1].gsub(/\\(.)/, '\1') if value.start_with?('"') && value.end_with?('"')
        [name.strip.downcase, value]
      end

      # A parameter's text, preferring the RFC 2231 form (name*) when present
      def decoded(params, name)
        extended = params["#{name}*"]
        return percent_decoded(extended) if extended

        plain = params[name]
        words_decoded(plain) if plain
      end

      def percent_decoded(text)
        charset, _language, encoded = text.split("'", 3)
        return text unless encoded

        transcode(encoded.gsub(/%(\h\h)/) { ::Regexp.last_match(1).hex.chr }, charset)
      end

      def words_decoded(text)
        text.gsub(ENCODED_WORD) do
          charset, kind, encoded = ::Regexp.last_match.captures
          bytes = kind.casecmp?('B') ? encoded.unpack1('m') : encoded.tr('_', ' ').unpack1('M')
          transcode(bytes, charset)
        end
      end

      # Bytes in charset as UTF-8; unknown charsets are read as UTF-8, and bad bytes become "?"
      def transcode(bytes, charset)
        text = bytes.dup
        encoding = Encoding.find(charset.to_s.strip.empty? ? 'UTF-8' : charset)
        text.force_encoding(encoding).encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      rescue ArgumentError
        text.force_encoding('UTF-8').scrub('?')
      end
    end
  end
end
