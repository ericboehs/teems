# frozen_string_literal: true

module Teems
  module Services
    # Keeps every chat directory owned by exactly one chat.
    #
    # Older teems versions could give several chats the same directory (see SyncDirNaming), and
    # syncing then merged their messages there. Stored messages carry no chat ID, so a shared
    # directory can't be split back into its chats reliably. Instead it is detached: the directory
    # and its files are left untouched, and each chat that used it forgets it (recording the path
    # under 'legacy_shared_dir') and resets its sync cursor, so it re-syncs into its own directory.
    module SyncDirOwnership
      # Directories more than one chat maps to: { "groups/Group Chat (19_abc)" => [chat_id, ...] }
      def shared_dirs(state)
        groups = dir_claims(state.fetch('chats', {})).group_by { |_id, path| fold(path) }.values
        groups.reject(&:one?).to_h { |claims| [claims.first.last, claims.map(&:first)] }
      end

      # Detaches every shared directory from its chats; returns the directories like #shared_dirs
      def detach_shared_dirs(state)
        shared = shared_dirs(state)
        chats = state['chats']
        shared.flat_map { |path, ids| ids.product([path]) }.each { |id, path| detach_entry(chats[id], path) }
        shared
      end

      private

      # [chat_id, directory relative to chats/] for every chat that has a directory
      def dir_claims(chats)
        chats.filter_map { |id, entry| [id, entry_dir(entry)] if entry['dir_name'] }
      end

      # Full chat IDs make clashes practically impossible, but on a case-insensitive filesystem
      # (the macOS default) two IDs that differ only in letter case would still share a directory.
      def dir_claimed?(state, chat_id, path)
        key = fold(path)
        dir_claims(state.fetch('chats', {}).except(chat_id)).any? { |_id, claimed| fold(claimed) == key }
      end

      def fallback_dir_name(chat_id) = "#{sanitize_id(chat_id)}-#{Digest::SHA256.hexdigest(chat_id)[0, 8]}"

      def detach_entry(entry, path)
        entry.delete('dir_name')
        entry.delete('last_synced_at')
        entry['legacy_shared_dir'] = path
      end

      def entry_dir(entry) = File.join(SyncDirNaming.type_dir(entry['chat_type']), entry['dir_name'])

      def fold(path) = path.unicode_normalize(:nfc).downcase(:fold)
    end
  end
end
