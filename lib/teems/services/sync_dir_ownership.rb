# frozen_string_literal: true

module Teems
  module Services
    # Keeps every chat directory owned by exactly one chat.
    #
    # Older teems versions could give several chats the same directory (see SyncDirNaming), and
    # syncing then merged their messages there. Stored messages carry no chat ID, so a shared
    # directory can't be split back into its chats reliably. Instead it is detached: the directory
    # and its files are left untouched, and each chat that used it forgets it (recording the path
    # under 'legacy_shared_dir') and re-syncs into its own directory, starting from the oldest
    # message in the shared one ('resync_from') so no history is left behind only there.
    module SyncDirOwnership
      # One chat's claim on a directory relative to chats/. A detached claim (attached: false) is a
      # directory the chat no longer syncs into but whose files still hold its older messages.
      DirClaim = Data.define(:chat_id, :path, :attached) do
        def key = SyncDirOwnership.fold(path)

        # A chat's claims: the directory it syncs into, and the shared one it was detached from
        def self.for_entry(chat_id, entry)
          name, legacy = entry.values_at('dir_name', 'legacy_shared_dir')
          own = new(chat_id, File.join(SyncDirNaming.type_dir(entry['chat_type']), name), true) if name
          [own, (new(chat_id, legacy, false) if legacy)].compact
        end
      end

      # Directory names compare case-insensitively and NFC-normalized, as on macOS and Windows
      def self.fold(path) = path.unicode_normalize(:nfc).downcase(:fold)

      # Directories that more than one chat has synced into, with the chats still syncing into
      # them: { "groups/Group Chat (19_abc)" => [chat_id, ...] }. With only:, just that chat.
      # Chats that never synced (404 on their first sync) don't count: nothing of theirs is there.
      def shared_dirs(state, only: nil)
        owner_claims(state.fetch('chats', {})).group_by(&:key).values.filter_map do |claims|
          shared_dir_entry(claims, only)
        end.to_h
      end

      # Detaches shared directories (see #shared_dirs) from their chats; returns what it detached
      def detach_shared_dirs(state, only: nil)
        shared = shared_dirs(state, only: only)
        chats = state['chats']
        oldest = shared.keys.to_h { |path| [path, oldest_message_time(path)] }
        shared.flat_map { |path, ids| ids.product([path]) }.each do |id, path|
          detach_entry(chats[id], path, oldest[path])
        end
        shared
      end

      # Directories chats were detached from that still exist: { path => [chat_id, ...] }
      def legacy_shared_dirs(state)
        detached = dir_claims(state.fetch('chats', {})).reject(&:attached)
        existing = detached.group_by(&:path).select { |path, _claims| File.directory?(chats_path(path)) }
        existing.transform_values { |claims| claims.map(&:chat_id) }
      end

      # Where a detached chat's re-sync starts: the oldest message in the directory it left
      def resync_from(state, chat_id) = parse_synced_at(state.dig('chats', chat_id, 'resync_from'))

      private

      def owner_claims(chats) = dir_claims(chats.select { |_id, entry| ever_synced?(entry) })

      def dir_claims(chats) = chats.flat_map { |id, entry| DirClaim.for_entry(id, entry) }

      # Only update_chat_state writes the first two. last_synced_at alone isn't enough: cursors get
      # cleared to force a re-fetch, which doesn't make the chat's existing files go away. A detached
      # chat's older messages are in its legacy_shared_dir.
      def ever_synced?(entry) = entry.values_at('last_synced_at', 'message_count', 'legacy_shared_dir').any?

      def shared_dir_entry(claims, only)
        return if claims.map(&:chat_id).uniq.one?

        attached = claims.select(&:attached)
        ids = attached.map(&:chat_id)
        ids &= [only] if only
        [attached.first.path, ids] unless ids.empty?
      end

      # Any claim by another chat blocks a new name, even one that never synced (it may be mid-run)
      def dir_claimed?(others, path) = claims_dir?(dir_claims(others), path)

      # Whether another chat has files in the directory, so it must not be moved or reused
      def owned?(others, path) = claims_dir?(owner_claims(others), path)

      def claims_dir?(claims, path)
        key = SyncDirOwnership.fold(path)
        claims.any? { |claim| claim.key == key }
      end

      def fallback_dir_name(chat_id) = "#{sanitize_id(chat_id)}-#{Digest::SHA256.hexdigest(chat_id)[0, 8]}"

      def detach_entry(entry, path, oldest)
        entry.delete('dir_name')
        entry.delete('last_synced_at')
        entry['legacy_shared_dir'] = path
        entry['resync_from'] = oldest.iso8601 if oldest
      end

      # Read-only on purpose: unlike load_json_or_default it never renames a corrupt file
      def oldest_message_time(path)
        messages = JSON.parse(File.read(File.join(chats_path(path), 'messages.json')))
        Array(messages).filter_map { |msg| parse_synced_at(msg['created_at']) if msg.is_a?(Hash) }.min
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def chats_path(path) = File.join(sync_dir, SyncStore::CHATS_DIR, path)
    end
  end
end
