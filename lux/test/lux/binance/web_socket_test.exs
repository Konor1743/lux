defmodule Lux.Binance.WebSocketTest do
  use ExUnit.Case, async: true
  alias Lux.Binance.WebSocket.Client
  alias Lux.Binance.WebSocket.UserDataStream

  setup do
    Req.Test.verify_on_exit!()
  end

  def start_mock_server do
    case :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, listen_socket} ->
        {:ok, port} = :inet.port(listen_socket)

        Task.start(fn ->
          mock_server_loop(listen_socket)
        end)

        {:ok, port}
      error -> error
    end
  end

  defp mock_server_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        Task.start(fn -> handle_mock_client(socket) end)
        mock_server_loop(listen_socket)
      _ -> :ok
    end
  end

  defp handle_mock_client(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, req} ->
        case Regex.run(~r/Sec-WebSocket-Key:\s*([^\r\n]+)/i, req) do
          [_, key] ->
            accept_key = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
            resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept_key}\r\n\r\n"
            :gen_tcp.send(socket, resp)
            keep_socket_open(socket)
          _ -> :gen_tcp.close(socket)
        end
      _ -> :gen_tcp.close(socket)
    end
  end

  defp keep_socket_open(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, _} -> keep_socket_open(socket)
      _ -> :gen_tcp.close(socket)
    end
  end

  describe "WebSocket.Client" do
    setup do
      {:ok, port} = start_mock_server()
      %{mock_url: "ws://127.0.0.1:#{port}"}
    end

    test "starts client and handles subscriptions and stream events", %{mock_url: mock_url} do
      {:ok, pid} = Client.start_link(subscriber: self(), streams: ["btcusdt@trade"], url: mock_url)

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

    test "handles corrupted JSON frame without process termination", %{mock_url: mock_url} do
      {:ok, pid} = Client.start_link(subscriber: self(), url: mock_url)
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

    test "creates listenKey for futures and connects to private socket" do
      {:ok, port} = start_mock_server()
      mock_url = "ws://127.0.0.1:#{port}"

      plug_fn = fn conn ->
        assert conn.request_path == "/fapi/v1/listenKey"
        case conn.method do
          "POST" -> Req.Test.json(conn, %{"listenKey" => "mock_futures_listen_key_456"})
          "DELETE" -> Req.Test.json(conn, %{})
          "PUT" -> Req.Test.json(conn, %{})
        end
      end

      opts = [
        req_options: [plug: plug_fn],
        market_type: :futures,
        api_key: "dummy_key",
        ws_base_url: mock_url,
        subscriber: self()
      ]

      assert {:ok, pid} = UserDataStream.start_link(opts)

      assert_receive {:listen_key_created, "mock_futures_listen_key_456"}, 1000

      state = :sys.get_state(pid)
      assert Process.alive?(state.ws_pid)
      assert state.listen_key == "mock_futures_listen_key_456"
      assert state.market_type == :futures
    end
  end
end
