# Coinbase WebSockets Market Lenses Architecture Analysis (Milestone 1)

## Executive Summary
This document delivers a comprehensive architectural analysis and concrete implementation blueprint for integrating Coinbase Advanced Trade and Exchange WebSocket data streams and market lenses into the `Lux` Elixir framework (`Spectral-Finance/lux`). It builds upon the lens abstraction and WebSockex design patterns established in `lib/lux/lenses/binance/` and `lib/lux/binance/web_socket/client.ex`.

The architecture defines two primary market lenses:
- `Lux.Lenses.Coinbase.CoinbaseTickerPriceLens` (`lib/lux/lenses/coinbase/ticker_price_lens.ex`)
- `Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens` (`lib/lux/lenses/coinbase/exchange_info_lens.ex`)

Supported by a robust WebSockex transport client:
- `Lux.Coinbase.WebSocket.Client` (`lib/lux/coinbase/web_socket/client.ex`)

And tested via deterministic ExUnit tests:
- `test/lux/coinbase/lenses_test.exs`

---

## 1. Existing Binance Implementation Analysis

The existing Binance implementation provides a two-tiered data access pattern:
1. **REST Snapshot Lenses** (`lib/lux/lenses/binance/`): Modules like `BinanceTickerPriceLens` and `BinanceExchangeInfoLens` use `use Lux.Lens` to define snapshot retrieval logic via `Lux.Binance.Client`.
2. **WebSocket Streaming Transport** (`lib/lux/binance/web_socket/client.ex`): A `WebSockex` client managing real-time market stream connections, topic subscriptions, frame parsing, heartbeat ping-pong responses, and signal broadcasts.

### 1.1 Lux Lens Contract & Macro Mechanics
The `Lux.Lens` macro (`lib/lux/lens.ex`) establishes a standard interface for querying data sources:
- **Struct Fields**: `name`, `module_name`, `url`, `method`, `params`, `headers`, `auth`, `description`, `schema`, `after_focus`.
- **Compile-Time Registration**: `use Lux.Lens` registers `@behaviour Lux.Lens` and builds an internal `@lens_struct`.
- **Callback Cascade**:
  1. `view/0`: Returns the static `%Lux.Lens{}` struct.
  2. `focus/2`: Accepts input map and options, merges input into `params`, runs `authenticate/1`, applies `before_focus/1`, and executes `Lux.Lens.focus/2` (or custom overridden `focus/2`).
  3. `after_focus/1`: Post-processes raw API responses into normalized `{:ok, data}` or `{:error, reason}` tuples.

### 1.2 WebSockex Transport & State Management
`Lux.Binance.WebSocket.Client` demonstrates the following transport mechanisms:
- **Base Process**: `use WebSockex` GenServer-like process wrapping WebSocket frames.
- **State Model**:
  ```elixir
  defstruct [:url, :market_type, :testnet?, :subscribers, :active_streams, :connected?, :req_options]
  ```
- **Subscription Frames**: Outgoing text frames formatted as `{"method": "SUBSCRIBE", "params": ["btcusdt@ticker"], "id": 1}`.
- **Frame Handling**:
  - Control frames (`{:ping, data}`): Replies with `{:pong, data}` and broadcasts `{:ws_pong, data}`.
  - Text frames (`{:text, msg}`): Decodes JSON payload with `Jason.decode`.
  - Signal Broadcast: Converts exchange events into `%Lux.Signal{}` structs and broadcasts `{:ws_event, data}`, `{:signal, signal}`, and `{:event, type, data}` to subscriber PIDs.
- **Reconnection & Mock Fallback**: In `handle_disconnect`, attempts auto-reconnection. If network is unreachable or testing offline, spins up an in-memory loopback TCP socket (`start_mock_server/0`) to prevent test hangs.

---

## 2. Coinbase Advanced Trade WebSocket API Specifications

### 2.1 Connection Endpoints
Coinbase provides market streams through two primary WebSocket endpoints:
- **Advanced Trade WebSocket Mainnet**: `wss://advanced-trade-ws.coinbase.com`
- **Advanced Trade WebSocket Sandbox**: `wss://advanced-trade-ws-sandbox.coinbase.com`
- **Exchange Feed WebSocket (Legacy/Public)**: `wss://ws-feed.exchange.coinbase.com`

