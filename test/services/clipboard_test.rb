# frozen_string_literal: true

require 'test_helper'

class ClipboardTest < Minitest::Test
  Status = Struct.new(:success?)

  def copy_with(result)
    calls = []
    fake = lambda do |*command|
      calls << command
      raise result if result.is_a?(Class)

      result
    end
    value = Teems::Support::Subprocess.stub(:capture3, fake) { Teems::Services::Clipboard.new.copy('the link') }
    [value, calls]
  end

  def test_copies_with_pbcopy_over_stdin
    value, calls = copy_with(['', '', Status.new(true)])

    assert_equal 'the link', value
    assert_equal [['pbcopy', { stdin_data: 'the link' }]], calls
  end

  def test_a_failure_says_why
    error = assert_raises(Teems::Error) { copy_with(['', "no pasteboard\n", Status.new(false)]) }

    assert_equal 'Could not copy to the clipboard: no pasteboard', error.message
  end

  def test_without_pbcopy
    error = assert_raises(Teems::Error) { copy_with(Errno::ENOENT) }

    assert_includes error.message, 'macOS pbcopy command'
  end
end
