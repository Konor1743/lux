# Coinbase Spot Trading Prisms Architectural Analysis & Design Blueprint

## Executive Summary
This document provides a comprehensive architectural analysis and implementation blueprint for integrating Coinbase Advanced Trade Spot Trading Prisms into the `lux` Elixir framework. Following the existing pattern established by `Lux.Prisms.Binance.Spot*` and `Lux.Prism`, four core Prisms are designed to interface with Coinbase Advanced Trade REST API endpoints:
1. `Lux.Prisms.Coinbase.SpotAccountPrism` (Account balances and single account details)
2. `Lux.Prisms.Coinbase.SpotOrderPrism` (Spot order placement with flat-to-nested payload translation)
3. `Lux.Prisms.Coinbase.SpotCancelOrderPrism` (Batch order cancellation)
4. `Lux.Prisms.Coinbase.SpotOpenOrdersPrism` (Query open spot orders)

---

## 1. Lux Prism Architecture & Binance Pattern Analysis

### 1.1 `Lux.Prism` Macro & Behaviour (`lib/lux/prism.ex`)
`Lux.Prism` provides a structured, composable action interface for agents in the Lux framework.
- **Module Definition**: Prisms invoke `use Lux.Prism, name: ..., description: ..., input_schema: ..., output_schema: ...`.
- **Compile-Time Registration**: The macro registers `@prism_config` and `@prism_struct` metadata and exports:
  - `handler(input, context)`: `@callback handler(input :: any(), context :: any()) :: {:ok, any()} | {:error, any()}`
  - `run(input, context \\ nil)`: Delegates execution to `Lux.Prism.run(__MODULE__, input, context)`.
  - `view/0`: Returns a `%Lux.Prism{}` struct holding configuration, ID, input/output schemas, and handler capture (`&__MODULE__.handler/2`).
- **Input Schema**: Uses JSON Schema-like maps describing property types (`:string`, `:number`, `:integer`, `:boolean`, `:object`, `:array`), default values, descriptions, enum limits, and `required` fields.

### 1.2 Binance Prism Patterns (`lib/lux/prisms/binance/`)
By inspecting `BinanceSpotAccountPrism`, `BinanceSpotOrderPrism`, `BinanceSpotCancelOrderPrism`, and `BinanceSpotOpenOrdersPrism`, the following canonical behaviors were identified:
1. **Dual Key & Context Resolution (`build_opts/2`)**:
   Input maps can contain atom keys (`:api_key`) or string keys (`"api_key"`), falling back to `context` (`context[:api_key]`), and default parameters:
   ```elixir
   defp build_opts(input, context) do
     ctx = context || %{}
     api_key = Map.get(input, :api_key) || Map.get(input, "api_key") || Map.get(ctx, :api_key)
     secret_key = Map.get(input, :secret_key) || Map.get(input, "secret_key") || Map.get(ctx, :secret_key)
     req_options = Map.get(input, :req_options) || Map.get(ctx, :req_options, [])
     [api_key: api_key, secret_key: secret_key, req_options: req_options]
   end
   ```
2. **System Parameter Separation**:
   Before constructing API request payloads, system keys (`:api_key`, `:secret_key`, `:req_options`, etc.) are removed from the input map using `Map.drop/2`.
3. **HTTP Client Integration (`Lux.Binance.Client`)**:
   Prisms invoke `Client.request(method, market_type, path, params, opts)`. HTTP response tuple `{:ok, body}` or `{:error, reason}` is matched directly.

---

## 2. Coinbase Advanced Trade REST API Mapping

| Prism Action | Coinbase Endpoint Path | Method | Expected Query/Body Parameters | Response Key / Structure |
|---|---|---|---|---|
| **Account Details** | `/api/v3/brokerage/accounts` or `/api/v3/brokerage/accounts/:account_uuid` | `GET` | `limit` (int), `cursor` (str), optional `account_uuid` (path param) | `{"accounts": [...], "has_next": bool, "cursor": str}` or `{"account": {...}}` |
| **Create Order** | `/api/v3/brokerage/orders` | `POST` | `client_order_id` (str), `product_id` (str), `side` ("BUY"/"SELL"), `order_configuration` (obj) | `{"success": bool, "order_id": str, "success_response": {...}, "error_response": {...}}` |
| **Cancel Order** | `/api/v3/brokerage/orders/batch_cancel` | `POST` | `order_ids` (array of strings) | `{"results": [{"success": true, "order_id": "..."}]}` |
| **List Open Orders**| `/api/v3/brokerage/orders/historical/batch` | `GET` | `order_status` ("OPEN"), `product_id` (str), `limit` (int), `cursor` (str) | `{"orders": [...], "has_next": bool, "cursor": str}` |

