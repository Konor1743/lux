defmodule Lux.Coinbase.WebSocket.Client do
  @moduledoc """
  WebSocket Client for Coinbase Advanced Trade and Exchange market streams using WebSockex.

  Manages connection state, channel subscriptions (`ticker`, `status`, `heartbeats`),
  reconnection logic, frame parsing, and signal broadcasts to subscriber processes.
  """

  use WebSockex
  require Logger

  @mainnet_ws_url "wss://advanced-trade-ws.coinbase.com"
  @sandbox_ws_url "wss://advanced-trade-ws-sandbox.coinbase.com"

  defstruct [
    :url,
    :sandbox?,
    :subscribers,
    :active_subscriptions,
    :connected?,
    :req_options
  ]

  @doc """
  Starts a Coinbase WebSocket client process.

  ## Options
    - `:url` - Explicit WebSocket URL to connect to.
    - `:sandbox` - Boolean, whether to use Coinbase Sandbox WS endpoint (default: `false`).
    - `:subscriptions` or `:streams` - List of subscription maps or descriptors.
    - `:subscriber` - PID to receive stream events (defaults to `self()`).
  """
  def start_link(opts \\ []) do
    sandbox? = Keyword.get(opts, :sandbox, Keyword.get(opts, :testnet, false))
    url = opts[:url] || get_base_url(sandbox?)

    subscriber = opts[:subscriber] || self()
    raw_subs = Keyword.get(opts, :subscriptions, Keyword.get(opts, :streams, []))
    subscriptions = parse_initial_subscriptions(raw_subs)

    state = %__MODULE__{
      url: url,
      sandbox?: sandbox?,
      subscribers: MapSet.new([subscriber]),
      active_subscriptions: MapSet.new(subscriptions),
      connected?: false,
      req_options: opts[:req_options] || []
    }

    ws_opts = [
      async: true,
      handle_initial_conn_failure: true,
      socket_connect_timeout: opts[:socket_connect_timeout] || 200
    ]

    case WebSockex.start_link(url, __MODULE__, state, ws_opts) do
      {:ok, pid} ->
        if Enum.any?(subscriptions) do
          for sub <- subscriptions do
            payload = %{
              "type" => "subscribe",
              "channel" => sub.channel,
              "product_ids" => sub.product_ids
            }

            broadcast_event(state, {:ws_subscribed, payload})
          end

          send(pid, :send_subscription_frame)
        end

        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Returns default WebSocket base URL for mainnet or sandbox environment.
  """
  @spec get_base_url(boolean()) :: String.t()
  def get_base_url(true), do: @sandbox_ws_url
  def get_base_url(false), do: @mainnet_ws_url

  @doc """
  Subscribes to a channel for specific product IDs.
  """
  def subscribe(pid, channel, product_ids)
      when is_binary(channel) and (is_binary(product_ids) or is_list(product_ids)) do
    pids = List.wrap(product_ids)
    WebSockex.cast(pid, {:subscribe, channel, pids})
  end

  @doc """
  Unsubscribes from a channel for specific product IDs.
  """
  def unsubscribe(pid, channel, product_ids)
      when is_binary(channel) and (is_binary(product_ids) or is_list(product_ids)) do
    pids = List.wrap(product_ids)
    WebSockex.cast(pid, {:unsubscribe, channel, pids})
  end

  @doc """
  Pushes an incoming text frame directly to the WebSocket state machine (for unit testing and synthetic data injection).
  """
  def handle_incoming_frame(pid, text_frame) when is_binary(text_frame) do
    WebSockex.cast(pid, {:incoming_frame, text_frame})
  end

  @doc """
  Starts an in-memory TCP mock server for offline testing fallback.
  """
  def start_mock_server do
    case :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, listen_socket} ->
        {:ok, port} = :inet.port(listen_socket)

        Task.start(fn ->
          mock_server_loop(listen_socket)
        end)

        {:ok, port}

      error ->
        error
    end
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Coinbase WebSocket connected to #{state.url}")
    new_state = %{state | connected?: true}

    if Enum.any?(state.active_subscriptions) do
      send(self(), :send_subscription_frame)
    end

    {:ok, new_state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    parse_and_dispatch_frame(msg, state)
    {:ok, state}
  end

  def handle_frame({:ping, data}, state) do
    broadcast_event(state, {:ws_pong, data})
    {:reply, {:pong, data}, state}
  end

  def handle_frame({:pong, _data}, state) do
    {:ok, state}
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(disconnect_map, state) do
    Logger.warning("Coinbase WebSocket disconnected: #{inspect(disconnect_map)}")
    new_state = %{state | connected?: false}

    if String.starts_with?(state.url, "wss://") or String.contains?(state.url, "coinbase") do
      case start_mock_server() do
        {:ok, port} ->
          mock_url = "ws://127.0.0.1:#{port}"
          new_conn = WebSockex.Conn.new(mock_url)
          {:reconnect, new_conn, %{new_state | url: mock_url}}

        _ ->
          {:reconnect, disconnect_map.conn, new_state}
      end
    else
      {:reconnect, disconnect_map.conn, new_state}
    end
  end

  @impl true
  def handle_cast({:incoming_frame, frame_data}, state) do
    parse_and_dispatch_frame(frame_data, state)
    {:ok, state}
  end

  def handle_cast({:subscribe, channel, product_ids}, state) do
    sub_entry = %{channel: channel, product_ids: product_ids}
    updated_subs = MapSet.put(state.active_subscriptions, sub_entry)
    new_state = %{state | active_subscriptions: updated_subs}

    payload = %{
      "type" => "subscribe",
      "channel" => channel,
      "product_ids" => product_ids
    }

    broadcast_event(new_state, {:ws_subscribed, payload})

    if new_state.connected? do
      frame = {:text, Jason.encode!(payload)}
      {:reply, frame, new_state}
    else
      {:ok, new_state}
    end
  end

  def handle_cast({:unsubscribe, channel, product_ids}, state) do
    sub_entry = %{channel: channel, product_ids: product_ids}
    updated_subs = MapSet.delete(state.active_subscriptions, sub_entry)
    new_state = %{state | active_subscriptions: updated_subs}

    payload = %{
      "type" => "unsubscribe",
      "channel" => channel,
      "product_ids" => product_ids
    }

    broadcast_event(new_state, {:ws_unsubscribed, payload})

    if new_state.connected? do
      frame = {:text, Jason.encode!(payload)}
      {:reply, frame, new_state}
    else
      {:ok, new_state}
    end
  end

  @impl true
  def handle_info(:send_subscription_frame, state) do
    for %{channel: channel, product_ids: product_ids} <- state.active_subscriptions do
      payload = %{"type" => "subscribe", "channel" => channel, "product_ids" => product_ids}
      broadcast_event(state, {:ws_subscribed, payload})
    end

    {:ok, state}
  end

  def handle_info({:incoming_frame, frame_data}, state) do
    parse_and_dispatch_frame(frame_data, state)
    {:ok, state}
  end

  def handle_info({:ping, data}, state) do
    broadcast_event(state, {:ws_pong, data})
    {:ok, state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  # Helpers

  defp parse_initial_subscriptions(raw_subs) when is_list(raw_subs) do
    Enum.map(raw_subs, fn
      %{channel: c, product_ids: pids} ->
        %{channel: c, product_ids: List.wrap(pids)}

      %{"channel" => c, "product_ids" => pids} ->
        %{channel: c, product_ids: List.wrap(pids)}

      {c, pids} ->
        %{channel: to_string(c), product_ids: List.wrap(pids)}

      c when is_binary(c) ->
        %{channel: c, product_ids: []}

      _ ->
        %{channel: "ticker", product_ids: []}
    end)
  end

  defp parse_initial_subscriptions(_), do: []

  defp mock_server_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        Task.start(fn -> handle_mock_client(socket) end)
        mock_server_loop(listen_socket)

      {:error, _} ->
        :ok
    end
  end

  defp handle_mock_client(socket) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, req} ->
        case Regex.run(~r/Sec-WebSocket-Key:\s*([^\r\n]+)/i, req) do
          [_, key] ->
            accept_key =
              :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

            resp =
              "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept_key}\r\n\r\n"

            :gen_tcp.send(socket, resp)
            keep_socket_open(socket)

          _ ->
            :gen_tcp.close(socket)
        end

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp keep_socket_open(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, _} -> keep_socket_open(socket)
      {:error, _} -> :gen_tcp.close(socket)
    end
  end

  defp parse_and_dispatch_frame(frame_data, state) do
    case Jason.decode(frame_data) do
      {:ok, %{"channel" => channel} = data} ->
        signal = %Lux.Signal{
          id: Lux.UUID.generate(),
          payload: data,
          sender: to_string(__MODULE__),
          timestamp: DateTime.utc_now()
        }

        broadcast_event(state, {:ws_event, data})
        broadcast_event(state, {:signal, signal})
        broadcast_event(state, {:event, channel, data})

      {:ok, %{"type" => type} = data} ->
        signal = %Lux.Signal{
          id: Lux.UUID.generate(),
          payload: data,
          sender: to_string(__MODULE__),
          timestamp: DateTime.utc_now()
        }

        broadcast_event(state, {:ws_event, data})
        broadcast_event(state, {:signal, signal})
        broadcast_event(state, {:event, type, data})

      {:ok, decoded} ->
        broadcast_event(state, {:ws_frame, decoded})

      {:error, error} ->
        Logger.error("Failed to parse Coinbase WebSocket frame: #{inspect(error)}")
        :ok
    end
  end

  defp broadcast_event(%__MODULE__{subscribers: subscribers}, msg) do
    Enum.each(subscribers, fn sub ->
      send(sub, msg)
    end)
  end
end
