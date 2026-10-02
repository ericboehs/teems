# frozen_string_literal: true

require 'test_helper'

# Tests for saving inline images beside synced chats
class SyncImagesTest < Minitest::Test
  Result = Teems::Services::InlineImageDownloader::Result

  # Downloader double that returns a PNG or raises, and records what it fetched
  class FakeDownloader
    attr_reader :fetched

    def initialize(error: nil)
      @error = error
      @fetched = []
    end

    def fetch(image)
      @fetched << image.file_stem
      raise @error if @error

      Result.new(body: "\x89PNG-synthetic".b, extension: 'png', url: image.url)
    end
  end

  def setup
    @dir = Dir.mktmpdir('teems-sync-images-')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_saves_each_image_once_by_object_id
    downloader = FakeDownloader.new
    saved = sync_images(downloader).save(@dir, [image_message, image_message])

    assert_equal 1, saved
    assert_equal "\x89PNG-synthetic".b, File.binread(File.join(@dir, 'images', "#{SAMPLE_AMS_OBJECT_ID}.png"))
  end

  def test_skips_images_already_on_disk
    write_image("#{SAMPLE_AMS_OBJECT_ID}.jpg")
    downloader = FakeDownloader.new

    assert_equal 0, sync_images(downloader).save(@dir, [image_message])
    assert_empty downloader.fetched
  end

  def test_download_failure_warns_and_continues
    result = capture_output do |out|
      saved = sync_images(FakeDownloader.new(error: Teems::ApiError.new('HTTP 403')), out).save(@dir, [image_message])
      assert_equal 0, saved
    end
    assert_includes result[:stderr], "Could not download image #{SAMPLE_AMS_OBJECT_ID}: HTTP 403"
  end

  def test_download_failure_without_output_is_silent
    assert_equal 0, sync_images(FakeDownloader.new(error: Teems::Error.new('nope')), nil).save(@dir, [image_message])
  end

  def test_saved_ignores_partial_downloads_and_missing_dirs
    assert_empty Teems::Services::SyncImages.saved(@dir)
    write_image('half.png.tmp')
    write_image('done.gif')

    assert_equal({ 'done' => 'done.gif' }, Teems::Services::SyncImages.saved(@dir))
  end

  def test_link_resolver_points_at_saved_files_only
    write_image("#{SAMPLE_AMS_OBJECT_ID}.png")
    resolver = Teems::Services::SyncImages.link_resolver(@dir)

    assert_equal "images/#{SAMPLE_AMS_OBJECT_ID}.png", resolver.call(sample_inline_image)
    assert_nil resolver.call(Teems::Models::InlineImage.new(id: 'other', url: SAMPLE_AMS_IMAGE_URL))
  end

  private

  def sync_images(downloader, output = test_output)
    Teems::Services::SyncImages.new(downloader: downloader, output: output)
  end

  def image_message = Teems::Models::Message.from_api(sample_image_message)

  def write_image(name)
    FileUtils.mkdir_p(File.join(@dir, 'images'))
    File.write(File.join(@dir, 'images', name), 'x')
  end
end
