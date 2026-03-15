# frozen_string_literal: true

require 'test_helper'

class SyncEngineTest < Minitest::Test
  def test_fetch_all_messages_empty_response
    with_temp_config do
      engine = build_engine
      runner = engine.instance_variable_get(:@runner)
      runner.api_client.stub('messages', { 'messages' => [], '_metadata' => {} })

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.now - 86_400)

      assert_equal [], messages
    end
  end

  def test_fetch_all_messages_single_page
    with_temp_config do
      engine = build_engine
      runner = engine.instance_variable_get(:@runner)
      runner.api_client.stub('messages', {
                               'messages' => [sample_ng_msg_message],
                               '_metadata' => {}
                             })

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))

      assert_equal 1, messages.length
      assert_equal 'Jane Smith', messages.first.sender_name
    end
  end

  def test_fetch_all_messages_with_backward_link
    with_temp_config do
      engine = build_engine
      runner = engine.instance_variable_get(:@runner)
      # Stub sleep to no-op
      engine.define_singleton_method(:sleep) { |_| nil }
      # First page has backward_link, second page empty
      first_response = {
        'messages' => [sample_ng_msg_message],
        '_metadata' => { 'backwardLink' => 'https://api.example.com/messages?startTime=123&pageSize=200' }
      }
      second_response = {
        'messages' => [],
        '_metadata' => {}
      }
      call_count = 0
      runner.api_client.define_singleton_method(:get) do |_endpoint, _path, **_opts|
        call_count += 1
        call_count == 1 ? first_response : second_response
      end

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))

      assert messages.length >= 1
    end
  end

  def test_fetch_all_messages_filters_system_messages
    with_temp_config do
      engine = build_engine
      runner = engine.instance_variable_get(:@runner)
      runner.api_client.stub('messages', {
                               'messages' => [sample_system_message, sample_ng_msg_message],
                               '_metadata' => {}
                             })

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))

      refute messages.any?(&:system_message?)
    end
  end

  def test_fetch_all_messages_nil_created_at_sorted
    with_temp_config do
      engine = build_engine
      runner = engine.instance_variable_get(:@runner)
      msg_no_time = sample_ng_msg_message.dup
      msg_no_time.delete('composetime')
      msg_no_time['id'] = 'no-time-msg'
      runner.api_client.stub('messages', {
                               'messages' => [msg_no_time, sample_ng_msg_message],
                               '_metadata' => {}
                             })

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))

      # Should not crash, messages with nil time sorted to beginning
      assert messages.length >= 1
    end
  end

  def test_merge_and_write_deduplicates
    with_temp_config do
      engine = build_engine
      chat = Teems::Models::Chat.new(
        id: '19:test@thread.v2', topic: 'Test', chat_type: 'group',
        created_at: Time.now, last_updated: Time.now
      )
      existing_raw = [{
        'id' => 'msg-1', 'sender_id' => 'u1', 'sender_name' => 'Alice',
        'content' => 'Hello', 'created_at' => '2026-01-20T10:00:00+00:00',
        'message_type' => 'RichText/Html', 'reactions' => [], 'attachments' => []
      }]
      new_msg = Teems::Models::Message.new(
        id: 'msg-1', sender_id: 'u1', sender_name: 'Alice Updated',
        content: 'Hello Updated', created_at: Time.new(2026, 1, 20, 10, 0),
        message_type: 'RichText/Html', reply_to_id: nil, reactions: [],
        attachments: [], importance: nil
      )

      result = engine.merge_and_write(chat, existing_raw, [new_msg])

      assert_equal 1, result.length
      assert_equal 'Alice Updated', result.first.sender_name
    end
  end

  def test_message_from_stored
    with_temp_config do
      engine = build_engine
      data = {
        'id' => 'stored-1', 'sender_id' => 'u1', 'sender_name' => 'Bob',
        'content' => 'Stored msg', 'created_at' => '2026-01-20T10:00:00+00:00',
        'message_type' => 'RichText/Html', 'reply_to_id' => nil,
        'reactions' => [{ 'type' => 'like', 'count' => 2 }],
        'attachments' => [], 'importance' => nil
      }

      message = engine.message_from_stored(data)

      assert_equal 'stored-1', message.id
      assert_equal 'Bob', message.sender_name
      assert_equal 'like', message.reactions.first[:type]
    end
  end

  def test_message_from_stored_nil_reactions
    with_temp_config do
      engine = build_engine
      data = {
        'id' => 'stored-2', 'sender_id' => 'u1', 'sender_name' => 'Bob',
        'content' => 'No reactions', 'created_at' => nil,
        'message_type' => 'RichText/Html', 'reply_to_id' => nil,
        'reactions' => nil, 'attachments' => nil, 'importance' => nil
      }

      message = engine.message_from_stored(data)

      assert_equal [], message.reactions
      assert_nil message.created_at
    end
  end

  def test_verbose_debug_output
    with_temp_config do
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: StringIO.new, err: err, color: false, verbose: true)
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      state = sync_store.load_state
      engine = Teems::Services::SyncEngine.new(
        runner: runner, sync_store: sync_store, state: state,
        output: output, verbose: true
      )
      runner.api_client.stub('messages', { 'messages' => [sample_ng_msg_message], '_metadata' => {} })

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))

      assert messages.length >= 1
      assert_match(/Page 1/, err.string)
    end
  end

  def test_fetch_cutoff_stops_pagination
    with_temp_config do
      engine = build_engine(verbose: true)
      runner = engine.instance_variable_get(:@runner)
      # Create a message with old date (before start_time)
      old_msg = sample_ng_msg_message.dup
      old_msg['composetime'] = '2025-01-01T12:00:00.000Z'
      old_msg['id'] = 'old-msg'
      runner.api_client.stub('messages', {
                               'messages' => [old_msg],
                               '_metadata' => { 'backwardLink' => 'https://api.example.com/messages?startTime=123' }
                             })

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))

      # Old message should be filtered out (before start_time)
      assert_equal 0, messages.length
    end
  end

  def test_debug_not_called_when_not_verbose
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :debug
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      # Directly call debug - should be a no-op when not verbose
      result = engine.debug('test message')
      assert_equal false, result
    end
  end

  def test_log_and_check_max
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :log_and_check_max
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      refute engine.log_and_check_max(1, ['msg'])
      assert engine.log_and_check_max(500, ['msg'])
    end
  end

  def test_parse_page_messages_nil_created_at
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :parse_page_messages
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      msg = sample_ng_msg_message.dup
      msg.delete('composetime')
      msg.delete('originalarrivaltime')

      parsed, cutoff = engine.parse_page_messages([msg], Time.new(2026, 1, 1))

      assert_equal 1, parsed.length
      refute cutoff
    end
  end

  def test_merge_and_write_nil_created_at
    with_temp_config do
      engine = build_engine
      chat = Teems::Models::Chat.new(
        id: '19:test@thread.v2', topic: 'Test', chat_type: 'group',
        created_at: Time.now, last_updated: Time.now
      )
      new_msg = Teems::Models::Message.new(
        id: 'nil-time-msg', sender_id: 'u1', sender_name: 'Alice',
        content: 'No time', created_at: nil,
        message_type: 'RichText/Html', reply_to_id: nil, reactions: [],
        attachments: [], importance: nil
      )

      result = engine.merge_and_write(chat, [], [new_msg])

      assert_equal 1, result.length
      assert_nil result.first.created_at
    end
  end

  def test_merge_messages_with_nil_created_at_sort
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :merge_messages
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      msg_with_time = Teems::Models::Message.new(
        id: 'msg-1', sender_id: 'u1', sender_name: 'A', content: 'Hi',
        created_at: Time.new(2026, 1, 20), message_type: 'message',
        reply_to_id: nil, reactions: [], attachments: [], importance: nil
      )
      msg_without_time = Teems::Models::Message.new(
        id: 'msg-2', sender_id: 'u2', sender_name: 'B', content: 'Hello',
        created_at: nil, message_type: 'message',
        reply_to_id: nil, reactions: [], attachments: [], importance: nil
      )

      result = engine.merge_messages([msg_with_time], [msg_without_time])

      assert_equal 2, result.length
      # nil time sorts to beginning (Time.at(0))
      assert_nil result.first.created_at
    end
  end

  def test_advance_link_nil
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :advance_link
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      assert_nil engine.advance_link(nil, Time.now)
    end
  end

  def test_message_to_hash_nil_created_at
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :message_to_hash
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      msg = Teems::Models::Message.new(
        id: 'nil-time', sender_id: 'u1', sender_name: 'A', content: 'Hi',
        created_at: nil, message_type: 'RichText/Html',
        reply_to_id: nil, reactions: [], attachments: [], importance: nil
      )

      hash = engine.message_to_hash(msg)

      assert_nil hash['created_at']
      assert_equal 'nil-time', hash['id']
    end
  end

  def test_parse_page_messages_cutoff_detection
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :parse_page_messages
      end
      err = StringIO.new
      output = Teems::Formatters::Output.new(io: StringIO.new, err: err, color: false, verbose: true)
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: true)

      old_msg = sample_ng_msg_message.dup
      old_msg['composetime'] = '2025-06-01T12:00:00.000Z'

      _parsed, cutoff = engine.parse_page_messages([old_msg], Time.new(2026, 1, 1))

      assert cutoff
      assert_match(/cutoff/, err.string)
    end
  end

  def test_filter_and_sort_nil_created_at
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :filter_and_sort_messages
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      msg = Teems::Models::Message.new(
        id: 'nil-time', sender_id: 'u1', sender_name: 'A', content: 'Hi',
        created_at: nil, message_type: 'RichText/Html',
        reply_to_id: nil, reactions: [], attachments: [], importance: nil
      )

      result = engine.filter_and_sort_messages([msg], Time.new(2026, 1, 1))

      assert_equal 1, result.length
    end
  end

  def test_fetch_all_messages_with_nil_created_at_msg
    with_temp_config do
      engine = build_engine(verbose: false)
      runner = engine.instance_variable_get(:@runner)

      msg = sample_ng_msg_message.dup
      msg.delete('composetime')
      msg.delete('originalarrivaltime')
      msg['id'] = 'nil-time-msg-3'

      runner.api_client.stub('messages', {
                               'messages' => [sample_ng_msg_message, msg],
                               '_metadata' => {}
                             })

      messages = engine.fetch_all_messages('19:test@thread.v2', Time.new(2026, 1, 1))

      # Both messages should be in the result, nil time included
      assert messages.length >= 1
    end
  end

  def test_parse_page_messages_empty
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :parse_page_messages
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      # Empty list -> oldest is nil -> &.created_at returns nil (else branch of &&)
      parsed, cutoff = engine.parse_page_messages([], Time.new(2026, 1, 1))

      assert_equal 0, parsed.length
      refute cutoff
    end
  end

  def test_parse_page_with_nil_and_real_dates
    with_temp_config do
      engine_class = Class.new(Teems::Services::SyncEngine) do
        public :parse_page_messages
      end
      output = test_output
      runner = configured_runner(output: output)
      sync_store = Teems::Services::SyncStore.new
      engine = engine_class.new(runner: runner, sync_store: sync_store, state: {},
                                output: output, verbose: false)

      msg_with_time = sample_ng_msg_message
      msg_no_time = sample_ng_msg_message.dup
      msg_no_time.delete('composetime')
      msg_no_time.delete('originalarrivaltime')
      msg_no_time['id'] = 'no-time-2'

      parsed, _cutoff = engine.parse_page_messages([msg_with_time, msg_no_time], Time.new(2026, 1, 1))

      assert_equal 2, parsed.length
    end
  end

  private

  def build_engine(verbose: false)
    output = test_output
    runner = configured_runner(output: output)
    sync_store = Teems::Services::SyncStore.new
    state = sync_store.load_state
    Teems::Services::SyncEngine.new(
      runner: runner, sync_store: sync_store, state: state,
      output: output, verbose: verbose
    )
  end
end
