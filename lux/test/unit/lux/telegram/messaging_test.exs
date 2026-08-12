defmodule Lux.Telegram.MessagingTest do
  use UnitAPICase, async: true

  alias Lux.Telegram.Messaging

  @bot_token "test_messaging_token_123"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "send_message/3" do
    test "sends text message with required parameters" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["text"] == "Hello World"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"message_id" => 1, "text" => "Hello World"}
        }))
      end)

      assert {:ok, res} = Messaging.send_message(12345, "Hello World", token: @bot_token)
      assert res["ok"] == true
      assert get_in(res, ["result", "message_id"]) == 1
    end

    test "includes optional parse_mode and reply_markup" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["parse_mode"] == "HTML"
        assert params["reply_markup"]["inline_keyboard"] != nil

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{}}))
      end)

      opts = [
        token: @bot_token,
        parse_mode: "HTML",
        reply_markup: %{inline_keyboard: []}
      ]

      assert {:ok, _} = Messaging.send_message(12345, "<b>Bold</b>", opts)
    end
  end

  describe "edit_message_text/4" do
    test "edits message text for chat_id and message_id" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/editMessageText"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["message_id"] == 99
        assert params["text"] == "Updated text"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 99}}))
      end)

      assert {:ok, res} = Messaging.edit_message_text(12345, 99, "Updated text", token: @bot_token)
      assert res["ok"] == true
    end
  end

  describe "delete_message/2" do
    test "deletes message by chat_id and message_id" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/deleteMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["message_id"] == 99

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, res} = Messaging.delete_message(12345, 99, token: @bot_token)
      assert res["result"] == true
    end
  end

  describe "copy_message/4" do
    test "copies message from one chat to another" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/copyMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 555
        assert params["from_chat_id"] == 111
        assert params["message_id"] == 42

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 101}}))
      end)

      assert {:ok, res} = Messaging.copy_message(555, 111, 42, token: @bot_token)
      assert get_in(res, ["result", "message_id"]) == 101
    end
  end

  describe "forward_message/4" do
    test "forwards message from one chat to another" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/forwardMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 555
        assert params["from_chat_id"] == 111
        assert params["message_id"] == 42

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 102}}))
      end)

      assert {:ok, res} = Messaging.forward_message(555, 111, 42, token: @bot_token)
      assert get_in(res, ["result", "message_id"]) == 102
    end
  end
end