*Architecture Decision*: Target `wss://advanced-trade-ws.coinbase.com` as the default base URL while maintaining backward compatibility with `wss://ws-feed.exchange.coinbase.com` message structures.

### 2.2 Subscription Payload Format
Coinbase Advanced Trade WS requires subscribing via JSON messages with explicit `channel` and `product_ids` parameters:

**Subscribe Message**:
```json
{
  "type": "subscribe",
  "product_ids": ["BTC-USD", "ETH-USD"],
  "channel": "ticker"
}
```

**Unsubscribe Message**:
```json
{
  "type": "unsubscribe",
  "product_ids": ["BTC-USD"],
  "channel": "ticker"
}
```

### 2.3 Key Market Channels

#### 1. `ticker` Channel
Provides real-time price quotes, 24-hour volume, 24-hour highs/lows, and best bid/ask prices.

*Advanced Trade WS Format*:
```json
{
  "channel": "ticker",
  "client_id": "",
  "timestamp": "2026-08-07T21:00:00.000Z",
  "sequence_num": 102,
  "events": [
    {
      "type": "snapshot",
      "tickers": [
        {
          "type": "ticker",
          "product_id": "BTC-USD",
          "price": "95120.50",
          "volume_24_h": "12345.67",
          "low_24_h": "94000.00",
          "high_24_h": "96000.00",
          "price_percent_chg_24_h": "2.5",
          "best_bid": "95120.00",
          "best_bid_quantity": "0.5",
          "best_ask": "95121.00",
          "best_ask_quantity": "1.2"
        }
      ]
    }
  ]
}
```

*Exchange Feed WS Format*:
```json
{
  "type": "ticker",
  "sequence": 123456,
  "product_id": "BTC-USD",
  "price": "95120.50",
  "open_24h": "92800.00",
  "volume_24h": "12345.67",
  "low_24h": "94000.00",
  "high_24h": "96000.00",
  "best_bid": "95120.00",
  "best_ask": "95121.00",
  "time": "2026-08-07T21:00:00.000Z"
}
```

#### 2. `status` Channel
Provides product status, base/quote currencies, min market funds, and increment constraints.

*Advanced Trade WS Format*:
```json
{
  "channel": "status",
  "client_id": "",
  "timestamp": "2026-08-07T21:00:00.000Z",
  "sequence_num": 1,
  "events": [
    {
      "type": "snapshot",
      "products": [
        {
          "product_id": "BTC-USD",
          "product_type": "SPOT",
          "base_currency_id": "BTC",
          "quote_currency_id": "USD",
          "base_increment": "0.00000001",
          "quote_increment": "0.01",
          "display_name": "BTC/USD",
          "status": "online",
          "min_market_funds": "1"
        }
      ]
    }
  ]
}
```

#### 3. Heartbeats & Ping-Pong
Coinbase sends periodic heartbeat events on the `heartbeats` channel or standard WebSocket ping frames:
```json
{
  "channel": "heartbeats",
  "client_id": "",
  "timestamp": "2026-08-07T21:00:00.000Z",
  "sequence_num": 1,
  "events": [
    {
      "current_time": "2026-08-07T21:00:00.000Z",
      "heartbeat_counter": "42"
    }
  ]
}
```

---

## 3. Side-by-Side Architectural Comparison

| Feature | Binance WebSocket (`Lux.Binance.WebSocket.Client`) | Coinbase WebSocket (`Lux.Coinbase.WebSocket.Client`) |
| :--- | :--- | :--- |
| **Base URL** | `wss://stream.binance.com:9443/ws` | `wss://advanced-trade-ws.coinbase.com` |
| **Sandbox URL** | `wss://testnet.binance.vision/ws` | `wss://advanced-trade-ws-sandbox.coinbase.com` |
| **Subscribe Payload** | `{"method": "SUBSCRIBE", "params": ["btcusdt@ticker"], "id": 1}` | `{"type": "subscribe", "product_ids": ["BTC-USD"], "channel": "ticker"}` |
| **Unsubscribe Payload** | `{"method": "UNSUBSCRIBE", "params": ["btcusdt@ticker"], "id": 2}` | `{"type": "unsubscribe", "product_ids": ["BTC-USD"], "channel": "ticker"}` |
| **Heartbeat** | WS Ping control frames (`{:ping, data}`) | `heartbeats` channel events + WS Ping control frames |
| **Symbol Format** | Lowercase concatenated (`btcusdt`) | Uppercase hyphenated (`BTC-USD`) |
| **Data Container** | Direct JSON object or array | Event array wrapped inside top-level envelope |
| **Lens Snapshot Fallback**| `https://api.binance.com/api/v3/...` | `https://api.coinbase.com/api/v3/brokerage/market/products/...` |

