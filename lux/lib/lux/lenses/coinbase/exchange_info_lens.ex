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
    description:
      "Fetches product trading rules, status, increments, and precisions from Coinbase Advanced Trade.",
    url: "https://api.coinbase.com/api/v3/brokerage/market/products",
    method: :get,
    schema: %{
      type: :object,
      properties: %{
        product_id: %{
          type: :string,
          description: "Optional specific trading pair product ID (e.g. 'BTC-USD')."
        },
        symbol: %{
          type: :string,
          description: "Optional symbol alias for product_id (e.g. 'BTC-USD')."
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

  defoverridable focus: 1, focus: 2

  @doc """
  Focuses the lens to fetch exchange info from Coinbase REST API.
  """
  def focus(input \\ %{}, opts \\ []) do
    product_id =
      Map.get(input, :product_id) ||
        Map.get(input, "product_id") ||
        Map.get(input, :symbol) ||
        Map.get(input, "symbol")

    sandbox? =
      Map.get(input, :sandbox) ||
        Map.get(input, "sandbox", false) ||
        Keyword.get(opts, :sandbox, false)

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
          "base_currency" => prod["base_currency_id"] || prod["base_currency"],
          "quote_currency" => prod["quote_currency_id"] || prod["quote_currency"],
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
