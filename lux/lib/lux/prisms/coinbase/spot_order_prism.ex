defmodule Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism do
  @moduledoc """
  A Prism for placing new spot orders (LIMIT, MARKET, STOP_LIMIT) on Coinbase Advanced Trade.

  ## Examples

      iex> Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism.run(%{
      ...>   product_id: "BTC-USD",
      ...>   side: "BUY",
      ...>   type: "LIMIT",
      ...>   base_size: "0.01",
      ...>   price: "95000.00",
      ...>   api_key: "key",
      ...>   secret_key: "secret"
      ...> })
      {:ok, %{"success" => true, "order_id" => "11111-22222-33333"}}
  """

  use Lux.Prism,
    name: "Coinbase Spot Order Prism",
    description: "Places a new spot order on Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        product_id: %{type: :string, description: "Trading pair (e.g. 'BTC-USD')"},
        symbol: %{type: :string, description: "Alias for product_id"},
        side: %{type: :string, enum: ["BUY", "SELL"], description: "Order side"},
        type: %{type: :string, enum: ["LIMIT", "MARKET", "STOP_LIMIT"], default: "LIMIT", description: "Order type"},
        base_size: %{type: :string, description: "Amount of base currency to trade"},
        quote_size: %{type: :string, description: "Amount of quote currency (for MARKET buys)"},
        price: %{type: :string, description: "Limit price"},
        stop_price: %{type: :string, description: "Trigger stop price for STOP_LIMIT"},
        time_in_force: %{type: :string, enum: ["GTC", "GTD", "IOC"], default: "GTC"},
        client_order_id: %{type: :string, description: "Unique client-generated order ID"},
        order_configuration: %{type: :object, description: "Raw order configuration map"}
      },
      required: ["side"]
    }

  alias Lux.Coinbase.Client

  def handler(input, context) do
    opts = build_opts(input, context)

    case build_order_payload(input) do
      {:ok, payload} ->
        case Client.request(:post, "/api/v3/brokerage/orders", payload, opts) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_order_payload(input) do
    product_id = Map.get(input, :product_id) || Map.get(input, "product_id") || Map.get(input, :symbol) || Map.get(input, "symbol")
    side = Map.get(input, :side) || Map.get(input, "side")
    client_order_id = Map.get(input, :client_order_id) || Map.get(input, "client_order_id") || Lux.UUID.generate()

    cond do
      is_nil(product_id) or product_id == "" -> {:error, :missing_product_id}
      is_nil(side) or side == "" -> {:error, :missing_side}
      true ->
        order_config = build_order_config(input)
        {:ok, %{
          "client_order_id" => to_string(client_order_id),
          "product_id" => to_string(product_id),
          "side" => String.upcase(to_string(side)),
          "order_configuration" => order_config
        }}
    end
  end

  defp build_order_config(input) do
    raw_config = Map.get(input, :order_configuration) || Map.get(input, "order_configuration")

    if is_map(raw_config) and map_size(raw_config) > 0 do
      raw_config
    else
      type = Map.get(input, :type) || Map.get(input, "type", "LIMIT")
      base_size = to_str(Map.get(input, :base_size) || Map.get(input, "base_size") || Map.get(input, :quantity) || Map.get(input, "quantity"))
      price = to_str(Map.get(input, :price) || Map.get(input, "price"))
      quote_size = to_str(Map.get(input, :quote_size) || Map.get(input, "quote_size"))

      case String.upcase(to_string(type)) do
        "MARKET" ->
          market_opts = %{}
          market_opts = if base_size, do: Map.put(market_opts, "base_size", base_size), else: market_opts
          market_opts = if quote_size, do: Map.put(market_opts, "quote_size", quote_size), else: market_opts
          %{"market_market_ioc" => market_opts}

        "STOP_LIMIT" ->
          stop_price = to_str(Map.get(input, :stop_price) || Map.get(input, "stop_price"))
          stop_direction = Map.get(input, :stop_direction) || Map.get(input, "stop_direction", "STOP_DIRECTION_STOP_UP")

          %{"stop_limit_stop_limit_gtc" => %{
            "base_size" => base_size || "",
            "limit_price" => price || "",
            "stop_price" => stop_price || "",
            "stop_direction" => to_string(stop_direction)
          }}

        _ -> # Default LIMIT (GTC)
          post_only = Map.get(input, :post_only) || Map.get(input, "post_only", false)

          %{"limit_limit_gtc" => %{
            "base_size" => base_size || "",
            "limit_price" => price || "",
            "post_only" => post_only
          }}
      end
    end
  end

  defp to_str(nil), do: nil
  defp to_str(val) when is_binary(val), do: val
  defp to_str(val), do: to_string(val)

  defp build_opts(input, context) do
    ctx = context || %{}
    api_key = Map.get(input, :api_key) || Map.get(input, "api_key") || Map.get(ctx, :api_key)
    secret_key = Map.get(input, :secret_key) || Map.get(input, "secret_key") || Map.get(ctx, :secret_key)
    req_options = Map.get(input, :req_options) || Map.get(ctx, :req_options, [])
    sandbox? = Map.get(input, :sandbox) || Map.get(input, "sandbox") || Map.get(ctx, :sandbox, false)

    [
      signed: true,
      api_key: api_key,
      secret_key: secret_key,
      sandbox: sandbox?,
      req_options: req_options
    ]
  end
end

defmodule Lux.Prisms.Coinbase.SpotOrderPrism do
  @moduledoc """
  Alias module for `Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism`.
  """

  use Lux.Prism,
    name: "Coinbase Spot Order Prism",
    description: "Places a new spot order on Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        product_id: %{type: :string, description: "Trading pair (e.g. 'BTC-USD')"},
        symbol: %{type: :string, description: "Alias for product_id"},
        side: %{type: :string, enum: ["BUY", "SELL"], description: "Order side"},
        type: %{type: :string, enum: ["LIMIT", "MARKET", "STOP_LIMIT"], default: "LIMIT", description: "Order type"},
        base_size: %{type: :string, description: "Amount of base currency to trade"},
        quote_size: %{type: :string, description: "Amount of quote currency (for MARKET buys)"},
        price: %{type: :string, description: "Limit price"},
        stop_price: %{type: :string, description: "Trigger stop price for STOP_LIMIT"},
        time_in_force: %{type: :string, enum: ["GTC", "GTD", "IOC"], default: "GTC"},
        client_order_id: %{type: :string, description: "Unique client-generated order ID"},
        order_configuration: %{type: :object, description: "Raw order configuration map"}
      },
      required: ["side"]
    }

  def handler(input, context), do: Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism.handler(input, context)
  def build_order_payload(input), do: Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism.build_order_payload(input)
end
