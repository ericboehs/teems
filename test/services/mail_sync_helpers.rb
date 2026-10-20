# frozen_string_literal: true

require 'tmpdir'

# Helpers for mail sync tests: a temp store root and state dir plus legacy outlook-cli files
module MailSyncTestHelpers
  def with_store
    Dir.mktmpdir('teems-mail-sync') do |dir|
      @tmp = dir
      yield Teems::Services::MailSyncStore.new(root: File.join(dir, 'Mail'), state_dir: File.join(dir, 'state'))
    end
  end

  # fields: id, subject and date as outlook-cli wrote them
  def write_legacy(store, folder, file, **fields)
    id, subject, date = fields.values_at(:id, :subject, :date)
    dir = store.folder_dir(folder)
    FileUtils.mkdir_p(dir)
    optional = fields.slice(:from, :to).map { |key, value| %(#{key}: "#{value}"\n) }.join
    File.write(File.join(dir, file), <<~MD)
      ---
      id: #{id}
      subject: "#{subject.gsub('"', '\\"')}"
      #{optional}date: "#{date}"
      ---

      # #{subject}
    MD
  end

  def mail(id, **overrides) = Teems::Models::MailMessage.from_api(sample_mail_message('id' => id, **overrides))

  def with_tz(zone = 'America/Chicago')
    saved = ENV.fetch('TZ', nil)
    ENV['TZ'] = zone
    yield
  ensure
    ENV['TZ'] = saved
  end
end