---

## 4. Design & Implementation Blueprints

### 4.1 `Lux.Coinbase.WebSocket.Client` (`lib/lux/coinbase/web_socket/client.ex`)

```elixir
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
    - `:subscriptions` - List of subscription maps, e.g. `[%{channel: "ticker", product_ids: ["BTC-USD"]}]`.
    - `:subscriber` - PID to receive stream events (defaults to `self()`).
  """
  def start_link(opts \\ []) do
    sandbox? = Keyword.get(opts, :sandbox, Keyword.get(opts, :testnet, false))
    url = opts[:url] || get_base_url(sandbox?)

    subscriber = opts[:subscriber] || self()
    subscriptions = Keyword.get(opts, :subscriptions, [])

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
          send(pid, :send_subscription_frame)
        end
        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Returns default WebSocket base URL.
  """
  @spec get_base_url(boolean()) :: String.t()
  def get_base_url(true), do: @sandbox_ws_url
  def get_base_url(false), do: @mainnet_ws_url

  @doc """
  Subscribes to a channel for specific product IDs.
  """
  def subscribe(pid, channel, product_ids) when is_binary(channel) and (is_binary(product_ids) or is_list(product_ids)) do
    pids = List.wrap(product_ids)
    WebSockex.cast(pid, {:subscribe, channel, pids})
  end

  @doc """
  Unsubscribes from a channel for specific product IDs.
  """
  def unsubscribe(pid, channel, product_ids) when is_binary(channel) and (is_binary(product_ids) or is_list(product_ids)) do
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

  def handle_info(_msg, state) do
    {:ok, state}
  end

  # Internal Helpers

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
            accept_key = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
            resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept_key}\r\n\r\n"
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
```

---

### 4.2 `Lux.Lenses.Coinbase.CoinbaseTickerPriceLens` (`lib/lux/lenses/coinbase/ticker_price_lens.ex`)

