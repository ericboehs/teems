# frozen_string_literal: true

require 'test_helper'

class SmimeDecryptorTest < Minitest::Test
  Status = Struct.new(:success?)

  def decrypt_with(result, envelope: 'cipher')
    calls = []
    fake = lambda do |*command|
      calls << command
      raise result if result.is_a?(Class)

      result
    end
    value = Teems::Support::Subprocess.stub(:capture3, fake) { Teems::Services::SmimeDecryptor.new.decrypt(envelope) }
    [value, calls]
  end

  def test_plaintext_from_security_cms
    plain, calls = decrypt_with(['plain', '', Status.new(true)])

    assert_equal 'plain', plain
    assert_equal ['security', 'cms', '-D', { stdin_data: 'cipher', binmode: true }], calls.first
  end

  def test_not_a_recipient
    error = assert_raises(Teems::Error) do
      decrypt_with(['', "security: failed to add data to decoder: UNKNOWN (-8147(d)\n", Status.new(false)])
    end

    assert_includes error.message, 'None of your keys can open this message'
    assert_includes error.message, 'PIV card inserted?'
  end

  def test_other_failure_shows_first_error_line
    error = assert_raises(Teems::Error) do
      decrypt_with(['', "\nsecurity: user canceled (-128)\nsecurity: problem decoding\n", Status.new(false)])
    end

    assert_equal 'Could not decrypt the message: user canceled (-128)', error.message
  end

  def test_failure_without_detail
    error = assert_raises(Teems::Error) { decrypt_with(['', '', Status.new(false)]) }

    assert_equal 'Could not decrypt the message', error.message
  end

  def test_missing_security_command
    error = assert_raises(Teems::Error) { decrypt_with(Errno::ENOENT) }

    assert_equal 'Decrypting needs the macOS security command', error.message
  end
end