---

## 3. Detailed Prism Specifications & Implementation Code

### 3.1 `Lux.Prisms.Coinbase.SpotAccountPrism`
- **File**: `lib/lux/prisms/coinbase/spot_account_prism.ex`
- **Module**: `Lux.Prisms.Coinbase.SpotAccountPrism` (also aliased as `Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism`)
- **Description**: Fetches accounts list or single account details from Coinbase Advanced Trade REST API.

```elixir
defmodule Lux.Prisms.Coinbase.SpotAccountPrism do
  @moduledoc """
  A Prism that retrieves Coinbase Spot account details, balances, and status.

  ## Examples

      iex> Lux.Prisms.Coinbase.SpotAccountPrism.run(%{api_key: "key", secret_key: "secret"})
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

    [
      api_key: api_key,
      secret_key: secret_key,
      req_options: req_options
    ]
  end
end
```

---

### 3.2 `Lux.Prisms.Coinbase.SpotOrderPrism`
- **File**: `lib/lux/prisms/coinbase/spot_order_prism.ex`
- **Module**: `Lux.Prisms.Coinbase.SpotOrderPrism`
- **Description**: Places a new spot order on Coinbase Advanced Trade API, translating flat parameter inputs into Coinbase `order_configuration` format.

```elixir
defmodule Lux.Prisms.Coinbase.SpotOrderPrism do
  @moduledoc """
  A Prism for placing new spot orders (LIMIT, MARKET, STOP_LIMIT) on Coinbase Advanced Trade.

  ## Examples

      iex> Lux.Prisms.Coinbase.SpotOrderPrism.run(%{
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
      is_nil(product_id) -> {:error, :missing_product_id}
      is_nil(side) -> {:error, :missing_side}
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
    if is_map(raw_config) do
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
          %{"stop_limit_stop_limit_gtc" => %{
            "base_size" => base_size || "",
            "limit_price" => price || "",
            "stop_price" => stop_price || "",
            "stop_direction" => "STOP_DIRECTION_STOP_UP"
          }}

        _ -> # Default LIMIT (GTC)
          %{"limit_limit_gtc" => %{
            "base_size" => base_size || "",
            "limit_price" => price || "",
            "post_only" => false
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

    [
      api_key: api_key,
      secret_key: secret_key,
      req_options: req_options
    ]
  end
end
```

---

### 3.3 `Lux.Prisms.Coinbase.SpotCancelOrderPrism`
- **File**: `lib/lux/prisms/coinbase/spot_cancel_order_prism.ex`
- **Module**: `Lux.Prisms.Coinbase.SpotCancelOrderPrism`
- **Description**: Batch cancels spot orders on Coinbase Advanced Trade API.

```elixir
defmodule Lux.Prisms.Coinbase.SpotCancelOrderPrism do
  @moduledoc """
  A Prism for cancelling active spot order(s) on Coinbase Advanced Trade.

  ## Examples

      iex> Lux.Prisms.Coinbase.SpotCancelOrderPrism.run(%{
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
      is_list(ids) and length(ids) > 0 -> {:ok, Enum.map(ids, &to_string/1)}
      not is_nil(single_id) and single_id != "" -> {:ok, [to_string(single_id)]}
      true -> {:error, :missing_order_ids}
    end
  end

  defp build_opts(input, context) do
    ctx = context || %{}
    api_key = Map.get(input, :api_key) || Map.get(input, "api_key") || Map.get(ctx, :api_key)
    secret_key = Map.get(input, :secret_key) || Map.get(input, "secret_key") || Map.get(ctx, :secret_key)
    req_options = Map.get(input, :req_options) || Map.get(ctx, :req_options, [])

    [
      api_key: api_key,
      secret_key: secret_key,
      req_options: req_options
    ]
  end
end
```

---

### 3.4 `Lux.Prisms.Coinbase.SpotOpenOrdersPrism`
- **File**: `lib/lux/prisms/coinbase/spot_open_orders_prism.ex`
- **Module**: `Lux.Prisms.Coinbase.SpotOpenOrdersPrism`
- **Description**: Queries all active open spot orders on Coinbase Advanced Trade API.

```elixir
defmodule Lux.Prisms.Coinbase.SpotOpenOrdersPrism do
  @moduledoc """
  A Prism for querying open spot orders on Coinbase Advanced Trade.

  ## Examples

      iex> Lux.Prisms.Coinbase.SpotOpenOrdersPrism.run(%{product_id: "BTC-USD", api_key: "key", secret_key: "secret"})
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

    params = %{order_status: "OPEN"}
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

    [
      api_key: api_key,
      secret_key: secret_key,
      req_options: req_options
    ]
  end
end
```

