# frozen_string_literal: true

require 'test_helper'

class BrowserTest < Minitest::Test
  Status = Struct.new(:success?)
  URL = 'https://outlook.office365.com/owa/?ItemID=1'

  def open_with(result)
    calls = []
    fake = lambda do |*command|
      calls << command
      raise result if result.is_a?(Class)

      result
    end
    value = Teems::Support::Subprocess.stub(:capture3, fake) { Teems::Services::Browser.new.open(URL) }
    [value, calls]
  end

  def test_opens_the_url_with_macos_open
    value, calls = open_with(['', '', Status.new(true)])

    assert_equal URL, value
    assert_equal [['open', URL]], calls
  end

  def test_a_failure_says_why
    error = assert_raises(Teems::Error) { open_with(['', "LSOpenURLsWithRole() failed\n", Status.new(false)]) }

    assert_equal 'Could not open the browser: LSOpenURLsWithRole() failed', error.message
  end

  def test_without_the_open_command
    error = assert_raises(Teems::Error) { open_with(Errno::ENOENT) }

    assert_includes error.message, 'macOS open command'
  end
end
