# frozen_string_literal: true

module Teems
  module Models
    # An Inbox rule from Microsoft Graph. conditions, exceptions and actions keep Graph's shape
    # (camelCase keys) because they are passed back unchanged and described as they are.
    MailRule = Data.define(:id, :name, :sequence, :enabled, :has_error, :conditions, :exceptions, :actions) do
      def self.from_api(data)
        new(id: data['id'], name: Support::ControlChars.strip(data['displayName'].to_s),
            sequence: data['sequence'].to_i, enabled: data['isEnabled'] == true, has_error: data['hasError'] == true,
            conditions: data['conditions'] || {}, exceptions: data['exceptions'] || {},
            actions: data['actions'] || {})
      end

      # Rules that send mail on; teems lists them but will not turn them on
      def forwards? = actions.keys.intersect?(MAIL_RULE_SENDING_ACTIONS)

      def folder_ids = actions.values_at('moveToFolder', 'copyToFolder').compact

      def state
        return 'error' if has_error

        enabled ? 'on' : 'off'
      end

      def columns = [sequence, state, name]

      def tsv_row(description) = [id, sequence, state, name, description].join("\t")

      def to_json_hash(description)
        { id: id, name: name, sequence: sequence, enabled: enabled, has_error: has_error,
          description: description, conditions: conditions, exceptions: exceptions, actions: actions }
      end
    end

    MAIL_RULE_SENDING_ACTIONS = %w[forwardTo forwardAsAttachmentTo redirectTo].freeze
  end
end
