# frozen_string_literal: true

require 'test_helper'

class MailFolderTest < Minitest::Test
  def test_from_api_with_parent_path
    folder = Teems::Models::MailFolder.from_api(sample_mail_folder('EERT', 'childFolderCount' => 1),
                                                parent_path: 'Projects')

    assert_equal 'Projects/EERT', folder.path
    assert_equal 'EERT', folder.name
    assert_equal [2, 10, 1], [folder.unread_count, folder.total_count, folder.child_count]
    assert_equal folder.to_h, folder.to_json_hash
  end
end
