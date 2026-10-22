# frozen_string_literal: true

require 'test_helper'

class MailRulesApiTest < Minitest::Test
  PATH = '/v1.0/me/mailFolders/inbox/messageRules'

  def setup
    @client = MockApiClient.new
    @api = Teems::Api::MailRules.new(@client, mock_account)
  end

  def test_list_follows_pages
    @client.stub("#{PATH}?page=2", { 'value' => [sample_mail_rule('Two')] })
    @client.stub(PATH,
                 { 'value' => [sample_mail_rule('One')],
                   '@odata.nextLink' => "https://graph.microsoft.com#{PATH}?page=2" })

    assert_equal(%w[One Two], @api.list.map { |rule| rule['displayName'] })
  end

  def test_list_without_rules
    assert_empty @api.list
  end

  def test_create_update_and_destroy
    @api.create({ 'displayName' => 'New' })
    @api.update('abc/d=', { isEnabled: false })
    @api.destroy('abc/d=')

    assert_equal([[:post, PATH, { 'displayName' => 'New' }],
                  [:patch, "#{PATH}/abc%2Fd%3D", { isEnabled: false }],
                  [:delete, "#{PATH}/abc%2Fd%3D", nil]],
                 @client.calls.map { |call| call.values_at(:method, :path, :body) })
  end
end
