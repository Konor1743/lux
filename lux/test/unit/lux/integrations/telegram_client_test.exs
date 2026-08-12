defmodule Lux.Integrations.TelegramClientTest do
  use UnitAPICase, async: true

  alias Lux.Integrations.Telegram.Client

  @bot_token "test_bot_token_123"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "request/3" do
    test "makes GET API call with token path interpolation" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/bot#{@bot_token}/getMe"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{
            "id" => 123_456,
            "is_bot" => true,
            "first_name" => "TestBot",
            "username" => "test_bot"
          }
        }))
      end)

      {:ok, response} = Client.request(:get, "/getMe", %{token: @bot_token})
      assert response["ok"] == true
      assert get_in(response, ["result", "username"]) == "test_bot"
    end

    test "makes POST API call with JSON payload" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@bot_token}/sendMessage"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        body_params = Jason.decode!(body)
        assert body_params["chat_id"] == 999
        assert body_params["text"] == "Hello Telegram"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"message_id" => 1}
        }))
      end)

      {:ok, response} =
        Client.request(:post, "/sendMessage", %{
          token: @bot_token,
          json: %{chat_id: 999, text: "Hello Telegram"}
        })

      assert response["ok"] == true
      assert get_in(response, ["result", "message_id"]) == 1
    end

    test "handles HTTP 401 unauthenticated errors" do
      invalid_token = "invalid_token_999"

      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path == "/bot#{invalid_token}/getMe"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{
          "ok" => false,
          "error_code" => 401,
          "description" => "Unauthorized"
        }))
      end)

      {:error, :invalid_token} = Client.request(:get, "/getMe", %{token: invalid_token})
    end
  end

  describe "Lux.Telegram.Lens" do
    defmodule TestBotLens do
      use Lux.Telegram.Lens,
        name: "Test Bot Lens",
        url: "https://api.telegram.org/bot/getMe",
        method: :get
    end

    test "lens interpolates token in URL and executes focus" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/bot#{@bot_token}/getMe"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"id" => 123, "username" => "lens_bot"}
        }))
      end)

      assert {:ok, %{"ok" => true, "result" => %{"username" => "lens_bot"}}} =
               TestBotLens.focus(%{token: @bot_token})
    end
  end
end
