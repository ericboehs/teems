# frozen_string_literal: true

require 'test_helper'

# Tests User model field extraction, email fallback logic, and best_name resolution
class UserTest < Minitest::Test
  def test_from_api_extracts_fields
    user = Teems::Models::User.from_api(sample_user_data)
    assert_equal 'user-uuid-123', user.id
    assert_equal 'John Doe', user.display_name
    assert_equal 'john.doe@example.com', user.email
    assert_equal 'john.doe@example.onmicrosoft.com', user.user_principal_name
  end

  def test_from_api_uses_email_fallback
    data = {
      'id' => 'user-123',
      'displayName' => 'John Doe',
      'email' => 'john@example.com' # 'email' instead of 'mail'
    }

    user = Teems::Models::User.from_api(data)

    assert_equal 'john@example.com', user.email
  end

  def test_from_api_prefers_mail_over_email
    data = {
      'id' => 'user-123',
      'displayName' => 'John Doe',
      'mail' => 'preferred@example.com',
      'email' => 'fallback@example.com'
    }

    user = Teems::Models::User.from_api(data)

    assert_equal 'preferred@example.com', user.email
  end

  def test_best_name_returns_display_name
    data = {
      'id' => 'user-123',
      'displayName' => 'John Doe',
      'mail' => 'john@example.com',
      'userPrincipalName' => 'john@example.onmicrosoft.com'
    }

    user = Teems::Models::User.from_api(data)

    assert_equal 'John Doe', user.best_name
  end

  def test_best_name_falls_back_to_email
    data = {
      'id' => 'user-123',
      'mail' => 'john@example.com',
      'userPrincipalName' => 'john@example.onmicrosoft.com'
    }

    user = Teems::Models::User.from_api(data)

    assert_equal 'john@example.com', user.best_name
  end

  def test_best_name_falls_back_to_upn
    data = {
      'id' => 'user-123',
      'userPrincipalName' => 'john@example.onmicrosoft.com'
    }

    user = Teems::Models::User.from_api(data)

    assert_equal 'john@example.onmicrosoft.com', user.best_name
  end

  def test_best_name_falls_back_to_id
    data = {
      'id' => 'user-uuid-last-resort'
    }

    user = Teems::Models::User.from_api(data)

    assert_equal 'user-uuid-last-resort', user.best_name
  end

  def test_handles_all_nil_fields
    data = {}

    user = Teems::Models::User.from_api(data)

    assert_nil user.id
    assert_nil user.display_name
    assert_nil user.email
    assert_nil user.user_principal_name
    assert_nil user.best_name
  end

  def test_handles_empty_display_name
    data = {
      'id' => 'user-123',
      'displayName' => '',
      'mail' => 'john@example.com'
    }

    user = Teems::Models::User.from_api(data)

    # Empty string should fall back to email
    assert_equal 'john@example.com', user.best_name
  end

  def test_to_s_delegates_to_best_name
    data = { 'id' => 'user-123', 'displayName' => 'John Doe', 'mail' => 'john@example.com' }
    user = Teems::Models::User.from_api(data)

    assert_equal 'John Doe', user.to_s
  end

  def test_to_s_with_nil_display_name
    data = { 'id' => 'user-123', 'mail' => 'john@example.com' }
    user = Teems::Models::User.from_api(data)

    assert_equal 'john@example.com', user.to_s
  end

  private

  def sample_user_data
    {
      'id' => 'user-uuid-123',
      'displayName' => 'John Doe',
      'mail' => 'john.doe@example.com',
      'userPrincipalName' => 'john.doe@example.onmicrosoft.com'
    }
  end
end