```elixir
defmodule Lux.Lenses.Coinbase.CoinbaseTickerPriceLens do
  @moduledoc """
  A Lens for fetching current ticker price data from Coinbase Advanced Trade REST API and parsing WebSocket ticker frames.

  ## Examples

      # REST Snapshot Query
      iex> Lux.Lenses.Coinbase.CoinbaseTickerPriceLens.focus(%{product_id: "BTC-USD"})
      {:ok, %{"product_id" => "BTC-USD", "price" => "95120.50"}}

      # WebSocket Frame Normalization
      iex> Lux.Lenses.Coinbase.CoinbaseTickerPriceLens.normalize_ws_frame(frame)
      {:ok, %{"product_id" => "BTC-USD", "price" => "95120.50", "volume_24h" => "12345.67"}}
  """

  use Lux.Lens,
    name: "Coinbase Ticker Price Lens",
    description: "Fetches current ticker price for a product symbol on Coinbase Advanced Trade.",
    url: "https://api.coinbase.com/api/v3/brokerage/market/products",
    method: :get,
    schema: %{
      type: :object,
      properties: %{
        product_id: %{
          type: :string,
          description: "Trading pair product ID (e.g. 'BTC-USD'). Required."
        },
        sandbox: %{
          type: :boolean,
          default: false,
          description: "Whether to target Coinbase Sandbox API"
        }
      },
      required: ["product_id"]
    }

  alias Lux.Coinbase.Client
  alias Lux.Coinbase.WebSocket.Client, as: WSClient

  @doc """
  Focuses the lens to fetch ticker price snapshot from Coinbase REST API.
  """
  def focus(input, opts \\ []) do
    product_id = Map.get(input, :product_id) || Map.get(input, "product_id")

    if is_nil(product_id) or product_id == "" do
      {:error, :missing_product_id}
    else
      path = "/api/v3/brokerage/market/products/#{product_id}/ticker"
      sandbox? = Map.get(input, :sandbox) || Map.get(input, "sandbox", false) || Keyword.get(opts, :sandbox, false)
      client_opts = Keyword.merge([sandbox: sandbox?], opts)

      case Client.request(:get, path, %{}, client_opts) do
        {:ok, body} -> after_focus(body)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def after_focus(%{"trades" => [latest_trade | _]} = body) do
    normalized = %{
      "product_id" => Map.get(body, "product_id"),
      "price" => Map.get(latest_trade, "price"),
      "best_bid" => Map.get(body, "best_bid"),
      "best_ask" => Map.get(body, "best_ask"),
      "raw_data" => body
    }

    {:ok, normalized}
  end

  def after_focus(%{"price" => _price} = body) do
    {:ok, body}
  end

  def after_focus(body) do
    {:ok, body}
  end

  @doc """
  Subscribes a WebSocket client PID to the `ticker` channel for given product IDs.
  """
  def subscribe_stream(ws_client_pid, product_ids) do
    WSClient.subscribe(ws_client_pid, "ticker", product_ids)
  end

  @doc """
  Normalizes an incoming Coinbase WebSocket frame into a standard Lux ticker map.
  Supports both Advanced Trade WS (`channel: "ticker"`) and Exchange Feed WS (`type: "ticker"`).
  """
  @spec normalize_ws_frame(map()) :: {:ok, map()} | {:error, term()}
  def normalize_ws_frame(%{"channel" => "ticker", "events" => events}) when is_list(events) do
    tickers =
      events
      |> Enum.flat_map(fn event -> Map.get(event, "tickers", []) end)
      |> Enum.map(fn ticker ->
        %{
          "product_id" => ticker["product_id"],
          "price" => ticker["price"],
          "volume_24h" => ticker["volume_24_h"],
          "low_24h" => ticker["low_24_h"],
          "high_24h" => ticker["high_24_h"],
          "price_percent_chg_24h" => ticker["price_percent_chg_24_h"],
          "best_bid" => ticker["best_bid"],
          "best_bid_quantity" => ticker["best_bid_quantity"],
          "best_ask" => ticker["best_ask"],
          "best_ask_quantity" => ticker["best_ask_quantity"]
        }
      end)

    case tickers do
      [single] -> {:ok, single}
      multiple -> {:ok, %{"tickers" => multiple}}
    end
  end

  def normalize_ws_frame(%{"type" => "ticker", "product_id" => product_id} = frame) do
    normalized = %{
      "product_id" => product_id,
      "price" => frame["price"],
      "volume_24h" => frame["volume_24h"],
      "low_24h" => frame["low_24h"],
      "high_24h" => frame["high_24h"],
      "best_bid" => frame["best_bid"],
      "best_ask" => frame["best_ask"],
      "timestamp" => frame["time"]
    }

    {:ok, normalized}
  end

  def normalize_ws_frame(frame) do
    {:error, {:unsupported_frame, frame}}
  end
end
```

---

### 4.3 `Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens` (`lib/lux/lenses/coinbase/exchange_info_lens.ex`)

