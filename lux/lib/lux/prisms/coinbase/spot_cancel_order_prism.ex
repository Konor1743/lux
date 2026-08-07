defmodule Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism do
  @moduledoc """
  A Prism for cancelling active spot order(s) on Coinbase Advanced Trade.

  ## Examples

      iex> Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism.run(%{
      ...>   order_ids: ["11111-22222-33333"],
      ...>   api_key: "key",
      ...>   secret_key: "secret"
      ...> })
      {:ok, %{"results" => [%{"success" => true, "order_id" => "11111-22222-33333"}]}}
  """

  use Lux.Prism,
    name: "Coinbase Spot Cancel Order Prism",
    description: "Cancels active spot order(s) on Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        order_ids: %{type: :array, items: %{type: :string}, description: "List of order IDs to cancel"},
        order_id: %{type: :string, description: "Single order ID to cancel"}
      }
    }

  alias Lux.Coinbase.Client

  def handler(input, context) do
    opts = build_opts(input, context)

    case extract_order_ids(input) do
      {:ok, order_ids} ->
        payload = %{"order_ids" => order_ids}

        case Client.request(:post, "/api/v3/brokerage/orders/batch_cancel", payload, opts) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def extract_order_ids(input) do
    ids = Map.get(input, :order_ids) || Map.get(input, "order_ids")
    single_id = Map.get(input, :order_id) || Map.get(input, "order_id")

    cond do
      is_list(ids) and length(ids) > 0 ->
        {:ok, Enum.map(ids, &to_string/1)}

      not is_nil(single_id) and to_string(single_id) != "" ->
        {:ok, [to_string(single_id)]}

      true ->
        {:error, :missing_order_ids}
    end
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

defmodule Lux.Prisms.Coinbase.SpotCancelOrderPrism do
  @moduledoc """
  Alias module for `Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism`.
  """

  use Lux.Prism,
    name: "Coinbase Spot Cancel Order Prism",
    description: "Cancels active spot order(s) on Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        order_ids: %{type: :array, items: %{type: :string}, description: "List of order IDs to cancel"},
        order_id: %{type: :string, description: "Single order ID to cancel"}
      }
    }

  def handler(input, context), do: Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism.handler(input, context)
  def extract_order_ids(input), do: Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism.extract_order_ids(input)
end
