# frozen_string_literal: true

module Teems
  module Api
    # Inbox rules (Graph /me/mailFolders/inbox/messageRules), which Exchange applies to mail as
    # it arrives. teems builds rules without forwarding or redirecting actions (see
    # Commands::MailRules), so nothing here makes the mailbox send mail.
    class MailRules < Client
      RULES_PATH = '/v1.0/me/mailFolders/inbox/messageRules'

      def list = collect_pages(get(RULES_PATH)).to_a

      def create(rule) = post(RULES_PATH, body: rule)

      def update(rule_id, changes) = patch(rule_path(rule_id), body: changes)

      def destroy(rule_id) = delete(rule_path(rule_id))

      private

      def rule_path(rule_id) = "#{RULES_PATH}/#{URI.encode_www_form_component(rule_id)}"
    end
  end
end