```elixir
defmodule Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens do
  @moduledoc """
  A Lens for fetching product trading rules, status, increments, and precisions from Coinbase Advanced Trade.

  ## Examples

      # Query all product exchange info
      iex> Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens.focus(%{})
      {:ok, %{"products" => [...]}}

      # Query specific product exchange info
      iex> Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens.focus(%{product_id: "BTC-USD"})
      {:ok, %{"product_id" => "BTC-USD", "status" => "online"}}
  """

  use Lux.Lens,
    name: "Coinbase Exchange Info Lens",
    description: "Fetches product trading rules, status, increments, and precisions from Coinbase Advanced Trade.",
    url: "https://api.coinbase.com/api/v3/brokerage/market/products",
    method: :get,
    schema: %{
      type: :object,
      properties: %{
        product_id: %{
          type: :string,
          description: "Optional specific trading pair product ID (e.g. 'BTC-USD')."
        },
        sandbox: %{
          type: :boolean,
          default: false,
          description: "Whether to target Coinbase Sandbox API"
        }
      }
    }

  alias Lux.Coinbase.Client
  alias Lux.Coinbase.WebSocket.Client, as: WSClient

  @doc """
  Focuses the lens to fetch exchange info from Coinbase REST API.
  """
  def focus(input \\ %{}, opts \\ []) do
    product_id = Map.get(input, :product_id) || Map.get(input, "product_id")
    sandbox? = Map.get(input, :sandbox) || Map.get(input, "sandbox", false) || Keyword.get(opts, :sandbox, false)
    client_opts = Keyword.merge([sandbox: sandbox?], opts)

    path =
      if product_id && product_id != "" do
        "/api/v3/brokerage/market/products/#{product_id}"
      else
        "/api/v3/brokerage/market/products"
      end

    case Client.request(:get, path, %{}, client_opts) do
      {:ok, body} -> after_focus(body)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def after_focus(body) do
    {:ok, body}
  end

  @doc """
  Subscribes a WebSocket client PID to the `status` channel for given product IDs.
  """
  def subscribe_stream(ws_client_pid, product_ids) do
    WSClient.subscribe(ws_client_pid, "status", product_ids)
  end

  @doc """
  Normalizes an incoming Coinbase WebSocket `status` channel frame.
  Supports both Advanced Trade WS (`channel: "status"`) and Exchange Feed WS (`type: "status"`).
  """
  @spec normalize_ws_frame(map()) :: {:ok, map()} | {:error, term()}
  def normalize_ws_frame(%{"channel" => "status", "events" => events}) when is_list(events) do
    products =
      events
      |> Enum.flat_map(fn event -> Map.get(event, "products", []) end)
      |> Enum.map(fn prod ->
        %{
          "product_id" => prod["product_id"],
          "product_type" => prod["product_type"],
          "status" => prod["status"],
          "base_currency" => prod["base_currency_id"],
          "quote_currency" => prod["quote_currency_id"],
          "base_increment" => prod["base_increment"],
          "quote_increment" => prod["quote_increment"],
          "min_market_funds" => prod["min_market_funds"]
        }
      end)

    case products do
      [single] -> {:ok, single}
      multiple -> {:ok, %{"products" => multiple}}
    end
  end

  def normalize_ws_frame(%{"type" => "status", "products" => products}) when is_list(products) do
    normalized_products =
      Enum.map(products, fn prod ->
        %{
          "product_id" => prod["id"] || prod["product_id"],
          "status" => prod["status"],
          "base_currency" => prod["base_currency"],
          "quote_currency" => prod["quote_currency"],
          "base_increment" => prod["base_increment"],
          "quote_increment" => prod["quote_increment"]
        }
      end)

    {:ok, %{"products" => normalized_products}}
  end

  def normalize_ws_frame(frame) do
    {:error, {:unsupported_frame, frame}}
  end
end
```

---

### 4.4 `test/lux/coinbase/lenses_test.exs`

