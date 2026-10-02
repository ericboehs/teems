# frozen_string_literal: true

require 'test_helper'

# Tests for SyncEngine message fetching, merging, pagination, and debug output
module SyncEngineTests
  # Shared builders for engine instances, message stubs, and paginated responses
  module SharedHelpers
    module_function

    def build_engine
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      Teems::Services::SyncEngine.new(
        runner: runner, sync_store: sync_store, state: sync_store.load_state, output: output
      )
    end

    def build_public_engine(method_name, verbose_err: nil)
      engine_class = Class.new(Teems::Services::SyncEngine) { public(method_name) }
      output = verbose_err ? verbose_output(verbose_err) : test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine_class.new(runner: runner, sync_store: sync_store, state: {}, output: output)
    end

    def build_nil_output_engine(method_name)
      engine_class = Class.new(Teems::Services::SyncEngine) { public(method_name) }
      runner = configured_runner
      sync_store = Teems::Services::SyncStore.new
      engine_class.new(runner: runner, sync_store: sync_store, state: {}, output: nil)
    end

    def build_verbose_engine(err:)
      output = verbose_output(err)
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      Teems::Services::SyncEngine.new(
        runner: runner, sync_store: sync_store, state: sync_store.load_state, output: output
      )
    end

    def verbose_output(err)
      Teems::Formatters::Output.new(io: StringIO.new, err: err, color: false, mode: :verbose)
    end

    def stub_messages(engine, msgs, backward_link: nil)
      runner = engine.instance_variable_get(:@runner)
      runner.api_client.stub('messages', messages_response(msgs, backward_link: backward_link))
    end

    def stub_paginated_responses(engine, responses)
      runner = engine.instance_variable_get(:@runner)
      call_count = 0
      runner.api_client.define_singleton_method(:get) do |_endpoint, _path, **_opts|
        call_count += 1
        responses[call_count - 1] || responses.last
      end
    end

    def messages_response(msgs, backward_link: nil)
      metadata = backward_link ? { 'backwardLink' => backward_link } : {}
      { 'messages' => msgs, '_metadata' => metadata }
    end

    def sample_engine_chat
      now = Time.now
      Teems::Models::Chat.new(
        id: '19:test@thread.v2', topic: 'Test', chat_type: 'group',
        created_at: now, last_updated: now,
        unread: false, favorite: false, pinned: false
      )
    end

    def build_message(**overrides)
      attrs = { id: 'x', sender_id: 'u1', sender_name: 'User', content: 'Hello',
                created_at: Time.now, message_type: 'RichText/Html',
                reply_to_id: nil, reactions: [], attachments: [], importance: nil,
                edited: false, mentions: [] }.merge(overrides)
      Teems::Models::Message.new(**attrs)
    end

    def stored_msg_hash(id, sender_name, created_at:, **overrides)
      { 'id' => id, 'sender_id' => 'u1', 'sender_name' => sender_name,
        'content' => overrides.fetch(:content, 'Hello'), 'created_at' => created_at,
        'message_type' => 'RichText/Html', 'reply_to_id' => nil,
        'reactions' => overrides.fetch(:reactions, []),
        'attachments' => overrides.fetch(:attachments, []), 'importance' => nil,
        'edited' => false, 'mentions' => [] }
    end
  end

  # Tests message fetching with pagination, filtering, cutoff detection, and verbose output
  class FetchMessagesTest < Minitest::Test
    include SharedHelpers

    def test_fetch_all_messages_empty_response
      with_temp_config do
        engine = build_engine
        stub_messages(engine, [])
        assert_equal [], engine.fetch_all_messages('19:test@thread.v2', Time.now - 86_400)
      end
    end

    def test_fetch_all_messages_single_page
      with_temp_config do
        engine = build_engine
        stub_messages(engine, [sample_ng_msg_message])
        messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))
        assert_equal 1, messages.length
        assert_equal 'Jane Smith', messages.first.sender_name
      end
    end

    def test_fetch_all_messages_with_backward_link
      with_temp_config do
        engine = build_engine
        engine.define_singleton_method(:sleep) { |_duration| nil }
        first = messages_response([sample_ng_msg_message],
                                  backward_link: 'https://api.example.com/messages?startTime=123&pageSize=200')
        second = messages_response([])
        stub_paginated_responses(engine, [first, second])
        messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))
        assert messages.length >= 1
      end
    end

    def test_fetch_all_messages_filters_system_messages
      with_temp_config do
        engine = build_engine
        stub_messages(engine, [sample_system_message, sample_ng_msg_message])
        messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))
        refute messages.any?(&:system_message?)
      end
    end

    def test_fetch_all_messages_nil_created_at_sorted
      with_temp_config do
        engine = build_engine
        no_time = sample_ng_msg_message.dup.tap do |msg|
          msg.delete('composetime')
          msg['id'] = 'no-time-msg'
        end
        stub_messages(engine, [no_time, sample_ng_msg_message])
        messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))
        assert messages.length >= 1
      end
    end

    def test_fetch_cutoff_stops_pagination
      with_temp_config do
        engine = build_engine
        old_msg = sample_ng_msg_message.dup.tap do |msg|
          msg['composetime'] = '2025-01-01T12:00:00.000Z'
          msg['id'] = 'old-msg'
        end
        stub_messages(engine, [old_msg], backward_link: 'https://api.example.com/messages?startTime=123')
        assert_equal 0, engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1)).length
      end
    end

    def test_fetch_all_messages_with_nil_created_at_msg
      with_temp_config do
        engine = build_engine
        no_time = sample_ng_msg_message.dup.tap do |msg|
          msg.delete('composetime')
          msg.delete('originalarrivaltime')
          msg['id'] = 'nil-time-msg-3'
        end
        stub_messages(engine, [sample_ng_msg_message, no_time])
        assert engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1)).length >= 1
      end
    end

    def test_verbose_debug_output
      with_temp_config do
        err = StringIO.new
        engine = build_verbose_engine(err: err)
        stub_messages(engine, [sample_ng_msg_message])
        messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))
        assert messages.length >= 1
        assert_match(/Page 1/, err.string)
      end
    end
  end

  # Tests message deduplication, stored message reconstruction, and nil timestamp handling
  class MergeTest < Minitest::Test
    include SharedHelpers

    def test_merge_and_write_deduplicates
      with_temp_config do
        engine = build_engine
        existing_raw = [stored_msg_hash('msg-1', 'Alice', created_at: '2026-01-20T10:00:00+00:00')]
        new_msg = build_message(id: 'msg-1', sender_name: 'Alice Updated', content: 'Hello Updated',
                                created_at: Time.new(2026, 1, 20, 10, 0))
        result = engine.merge_and_write(sample_engine_chat, existing_raw, [new_msg])
        assert_equal 1, result.length
        assert_equal 'Alice Updated', result.first.sender_name
      end
    end

    def test_message_from_stored
      with_temp_config do
        engine = build_engine
        data = stored_msg_hash('stored-1', 'Bob', created_at: '2026-01-20T10:00:00+00:00',
                                                  reactions: [{ 'type' => 'like', 'count' => 2 }])
        message = engine.message_from_stored(data)
        assert_equal 'stored-1', message.id
        assert_equal 'Bob', message.sender_name
        assert_equal 'like', message.reactions.first[:type]
      end
    end

    def test_message_from_stored_nil_reactions
      with_temp_config do
        engine = build_engine
        data = stored_msg_hash('stored-2', 'Bob', created_at: nil, reactions: nil, attachments: nil)
        message = engine.message_from_stored(data)
        assert_equal [], message.reactions
        assert_nil message.created_at
      end
    end

    def test_merge_and_write_nil_created_at
      with_temp_config do
        engine = build_engine
        new_msg = build_message(id: 'nil-time-msg', sender_name: 'Alice', content: 'No time', created_at: nil)
        result = engine.merge_and_write(sample_engine_chat, [], [new_msg])
        assert_equal 1, result.length
        assert_nil result.first.created_at
      end
    end

    def test_merge_messages_with_nil_created_at_sort
      with_temp_config do
        engine = build_public_engine(:merge_messages)
        msg_with_time = build_message(id: 'msg-1', sender_name: 'A', content: 'Hi',
                                      created_at: Time.new(2026, 1, 20))
        msg_without_time = build_message(id: 'msg-2', sender_id: 'u2', sender_name: 'B',
                                         content: 'Hello', created_at: nil)
        result = engine.merge_messages([msg_with_time], [msg_without_time])
        assert_equal 2, result.length
        assert_nil result.first.created_at
      end
    end
  end

  # Tests internal helpers: debug output, page parsing, cutoff detection, and link advancement
  class InternalsTest < Minitest::Test
    include SharedHelpers

    def test_debug_not_called_when_not_verbose
      with_temp_config do
        assert_equal false, build_public_engine(:debug).debug('test message')
      end
    end

    def test_debug_with_nil_output
      with_temp_config do
        engine = build_nil_output_engine(:debug)
        assert_nil engine.debug('test message')
      end
    end

    def test_log_and_check_max
      with_temp_config do
        engine = build_public_engine(:log_and_check_max?)
        refute engine.log_and_check_max?(1, ['msg'])
        assert engine.log_and_check_max?(500, ['msg'])
      end
    end

    def test_parse_page_messages_nil_created_at
      with_temp_config do
        engine = build_public_engine(:parse_page_messages)
        msg = sample_ng_msg_message.dup.tap do |msg_data|
          msg_data.delete('composetime')
          msg_data.delete('originalarrivaltime')
        end
        parsed, cutoff = engine.parse_page_messages([msg], Time.new(2026, 1, 1))
        assert_equal 1, parsed.length
        refute cutoff
      end
    end

    def test_advance_link_nil
      with_temp_config do
        engine = build_public_engine(:advance_link)
        engine.instance_variable_set(:@backward_link, nil)
        assert_nil engine.advance_link(Time.now)
      end
    end

    def test_message_to_hash_nil_created_at
      with_temp_config do
        engine = build_public_engine(:message_to_hash)
        msg = build_message(id: 'nil-time', sender_name: 'A', content: 'Hi', created_at: nil)
        hash = engine.message_to_hash(msg)
        assert_nil hash['created_at']
        assert_equal 'nil-time', hash['id']
      end
    end

    def test_parse_page_messages_cutoff_detection
      with_temp_config do
        err = StringIO.new
        engine = build_public_engine(:parse_page_messages, verbose_err: err)
        old_msg = sample_ng_msg_message.dup.tap { |msg| msg['composetime'] = '2025-06-01T12:00:00.000Z' }
        _parsed, cutoff = engine.parse_page_messages([old_msg], Time.new(2026, 1, 1))
        assert cutoff
        assert_match(/cutoff/, err.string)
      end
    end

    def test_filter_and_sort_nil_created_at
      with_temp_config do
        engine = build_public_engine(:filter_and_sort_messages)
        msg = build_message(id: 'nil-time', sender_name: 'A', content: 'Hi', created_at: nil)
        assert_equal 1, engine.filter_and_sort_messages([msg], Time.new(2026, 1, 1)).length
      end
    end

    def test_parse_page_messages_empty
      with_temp_config do
        engine = build_public_engine(:parse_page_messages)
        parsed, cutoff = engine.parse_page_messages([], Time.new(2026, 1, 1))
        assert_equal 0, parsed.length
        refute cutoff
      end
    end

    def test_parse_page_with_nil_and_real_dates
      with_temp_config do
        engine = build_public_engine(:parse_page_messages)
        no_time = sample_ng_msg_message.dup.tap do |msg|
          msg.delete('composetime')
          msg.delete('originalarrivaltime')
          msg['id'] = 'no-time-2'
        end
        parsed, _cutoff = engine.parse_page_messages([sample_ng_msg_message, no_time], Time.new(2026, 1, 1))
        assert_equal 2, parsed.length
      end
    end
  end

  # Tests inline image persistence in messages.json and links in messages.md
  class InlineImageTest < Minitest::Test
    include SharedHelpers

    def test_images_round_trip_through_stored_json
      with_temp_config do
        hash = build_public_engine(:message_to_hash).message_to_hash(build_message(images: [sample_inline_image]))
        stored = JSON.parse(JSON.generate(hash))

        assert_includes stored['images'].first['full_size_url'], 'imgpsh_fullsize_anim'
        assert_equal [sample_inline_image], build_engine.message_from_stored(stored).images
      end
    end

    def test_stored_messages_without_images_load_empty
      with_temp_config do
        message = build_engine.message_from_stored(stored_msg_hash('m', 'A', created_at: '2026-01-20T10:00:00+00:00'))
        assert_empty message.images
      end
    end

    def test_merge_and_write_yields_chat_dir_and_links_saved_images
      with_temp_config do
        markdown = merge_with_saved_image
        assert_includes markdown, "![image: image (640x120)](images/#{SAMPLE_AMS_OBJECT_ID}.png)"
      end
    end

    private

    def merge_with_saved_image
      yielded = nil
      new_messages = [build_message(images: [sample_inline_image])]
      build_engine.merge_and_write(sample_engine_chat, [], new_messages) do |dir, msgs|
        yielded = msgs
        save_fake_image(dir)
      end
      assert_equal 1, yielded.length
      store = Teems::Services::SyncStore.new
      File.read(File.join(store.chat_dir(sample_engine_chat.id, state: store.load_state), 'messages.md'))
    end

    def save_fake_image(chat_dir)
      FileUtils.mkdir_p(File.join(chat_dir, 'images'))
      File.write(File.join(chat_dir, 'images', "#{SAMPLE_AMS_OBJECT_ID}.png"), 'x')
    end
  end
end
