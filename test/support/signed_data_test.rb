# frozen_string_literal: true

require 'test_helper'
require 'smime_fixtures'

class SignedDataTest < Minitest::Test
  include SmimeFixtures

  def test_content_of_opaque_signature
    assert_equal "Content-Type: text/plain\r\n\r\nsigned",
                 Teems::Support::SignedData.content(smime_signed("Content-Type: text/plain\r\n\r\nsigned"))
  end

  def test_enveloped_data_is_refused
    error = assert_raises(Teems::Error) { Teems::Support::SignedData.content(smime_envelope('inner')) }

    assert_includes error.message, 'encrypted again inside'
  end

  def test_garbage_is_reported
    error = assert_raises(Teems::Error) { Teems::Support::SignedData.content('not der') }

    assert_includes error.message, 'Could not read the signed content'
  end
end
