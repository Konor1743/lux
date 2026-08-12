defmodule Lux.Lenses.Telegram.LensesTest do
  use UnitAPICase, async: true

  alias Lux.Lenses.Telegram.DeleteMessage
  alias Lux.Lenses.Telegram.EditMessage
  alias Lux.Lenses.Telegram.GetFile
  alias Lux.Lenses.Telegram.SendDocument
  alias Lux.Lenses.Telegram.SendMessage
  alias Lux.Lenses.Telegram.SendPhoto
  alias Lux.Lenses.Telegram.SendVoice

  @token "lens_test_token"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "SendMessage lens" do
    test "focus sends text message to chat" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@token}/sendMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["text"] == "Hello from SendMessage lens"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 101}}))
      end)

      assert {:ok, %{"ok" => true, "result" => %{"message_id" => 101}}} =
               SendMessage.focus(%{token: @token, chat_id: 12345, text: "Hello from SendMessage lens"})
    end
  end

  describe "EditMessage lens" do
    test "focus edits message text" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@token}/editMessageText"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["message_id"] == 101
        assert params["text"] == "Edited message text"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 101}}))
      end)

      assert {:ok, %{"ok" => true}} =
               EditMessage.focus(%{token: @token, chat_id: 12345, message_id: 101, text: "Edited message text"})
    end
  end

  describe "DeleteMessage lens" do
    test "focus deletes message" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@token}/deleteMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["message_id"] == 101

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, %{"ok" => true, "result" => true}} =
               DeleteMessage.focus(%{token: @token, chat_id: 12345, message_id: 101})
    end
  end

  describe "GetFile lens" do
    test "focus retrieves file info" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@token}/getFile"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["file_id"] == "file_abc"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"file_path" => "voice/file_abc.oga"}}))
      end)

      assert {:ok, %{"result" => %{"file_path" => "voice/file_abc.oga"}}} =
               GetFile.focus(%{token: @token, file_id: "file_abc"})
    end
  end

  describe "SendDocument lens" do
    test "focus sends document URL or file_id" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@token}/sendDocument"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["document"] == "doc_id_999"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 102}}))
      end)

      assert {:ok, %{"ok" => true}} =
               SendDocument.focus(%{token: @token, chat_id: 12345, document: "doc_id_999"})
    end
  end

  describe "SendPhoto lens" do
    test "focus sends photo URL or file_id" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@token}/sendPhoto"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["photo"] == "photo_id_999"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 103}}))
      end)

      assert {:ok, %{"ok" => true}} =
               SendPhoto.focus(%{token: @token, chat_id: 12345, photo: "photo_id_999"})
    end
  end

  describe "SendVoice lens" do
    test "focus sends voice URL or file_id" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@token}/sendVoice"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["voice"] == "voice_id_999"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 104}}))
      end)

      assert {:ok, %{"ok" => true}} =
               SendVoice.focus(%{token: @token, chat_id: 12345, voice: "voice_id_999"})
    end
  end
end
