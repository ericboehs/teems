# frozen_string_literal: true

require 'test_helper'

# Tests for Account model creation, validation, and auth header generation
module AccountTests
  # Tests Account construction, token validation, and string freezing
  class BasicTest < Minitest::Test
    def test_creates_account_with_required_tokens
      account = Teems::Models::Account.new(name: 'default', auth_token: 'eyJ0test', skype_token: 'eyJ1test')
      assert_equal 'default', account.name
      assert_equal 'eyJ0test', account.auth_token
      assert_equal 'eyJ1test', account.skype_token
      assert_nil account.chatsvc_token
    end

    def test_creates_account_with_optional_chatsvc_token
      account = Teems::Models::Account.new(
        name: 'default', auth_token: 'eyJ0test', skype_token: 'eyJ1test', chatsvc_token: 'eyJ2test'
      )
      assert_equal 'eyJ2test', account.chatsvc_token
    end

    def test_raises_when_auth_token_empty
      error = assert_raises(ArgumentError) do
        Teems::Models::Account.new(name: 'default', auth_token: '', skype_token: 'eyJ1test')
      end
      assert_equal 'auth_token is required', error.message
    end

    def test_raises_when_auth_token_nil
      error = assert_raises(ArgumentError) do
        Teems::Models::Account.new(name: 'default', auth_token: nil, skype_token: 'eyJ1test')
      end
      assert_equal 'auth_token is required', error.message
    end

    def test_raises_when_skype_token_empty
      error = assert_raises(ArgumentError) do
        Teems::Models::Account.new(name: 'default', auth_token: 'eyJ0test', skype_token: '')
      end
      assert_equal 'skype_token is required', error.message
    end

    def test_raises_when_skype_token_nil
      error = assert_raises(ArgumentError) do
        Teems::Models::Account.new(name: 'default', auth_token: 'eyJ0test', skype_token: nil)
      end
      assert_equal 'skype_token is required', error.message
    end

    def test_strings_are_frozen
      account = mock_account
      assert account.name.frozen?
      assert account.auth_token.frozen?
      assert account.skype_token.frozen?
    end

    def test_name_converts_to_string
      account = Teems::Models::Account.new(name: :symbolic_name, auth_token: 'eyJ0test', skype_token: 'eyJ1test')
      assert_equal 'symbolic_name', account.name
    end
  end

  # Tests auth header formatting for Teams, Skype, and chatsvc endpoints
  class HeadersTest < Minitest::Test
    def test_teams_auth_header_format
      assert_equal 'Bearer my-auth-token', mock_account(auth_token: 'my-auth-token').teams_auth_header
    end

    def test_skype_auth_header_format
      assert_equal 'skypetoken=my-skype-token', mock_account(skype_token: 'my-skype-token').skype_auth_header
    end

    def test_chatsvc_auth_header_when_present
      account = Teems::Models::Account.new(
        name: 'default', auth_token: 'eyJ0test', skype_token: 'eyJ1test', chatsvc_token: 'my-chatsvc-token'
      )
      assert_equal 'Bearer my-chatsvc-token', account.chatsvc_auth_header
    end

    def test_chatsvc_auth_header_when_nil
      assert_nil mock_account.chatsvc_auth_header
    end

    def test_teams_headers_includes_auth_and_content_type
      headers = mock_account(auth_token: 'my-token').teams_headers
      assert_equal 'Bearer my-token', headers['Authorization']
      assert_equal 'application/json', headers['Content-Type']
    end

    def test_skype_headers_includes_auth_and_content_type
      headers = mock_account(skype_token: 'my-skype').skype_headers
      assert_equal 'skypetoken=my-skype', headers['Authentication']
      assert_equal 'application/json', headers['Content-Type']
    end
  end
end
