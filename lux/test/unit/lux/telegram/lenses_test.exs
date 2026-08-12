defmodule Lux.Telegram.LensesTest do
  use UnitAPICase, async: true

  alias Lux.Lenses.Telegram.DeleteMessage
  alias Lux.Lenses.Telegram.EditMessage
  alias Lux.Lenses.Telegram.GetFile
  alias Lux.Lenses.Telegram.SendDocument
  alias Lux.Lenses.Telegram.SendMessage
  alias Lux.Lenses.Telegram.SendPhoto
  alias Lux.Lenses.Telegram.SendVoice

  @bot_token "test_lenses_token_123"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "Lux.Lenses.Telegram.SendMessage" do
    test "focus sends POST request to /sendMessage" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 123
        assert params["text"] == "Hello Lens"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
      end)

      assert {:ok, res} = SendMessage.focus(%{token: @bot_token, chat_id: 123, text: "Hello Lens"})
      assert res["ok"] == true
    end
  end

  describe "Lux.Lenses.Telegram.EditMessage" do
    test "focus sends POST request to /editMessageText" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/editMessageText"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 10}}))
      end)

      assert {:ok, res} = EditMessage.focus(%{token: @bot_token, chat_id: 123, message_id: 10, text: "New Text"})
      assert res["ok"] == true
    end
  end

  describe "Lux.Lenses.Telegram.DeleteMessage" do
    test "focus sends POST request to /deleteMessage" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/deleteMessage"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, res} = DeleteMessage.focus(%{token: @bot_token, chat_id: 123, message_id: 10})
      assert res["result"] == true
    end
  end

  describe "Lux.Lenses.Telegram.SendPhoto" do
    test "focus sends POST request to /sendPhoto" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendPhoto"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 20}}))
      end)

      assert {:ok, res} = SendPhoto.focus(%{token: @bot_token, chat_id: 123, photo: "file_id_1"})
      assert res["ok"] == true
    end
  end

  describe "Lux.Lenses.Telegram.SendDocument" do
    test "focus sends POST request to /sendDocument" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendDocument"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 21}}))
      end)

      assert {:ok, res} = SendDocument.focus(%{token: @bot_token, chat_id: 123, document: "file_id_2"})
      assert res["ok"] == true
    end
  end

  describe "Lux.Lenses.Telegram.SendVoice" do
    test "focus sends POST request to /sendVoice" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendVoice"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 22}}))
      end)

      assert {:ok, res} = SendVoice.focus(%{token: @bot_token, chat_id: 123, voice: "file_id_3"})
      assert res["ok"] == true
    end
  end

  describe "Lux.Lenses.Telegram.GetFile" do
    test "focus sends POST request to /getFile" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/getFile"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"file_id" => "f1", "file_path" => "path.jpg"}}))
      end)

      assert {:ok, res} = GetFile.focus(%{token: @bot_token, file_id: "f1"})
      assert res["ok"] == true
    end
  end
end
