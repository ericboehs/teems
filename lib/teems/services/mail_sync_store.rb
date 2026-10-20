# frozen_string_literal: true

module Teems
  module Services
    # On-disk layout for `teems mail sync`:
    #
    #   <root>/<Folder>/<YYYY-MM-DD>-<subject>-<short id>.md   one file per message
    #   <root>/<Folder>/index.json                             message ID -> file and summary
    #   <root>/<Folder>/attachments/<short id>/                with --attachments
    #
    # <Folder> is the folder path with "/" as "-", as outlook-cli named them, so its files
    # are adopted. A folder whose name another folder's index already claims (Projects/Reports
    # and a top-level Projects-Reports), or that is no usable directory name ("." or ".."),
    # gets "<Folder> (<8 hex digits>)" instead.
    #
    # Delta links and the run lock live in the XDG state dir, outside the root, so a run that
    # changes no mail changes nothing under the root (watchers keyed on mtimes stay quiet).
    class MailSyncStore
      include SyncFileOps

      INDEX_FILE = 'index.json'
      STATE_FILE = 'mail-sync.json'
      UNUSABLE_NAMES = ['', '.', '..'].freeze

      attr_reader :root

      def self.default_root = File.join(Support::XdgPaths.new.data_dir, SyncStore::SYNC_DIR, 'mail')

      def self.default_state_dir
        File.join(ENV.fetch('XDG_STATE_HOME') { File.join(Dir.home, '.local', 'state') }, 'teems')
      end

      def initialize(root: MailSyncStore.default_root, state_dir: MailSyncStore.default_state_dir)
        @root = File.expand_path(root)
        @state_dir = state_dir
        @folder_dirs = {}
      end

      def folder_dir(folder_path) = @folder_dirs[folder_path] ||= File.join(root, dir_name(folder_path))

      def index_exists?(folder_path) = File.file?(index_path(folder_path))

      def load_index(folder_path)
        read_json(index_path(folder_path)).fetch('messages', {})
      end

      def save_index(folder_path, messages)
        dir = ensure_dir(folder_dir(folder_path))
        atomic_write(File.join(dir, INDEX_FILE),
                     JSON.pretty_generate('version' => 1, 'folder' => folder_path, 'messages' => messages))
      end

      # :created, :updated, or :unchanged (identical content is never rewritten)
      def write_message(folder_path, filename, content)
        path = File.join(ensure_dir(folder_dir(folder_path)), filename)
        existed = File.exist?(path)
        return :unchanged if existed && File.read(path) == content

        atomic_write(path, content)
        existed ? :updated : :created
      end

      # Delta state for this root, keyed by Graph folder ID
      def load_state
        folders = read_json(state_path).dig('roots', root, 'folders')
        folders.is_a?(Hash) ? folders : {}
      end

      def save_state(folders)
        data = read_json(state_path)
        (data['roots'] ||= {})[root] = { 'folders' => folders }
        ensure_dir(@state_dir)
        atomic_write(state_path, JSON.pretty_generate(data))
      end

      # Yields while holding the mail sync lock; returns :locked without yielding if another run holds it
      def with_lock
        ensure_dir(@state_dir)
        File.open(File.join(@state_dir, 'mail-sync.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
          return :locked unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      private

      def index_path(folder_path) = File.join(folder_dir(folder_path), INDEX_FILE)

      def dir_name(folder_path)
        name = folder_path.tr('/', '-')
        return name unless UNUSABLE_NAMES.include?(name) || claimed_by_another?(name, folder_path)

        "#{name} (#{Digest::SHA256.hexdigest(folder_path)[0, 8]})"
      end

      # An index records the folder path it was saved for
      def claimed_by_another?(name, folder_path)
        read_json(File.join(root, name, INDEX_FILE)).fetch('folder', folder_path) != folder_path
      end

      def state_path = File.join(@state_dir, STATE_FILE)

      def ensure_dir(dir)
        FileUtils.mkdir_p(dir, mode: 0o700)
        dir
      end

      # A JSON object from the file, or {} for anything else
      def read_json(path)
        data = load_json_or_default(path, {})
        data.is_a?(Hash) ? data : {}
      end
    end
  end
end
