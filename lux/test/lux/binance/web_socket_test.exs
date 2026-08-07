defmodule Lux.Binance.WebSocketTest do
  use ExUnit.Case, async: true
  alias Lux.Binance.WebSocket.Client
  alias Lux.Binance.WebSocket.UserDataStream

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "WebSocket.Client" do
    test "starts client and handles subscriptions and stream events" do
      {:ok, pid} = Client.start_link(subscriber: self(), streams: ["btcusdt@trade"])

      assert_receive {:ws_subscribed, %{"method" => "SUBSCRIBE"}}, 1000

      assert :ok == Client.subscribe(pid, "ethusdt@ticker")
      assert_receive {:ws_subscribed, %{"params" => ["ethusdt@ticker"]}}, 3000

      # Dispatch synthetic trade frame
      trade_frame = Jason.encode!(%{
        "e" => "trade",
        "E" => 1672515782136,
        "s" => "BTCUSDT",
        "t" => 12345,
        "p" => "95000.00",
        "q" => "0.05"
      })

      Client.handle_incoming_frame(pid, trade_frame)

      assert_receive {:ws_event, %{"e" => "trade", "s" => "BTCUSDT"}}, 3000
      assert_receive {:signal, %Lux.Signal{payload: %{"p" => "95000.00"}}}, 3000
    end

    test "handles corrupted JSON frame without process termination" do
      {:ok, pid} = Client.start_link(subscriber: self())
      Client.handle_incoming_frame(pid, "INVALID_RAW_JSON{{{")

      assert Process.alive?(pid)
    end
  end

  describe "WebSocket.UserDataStream" do
    test "creates and closes listenKey via HTTP requests" do
      Req.Test.expect(Lux.Binance.WebSocketTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/userDataStream"
        Req.Test.json(conn, %{"listenKey" => "mock_listen_key_123"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Binance.WebSocketTest}]]
      assert {:ok, "mock_listen_key_123"} = UserDataStream.create_listen_key(:spot, opts)

      Req.Test.expect(Lux.Binance.WebSocketTest, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/api/v3/userDataStream"
        assert conn.query_string =~ "listenKey=mock_listen_key_123"
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{}} = UserDataStream.keep_alive_listen_key(:spot, "mock_listen_key_123", opts)
    end
  end
end
