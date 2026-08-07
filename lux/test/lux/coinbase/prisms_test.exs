defmodule Lux.Prisms.Coinbase.PrismsTest do
  use ExUnit.Case, async: true

  alias Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism
  alias Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism
  alias Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism
  alias Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism
  alias Lux.Prisms.Coinbase.SpotAccountPrism
  alias Lux.Prisms.Coinbase.SpotCancelOrderPrism
  alias Lux.Prisms.Coinbase.SpotOpenOrdersPrism
  alias Lux.Prisms.Coinbase.SpotOrderPrism

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "Prism Registration and Schemas" do
    test "verifies SpotAccountPrism metadata and schema" do
      prism = CoinbaseSpotAccountPrism.view()
      assert prism.name == "Coinbase Spot Account Prism"
      assert prism.description =~ "Coinbase Advanced Trade API"
      assert is_map(prism.input_schema)
      assert Map.has_key?(prism.input_schema.properties, :account_uuid)
      assert SpotAccountPrism.view().name == prism.name
    end

    test "verifies SpotOrderPrism metadata and schema" do
      prism = CoinbaseSpotOrderPrism.view()
      assert prism.name == "Coinbase Spot Order Prism"
      assert is_map(prism.input_schema)
      assert Map.has_key?(prism.input_schema.properties, :product_id)
      assert Map.has_key?(prism.input_schema.properties, :side)
      assert SpotOrderPrism.view().name == prism.name
    end

    test "verifies SpotCancelOrderPrism metadata and schema" do
      prism = CoinbaseSpotCancelOrderPrism.view()
      assert prism.name == "Coinbase Spot Cancel Order Prism"
      assert is_map(prism.input_schema)
      assert Map.has_key?(prism.input_schema.properties, :order_ids)
      assert SpotCancelOrderPrism.view().name == prism.name
    end

    test "verifies SpotOpenOrdersPrism metadata and schema" do
      prism = CoinbaseSpotOpenOrdersPrism.view()
      assert prism.name == "Coinbase Spot Open Orders Prism"
      assert is_map(prism.input_schema)
      assert Map.has_key?(prism.input_schema.properties, :product_id)
      assert SpotOpenOrdersPrism.view().name == prism.name
    end
  end

  describe "CoinbaseSpotAccountPrism" do
    test "retrieves list of spot accounts" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/accounts"

        Req.Test.json(conn, %{
          "accounts" => [
            %{"currency" => "USD", "available_balance" => %{"value" => "1000.00"}},
            %{"currency" => "BTC", "available_balance" => %{"value" => "1.5"}}
          ],
          "has_next" => false,
          "cursor" => ""
        })
      end)

      input = %{
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"accounts" => accounts}} = CoinbaseSpotAccountPrism.run(input)
      assert length(accounts) == 2
    end

    test "retrieves single account details when account_uuid provided" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/accounts/acc-uuid-12345"

        Req.Test.json(conn, %{
          "account" => %{
            "uuid" => "acc-uuid-12345",
            "name" => "USD Wallet",
            "currency" => "USD",
            "available_balance" => %{"value" => "500.00"}
          }
        })
      end)

      input = %{
        account_uuid: "acc-uuid-12345",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"account" => %{"uuid" => "acc-uuid-12345"}}} =
               SpotAccountPrism.run(input)
    end

    test "resolves api_key and secret_key from context" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/accounts"

        headers = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers, "cb-access-key") == "ctx_key"

        Req.Test.json(conn, %{"accounts" => []})
      end)

      context = %{
        api_key: "ctx_key",
        secret_key: "ctx_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"accounts" => []}} = CoinbaseSpotAccountPrism.run(%{}, context)
    end
  end

  describe "CoinbaseSpotOrderPrism" do
    test "places a LIMIT spot order successfully" do
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
          "order_id" => "ord-uuid-9999",
          "success_response" => %{"order_id" => "ord-uuid-9999"}
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

      assert {:ok, %{"success" => true, "order_id" => "ord-uuid-9999"}} =
               CoinbaseSpotOrderPrism.run(input)
    end

    test "places a MARKET spot order with quote_size" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/brokerage/orders"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)

        assert json["product_id"] == "ETH-USD"
        assert json["side"] == "BUY"
        assert json["order_configuration"]["market_market_ioc"]["quote_size"] == "500.00"

        Req.Test.json(conn, %{
          "success" => true,
          "order_id" => "ord-mkt-123"
        })
      end)

      input = %{
        symbol: "ETH-USD",
        side: "BUY",
        type: "MARKET",
        quote_size: "500.00",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"success" => true, "order_id" => "ord-mkt-123"}} =
               SpotOrderPrism.run(input)
    end

    test "places a STOP_LIMIT spot order" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/brokerage/orders"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)

        assert json["product_id"] == "SOL-USD"
        assert json["side"] == "SELL"
        stop_config = json["order_configuration"]["stop_limit_stop_limit_gtc"]
        assert stop_config["base_size"] == "5.0"
        assert stop_config["limit_price"] == "140.00"
        assert stop_config["stop_price"] == "145.00"
        assert stop_config["stop_direction"] == "STOP_DIRECTION_STOP_UP"

        Req.Test.json(conn, %{"success" => true, "order_id" => "ord-stop-456"})
      end)

      input = %{
        product_id: "SOL-USD",
        side: "SELL",
        type: "STOP_LIMIT",
        base_size: "5.0",
        price: "140.00",
        stop_price: "145.00",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"success" => true, "order_id" => "ord-stop-456"}} =
               CoinbaseSpotOrderPrism.run(input)
    end

    test "returns error when product_id is missing" do
      input = %{side: "BUY", base_size: "1.0", api_key: "k", secret_key: "s"}
      assert {:error, :missing_product_id} = CoinbaseSpotOrderPrism.run(input)
    end

    test "returns error when side is missing" do
      input = %{product_id: "BTC-USD", base_size: "1.0", api_key: "k", secret_key: "s"}
      assert {:error, :missing_side} = CoinbaseSpotOrderPrism.run(input)
    end
  end

  describe "CoinbaseSpotCancelOrderPrism" do
    test "cancels batch orders using order_ids list" do
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

      assert {:ok, %{"results" => [%{"success" => true}, %{"success" => true}]}} =
               CoinbaseSpotCancelOrderPrism.run(input)
    end

    test "cancels single order using order_id string" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/brokerage/orders/batch_cancel"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)

        assert json["order_ids"] == ["single-ord-777"]

        Req.Test.json(conn, %{
          "results" => [%{"success" => true, "order_id" => "single-ord-777"}]
        })
      end)

      input = %{
        order_id: "single-ord-777",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"results" => [%{"success" => true}]}} = SpotCancelOrderPrism.run(input)
    end

    test "returns error when no order IDs provided" do
      input = %{api_key: "key", secret_key: "sec"}
      assert {:error, :missing_order_ids} = CoinbaseSpotCancelOrderPrism.run(input)
    end
  end

  describe "CoinbaseSpotOpenOrdersPrism" do
    test "queries open spot orders with order_status=OPEN" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/orders/historical/batch"
        assert conn.query_string =~ "order_status=OPEN"

        Req.Test.json(conn, %{
          "orders" => [
            %{"order_id" => "ord-open-101", "product_id" => "BTC-USD", "status" => "OPEN"}
          ],
          "has_next" => false
        })
      end)

      input = %{
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"orders" => [%{"order_id" => "ord-open-101"}]}} =
               CoinbaseSpotOpenOrdersPrism.run(input)
    end

    test "queries open spot orders with product_id, limit, and cursor" do
      Req.Test.expect(Lux.Prisms.Coinbase.PrismsTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/orders/historical/batch"
        assert conn.query_string =~ "order_status=OPEN"
        assert conn.query_string =~ "product_id=ETH-USD"
        assert conn.query_string =~ "limit=10"
        assert conn.query_string =~ "cursor=page2"

        Req.Test.json(conn, %{
          "orders" => [
            %{"order_id" => "ord-open-202", "product_id" => "ETH-USD", "status" => "OPEN"}
          ]
        })
      end)

      input = %{
        product_id: "ETH-USD",
        limit: 10,
        cursor: "page2",
        api_key: "test_key",
        secret_key: "test_secret",
        req_options: [plug: {Req.Test, Lux.Prisms.Coinbase.PrismsTest}]
      }

      assert {:ok, %{"orders" => [%{"order_id" => "ord-open-202"}]}} =
               SpotOpenOrdersPrism.run(input)
    end
  end
end
