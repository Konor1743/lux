defmodule Lux.Signals.TelegramUpdateTest do
  use UnitCase, async: true

  alias Lux.Signals.TelegramUpdate
  alias Lux.Telegram.Types.{Chat, Message, Update, User}

  describe "new/1 constructor" do
    test "creates signal with raw atom key map" do
      raw = %{
        update_id: 123_456,
        message: %{
          message_id: 1,
          date: 1_700_000_000,
          chat: %{id: 999, type: "private"},
          text: "hello world"
        }
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(raw)
      assert signal.schema_id == Lux.Schemas.TelegramUpdateSchema
      assert signal.payload.update_id == 123_456
      assert is_binary(signal.id)
      assert %DateTime{} = signal.timestamp
    end

    test "creates signal with raw string key map" do
      raw = %{
        "update_id" => 789_012,
        "message" => %{
          "message_id" => 2,
          "date" => 1_700_000_000,
          "chat" => %{"id" => 888, "type" => "group"},
          "text" => "string keys test"
        }
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(raw)
      assert signal.schema_id == Lux.Schemas.TelegramUpdateSchema
      assert signal.payload["update_id"] == 789_012
    end

    test "creates signal with structured signal map preserving metadata and fields" do
      attrs = %{
        id: "custom-signal-id-123",
        sender: "telegram-bot-service",
        recipient: "agent-worker",
        topic: "telegram/updates",
        metadata: %{source: "webhook", ip: "1.2.3.4"},
        payload: %{
          update_id: 555_666,
          message: %{
            message_id: 10,
            text: "structured signal"
          }
        }
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(attrs)
      assert signal.id == "custom-signal-id-123"
      assert signal.sender == "telegram-bot-service"
      assert signal.recipient == "agent-worker"
      assert signal.topic == "telegram/updates"
      assert signal.metadata == %{source: "webhook", ip: "1.2.3.4"}
      assert signal.payload.update_id == 555_666
    end

    test "creates signal with structured signal map using string keys" do
      attrs = %{
        "id" => "custom-signal-id-456",
        "sender" => "bot-sender",
        "recipient" => "bot-recipient",
        "topic" => "telegram/channel",
        "metadata" => %{"env" => "test"},
        "payload" => %{
          "update_id" => 333_444
        }
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(attrs)
      assert signal.id == "custom-signal-id-456"
      assert signal.sender == "bot-sender"
      assert signal.recipient == "bot-recipient"
      assert signal.topic == "telegram/channel"
      assert signal.metadata == %{"env" => "test"}
      assert signal.payload["update_id"] == 333_444
    end

    test "creates signal from %Lux.Telegram.Types.Update{} struct" do
      update = %Update{
        update_id: 999_888,
        message: %Message{
          message_id: 42,
          date: 1_700_000_000,
          text: "from struct",
          from: %User{id: 101, first_name: "Alice", is_bot: false},
          chat: %Chat{id: 202, type: "private"}
        }
      }

      assert {:ok, %Lux.Signal{} = signal} = TelegramUpdate.new(update)
      assert signal.schema_id == Lux.Schemas.TelegramUpdateSchema
      assert signal.payload.update_id == 999_888
      assert signal.payload.message.text == "from struct"
      assert signal.payload.message.chat.id == 202
      assert signal.payload.message.from.first_name == "Alice"
    end

    test "fails validation when update_id is missing" do
      invalid_raw = %{
        message: %{
          text: "missing update_id"
        }
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid_raw)
    end

    test "fails validation when update_id has invalid type" do
      invalid_type = %{
        update_id: "not-an-integer",
        message: %{text: "bad type"}
      }

      assert {:error, _errors} = TelegramUpdate.new(invalid_type)
    end

    test "fails when input is not a map" do
      assert {:error, :invalid_update} = TelegramUpdate.new("not-a-map")
      assert {:error, :invalid_update} = TelegramUpdate.new(12345)
      assert {:error, :invalid_update} = TelegramUpdate.new(nil)
    end
  end

  describe "application-layer helpers" do
    test "to_struct/1 converts signal and maps to %Lux.Telegram.Types.Update{}" do
      raw = %{
        "update_id" => 123,
        "message" => %{
          "message_id" => 1,
          "text" => "hello",
          "chat" => %{"id" => 456, "type" => "private"}
        }
      }

      {:ok, signal} = TelegramUpdate.new(raw)

      struct_from_signal = TelegramUpdate.to_struct(signal)
      assert %Update{update_id: 123} = struct_from_signal
      assert %Message{text: "hello", chat: %Chat{id: 456}} = struct_from_signal.message

      struct_from_map = TelegramUpdate.to_struct(raw)
      assert %Update{update_id: 123} = struct_from_map

      assert TelegramUpdate.to_struct(struct_from_signal) == struct_from_signal
      assert is_nil(TelegramUpdate.to_struct(nil))
    end

    test "to_atom_keys/1 converts map or signal payload keys recursively" do
      string_map = %{
        "update_id" => 123,
        "message" => %{
          "text" => "hello",
          "chat" => %{"id" => 456}
        }
      }

      {:ok, signal} = TelegramUpdate.new(string_map)

      atom_map = TelegramUpdate.to_atom_keys(signal)
      assert atom_map == %{
        update_id: 123,
        message: %{
          text: "hello",
          chat: %{id: 456}
        }
      }
    end

    test "update_id/1 extracts update_id from signal, struct, and map" do
      {:ok, signal} = TelegramUpdate.new(%{update_id: 42})
      assert TelegramUpdate.update_id(signal) == 42
      assert TelegramUpdate.update_id(%Update{update_id: 42}) == 42
      assert TelegramUpdate.update_id(%{"update_id" => 42}) == 42
      assert TelegramUpdate.update_id(%{update_id: 42}) == 42
      assert is_nil(TelegramUpdate.update_id(nil))
    end

    test "message/1 extracts message from signal, struct, and map" do
      msg = %{message_id: 1, text: "msg test"}
      {:ok, signal} = TelegramUpdate.new(%{update_id: 1, message: msg})

      assert TelegramUpdate.message(signal) == msg
      assert TelegramUpdate.message(%Update{update_id: 1, message: %Message{text: "msg test"}}).text == "msg test"
      assert TelegramUpdate.message(%{"update_id" => 1, "message" => %{"text" => "msg test"}}) == %{"text" => "msg test"}
    end

    test "chat_id/1 extracts chat_id across multiple update types" do
      # Regular message
      {:ok, sig1} = TelegramUpdate.new(%{
        update_id: 1,
        message: %{chat: %{id: 1001}}
      })
      assert TelegramUpdate.chat_id(sig1) == 1001

      # Edited message
      {:ok, sig2} = TelegramUpdate.new(%{
        update_id: 2,
        edited_message: %{"chat" => %{"id" => 1002}}
      })
      assert TelegramUpdate.chat_id(sig2) == 1002

      # Channel post
      {:ok, sig3} = TelegramUpdate.new(%{
        update_id: 3,
        channel_post: %{chat: %{id: 1003}}
      })
      assert TelegramUpdate.chat_id(sig3) == 1003

      # Callback query
      {:ok, sig4} = TelegramUpdate.new(%{
        update_id: 4,
        callback_query: %{message: %{chat: %{id: 1004}}}
      })
      assert TelegramUpdate.chat_id(sig4) == 1004

      # Struct format
      update_struct = %Update{
        update_id: 5,
        message: %Message{chat: %Chat{id: 1005}}
      }
      assert TelegramUpdate.chat_id(update_struct) == 1005
    end

    test "text/1 extracts text from message, edited_message, channel_post, or callback_query" do
      {:ok, sig1} = TelegramUpdate.new(%{
        update_id: 1,
        message: %{text: "direct message"}
      })
      assert TelegramUpdate.text(sig1) == "direct message"

      {:ok, sig2} = TelegramUpdate.new(%{
        update_id: 2,
        edited_message: %{"text" => "edited text"}
      })
      assert TelegramUpdate.text(sig2) == "edited text"

      {:ok, sig3} = TelegramUpdate.new(%{
        update_id: 3,
        channel_post: %{text: "channel update"}
      })
      assert TelegramUpdate.text(sig3) == "channel update"

      {:ok, sig4} = TelegramUpdate.new(%{
        update_id: 4,
        callback_query: %{data: "button_pressed"}
      })
      assert TelegramUpdate.text(sig4) == "button_pressed"
    end

    test "callback_query/1 extracts callback query object" do
      cb = %{id: "cb-123", data: "btn_click"}
      {:ok, signal} = TelegramUpdate.new(%{update_id: 1, callback_query: cb})
      assert TelegramUpdate.callback_query(signal) == cb

      assert TelegramUpdate.callback_query(%{"update_id" => 1, "callback_query" => %{"id" => "cb-456"}}) ==
               %{"id" => "cb-456"}
    end
  end
end
