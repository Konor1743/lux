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
          description: "Trading pair product ID (e.g. 'BTC-USD'). Required unless symbol is provided."
        },
        symbol: %{
          type: :string,
          description: "Trading pair symbol alias for product_id (e.g. 'BTC-USD')."
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
  Focuses the lens to fetch ticker price snapshot from Coinbase REST API.
  """
  def focus(input, opts) do
    product_id =
      Map.get(input, :product_id) ||
        Map.get(input, "product_id") ||
        Map.get(input, :symbol) ||
        Map.get(input, "symbol")

    if is_nil(product_id) or product_id == "" do
      {:error, :missing_product_id}
    else
      path = "/api/v3/brokerage/market/products/#{product_id}/ticker"

      sandbox? =
        Map.get(input, :sandbox) ||
          Map.get(input, "sandbox", false) ||
          Keyword.get(opts, :sandbox, false)

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
          "volume_24h" => ticker["volume_24_h"] || ticker["volume_24h"],
          "low_24h" => ticker["low_24_h"] || ticker["low_24h"],
          "high_24h" => ticker["high_24_h"] || ticker["high_24h"],
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
      "volume_24h" => frame["volume_24h"] || frame["volume_24_h"],
      "low_24h" => frame["low_24h"] || frame["low_24_h"],
      "high_24h" => frame["high_24h"] || frame["high_24_h"],
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
