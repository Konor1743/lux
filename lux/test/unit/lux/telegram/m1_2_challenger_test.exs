defmodule Lux.Telegram.M12ChallengerTest do
  use UnitAPICase, async: true

  require Logger
  import ExUnit.CaptureLog

  alias Lux.Telegram.Client
  alias Lux.Lenses.Telegram.Close
  alias Lux.Lenses.Telegram.DeleteWebhook
  alias Lux.Lenses.Telegram.GetMe
  alias Lux.Lenses.Telegram.GetWebhookInfo
  alias Lux.Lenses.Telegram.LogOut
  alias Lux.Lenses.Telegram.SetWebhook

  @secret_token "secret_bot_token_99999_xyz"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "1. Inspect Masking & Token Security" do
    test "inspect(%Lux.Telegram.Client{}) masks the secret token" do
      client = Client.new(@secret_token)
      inspected = inspect(client)

      assert String.contains?(inspected, "[REDACTED]")
      refute String.contains?(inspected, @secret_token)
    end

    test "inspect masks token in nested data structures (maps, lists, tuples, keywords)" do
      client = Client.new(@secret_token)

      nested_map = %{client: client, meta: "data"}
      nested_list = [client, client]
      nested_tuple = {:ok, client}
      nested_kw = [bot_client: client]

      refute String.contains?(inspect(nested_map), @secret_token)
      refute String.contains?(inspect(nested_list), @secret_token)
      refute String.contains?(inspect(nested_tuple), @secret_token)
      refute String.contains?(inspect(nested_kw), @secret_token)

      assert String.contains?(inspect(nested_map), "[REDACTED]")
      assert String.contains?(inspect(nested_list), "[REDACTED]")
      assert String.contains?(inspect(nested_tuple), "[REDACTED]")
      assert String.contains?(inspect(nested_kw), "[REDACTED]")
    end

    test "inspect with nil token displays token: nil" do
      client = %Client{token: nil}
      inspected = inspect(client)
      assert String.contains?(inspected, "token: nil")
      refute String.contains?(inspected, "[REDACTED]")
    end

    test "inspect with structs: false exposes token (known Elixir behaviour)" do
      client = Client.new(@secret_token)
      raw_inspect = inspect(client, structs: false)
      # Documenting empirical finding: structs: false bypasses Inspect protocol
      assert String.contains?(raw_inspect, @secret_token)
    end

    test "error tuples returned by request/3 do not leak secret tokens" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{
          "ok" => false,
          "error_code" => 401,
          "description" => "Unauthorized"
        }))
      end)

      {:error, reason} = Client.request(:get, "/getMe", token: @secret_token)
      refute String.contains?(inspect(reason), @secret_token)
      assert reason == :invalid_token
    end

    test "error response 400 description does not leak token" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: chat not found"
        }))
      end)

      {:error, {400, msg}} = Client.request(:get, "/getMe", token: @secret_token)
      refute String.contains?(inspect(msg), @secret_token)
      assert msg == "Bad Request: chat not found"
    end
  end

  describe "2. Memory & Logging Leak Prevention" do
    test "Logger output does not leak token when logging inspected Client struct" do
      client = Client.new(@secret_token)

      log = capture_log(fn ->
        Logger.info("Created client: #{inspect(client)}")
      end)

      assert String.contains?(log, "[REDACTED]")
      refute String.contains?(log, @secret_token)
    end

    test "Logger output does not leak token during request handling" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"id" => 123, "username" => "secure_bot"}
        }))
      end)

      log = capture_log(fn ->
        Client.request(:get, "/getMe", token: @secret_token)
      end)

      refute String.contains?(log, @secret_token)
    end

    test "memory usage remains stable under batch client creation" do
      initial_mem = :erlang.memory(:total)

      clients = Enum.map(1..5000, fn i ->
        Client.new("token_batch_#{i}")
      end)

      assert length(clients) == 5000
      :erlang.garbage_collect()

      after_mem = :erlang.memory(:total)
      # Verify garbage collector cleans up transient client structs without memory growth spike
      diff_mb = (after_mem - initial_mem) / (1024 * 1024)
      assert diff_mb < 20.0
    end
  end

  describe "3. Lens Focus Capabilities" do
    test "GetMe lens executes focus and returns bot info" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/bot#{@secret_token}/getMe"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{
            "id" => 987_654,
            "is_bot" => true,
            "first_name" => "ChallengerBot",
            "username" => "challenger_bot"
          }
        }))
      end)

      assert {:ok, %{"ok" => true, "result" => %{"username" => "challenger_bot"}}} =
               GetMe.focus(%{token: @secret_token})
    end

    test "SetWebhook lens executes focus with options and before_focus transformation" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@secret_token}/setWebhook"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)

        assert params["url"] == "https://mydomain.com/telegram/webhook"
        assert params["secret_token"] == "super_secret_webhook_token"
        assert params["max_connections"] == 50

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true, "description" => "Webhook was set"}))
      end)

      assert {:ok, %{"ok" => true, "result" => true}} =
               SetWebhook.focus(%{
                 token: @secret_token,
                 url: "https://mydomain.com/telegram/webhook",
                 secret_token: "super_secret_webhook_token",
                 max_connections: 50
               })
    end

    test "DeleteWebhook lens executes focus with drop_pending_updates" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@secret_token}/deleteWebhook"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["drop_pending_updates"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true, "description" => "Webhook was deleted"}))
      end)

      assert {:ok, %{"ok" => true, "result" => true}} =
               DeleteWebhook.focus(%{token: @secret_token, drop_pending_updates: true})
    end

    test "GetWebhookInfo lens executes focus and returns webhook status" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/bot#{@secret_token}/getWebhookInfo"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{
            "url" => "https://mydomain.com/telegram/webhook",
            "has_custom_certificate" => false,
            "pending_update_count" => 0
          }
        }))
      end)

      assert {:ok, %{"ok" => true, "result" => %{"url" => "https://mydomain.com/telegram/webhook"}}} =
               GetWebhookInfo.focus(%{token: @secret_token})
    end

    test "LogOut lens executes focus" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@secret_token}/logOut"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, %{"ok" => true, "result" => true}} =
               LogOut.focus(%{token: @secret_token})
    end

    test "Close lens executes focus" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/bot#{@secret_token}/close"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, %{"ok" => true, "result" => true}} =
               Close.focus(%{token: @secret_token})
    end
  end
end
