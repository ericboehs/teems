# frozen_string_literal: true

module Teems
  module Formatters
    # Decodes the HTML character references found in mail bodies
    module HtmlEntities
      ENTITY = /&(?:#(\d{1,7})|#[xX](\h{1,6})|([a-zA-Z][a-zA-Z0-9]{1,31}));?/
      NAMED = {
        'amp' => '&', 'lt' => '<', 'gt' => '>', 'quot' => '"', 'apos' => "'", 'nbsp' => "\u00a0",
        'ensp' => "\u2002", 'emsp' => "\u2003", 'thinsp' => "\u2009", 'zwnj' => "\u200c", 'zwj' => "\u200d",
        'shy' => "\u00ad", 'ndash' => "\u2013", 'mdash' => "\u2014", 'lsquo' => "\u2018", 'rsquo' => "\u2019",
        'sbquo' => "\u201a", 'ldquo' => "\u201c", 'rdquo' => "\u201d", 'bdquo' => "\u201e",
        'hellip' => "\u2026", 'bull' => "\u2022", 'middot' => "\u00b7", 'copy' => "\u00a9", 'reg' => "\u00ae",
        'trade' => "\u2122", 'deg' => "\u00b0", 'times' => "\u00d7", 'divide' => "\u00f7",
        'laquo' => "\u00ab", 'raquo' => "\u00bb", 'euro' => "\u20ac", 'pound' => "\u00a3", 'cent' => "\u00a2",
        'yen' => "\u00a5", 'sect' => "\u00a7", 'para' => "\u00b6", 'plusmn' => "\u00b1", 'micro' => "\u00b5",
        'frac12' => "\u00bd", 'frac14' => "\u00bc", 'frac34' => "\u00be", 'rarr' => "\u2192",
        'larr' => "\u2190", 'uarr' => "\u2191", 'darr' => "\u2193", 'iexcl' => "\u00a1", 'iquest' => "\u00bf"
      }.freeze

      module_function

      def decode(text)
        return text unless text.include?('&')

        text.gsub(ENTITY) do
          dec, hex, name = Regexp.last_match.captures
          name ? NAMED.fetch(name, Regexp.last_match(0)) : codepoint((dec || hex.to_i(16)).to_i)
        end
      end

      # Like browsers, 0x80-0x9F mean their Windows-1252 characters (&#146; is a right quote).
      # Other control characters decode to nothing (see Support::ControlChars).
      def codepoint(number)
        return windows_char(number) if number.between?(0x80, 0x9F)
        return '' if number.between?(0xD800, 0xDFFF) || number > 0x10FFFF

        Support::ControlChars.strip([number].pack('U'))
      end

      # '' for the five bytes Windows-1252 leaves undefined
      def windows_char(number)
        number.chr.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
      rescue EncodingError
        ''
      end
    end
  end
end
