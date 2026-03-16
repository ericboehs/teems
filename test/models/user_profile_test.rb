# frozen_string_literal: true

require 'test_helper'

module UserProfileTests
  FULL_PROFILE = {
    'id' => 'user-uuid-123', 'displayName' => 'John Doe',
    'mail' => 'john.doe@example.com', 'userPrincipalName' => 'john.doe@example.onmicrosoft.com',
    'jobTitle' => 'Senior Engineer', 'department' => 'Engineering',
    'officeLocation' => 'Building A, Room 302',
    'businessPhones' => ['+1 (555) 123-4567'], 'mobilePhone' => '+1 (555) 987-6543'
  }.freeze

  class FromApiTest < Minitest::Test
    def test_extracts_identity_fields
      profile = Teems::Models::UserProfile.from_api(FULL_PROFILE)

      assert_equal 'user-uuid-123', profile.id
      assert_equal 'John Doe', profile.display_name
      assert_equal 'john.doe@example.com', profile.email
      assert_equal 'john.doe@example.onmicrosoft.com', profile.user_principal_name
    end

    def test_extracts_detail_fields
      profile = Teems::Models::UserProfile.from_api(FULL_PROFILE)

      assert_equal 'Senior Engineer', profile.job_title
      assert_equal 'Engineering', profile.department
      assert_equal 'Building A, Room 302', profile.office_location
      assert_equal ['+1 (555) 123-4567'], profile.business_phones
      assert_equal '+1 (555) 987-6543', profile.mobile_phone
    end

    def test_uses_email_fallback
      data = { 'id' => 'user-123', 'displayName' => 'John', 'email' => 'john@example.com' }
      profile = Teems::Models::UserProfile.from_api(data)

      assert_equal 'john@example.com', profile.email
    end

    def test_prefers_mail_over_email
      data = { 'id' => 'user-123', 'mail' => 'preferred@example.com', 'email' => 'fallback@example.com' }

      assert_equal 'preferred@example.com', Teems::Models::UserProfile.from_api(data).email
    end

    def test_handles_missing_fields
      profile = Teems::Models::UserProfile.from_api({})

      assert_nil profile.id
      assert_nil profile.display_name
      assert_nil profile.job_title
      assert_equal [], profile.business_phones
      assert_nil profile.mobile_phone
    end
  end

  class BestNameTest < Minitest::Test
    def test_returns_display_name
      assert_equal 'John Doe', Teems::Models::UserProfile.from_api(FULL_PROFILE).best_name
    end

    def test_falls_back_to_email
      data = { 'id' => 'user-123', 'mail' => 'john@example.com' }

      assert_equal 'john@example.com', Teems::Models::UserProfile.from_api(data).best_name
    end

    def test_falls_back_to_upn
      data = { 'id' => 'user-123', 'userPrincipalName' => 'john@example.onmicrosoft.com' }

      assert_equal 'john@example.onmicrosoft.com', Teems::Models::UserProfile.from_api(data).best_name
    end

    def test_falls_back_to_id
      assert_equal 'user-last', Teems::Models::UserProfile.from_api({ 'id' => 'user-last' }).best_name
    end

    def test_skips_empty_strings
      data = { 'id' => 'user-123', 'displayName' => '', 'mail' => 'john@example.com' }

      assert_equal 'john@example.com', Teems::Models::UserProfile.from_api(data).best_name
    end

    def test_returns_nil_for_all_empty
      assert_nil Teems::Models::UserProfile.from_api({}).best_name
    end
  end

  class ToHashTest < Minitest::Test
    def test_returns_identity_keys
      hash = Teems::Models::UserProfile.from_api(FULL_PROFILE).to_h

      assert_equal 'user-uuid-123', hash[:id]
      assert_equal 'John Doe', hash[:display_name]
      assert_equal 'john.doe@example.com', hash[:email]
    end

    def test_returns_detail_keys
      hash = Teems::Models::UserProfile.from_api(FULL_PROFILE).to_h

      assert_equal 'Senior Engineer', hash[:job_title]
      assert_equal 'Engineering', hash[:department]
      assert_equal 'Building A, Room 302', hash[:office_location]
      assert_equal ['+1 (555) 123-4567'], hash[:business_phones]
    end
  end

  class SearchDisplayTest < Minitest::Test
    def test_returns_name_title_email
      profile = Teems::Models::UserProfile.from_api(FULL_PROFILE)
      name, title, email = profile.search_display

      assert_equal 'John Doe', name
      assert_equal 'Senior Engineer', title
      assert_equal 'john.doe@example.com', email
    end
  end

  class JsonAttrsTest < Minitest::Test
    def test_returns_hash_and_id
      profile = Teems::Models::UserProfile.from_api(FULL_PROFILE)
      attrs, user_id = profile.json_attrs

      assert_instance_of Hash, attrs
      assert_equal 'user-uuid-123', user_id
    end
  end
end
