defmodule Lux.Telegram.WebhookPlugTest do
  use UnitAPICase, async: false
  import Mock

  alias Lux.Telegram.WebhookPlug

  defmodule DummyHandler do
    def handle_signal(signal) do
      send(self(), {:dummy_handled, signal})
      :ok
    end
  end

  describe "init/1" do
    test "initializes with explicit secret_token and handler" do
      opts = WebhookPlug.init(secret_token: "my_secret", handler: self())
      assert opts.secret_token == "my_secret"
      assert opts.handler == self()
    end

    test "initializes with string key secret_token" do
      opts = WebhookPlug.init(%{"secret_token" => "string_secret"})
      assert opts.secret_token == "string_secret"
    end

    test "falls back to config or env for secret token" do
      System.put_env("TELEGRAM_SECRET_TOKEN", "env_secret_token")

      with_mock Lux.Config, [:passthrough], [telegram_secret_token: fn -> nil end] do
        opts = WebhookPlug.init(%{})
        assert opts.secret_token == "env_secret_token"
      end

      System.delete_env("TELEGRAM_SECRET_TOKEN")
    end
  end

  describe "call/2 authorization" do
    test "allows request when secret_token is nil or empty" do
      opts = WebhookPlug.init(secret_token: nil, handler: self())

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 100}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:telegram_update, signal}
      assert signal.payload["update_id"] == 100
    end

    test "allows request when secret_token matches X-Telegram-Bot-Api-Secret-Token header" do
      opts = WebhookPlug.init(secret_token: "secret_123", handler: self())

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 101}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "secret_123")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:telegram_update, signal}
      assert signal.payload["update_id"] == 101
    end

    test "rejects request with 401 when secret_token header is invalid or missing" do
      opts = WebhookPlug.init(secret_token: "secret_123", handler: self())

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 102}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", "wrong_secret")
        |> WebhookPlug.call(opts)

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized", "status" => "error"}
    end
  end

  describe "dispatch_signal with different handlers" do
    test "dispatches signal to function handler" do
      test_pid = self()
      handler_fn = fn sig -> send(test_pid, {:fn_handled, sig}) end
      opts = WebhookPlug.init(handler: handler_fn)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 201}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:fn_handled, signal}
      assert signal.payload["update_id"] == 201
    end

    test "handles exceptions in function handler gracefully" do
      failing_fn = fn _sig -> raise "Handler crash test" end
      opts = WebhookPlug.init(handler: failing_fn)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 202}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
    end

    test "dispatches signal to module handler" do
      opts = WebhookPlug.init(handler: DummyHandler)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 203}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:dummy_handled, signal}
      assert signal.payload["update_id"] == 203
    end

    test "parses payload pre-populated in body_params" do
      opts = WebhookPlug.init(handler: self())

      conn =
        :post
        |> Plug.Test.conn("/webhook")
        |> Map.put(:body_params, %{"update_id" => 301, "message" => %{"text" => "preparsed"}})
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:telegram_update, signal}
      assert signal.payload["update_id"] == 301
    end
  end
end
