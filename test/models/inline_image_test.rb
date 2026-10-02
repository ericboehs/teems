# frozen_string_literal: true

require 'test_helper'

# Tests for inline (AMS) image parsing and the InlineImage value object
module InlineImageTests
  # Parsing <img> tags out of Teams message HTML
  class ParseTest < Minitest::Test
    def test_parses_ams_image_attributes
      image = parse(sample_inline_image_html).first

      assert_equal SAMPLE_AMS_OBJECT_ID, image.id
      assert_equal SAMPLE_AMS_IMAGE_URL, image.url
      assert_equal 'image', image.alt
      assert_equal [640, 120], [image.width, image.height]
      assert_equal 'png', image.format
    end

    def test_returns_empty_for_nil_or_plain_html
      assert_empty parse(nil)
      assert_empty parse('<p>No pictures here</p>')
    end

    def test_ignores_emoji_and_external_images
      html = '<img itemtype="http://schema.skype.com/Emoji" src="https://statics.example.net/smile.png" alt="smile">' \
             '<img src="https://cdn.example.com/banner.png">'
      assert_empty parse(html)
    end

    def test_detects_ams_path_without_itemtype
      image = parse(%(<img src="https://eu-api.asm.skype.com/v1/objects/0-weu-d2-abc/views/imgo">)).first

      assert_equal '0-weu-d2-abc', image.id
      assert_nil image.alt
    end

    def test_ignores_non_https_sources
      assert_empty parse(%(<img itemtype="http://schema.skype.com/AMSImage" src="http://example.com/v1/objects/a/views/imgo">))
    end

    def test_deduplicates_repeated_sources
      assert_equal 1, parse(sample_inline_image_html * 2).length
    end

    def test_unescapes_entities_and_single_quotes
      html = "<IMG SRC='https://api.ams.test.teams.microsoft.com/v1/objects/0-x/views/imgo?a=1&amp;b=2' " \
             "itemtype='http://schema.skype.com/AMSImage' alt='chart &amp; graph'>"
      image = parse(html).first

      assert_equal 'https://api.ams.test.teams.microsoft.com/v1/objects/0-x/views/imgo?a=1&b=2', image.url
      assert_equal 'chart & graph', image.alt
    end

    def test_invalid_dimensions_become_nil
      image = parse(sample_inline_image_html(width: 'auto', height: 0)).first

      assert_nil image.width
      assert_nil image.height
    end

    private

    def parse(html) = Teems::Models::InlineImage.parse_html(html)
  end

  # Derived attributes and serialization
  class ValueTest < Minitest::Test
    def test_only_url_is_required
      image = Teems::Models::InlineImage.new(url: SAMPLE_AMS_IMAGE_URL)

      assert_nil image.id
      assert_nil image.format
    end

    def test_full_size_url_swaps_the_view
      expected = SAMPLE_AMS_IMAGE_URL.sub('/views/imgo', '/views/imgpsh_fullsize_anim')
      assert_equal expected, sample_inline_image.full_size_url
    end

    def test_full_size_url_leaves_other_urls_alone
      image = Teems::Models::InlineImage.new(url: 'https://example.teams.microsoft.com/image.png')
      assert_equal image.url, image.full_size_url
    end

    def test_label_includes_alt_and_dimensions
      assert_equal 'image (640x120)', sample_inline_image.label
    end

    def test_label_defaults_when_alt_blank_and_no_dimensions
      image = Teems::Models::InlineImage.new(url: SAMPLE_AMS_IMAGE_URL, alt: '  ', width: 10)

      assert_equal 'image', image.label
      assert_nil image.dimensions
    end

    def test_file_stem_prefers_id_then_url_then_fallback
      assert_equal SAMPLE_AMS_OBJECT_ID, sample_inline_image.file_stem
      assert_equal SAMPLE_AMS_OBJECT_ID, Teems::Models::InlineImage.new(url: SAMPLE_AMS_IMAGE_URL).file_stem
      assert_equal 'image', Teems::Models::InlineImage.new(url: 'https://example.com/x.png').file_stem
    end

    def test_file_stem_is_filesystem_safe
      image = Teems::Models::InlineImage.new(id: '../evil/id', url: SAMPLE_AMS_IMAGE_URL)
      assert_equal '.._evil_id', image.file_stem
    end

    def test_as_json_adds_full_size_url
      json = sample_inline_image.as_json

      assert_equal SAMPLE_AMS_IMAGE_URL, json[:url]
      assert_includes json[:full_size_url], 'imgpsh_fullsize_anim'
    end

    def test_from_h_round_trips_stored_json
      stored = JSON.parse(JSON.generate(sample_inline_image.as_json))
      assert_equal sample_inline_image, Teems::Models::InlineImage.from_h(stored)
    end

    def test_from_h_rejects_invalid_entries
      assert_nil Teems::Models::InlineImage.from_h({ 'alt' => 'no url' })
      assert_nil Teems::Models::InlineImage.from_h('not a hash')
    end
  end
end
