# frozen_string_literal: true

require 'test_helper'

class MailFoldersTest < Minitest::Test
  def setup
    @client = MockApiClient.new
    @folders = Teems::Services::MailFolders.new(Teems::Api::Mail.new(@client, mock_account))
  end

  def stub_tree
    projects = sample_mail_folder('Projects', 'childFolderCount' => 1)
    @client.stub("mailFolders/#{projects['id']}/childFolders", { 'value' => [sample_mail_folder('EERT')] })
    @client.stub('/v1.0/me/mailFolders', { 'value' => [sample_mail_folder, projects, sample_mail_folder('eert')] })
  end

  def test_all_walks_children_with_paths
    stub_tree

    assert_equal %w[Inbox Projects Projects/EERT eert], @folders.all.map(&:path)
    @folders.all

    assert_equal 2, @client.calls.length
  end

  def test_resolve_id_shortcuts
    assert_equal 'sentitems', @folders.resolve_id(' Sent Items ')
    assert_equal 'deleteditems', @folders.resolve_id('trash')
    long_id = 'A' * 80

    assert_equal long_id, @folders.resolve_id(long_id)
    assert_empty @client.calls
  end

  def test_resolve_by_path_then_name
    stub_tree

    assert_equal 'Projects/EERT', @folders.resolve('projects/eert').path
    assert_equal 'eert', @folders.resolve('EERT').path
    assert_equal sample_mail_folder('EERT')['id'], @folders.resolve_id('Projects/EERT')
  end

  def test_resolve_well_known_and_ids_look_up_the_folder
    @client.stub('/mailFolders/', sample_mail_folder('Archive'))

    folder = @folders.resolve('archive')

    assert_equal 'Archive', folder.path
    assert_equal '/v1.0/me/mailFolders/archive', @client.calls.last[:path]
    @folders.resolve('B' * 80)

    assert_equal "/v1.0/me/mailFolders/#{'B' * 80}", @client.calls.last[:path]
  end

  def test_resolve_unknown
    stub_tree

    error = assert_raises(Teems::Error) { @folders.resolve('Nope') }
    assert_match(/Mail folder not found: Nope/, error.message)
  end
end
