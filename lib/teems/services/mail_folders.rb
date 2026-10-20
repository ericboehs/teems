# frozen_string_literal: true

module Teems
  module Services
    # Resolves mail folder names ("Inbox", "Sent Items", "Projects/EERT") to Graph folders.
    # Well-known folders resolve without listing the mailbox; other names match a folder's
    # display name or full path, case-insensitively.
    class MailFolders
      WELL_KNOWN = {
        'inbox' => 'inbox', 'archive' => 'archive', 'drafts' => 'drafts', 'outbox' => 'outbox',
        'sent' => 'sentitems', 'sent items' => 'sentitems', 'sentitems' => 'sentitems',
        'deleted' => 'deleteditems', 'deleted items' => 'deleteditems', 'deleteditems' => 'deleteditems',
        'trash' => 'deleteditems', 'junk' => 'junkemail', 'junk email' => 'junkemail', 'junkemail' => 'junkemail'
      }.freeze
      # Graph folder IDs are long base64url strings; nothing a person names a folder looks like one
      FOLDER_ID = /\A[A-Za-z0-9_=-]{60,}\z/

      def initialize(api)
        @api = api
        @all = nil
      end

      # Every folder, depth first, with "/"-joined paths
      def all
        @all ||= walk(@api.folders, nil)
      end

      # ID usable in a /me/mailFolders/{id} path, without a lookup where possible
      def resolve_id(name)
        well_known = well_known(name)
        return well_known if well_known
        return name if name.match?(FOLDER_ID)

        resolve(name).id
      end

      def resolve(name)
        direct = well_known(name) || (name if name.match?(FOLDER_ID))
        return Models::MailFolder.from_api(@api.folder(direct)) if direct

        find(name) or raise Error, "Mail folder not found: #{name} (run: teems mail folders)"
      end

      private

      def well_known(name) = WELL_KNOWN[name.to_s.strip.downcase]

      def find(name) = Models::MailFolder.find_named(all, name)

      def walk(items, parent_path)
        items.flat_map do |data|
          folder = Models::MailFolder.from_api(data, parent_path: parent_path)
          [folder, *children(folder)]
        end
      end

      def children(folder)
        parent_id, path = folder.child_lookup
        parent_id ? walk(@api.folders(parent_id: parent_id), path) : []
      end
    end
  end
end
