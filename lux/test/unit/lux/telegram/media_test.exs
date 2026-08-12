defmodule Lux.Telegram.MediaTest do
  use UnitAPICase, async: true

  alias Lux.Telegram.Media

  @bot_token "test_bot_token_media"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "send_photo/3" do
    test "sends photo using file_id string via JSON" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendPhoto"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["chat_id"] == 12345
        assert params["photo"] == "file_id_xyz"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
      end)

      {:ok, res} = Media.send_photo(12345, "file_id_xyz", token: @bot_token)
      assert res["ok"] == true
    end

    test "sends photo using {:file, path} via multipart form" do
      # Create temp file
      tmp_path = Path.join(System.tmp_dir!(), "test_photo_#{Lux.UUID.generate()}.png")
      File.write!(tmp_path, "fake photo content")

      on_exit(fn -> File.rm(tmp_path) end)

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendPhoto"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        assert String.contains?(body, "fake photo content")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 2}}))
      end)

      {:ok, res} = Media.send_photo(12345, {:file, tmp_path}, token: @bot_token)
      assert res["ok"] == true
    end
  end

  describe "send_document/3, send_voice/3, send_audio/3, send_video/3" do
    test "sends document via JSON" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/sendDocument"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["document"] == "doc_id_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 3}}))
      end)

      {:ok, res} = Media.send_document(12345, "doc_id_123", token: @bot_token)
      assert res["ok"] == true
    end

    test "sends voice via JSON" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/sendVoice"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["voice"] == "voice_id_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 4}}))
      end)

      {:ok, res} = Media.send_voice(12345, "voice_id_123", token: @bot_token)
      assert res["ok"] == true
    end

    test "sends audio via JSON" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/sendAudio"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["audio"] == "audio_id_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 5}}))
      end)

      {:ok, res} = Media.send_audio(12345, "audio_id_123", token: @bot_token)
      assert res["ok"] == true
    end

    test "sends video via JSON" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/sendVideo"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["video"] == "video_id_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 6}}))
      end)

      {:ok, res} = Media.send_video(12345, "video_id_123", token: @bot_token)
      assert res["ok"] == true
    end
  end

  describe "get_file/2" do
    test "fetches file info for given file_id" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/getFile"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["file_id"] == "file_xyz"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"file_id" => "file_xyz", "file_path" => "photos/file_xyz.jpg"}
        }))
      end)

      {:ok, res} = Media.get_file("file_xyz", token: @bot_token)
      assert res["result"]["file_path"] == "photos/file_xyz.jpg"
    end
  end

  describe "download_file/2" do
    test "downloads file directly when path contains slash" do
      file_path = "photos/file_123.jpg"

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/file/bot#{@bot_token}/#{file_path}"

        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.send_resp(200, "fake binary data")
      end)

      {:ok, binary} = Media.download_file(file_path, token: @bot_token, plug: {Req.Test, TelegramClientMock})
      assert binary == "fake binary data"
    end

    test "resolves file_id via get_file when given raw file_id without slashes" do
      file_id = "file_id_raw"
      resolved_path = "documents/file_raw.pdf"

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/getFile"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"file_id" => file_id, "file_path" => resolved_path}
        }))
      end)

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/file/bot#{@bot_token}/#{resolved_path}"

        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_resp(200, "pdf content binary")
      end)

      {:ok, binary} = Media.download_file(file_id, token: @bot_token, plug: {Req.Test, TelegramClientMock})
      assert binary == "pdf content binary"
    end

    test "handles error response on file download" do
      file_path = "photos/nonexistent.jpg"

      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"ok" => false, "description" => "Not Found"}))
      end)

      {:error, {404, body}} = Media.download_file(file_path, token: @bot_token, plug: {Req.Test, TelegramClientMock})
      assert body["description"] == "Not Found"
    end
  end
end
