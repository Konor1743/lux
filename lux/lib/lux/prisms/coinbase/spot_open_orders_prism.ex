defmodule Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism do
  @moduledoc """
  A Prism for querying open spot orders on Coinbase Advanced Trade.

  ## Examples

      iex> Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism.run(%{product_id: "BTC-USD", api_key: "key", secret_key: "secret"})
      {:ok, %{"orders" => [%{"order_id" => "11111-22222-33333", "status" => "OPEN"}]}}
  """

  use Lux.Prism,
    name: "Coinbase Spot Open Orders Prism",
    description: "Queries active open spot orders on Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        product_id: %{type: :string, description: "Optional trading pair filter (e.g. 'BTC-USD')"},
        symbol: %{type: :string, description: "Alias for product_id"},
        limit: %{type: :integer, description: "Number of orders to return"},
        cursor: %{type: :string, description: "Pagination cursor"},
        order_type: %{type: :string, enum: ["MARKET", "LIMIT", "STOP_LIMIT"]},
        order_side: %{type: :string, enum: ["BUY", "SELL"]}
      }
    }

  alias Lux.Coinbase.Client

  def handler(input, context) do
    opts = build_opts(input, context)
    params = build_params(input)

    case Client.request(:get, "/api/v3/brokerage/orders/historical/batch", params, opts) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_params(input) do
    product_id = Map.get(input, :product_id) || Map.get(input, "product_id") || Map.get(input, :symbol) || Map.get(input, "symbol")
    order_status = Map.get(input, :order_status) || Map.get(input, "order_status", "OPEN")

    params = %{order_status: order_status}
    params = if product_id, do: Map.put(params, :product_id, product_id), else: params

    params
    |> put_optional(input, :limit, "limit")
    |> put_optional(input, :cursor, "cursor")
    |> put_optional(input, :order_type, "order_type")
    |> put_optional(input, :order_side, "order_side")
  end

  defp put_optional(map, input, atom_key, string_key) do
    val = Map.get(input, atom_key) || Map.get(input, string_key)
    if is_nil(val), do: map, else: Map.put(map, atom_key, val)
  end

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

defmodule Lux.Prisms.Coinbase.SpotOpenOrdersPrism do
  @moduledoc """
  Alias module for `Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism`.
  """

  use Lux.Prism,
    name: "Coinbase Spot Open Orders Prism",
    description: "Queries active open spot orders on Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        product_id: %{type: :string, description: "Optional trading pair filter (e.g. 'BTC-USD')"},
        symbol: %{type: :string, description: "Alias for product_id"},
        limit: %{type: :integer, description: "Number of orders to return"},
        cursor: %{type: :string, description: "Pagination cursor"},
        order_type: %{type: :string, enum: ["MARKET", "LIMIT", "STOP_LIMIT"]},
        order_side: %{type: :string, enum: ["BUY", "SELL"]}
      }
    }

  def handler(input, context), do: Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism.handler(input, context)
end
