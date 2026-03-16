# frozen_string_literal: true

module Teems
  module Models
    # Rich user profile with extended fields for who/org commands
    UserProfile = Data.define(
      :id,
      :display_name,
      :email,
      :user_principal_name,
      :job_title,
      :department,
      :office_location,
      :business_phones,
      :mobile_phone
    ) do
      def self.from_api(data)
        new(**identity_attrs(data), **detail_attrs(data))
      end

      def self.identity_attrs(data)
        { id: data['id'], display_name: data['displayName'],
          email: data['mail'] || data['email'], user_principal_name: data['userPrincipalName'] }
      end

      def self.detail_attrs(data)
        { job_title: data['jobTitle'], department: data['department'],
          office_location: data['officeLocation'],
          business_phones: data['businessPhones'] || [], mobile_phone: data['mobilePhone'] }
      end

      def best_name
        [display_name, email, user_principal_name, id].find { |value| value && !value.empty? }
      end

      def json_attrs
        [to_h, id]
      end

      def search_display
        [best_name, job_title, email]
      end
    end
  end
end