---

### 3.5 Automated Test Suite (`test/lux/coinbase/prisms_test.exs`)

```elixir
defmodule Lux.Prisms.Coinbase.PrismsTest do
  use ExUnit.Case, async: true

  alias Lux.Prisms.Coinbase.SpotAccountPrism
  alias Lux.Prisms.Coinbase.SpotOrderPrism
  alias Lux.Prisms.Coinbase.SpotCancelOrderPrism
  alias Lux.Prisms.Coinbase.SpotOpenOrdersPrism

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "SpotAccountPrism" do
    test "retrieves list of accounts" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/accounts"
        Req.Test.json(conn, %{
          "accounts" => [
            %{"currency" => "USD", "available_balance" => %{"value" => "1000.00"}}
          ]
        })
      end)

      input = %{
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"accounts" => [%{"currency" => "USD"}]}} = SpotAccountPrism.run(input)
    end

    test "retrieves single account details when account_uuid provided" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/accounts/acc-123-uuid"
        Req.Test.json(conn, %{"account" => %{"uuid" => "acc-123-uuid", "currency" => "BTC"}})
      end)

      input = %{
        account_uuid: "acc-123-uuid",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"account" => %{"uuid" => "acc-123-uuid"}}} = SpotAccountPrism.run(input)
    end
  end

  describe "SpotOrderPrism" do
    test "places a LIMIT order successfully" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/brokerage/orders"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)

        assert json["product_id"] == "BTC-USD"
        assert json["side"] == "BUY"
        assert json["order_configuration"]["limit_limit_gtc"]["base_size"] == "0.01"
        assert json["order_configuration"]["limit_limit_gtc"]["limit_price"] == "95000.00"

        Req.Test.json(conn, %{
          "success" => true,
          "order_id" => "ord-999-uuid",
          "success_response" => %{"order_id" => "ord-999-uuid"}
        })
      end)

      input = %{
        product_id: "BTC-USD",
        side: "BUY",
        type: "LIMIT",
        base_size: "0.01",
        price: "95000.00",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"success" => true, "order_id" => "ord-999-uuid"}} = SpotOrderPrism.run(input)
    end

    test "returns error when required fields missing" do
      input = %{side: "BUY"}
      assert {:error, :missing_product_id} = SpotOrderPrism.run(input)
    end
  end

  describe "SpotCancelOrderPrism" do
    test "cancels batch orders successfully" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/brokerage/orders/batch_cancel"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)

        assert json["order_ids"] == ["ord-111", "ord-222"]
        Req.Test.json(conn, %{
          "results" => [
            %{"success" => true, "order_id" => "ord-111"},
            %{"success" => true, "order_id" => "ord-222"}
          ]
        })
      end)

      input = %{
        order_ids: ["ord-111", "ord-222"],
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"results" => [%{"success" => true}, %{"success" => true}]}} = SpotCancelOrderPrism.run(input)
    end

    test "returns error when no order IDs provided" do
      input = %{api_key: "key", secret_key: "sec"}
      assert {:error, :missing_order_ids} = SpotCancelOrderPrism.run(input)
    end
  end

  describe "SpotOpenOrdersPrism" do
    test "queries open orders with status OPEN" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/orders/historical/batch"
        assert conn.query_string =~ "order_status=OPEN"
        assert conn.query_string =~ "product_id=BTC-USD"

        Req.Test.json(conn, %{
          "orders" => [
            %{"order_id" => "ord-123", "product_id" => "BTC-USD", "status" => "OPEN"}
          ]
        })
      end)

      input = %{
        product_id: "BTC-USD",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"orders" => [%{"order_id" => "ord-123"}]}} = SpotOpenOrdersPrism.run(input)
    end
  end
end
```

---

## 4. Step-by-Step Implementation Roadmap for Milestone 5

1. **Step 1: Directory Setup**
   - Ensure target directory `lib/lux/prisms/coinbase/` exists.
   - Create `test/lux/coinbase/` if not present.

2. **Step 2: File Creation**
   - Implement `lib/lux/prisms/coinbase/spot_account_prism.ex`.
   - Implement `lib/lux/prisms/coinbase/spot_order_prism.ex`.
   - Implement `lib/lux/prisms/coinbase/spot_cancel_order_prism.ex`.
   - Implement `lib/lux/prisms/coinbase/spot_open_orders_prism.ex`.
   - Implement `test/lux/coinbase/prisms_test.exs`.

3. **Step 3: Verification & Execution**
   - Execute `mix test test/lux/coinbase/prisms_test.exs` to confirm mock HTTP interaction with `Req.Test`.
   - Run `mix compile --warnings-as-errors` to ensure zero compilation warnings or type spec errors.
