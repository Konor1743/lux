defmodule Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism do
  @moduledoc """
  A Prism that retrieves Coinbase Spot account details, balances, and status.

  ## Examples

      iex> Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism.run(%{api_key: "key", secret_key: "secret"})
      {:ok, %{"accounts" => [%{"currency" => "USD", "available_balance" => %{"value" => "100.00"}}]}}
  """

  use Lux.Prism,
    name: "Coinbase Spot Account Prism",
    description: "Retrieves Spot account balances and details from Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        account_uuid: %{type: :string, description: "Optional account UUID for single account lookup"},
        limit: %{type: :integer, default: 49, description: "Number of accounts to return (max 250)"},
        cursor: %{type: :string, description: "Cursor for pagination"},
        api_key: %{type: :string, description: "Coinbase API Key"},
        secret_key: %{type: :string, description: "Coinbase Secret Key"}
      }
    }

  alias Lux.Coinbase.Client

  def handler(input, context) do
    opts = build_opts(input, context)
    account_uuid = Map.get(input, :account_uuid) || Map.get(input, "account_uuid")

    {path, params} =
      if account_uuid do
        {"/api/v3/brokerage/accounts/#{account_uuid}", %{}}
      else
        params = build_params(input)
        {"/api/v3/brokerage/accounts", params}
      end

    case Client.request(:get, path, params, opts) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_params(input) do
    %{}
    |> put_optional(input, :limit, "limit")
    |> put_optional(input, :cursor, "cursor")
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

defmodule Lux.Prisms.Coinbase.SpotAccountPrism do
  @moduledoc """
  Alias module for `Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism`.
  """

  use Lux.Prism,
    name: "Coinbase Spot Account Prism",
    description: "Retrieves Spot account balances and details from Coinbase Advanced Trade API.",
    input_schema: %{
      type: :object,
      properties: %{
        account_uuid: %{type: :string, description: "Optional account UUID for single account lookup"},
        limit: %{type: :integer, default: 49, description: "Number of accounts to return (max 250)"},
        cursor: %{type: :string, description: "Cursor for pagination"},
        api_key: %{type: :string, description: "Coinbase API Key"},
        secret_key: %{type: :string, description: "Coinbase Secret Key"}
      }
    }

  def handler(input, context), do: Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism.handler(input, context)
end