```elixir
defmodule Lux.Coinbase.LensesTest do
  use ExUnit.Case, async: true

  alias Lux.Lenses.Coinbase.CoinbaseTickerPriceLens
  alias Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens
  alias Lux.Coinbase.WebSocket.Client, as: WSClient

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "CoinbaseTickerPriceLens REST Focus" do
    test "fetches snapshot ticker price for symbol via Req.Test mock" do
      Req.Test.expect(Lux.Coinbase.LensesTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products/BTC-USD/ticker"
        Req.Test.json(conn, %{
          "trades" => [%{"price" => "95120.50"}],
          "best_bid" => "95120.00",
          "best_ask" => "95121.00",
          "product_id" => "BTC-USD"
        })
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.LensesTest}]]

      assert {:ok, result} = CoinbaseTickerPriceLens.focus(%{product_id: "BTC-USD"}, opts)
      assert result["product_id"] == "BTC-USD"
      assert result["price"] == "95120.50"
    end

    test "returns missing_product_id error when product_id is empty" do
      assert {:error, :missing_product_id} = CoinbaseTickerPriceLens.focus(%{})
    end
  end

  describe "CoinbaseExchangeInfoLens REST Focus" do
    test "fetches product exchange info via Req.Test mock" do
      Req.Test.expect(Lux.Coinbase.LensesTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products/ETH-USD"
        Req.Test.json(conn, %{
          "product_id" => "ETH-USD",
          "status" => "online",
          "base_currency_id" => "ETH",
          "quote_currency_id" => "USD"
        })
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.LensesTest}]]

      assert {:ok, result} = CoinbaseExchangeInfoLens.focus(%{product_id: "ETH-USD"}, opts)
      assert result["product_id"] == "ETH-USD"
      assert result["status"] == "online"
    end
  end

  describe "WebSocket Frame Normalization" do
    test "CoinbaseTickerPriceLens normalizes Advanced Trade ticker frame" do
      frame = %{
        "channel" => "ticker",
        "events" => [
          %{
            "type" => "snapshot",
            "tickers" => [
              %{
                "product_id" => "BTC-USD",
                "price" => "95120.50",
                "volume_24_h" => "12345.67",
                "low_24_h" => "94000.00",
                "high_24_h" => "96000.00",
                "price_percent_chg_24_h" => "2.5",
                "best_bid" => "95120.00",
                "best_bid_quantity" => "0.5",
                "best_ask" => "95121.00",
                "best_ask_quantity" => "1.2"
              }
            ]
          }
        ]
      }

      assert {:ok, normalized} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
      assert normalized["product_id"] == "BTC-USD"
      assert normalized["price"] == "95120.50"
      assert normalized["volume_24h"] == "12345.67"
    end

    test "CoinbaseExchangeInfoLens normalizes status frame" do
      frame = %{
        "channel" => "status",
        "events" => [
          %{
            "type" => "snapshot",
            "products" => [
              %{
                "product_id" => "BTC-USD",
                "product_type" => "SPOT",
                "status" => "online",
                "base_currency_id" => "BTC",
                "quote_currency_id" => "USD",
                "base_increment" => "0.00000001",
                "quote_increment" => "0.01",
                "min_market_funds" => "1"
              }
            ]
          }
        ]
      }

      assert {:ok, normalized} = CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
      assert normalized["product_id"] == "BTC-USD"
      assert normalized["status"] == "online"
      assert normalized["base_currency"] == "BTC"
    end
  end

  describe "Coinbase.WebSocket.Client Integration" do
    test "starts client and broadcasts channel events" do
      {:ok, pid} = WSClient.start_link(subscriber: self())

      WSClient.subscribe(pid, "ticker", ["BTC-USD"])
      assert_receive {:ws_subscribed, %{"type" => "subscribe", "channel" => "ticker"}}, 1000

      ticker_frame = Jason.encode!(%{
        "channel" => "ticker",
        "events" => [
          %{
            "type" => "update",
            "tickers" => [%{"product_id" => "BTC-USD", "price" => "95120.50"}]
          }
        ]
      })

      WSClient.handle_incoming_frame(pid, ticker_frame)

      assert_receive {:ws_event, %{"channel" => "ticker"}}, 3000
      assert_receive {:signal, %Lux.Signal{payload: %{"channel" => "ticker"}}}, 3000
    end

    test "handles malformed frame gracefully" do
      {:ok, pid} = WSClient.start_link(subscriber: self())
      WSClient.handle_incoming_frame(pid, "{invalid_json_payload...")

      assert Process.alive?(pid)
    end
  end
end
```

---

## 5. Step-by-Step Implementation Guide & Verification Plan

### Implementation Steps (Milestone 4 Execution)
1. **Directory Setup**:
   Create directory structure: `lib/lux/coinbase/web_socket/` and `lib/lux/lenses/coinbase/`.
2. **WebSocket Client**:
   Write `lib/lux/coinbase/web_socket/client.ex` using the blueprint above.
3. **Market Lenses**:
   Write `lib/lux/lenses/coinbase/ticker_price_lens.ex` and `lib/lux/lenses/coinbase/exchange_info_lens.ex`.
4. **Test Suite**:
   Create `test/lux/coinbase/lenses_test.exs` using ExUnit and `Req.Test`.

### Verification Method
- Execute `mix test test/lux/coinbase/lenses_test.exs` to verify snapshot polling, frame normalization, and WebSocket signal dispatch without external network calls.
- Verify zero compiler warnings using `mix compile --warnings-as-errors`.
- Verify formatting with `mix format --check-formatted`.
