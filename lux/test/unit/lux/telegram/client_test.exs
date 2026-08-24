defmodule Lux.Telegram.ClientTest do
  use UnitAPICase, async: true

  alias Lux.Telegram.Client
  alias Lux.Telegram.Types.{User, WebhookInfo}

  @bot_token "test_client_token_12345"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "new/1,2 struct initialization" do
    test "creates client with explicit token" do
      client = Client.new(@bot_token)
      assert client.token == @bot_token
      assert client.base_url == "https://api.telegram.org/bot"
      assert client.req_options == []
    end

    test "creates client with options keyword / map" do
      client = Client.new(token: @bot_token, base_url: "https://custom.tg.api/bot", req_options: [timeout: 5000])
      assert client.token == @bot_token
      assert client.base_url == "https://custom.tg.api/bot"
      assert client.req_options == [timeout: 5000]

      client_map = Client.new(%{token: @bot_token, base_url: "https://custom.tg.api/bot"})
      assert client_map.token == @bot_token
      assert client_map.base_url == "https://custom.tg.api/bot"
    end

    test "creates default client when nil passed" do
      client = Client.new()
      assert %Client{} = client
      assert client.base_url == "https://api.telegram.org/bot"
    end
  end

  describe "build_url/3" do
    test "interpolates token and endpoint correctly" do
      assert Client.build_url("https://api.telegram.org/bot", "123", "getMe") ==
               "https://api.telegram.org/bot123/getMe"

      assert Client.build_url("https://api.telegram.org/bot", "123", "/getMe") ==
               "https://api.telegram.org/bot123/getMe"

      assert Client.build_url("https://api.telegram.org/bot{token}", "123", "/sendMessage") ==
               "https://api.telegram.org/bot123/sendMessage"

      assert Client.build_url("https://custom-proxy.com", "123", "/getMe") ==
               "https://custom-proxy.com/bot123/getMe"
    end
  end

  describe "request/2,3,4 HTTP dispatching" do
    test "dispatches GET request with client struct" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/bot#{@bot_token}/getMe"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"id" => 123, "username" => "test_bot"}
        }))
      end)

      assert {:ok, resp} = Client.request(client, :get, "/getMe", [])
      assert resp["ok"] == true
      assert resp["result"]["username"] == "test_bot"
    end

    test "dispatches POST request with JSON payload" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)
        assert json["chat_id"] == 123
        assert json["text"] == "test message"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"message_id" => 100}
        }))
      end)

      assert {:ok, resp} = Client.request(client, :post, "/sendMessage", json: %{chat_id: 123, text: "test message"})
      assert resp["ok"] == true
      assert resp["result"]["message_id"] == 100
    end

    test "handles 401 invalid token response" do
      client = Client.new("invalid_tok")

      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{
          "ok" => false,
          "error_code" => 401,
          "description" => "Unauthorized"
        }))
      end)

      assert {:error, :invalid_token} = Client.request(client, :get, "/getMe")
    end

    test "handles 400 error description response" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: chat not found"
        }))
      end)

      assert {:error, {400, "Bad Request: chat not found"}} = Client.request(client, :post, "/sendMessage", json: %{chat_id: 0})
    end

    test "handles 429 rate limit response" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{
          "ok" => false,
          "error_code" => 429,
          "description" => "Too Many Requests: retry after 2",
          "parameters" => %{"retry_after" => 2}
        }))
      end)

      assert {:error, {429, body}} = Client.request(client, :get, "/getMe", max_rate_limit_retries: 0)
      assert body["parameters"]["retry_after"] == 2
    end
  end

  describe "bot management helpers" do
    test "get_me/1 returns Types.User struct on success" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{
            "id" => 12345,
            "is_bot" => true,
            "first_name" => "Botty",
            "username" => "botty_bot"
          }
        }))
      end)

      assert {:ok, %User{} = user} = Client.get_me(client)
      assert user.id == 12345
      assert user.first_name == "Botty"
      assert user.username == "botty_bot"
    end

    test "get_webhook_info/1 returns Types.WebhookInfo struct on success" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{
            "url" => "https://example.com/tg/webhook",
            "has_custom_certificate" => false,
            "pending_update_count" => 0
          }
        }))
      end)

      assert {:ok, %WebhookInfo{} = info} = Client.get_webhook_info(client)
      assert info.url == "https://example.com/tg/webhook"
      assert info.pending_update_count == 0
    end
  end

  describe "media delegations and client-first helpers" do
    test "get_file/1,2 and get_file(client, file_id, opts)" do
      client = Client.new(@bot_token)

      # 1. Client-first call
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/getFile"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"file_id" => "fid_1", "file_path" => "photos/f1.jpg"}
        }))
      end)

      assert {:ok, resp1} = Client.get_file(client, "fid_1")
      assert resp1["result"]["file_path"] == "photos/f1.jpg"

      # 2. Direct delegation call with opts
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/getFile"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"file_id" => "fid_2", "file_path" => "photos/f2.jpg"}
        }))
      end)

      assert {:ok, resp2} = Client.get_file("fid_2", token: @bot_token)
      assert resp2["result"]["file_path"] == "photos/f2.jpg"
    end

    test "download_file/1,2 and download_file(client, path_or_id, opts)" do
      client = Client.new(@bot_token)

      # Client-first download by direct file_path
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/file/bot#{@bot_token}/documents/report.pdf"

        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_resp(200, "BINARY_PDF_DATA")
      end)

      assert {:ok, "BINARY_PDF_DATA"} = Client.download_file(client, "documents/report.pdf")

      # Direct delegation download by file_id (calls getFile then file download)
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/getFile"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"file_id" => "fid_doc", "file_path" => "documents/report2.pdf"}
        }))
      end)

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/file/bot#{@bot_token}/documents/report2.pdf"

        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_resp(200, "BINARY_PDF_DATA_2")
      end)

      assert {:ok, "BINARY_PDF_DATA_2"} = Client.download_file("fid_doc", token: @bot_token)
    end

    test "send_audio/2,3,4 client-first and direct delegation" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendAudio"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"message_id" => 501}
        }))
      end)

      assert {:ok, resp} = Client.send_audio(client, 123, "https://example.com/sound.mp3")
      assert resp["ok"] == true
    end

    test "send_video/2,3,4 client-first and direct delegation" do
      client = Client.new(@bot_token)

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendVideo"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"message_id" => 502}
        }))
      end)

      assert {:ok, resp} = Client.send_video(client, 123, "https://example.com/clip.mp4")
      assert resp["ok"] == true
    end
  end

  describe "mock isolation & plug preservation" do
    test "custom plug option is preserved across request dispatch without hitting network" do
      custom_plug = fn conn ->
        assert conn.request_path == "/botcustom_token/getMe"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"id" => 777, "username" => "custom_mock_bot"}
        }))
      end

      assert {:ok, resp} = Client.request(:get, "/getMe", token: "custom_token", plug: custom_plug)
      assert resp["result"]["username"] == "custom_mock_bot"
    end
  end
end
