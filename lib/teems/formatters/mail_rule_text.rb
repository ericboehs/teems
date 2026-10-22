# frozen_string_literal: true

module Teems
  module Formatters
    # One line saying what an Inbox rule does, e.g.
    #   from jira@example.com, except subject has "urgent" -> move to Inbox/Jira, stop
    # Keys this does not know are spelled out from their Graph names, so nothing is hidden.
    class MailRuleText
      LABELS = {
        'fromAddresses' => 'from', 'sentToAddresses' => 'to', 'subjectContains' => 'subject has',
        'bodyContains' => 'body has', 'bodyOrSubjectContains' => 'subject or body has',
        'senderContains' => 'sender has', 'recipientContains' => 'recipient has',
        'headerContains' => 'header has', 'moveToFolder' => 'move to', 'copyToFolder' => 'copy to',
        'assignCategories' => 'categories', 'markImportance' => 'importance',
        'forwardTo' => 'FORWARD to', 'forwardAsAttachmentTo' => 'FORWARD as attachment to',
        'redirectTo' => 'REDIRECT to'
      }.freeze
      # Conditions and actions that are simply on
      SWITCHES = { 'markAsRead' => 'mark read', 'stopProcessingRules' => 'stop',
                   'delete' => 'delete', 'permanentDelete' => 'PERMANENTLY delete',
                   'isMeetingRequest' => 'meeting requests', 'hasAttachments' => 'with attachments' }.freeze
      FOLDER_ACTIONS = %w[moveToFolder copyToFolder].freeze

      # folder_names: Graph folder ID => path, to name a rule's destination
      def initialize(folder_names = {})
        @folder_names = folder_names
      end

      def describe(rule)
        exceptions = phrases(rule.exceptions)
        tests = phrases(rule.conditions).join(', ')
        tests = 'all mail' if tests.empty?
        tests += ", except #{exceptions.join(', ')}" if exceptions.any?
        "#{tests} -> #{phrases(rule.actions).join(', ')}"
      end

      private

      def phrases(settings) = settings.filter_map { |key, value| phrase(key, value) }

      def phrase(key, value)
        return if [false, nil, []].include?(value)

        switch = value == true
        label = (switch ? SWITCHES : LABELS).fetch(key) { spelled(key) }
        switch ? label : "#{label} #{values_text(key, value)}"
      end

      def values_text(key, value) = Array(value).map { |item| item_text(key, item) }.join(', ')

      def item_text(key, item)
        return @folder_names.fetch(item, 'another folder') if FOLDER_ACTIONS.include?(key)
        return recipient_text(item) if item.is_a?(Hash)

        key.end_with?('Contains') ? %("#{item}") : item.to_s
      end

      def recipient_text(item)
        address = item['emailAddress'] || item
        address.values_at('address', 'name').compact.first.to_s
      end

      # isAutomaticReply -> is automatic reply
      def spelled(key) = key.gsub(/[A-Z]/) { |letter| " #{letter.downcase}" }
    end
  end
end
