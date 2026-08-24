defmodule Lux.Signals.TelegramUpdateAdversarialTest do
  use UnitAPICase, async: true

  alias Lux.Signals.TelegramUpdate
  alias Lux.Schemas.TelegramUpdateSchema
  alias Lux.Telegram.Types
  alias Lux.Telegram.Types.{Chat, Message, Update, User, InlineKeyboardMarkup, InlineKeyboardButton}
  alias Lux.Telegram.Poller
  alias Lux.Telegram.WebhookPlug

  describe "1. Raw Update Maps & Key Variations" do
    test "pure atom keys with nested structures" do
      raw = %{
        update_id: 100_001,
        message: %{
          message_id: 10,
          from: %{id: 2001, is_bot: false, first_name: "Alice", username: "alice_bot"},
          chat: %{id: -100_123_456_789, type: "supergroup", title: "Elixir Devs"},
          date: 1_700_000_000,
          text: "Hello pure atom"
        }
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(raw)
      assert signal.schema_id == TelegramUpdateSchema
      assert signal.payload.update_id == 100_001
      assert TelegramUpdate.update_id(signal) == 100_001
      assert TelegramUpdate.chat_id(signal) == -100_123_456_789
      assert TelegramUpdate.text(signal) == "Hello pure atom"
    end

    test "pure string keys with deep nesting" do
      raw = %{
        "update_id" => 100_002,
        "message" => %{
          "message_id" => 11,
          "from" => %{"id" => 2002, "is_bot" => false, "first_name" => "Bob"},
          "chat" => %{"id" => 3002, "type" => "private"},
          "date" => 1_700_000_001,
          "text" => "Hello pure string"
        }
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(raw)
      assert signal.payload["update_id"] == 100_002
      assert TelegramUpdate.update_id(signal) == 100_002
      assert TelegramUpdate.chat_id(signal) == 3002
      assert TelegramUpdate.text(signal) == "Hello pure string"
    end

    test "mixed atom and string keys at various depths" do
      mixed_1 = %{
        "update_id" => 100_003,
        :message => %{
          "message_id" => 12,
          :chat => %{"id" => -5001, type: "group"},
          "text" => "Mixed keys 1"
        }
      }

      assert {:ok, signal1} = TelegramUpdate.new(mixed_1)
      assert TelegramUpdate.update_id(signal1) == 100_003
      assert TelegramUpdate.chat_id(signal1) == -5001
      assert TelegramUpdate.text(signal1) == "Mixed keys 1"

      mixed_2 = %{
        :update_id => 100_004,
        "edited_message" => %{
          :message_id => 13,
          "chat" => %{:id => -5002},
          :text => "Edited mixed text"
        }
      }

      assert {:ok, signal2} = TelegramUpdate.new(mixed_2)
      assert TelegramUpdate.update_id(signal2) == 100_004
      assert TelegramUpdate.chat_id(signal2) == -5002
      assert TelegramUpdate.text(signal2) == "Edited mixed text"
    end

    test "handles unexpected/future Telegram Bot API fields gracefully" do
      # Telegram periodically adds new update types like business_message, message_reaction, etc.
      future_update = %{
        update_id: 100_005,
        business_message: %{
          business_connection_id: "biz_123",
          message_id: 99,
          chat: %{id: 4001, type: "private"},
          text: "Business order received"
        },
        custom_unrecognized_field: %{nested: "value"}
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(future_update)
      assert TelegramUpdate.update_id(signal) == 100_005
    end

    test "handles Unicode, emojis, zero-width chars, and multiline text" do
      unicode_text = "🎉 Hello World 🤖\nLine 2: 🚀 العربية 中文 Русский \u200B\uFEFF"
      raw = %{
        update_id: 100_006,
        message: %{
          message_id: 14,
          chat: %{id: 5001, type: "private"},
          text: unicode_text
        }
      }

      assert {:ok, signal} = TelegramUpdate.new(raw)
      assert TelegramUpdate.text(signal) == unicode_text
    end

    test "handles large text payload (stress test)" do
      large_text = String.duplicate("A quick brown fox jumps over the lazy dog. ", 1000)
      raw = %{
        update_id: 100_007,
        message: %{
          message_id: 15,
          chat: %{id: 5002},
          text: large_text
        }
      }

      assert {:ok, signal} = TelegramUpdate.new(raw)
      assert TelegramUpdate.text(signal) == large_text
    end
  end

  describe "2. Structured Signal Maps" do
    test "preserves explicit signal attributes with atom keys" do
      custom_time = ~U[2026-08-24 12:00:00Z]
      attrs = %{
        id: "sig-custom-uuid-1",
        sender: "telegram-bot-gateway",
        recipient: "order-processor-agent",
        topic: "telegram/inbound",
        timestamp: custom_time,
        metadata: %{origin: "webhook", ip: "192.168.1.1", cluster: "us-east-1"},
        payload: %{
          update_id: 200_001,
          message: %{
            message_id: 20,
            chat: %{id: 6001},
            text: "Order #1234"
          }
        }
      }

      assert {:ok, signal} = TelegramUpdate.new(attrs)
      assert signal.id == "sig-custom-uuid-1"
      assert signal.sender == "telegram-bot-gateway"
      assert signal.recipient == "order-processor-agent"
      assert signal.topic == "telegram/inbound"
      assert signal.timestamp == custom_time
      assert signal.metadata == %{origin: "webhook", ip: "192.168.1.1", cluster: "us-east-1"}
      assert signal.schema_id == TelegramUpdateSchema
      assert TelegramUpdate.update_id(signal) == 200_001
      assert TelegramUpdate.chat_id(signal) == 6001
      assert TelegramUpdate.text(signal) == "Order #1234"
    end

    test "preserves explicit signal attributes with string keys" do
      custom_time = ~U[2026-08-24 12:30:00Z]
      attrs = %{
        "id" => "sig-custom-uuid-2",
        "sender" => "string-sender",
        "recipient" => "string-recipient",
        "topic" => "telegram/string-topic",
        "timestamp" => custom_time,
        "metadata" => %{"tag" => "production"},
        "payload" => %{
          "update_id" => 200_002,
          "message" => %{
            "message_id" => 21,
            "chat" => %{"id" => 6002},
            "text" => "String key signal"
          }
        }
      }

      assert {:ok, signal} = TelegramUpdate.new(attrs)
      assert signal.id == "sig-custom-uuid-2"
      assert signal.sender == "string-sender"
      assert signal.recipient == "string-recipient"
      assert signal.topic == "telegram/string-topic"
      assert signal.timestamp == custom_time
      assert signal.metadata == %{"tag" => "production"}
      assert TelegramUpdate.update_id(signal) == 200_002
      assert TelegramUpdate.chat_id(signal) == 6002
      assert TelegramUpdate.text(signal) == "String key signal"
    end

    test "supports %Lux.Telegram.Types.Update{} struct as payload inside structured map" do
      update_struct = %Update{
        update_id: 200_003,
        message: %Message{
          message_id: 22,
          text: "Struct in payload",
          chat: %Chat{id: 6003, type: "private"}
        }
      }

      attrs = %{
        id: "sig-with-struct-payload",
        sender: "poller",
        payload: update_struct
      }

      assert {:ok, signal} = TelegramUpdate.new(attrs)
      assert signal.id == "sig-with-struct-payload"
      assert signal.sender == "poller"
      assert TelegramUpdate.update_id(signal) == 200_003
      assert TelegramUpdate.chat_id(signal) == 6003
      assert TelegramUpdate.text(signal) == "Struct in payload"
    end

    test "fails when payload inside structured map is invalid or missing update_id" do
      invalid_attrs = %{
        id: "sig-invalid-payload",
        payload: %{
          message: %{text: "No update_id"}
        }
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid_attrs)
    end
  end

  describe "3. %Lux.Telegram.Types.Update{} Structs & Conversions" do
    test "creates signal directly from %Types.Update{}" do
      update = %Update{
        update_id: 300_001,
        message: %Message{
          message_id: 30,
          date: 1_700_000_100,
          text: "Direct struct update",
          from: %User{id: 7001, first_name: "Charlie", username: "charlie_tg", is_bot: false},
          chat: %Chat{id: 8001, type: "group", title: "Test Group"}
        }
      }

      assert {:ok, signal} = TelegramUpdate.new(update)
      assert signal.payload.update_id == 300_001
      assert signal.payload.message.text == "Direct struct update"
      assert signal.payload.message.from.first_name == "Charlie"
      assert signal.payload.message.chat.id == 8001
      refute Map.has_key?(signal.payload, :edited_message)
    end

    test "Types.to_map/1 strips nil fields recursively" do
      update = %Update{
        update_id: 300_002,
        message: %Message{
          message_id: 31,
          text: "Nil stripping test",
          chat: %Chat{id: 8002}
        }
      }

      map = Types.to_map(update)
      assert map.update_id == 300_002
      assert map.message.text == "Nil stripping test"
      assert map.message.chat.id == 8002

      # Verify nil fields are stripped
      refute Map.has_key?(map, :edited_message)
      refute Map.has_key?(map, :callback_query)
      refute Map.has_key?(map.message, :reply_to_message)
      refute Map.has_key?(map.message.chat, :title)
    end

    test "Jason.encode/1 on %Types.Update{} produces valid JSON with nil omitted" do
      update = %Update{
        update_id: 300_003,
        message: %Message{
          message_id: 32,
          text: "JSON encode test",
          chat: %Chat{id: 8003, type: "private"}
        }
      }

      {:ok, json} = Jason.encode(update)
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert decoded["update_id"] == 300_003
      assert decoded["message"]["text"] == "JSON encode test"
      assert decoded["message"]["chat"]["id"] == 8003
      refute Map.has_key?(decoded, "edited_message")
    end

    test "round-trip conversion: Map -> Update struct -> to_map -> Signal -> to_struct" do
      original_map = %{
        "update_id" => 300_004,
        "message" => %{
          "message_id" => 33,
          "text" => "Roundtrip test",
          "chat" => %{"id" => 8004, "type" => "private"},
          "from" => %{"id" => 9004, "first_name" => "Dave", "is_bot" => false}
        }
      }

      struct_1 = Types.Update.from_map(original_map)
      assert struct_1.update_id == 300_004
      assert struct_1.message.text == "Roundtrip test"
      assert struct_1.message.chat.id == 8004
      assert struct_1.message.from.first_name == "Dave"

      map_from_struct = Types.to_map(struct_1)
      {:ok, signal} = TelegramUpdate.new(map_from_struct)

      struct_2 = TelegramUpdate.to_struct(signal)
      assert struct_2.update_id == 300_004
      assert struct_2.message.text == "Roundtrip test"
      assert struct_2.message.chat.id == 8004
      assert struct_2.message.from.first_name == "Dave"
    end
  end

  describe "4. Schema Rejection & Validation Failure Modes" do
    test "fails when update_id is missing entirely" do
      invalid = %{
        message: %{
          message_id: 1,
          text: "Missing update_id"
        }
      }

      assert {:error, errors} = TelegramUpdate.new(invalid)
      assert is_list(errors) or is_map(errors)
    end

    test "fails when update_id is nil" do
      invalid = %{
        update_id: nil,
        message: %{text: "Nil update_id"}
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid)
    end

    test "fails when update_id is a string" do
      invalid = %{
        update_id: "12345",
        message: %{text: "String update_id"}
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid)
    end

    test "fails when update_id is a float" do
      invalid = %{
        update_id: 123.456,
        message: %{text: "Float update_id"}
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid)
    end

    test "fails when update_id is a boolean, map, or list" do
      assert {:error, _} = TelegramUpdate.new(%{update_id: true})
      assert {:error, _} = TelegramUpdate.new(%{update_id: %{id: 123}})
      assert {:error, _} = TelegramUpdate.new(%{update_id: [123]})
    end

    test "accepts 0, negative, and very large 64-bit integers for update_id" do
      # 0
      assert {:ok, s0} = TelegramUpdate.new(%{update_id: 0})
      assert TelegramUpdate.update_id(s0) == 0

      # Negative
      assert {:ok, s_neg} = TelegramUpdate.new(%{update_id: -1})
      assert TelegramUpdate.update_id(s_neg) == -1

      # Max 64-bit integer
      max_int64 = 9_223_372_036_854_775_807
      assert {:ok, s_max} = TelegramUpdate.new(%{update_id: max_int64})
      assert TelegramUpdate.update_id(s_max) == max_int64

      # Arbitrary large integer
      huge_int = 100_000_000_000_000_000_000_000
      assert {:ok, s_huge} = TelegramUpdate.new(%{update_id: huge_int})
      assert TelegramUpdate.update_id(s_huge) == huge_int
    end

    test "fails validation when known object fields are non-objects" do
      invalid_message = %{
        update_id: 400_001,
        message: "this should be an object, not a string"
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid_message)

      invalid_cb = %{
        update_id: 400_002,
        callback_query: 12345
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid_cb)
    end

    test "rejects non-map root arguments with {:error, :invalid_update}" do
      assert {:error, :invalid_update} = TelegramUpdate.new(nil)
      assert {:error, :invalid_update} = TelegramUpdate.new("not-a-map")
      assert {:error, :invalid_update} = TelegramUpdate.new(123)
      assert {:error, :invalid_update} = TelegramUpdate.new(123.45)
      assert {:error, :invalid_update} = TelegramUpdate.new(true)
      assert {:error, :invalid_update} = TelegramUpdate.new([update_id: 123])
      assert {:error, :invalid_update} = TelegramUpdate.new({:tuple, 123})
    end
  end

  describe "5. Application-Layer Helpers Adversarial Stress Testing" do
    test "to_struct/1 with all input types and edge cases" do
      # 1. nil
      assert is_nil(TelegramUpdate.to_struct(nil))

      # 2. non-map primitives
      assert is_nil(TelegramUpdate.to_struct("invalid"))
      assert is_nil(TelegramUpdate.to_struct(12345))
      assert is_nil(TelegramUpdate.to_struct([1, 2, 3]))

      # 3. %Types.Update{} struct returns itself
      struct_in = %Update{update_id: 500_001}
      assert TelegramUpdate.to_struct(struct_in) == struct_in

      # 4. Map with atom keys
      atom_map = %{update_id: 500_002, message: %{text: "atom", chat: %{id: 1}}}
      assert %Update{update_id: 500_002, message: %Message{text: "atom", chat: %Chat{id: 1}}} =
               TelegramUpdate.to_struct(atom_map)

      # 5. Map with string keys
      string_map = %{"update_id" => 500_003, "message" => %{"text" => "str", "chat" => %{"id" => 2}}}
      assert %Update{update_id: 500_003, message: %Message{text: "str", chat: %Chat{id: 2}}} =
               TelegramUpdate.to_struct(string_map)

      # 6. Signal with atom keys payload
      {:ok, sig_atom} = TelegramUpdate.new(atom_map)
      assert %Update{update_id: 500_002} = TelegramUpdate.to_struct(sig_atom)

      # 7. Signal with string keys payload
      {:ok, sig_str} = TelegramUpdate.new(string_map)
      assert %Update{update_id: 500_003} = TelegramUpdate.to_struct(sig_str)
    end

    test "to_atom_keys/1 deep recursion with mixed types, lists, structs" do
      # Deeply nested map with mixed keys, lists, and primitives
      input = %{
        "a" => %{
          "b" => [
            %{"c" => 1, :d => 2},
            %{"e" => "hello", "f" => [1, "two", %{"g" => true}]}
          ]
        },
        :already_atom => %{
          "nested_str" => %{123 => "non-string key preserved"}
        }
      }

      converted = TelegramUpdate.to_atom_keys(input)

      assert converted.a.b == [
        %{c: 1, d: 2},
        %{e: "hello", f: [1, "two", %{g: true}]}
      ]
      assert converted.already_atom.nested_str == %{123 => "non-string key preserved"}

      # Test with Signal
      {:ok, signal} = TelegramUpdate.new(%{"update_id" => 500_010, "message" => %{"text" => "sig"}})
      converted_sig = TelegramUpdate.to_atom_keys(signal)
      assert converted_sig == %{update_id: 500_010, message: %{text: "sig"}}

      # Test with struct
      user_struct = %User{id: 99, first_name: "Eve"}
      assert TelegramUpdate.to_atom_keys(user_struct).first_name == "Eve"

      # Test primitives pass through unchanged
      assert TelegramUpdate.to_atom_keys(42) == 42
      assert TelegramUpdate.to_atom_keys("test") == "test"
      assert TelegramUpdate.to_atom_keys(nil) == nil
    end

    test "chat_id/1 across all 9 supported update variants" do
      # 1. message -> chat -> id
      assert TelegramUpdate.chat_id(%{message: %{chat: %{id: 101}}}) == 101
      assert TelegramUpdate.chat_id(%{"message" => %{"chat" => %{"id" => 101}}}) == 101

      # 2. edited_message -> chat -> id
      assert TelegramUpdate.chat_id(%{edited_message: %{chat: %{id: 102}}}) == 102
      assert TelegramUpdate.chat_id(%{"edited_message" => %{"chat" => %{"id" => 102}}}) == 102

      # 3. channel_post -> chat -> id
      assert TelegramUpdate.chat_id(%{channel_post: %{chat: %{id: -100_103}}}) == -100_103
      assert TelegramUpdate.chat_id(%{"channel_post" => %{"chat" => %{"id" => -100_103}}}) == -100_103

      # 4. edited_channel_post -> chat -> id
      assert TelegramUpdate.chat_id(%{edited_channel_post: %{chat: %{id: -100_104}}}) == -100_104
      assert TelegramUpdate.chat_id(%{"edited_channel_post" => %{"chat" => %{"id" => -100_104}}}) == -100_104

      # 5. callback_query -> message -> chat -> id
      assert TelegramUpdate.chat_id(%{callback_query: %{message: %{chat: %{id: 105}}}}) == 105
      assert TelegramUpdate.chat_id(%{"callback_query" => %{"message" => %{"chat" => %{"id" => 105}}}}) == 105

      # 6. callback_query -> chat_instance (inline message without chat object)
      assert TelegramUpdate.chat_id(%{callback_query: %{chat_instance: "chat_inst_106"}}) == "chat_inst_106"
      assert TelegramUpdate.chat_id(%{"callback_query" => %{"chat_instance" => "chat_inst_106"}}) == "chat_inst_106"

      # 7. my_chat_member -> chat -> id
      assert TelegramUpdate.chat_id(%{my_chat_member: %{chat: %{id: 107}}}) == 107
      assert TelegramUpdate.chat_id(%{"my_chat_member" => %{"chat" => %{"id" => 107}}}) == 107

      # 8. chat_member -> chat -> id
      assert TelegramUpdate.chat_id(%{chat_member: %{chat: %{id: 108}}}) == 108
      assert TelegramUpdate.chat_id(%{"chat_member" => %{"chat" => %{"id" => 108}}}) == 108

      # 9. chat_join_request -> chat -> id
      assert TelegramUpdate.chat_id(%{chat_join_request: %{chat: %{id: 109}}}) == 109
      assert TelegramUpdate.chat_id(%{"chat_join_request" => %{"chat" => %{"id" => 109}}}) == 109

      # 10. With %Types.Update{} struct
      update_struct = %Update{
        update_id: 1,
        callback_query: %{message: %Message{chat: %Chat{id: 110}}}
      }
      assert TelegramUpdate.chat_id(update_struct) == 110

      # 11. No chat_id present
      assert is_nil(TelegramUpdate.chat_id(%{update_id: 1, poll: %{id: "p1"}}))
      assert is_nil(TelegramUpdate.chat_id(nil))
    end

    test "text/1 across all 7 supported update variants" do
      # 1. message -> text
      assert TelegramUpdate.text(%{message: %{text: "direct"}}) == "direct"
      assert TelegramUpdate.text(%{"message" => %{"text" => "direct"}}) == "direct"

      # 2. edited_message -> text
      assert TelegramUpdate.text(%{edited_message: %{text: "edited"}}) == "edited"
      assert TelegramUpdate.text(%{"edited_message" => %{"text" => "edited"}}) == "edited"

      # 3. channel_post -> text
      assert TelegramUpdate.text(%{channel_post: %{text: "channel"}}) == "channel"
      assert TelegramUpdate.text(%{"channel_post" => %{"text" => "channel"}}) == "channel"

      # 4. edited_channel_post -> text
      assert TelegramUpdate.text(%{edited_channel_post: %{text: "edited_chan"}}) == "edited_chan"
      assert TelegramUpdate.text(%{"edited_channel_post" => %{"text" => "edited_chan"}}) == "edited_chan"

      # 5. message -> caption (e.g. photo/video message without text field)
      assert TelegramUpdate.text(%{message: %{caption: "photo caption"}}) == "photo caption"
      assert TelegramUpdate.text(%{"message" => %{"caption" => "photo caption"}}) == "photo caption"

      # 6. callback_query -> data
      assert TelegramUpdate.text(%{callback_query: %{data: "btn_action_1"}}) == "btn_action_1"
      assert TelegramUpdate.text(%{"callback_query" => %{"data" => "btn_action_1"}}) == "btn_action_1"

      # 7. callback_query -> message -> text
      assert TelegramUpdate.text(%{callback_query: %{message: %{text: "parent message text"}}}) == "parent message text"
      assert TelegramUpdate.text(%{"callback_query" => %{"message" => %{"text" => "parent message text"}}}) == "parent message text"

      # 8. With %Types.Update{} struct
      update_struct = %Update{
        update_id: 1,
        message: %Message{text: "struct message text"}
      }
      assert TelegramUpdate.text(update_struct) == "struct message text"

      # 9. No text present
      assert is_nil(TelegramUpdate.text(%{update_id: 1, poll: %{question: "Is this text?"}}))
      assert is_nil(TelegramUpdate.text(nil))
    end

    test "update_id/1 extracts correctly across all data formats" do
      assert TelegramUpdate.update_id(%{update_id: 601}) == 601
      assert TelegramUpdate.update_id(%{"update_id" => 602}) == 602
      assert TelegramUpdate.update_id(%Update{update_id: 603}) == 603
      {:ok, sig} = TelegramUpdate.new(%{update_id: 604})
      assert TelegramUpdate.update_id(sig) == 604
      assert is_nil(TelegramUpdate.update_id(nil))
      assert is_nil(TelegramUpdate.update_id("invalid"))
    end

    test "message/1 and callback_query/1 extract correctly" do
      msg = %{message_id: 1, text: "msg_content"}
      cb = %{id: "cb_1", data: "cb_data"}

      {:ok, sig_msg} = TelegramUpdate.new(%{update_id: 701, message: msg})
      {:ok, sig_cb} = TelegramUpdate.new(%{update_id: 702, callback_query: cb})

      assert TelegramUpdate.message(sig_msg) == msg
      assert is_nil(TelegramUpdate.message(sig_cb))

      assert TelegramUpdate.callback_query(sig_cb) == cb
      assert is_nil(TelegramUpdate.callback_query(sig_msg))
    end
  end

  describe "6. Poller & WebhookPlug Integration Compatibility" do
    test "Poller dispatches valid TelegramUpdate signals with varying payloads and updates offset correctly" do
      test_pid = self()

      # Updates with out-of-order IDs and different update types
      mock_updates = [
        %{"update_id" => 500, "message" => %{"message_id" => 1, "chat" => %{"id" => 111}, "text" => "First"}},
        %{"update_id" => 505, "callback_query" => %{"id" => "cb_505", "data" => "btn_click", "message" => %{"chat" => %{"id" => 222}}}},
        %{"update_id" => 502, "channel_post" => %{"message_id" => 2, "chat" => %{"id" => -100_333}, "text" => "Post"}}
      ]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => mock_updates
        }))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "poller_adversarial_token",
          plug: plug,
          handler: test_pid,
          autostart: false,
          offset: 100
        })

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 3

      # Verify each signal received in PID
      assert_receive {:telegram_update, s1}
      assert TelegramUpdate.update_id(s1) == 500
      assert TelegramUpdate.chat_id(s1) == 111
      assert TelegramUpdate.text(s1) == "First"

      assert_receive {:telegram_update, s2}
      assert TelegramUpdate.update_id(s2) == 505
      assert TelegramUpdate.chat_id(s2) == 222
      assert TelegramUpdate.text(s2) == "btn_click"

      assert_receive {:telegram_update, s3}
      assert TelegramUpdate.update_id(s3) == 502
      assert TelegramUpdate.chat_id(s3) == -100_333
      assert TelegramUpdate.text(s3) == "Post"

      # New offset should be max(100, 500+1, 505+1, 502+1) = 506
      assert Poller.get_offset(poller) == 506
    end

    test "WebhookPlug receives webhook update and dispatches valid TelegramUpdate signal" do
      test_pid = self()
      opts = WebhookPlug.init(secret_token: "super_secret_token", handler: test_pid)

      payload = %{
        "update_id" => 900_001,
        "message" => %{
          "message_id" => 55,
          "chat" => %{"id" => 888_999, "type" => "private"},
          "text" => "Hello via webhook"
        }
      }

      conn =
        :post
        |> Plug.Test.conn("/telegram/webhook", Jason.encode!(payload))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "super_secret_token")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:telegram_update, signal}

      # Test signal properties
      assert signal.schema_id == TelegramUpdateSchema
      assert TelegramUpdate.update_id(signal) == 900_001
      assert TelegramUpdate.chat_id(signal) == 888_999
      assert TelegramUpdate.text(signal) == "Hello via webhook"

      # Test converting signal to struct
      struct = TelegramUpdate.to_struct(signal)
      assert %Update{update_id: 900_001, message: %Message{text: "Hello via webhook"}} = struct
    end

    test "WebhookPlug returns 200 and logs error when handler raises exception" do
      failing_handler = fn _sig -> raise "Adversarial crash test in webhook handler" end
      opts = WebhookPlug.init(handler: failing_handler)

      conn =
        :post
        |> Plug.Test.conn("/telegram/webhook", Jason.encode!(%{"update_id" => 900_002}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      # Telegram requires 200 OK so it does not retry failed delivery endlessly
      assert conn.status == 200
    end

    test "WebhookPlug handles malformed or empty JSON body without crashing" do
      test_pid = self()
      opts = WebhookPlug.init(handler: test_pid)

      conn =
        :post
        |> Plug.Test.conn("/telegram/webhook", "invalid-non-json-body")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
    end
  end

  describe "7. Advanced Entity & Inline Keyboard Struct Conversions" do
    test "converts complex inline keyboard markup and buttons between structs and maps" do
      markup = %InlineKeyboardMarkup{
        inline_keyboard: [
          [
            %InlineKeyboardButton{text: "Button 1", callback_data: "data_1"},
            %InlineKeyboardButton{text: "URL Link", url: "https://example.com"}
          ],
          [
            %InlineKeyboardButton{text: "Switch Query", switch_inline_query: "query text"}
          ]
        ]
      }

      map = Types.to_map(markup)
      assert length(map.inline_keyboard) == 2
      assert hd(hd(map.inline_keyboard)).text == "Button 1"
      assert hd(hd(map.inline_keyboard)).callback_data == "data_1"
      refute Map.has_key?(hd(hd(map.inline_keyboard)), :url)

      # Convert back from map to struct
      restored = InlineKeyboardMarkup.from_map(map)
      assert %InlineKeyboardMarkup{} = restored
      assert length(restored.inline_keyboard) == 2
      assert hd(hd(restored.inline_keyboard)).text == "Button 1"
      assert hd(hd(restored.inline_keyboard)).callback_data == "data_1"
    end

    test "to_atom_keys/1 processes nested keyboard rows and button lists safely" do
      raw_keyboard = %{
        "reply_markup" => %{
          "inline_keyboard" => [
            [%{"text" => "A", "callback_data" => "a"}],
            [%{"text" => "B", "callback_data" => "b"}]
          ]
        }
      }

      atom_keyboard = TelegramUpdate.to_atom_keys(raw_keyboard)
      assert atom_keyboard.reply_markup.inline_keyboard == [
        [%{text: "A", callback_data: "a"}],
        [%{text: "B", callback_data: "b"}]
      ]
    end
  end
end
