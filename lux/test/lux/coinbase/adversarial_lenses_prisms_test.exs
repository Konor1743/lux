defmodule Lux.Coinbase.AdversarialLensesPrismsTest do
  use ExUnit.Case, async: true

  alias Lux.Lenses.Coinbase.CoinbaseTickerPriceLens
  alias Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens
  alias Lux.Prisms.Coinbase.SpotAccountPrism
  alias Lux.Prisms.Coinbase.SpotOrderPrism
  alias Lux.Prisms.Coinbase.SpotCancelOrderPrism
  alias Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "Adversarial & Edge Cases: CoinbaseTickerPriceLens WS Frame Normalization" do
    test "handles empty map and unsupported frames gracefully" do
      assert {:error, {:unsupported_frame, %{}}} = CoinbaseTickerPriceLens.normalize_ws_frame(%{})
      assert {:error, {:unsupported_frame, nil}} = CoinbaseTickerPriceLens.normalize_ws_frame(nil)
      assert {:error, {:unsupported_frame, "random_string"}} = CoinbaseTickerPriceLens.normalize_ws_frame("random_string")
    end

    test "handles ticker channel with empty events array" do
      frame = %{"channel" => "ticker", "events" => []}
      assert {:ok, %{"tickers" => []}} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
    end

    test "handles ticker channel with event containing empty tickers array" do
      frame = %{"channel" => "ticker", "events" => [%{"tickers" => []}]}
      assert {:ok, %{"tickers" => []}} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
    end

    test "handles ticker event with partial or missing ticker fields" do
      frame = %{
        "channel" => "ticker",
        "events" => [
          %{
            "tickers" => [
              %{"product_id" => "BTC-USD"}
            ]
          }
        ]
      }

      assert {:ok, result} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
      assert result["product_id"] == "BTC-USD"
      assert is_nil(result["price"])
      assert is_nil(result["volume_24h"])
      assert is_nil(result["best_bid"])
    end

    test "handles ticker channel with non-list events via pattern fallback" do
      frame = %{"channel" => "ticker", "events" => "not_a_list"}
      assert {:error, {:unsupported_frame, ^frame}} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
    end

    test "handles Exchange Feed ticker missing product_id" do
      frame = %{"type" => "ticker", "price" => "100.00"}
      assert {:error, {:unsupported_frame, ^frame}} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
    end

    test "crashes with BadMapError when events contain non-map items" do
      frame = %{"channel" => "ticker", "events" => [123]}
      assert_raise BadMapError, fn ->
        CoinbaseTickerPriceLens.normalize_ws_frame(frame)
      end
    end

    test "crashes with FunctionClauseError when tickers contain non-map items" do
      frame = %{"channel" => "ticker", "events" => [%{"tickers" => ["invalid"]}]}
      assert_raise FunctionClauseError, fn ->
        CoinbaseTickerPriceLens.normalize_ws_frame(frame)
      end
    end
  end

  describe "Adversarial & Edge Cases: CoinbaseExchangeInfoLens WS Frame Normalization" do
    test "handles empty map and unsupported frames" do
      assert {:error, {:unsupported_frame, %{}}} = CoinbaseExchangeInfoLens.normalize_ws_frame(%{})
    end

    test "handles status channel with empty events array" do
      frame = %{"channel" => "status", "events" => []}
      assert {:ok, %{"products" => []}} = CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
    end

    test "handles status channel with empty products array" do
      frame = %{"channel" => "status", "events" => [%{"products" => []}]}
      assert {:ok, %{"products" => []}} = CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
    end

    test "handles status event with partial product fields" do
      frame = %{
        "channel" => "status",
        "events" => [
          %{
            "products" => [
              %{"product_id" => "BTC-USD"}
            ]
          }
        ]
      }

      assert {:ok, result} = CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
      assert result["product_id"] == "BTC-USD"
      assert is_nil(result["status"])
    end

    test "handles Exchange Feed status with non-list products" do
      frame = %{"type" => "status", "products" => "not_a_list"}
      assert {:error, {:unsupported_frame, ^frame}} = CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
    end

    test "crashes with FunctionClauseError when products contain non-map items in Exchange Feed status" do
      frame = %{"type" => "status", "products" => [123]}
      assert_raise FunctionClauseError, fn ->
        CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
      end
    end
  end

  describe "Adversarial & Edge Cases: SpotOrderPrism" do
    test "returns error on missing product_id" do
      assert {:error, :missing_product_id} = SpotOrderPrism.build_order_payload(%{side: "BUY"})
      assert {:error, :missing_product_id} = SpotOrderPrism.build_order_payload(%{product_id: "", side: "BUY"})
      assert {:error, :missing_product_id} = SpotOrderPrism.build_order_payload(%{symbol: "", side: "BUY"})
    end

    test "returns error on missing side" do
      assert {:error, :missing_side} = SpotOrderPrism.build_order_payload(%{product_id: "BTC-USD"})
      assert {:error, :missing_side} = SpotOrderPrism.build_order_payload(%{product_id: "BTC-USD", side: ""})
    end

    test "unsupported order type defaults to LIMIT order configuration" do
      input = %{product_id: "BTC-USD", side: "BUY", type: "UNSUPPORTED_TYPE", base_size: "1.0", price: "50000.00"}
      assert {:ok, payload} = SpotOrderPrism.build_order_payload(input)
      assert Map.has_key?(payload["order_configuration"], "limit_limit_gtc")
      assert payload["order_configuration"]["limit_limit_gtc"]["base_size"] == "1.0"
    end

    test "unsupported order type with nil type defaults to LIMIT order configuration" do
      input = %{product_id: "BTC-USD", side: "BUY", type: nil, base_size: "1.0", price: "50000.00"}
      assert {:ok, payload} = SpotOrderPrism.build_order_payload(input)
      assert Map.has_key?(payload["order_configuration"], "limit_limit_gtc")
    end

    test "MARKET order with missing sizes generates empty market_market_ioc config" do
      input = %{product_id: "BTC-USD", side: "BUY", type: "MARKET"}
      assert {:ok, payload} = SpotOrderPrism.build_order_payload(input)
      assert payload["order_configuration"] == %{"market_market_ioc" => %{}}
    end

    test "STOP_LIMIT order with missing stop_price sets stop_price to empty string" do
      input = %{product_id: "BTC-USD", side: "SELL", type: "STOP_LIMIT", base_size: "1.0", price: "90000.00"}
      assert {:ok, payload} = SpotOrderPrism.build_order_payload(input)
      config = payload["order_configuration"]["stop_limit_stop_limit_gtc"]
      assert config["stop_price"] == ""
      assert config["limit_price"] == "90000.00"
    end

    test "custom order_configuration map overrides type building" do
      custom_config = %{"custom_type" => %{"foo" => "bar"}}
      input = %{product_id: "BTC-USD", side: "BUY", order_configuration: custom_config}
      assert {:ok, payload} = SpotOrderPrism.build_order_payload(input)
      assert payload["order_configuration"] == custom_config
    end

    test "empty order_configuration map falls back to type building logic" do
      input = %{product_id: "BTC-USD", side: "BUY", type: "LIMIT", base_size: "1.0", price: "50000.00", order_configuration: %{}}
      assert {:ok, payload} = SpotOrderPrism.build_order_payload(input)
      assert Map.has_key?(payload["order_configuration"], "limit_limit_gtc")
    end
  end

  describe "Adversarial & Edge Cases: SpotCancelOrderPrism" do
    test "empty order_ids array returns :missing_order_ids error" do
      assert {:error, :missing_order_ids} = SpotCancelOrderPrism.extract_order_ids(%{order_ids: []})
      assert {:error, :missing_order_ids} = SpotCancelOrderPrism.extract_order_ids(%{"order_ids" => []})
    end

    test "neither order_ids nor order_id provided returns :missing_order_ids error" do
      assert {:error, :missing_order_ids} = SpotCancelOrderPrism.extract_order_ids(%{})
      assert {:error, :missing_order_ids} = SpotCancelOrderPrism.extract_order_ids(%{order_id: ""})
      assert {:error, :missing_order_ids} = SpotCancelOrderPrism.extract_order_ids(%{order_id: nil})
    end

    test "empty order_ids array falls back to order_id if order_id is present" do
      input = %{order_ids: [], order_id: "single-123"}
      assert {:ok, ["single-123"]} = SpotCancelOrderPrism.extract_order_ids(input)
    end

    test "non-empty order_ids list takes precedence over order_id" do
      input = %{order_ids: ["ord-1", "ord-2"], order_id: "single-123"}
      assert {:ok, ["ord-1", "ord-2"]} = SpotCancelOrderPrism.extract_order_ids(input)
    end

    test "order_ids list containing non-string items coerces them to strings" do
      input = %{order_ids: [101, :order_xyz, "ord-303"]}
      assert {:ok, ["101", "order_xyz", "ord-303"]} = SpotCancelOrderPrism.extract_order_ids(input)
    end

    test "integer order_id is coerced to string in single order_id mode" do
      input = %{order_id: 998877}
      assert {:ok, ["998877"]} = SpotCancelOrderPrism.extract_order_ids(input)
    end
  end

  describe "Adversarial & Edge Cases: Context Credential Inheritance vs Option Override Precedence" do
    test "input credentials override context credentials" do
      Req.Test.expect(Lux.Coinbase.AdversarialLensesPrismsTest, fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers, "cb-access-key") == "input_key"
        Req.Test.json(conn, %{"accounts" => []})
      end)

      input = %{
        api_key: "input_key",
        secret_key: "input_secret",
        req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialLensesPrismsTest}]
      }

      context = %{
        api_key: "context_key",
        secret_key: "context_secret"
      }

      assert {:ok, %{"accounts" => []}} = CoinbaseSpotAccountPrism.run(input, context)
    end

    test "input string-key credentials override context atom-key credentials" do
      Req.Test.expect(Lux.Coinbase.AdversarialLensesPrismsTest, fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers, "cb-access-key") == "input_string_key"
        Req.Test.json(conn, %{"accounts" => []})
      end)

      input = %{
        "api_key" => "input_string_key",
        "secret_key" => "input_string_secret",
        :req_options => [plug: {Req.Test, Lux.Coinbase.AdversarialLensesPrismsTest}]
      }

      context = %{
        api_key: "context_key",
        secret_key: "context_secret"
      }

      assert {:ok, %{"accounts" => []}} = SpotAccountPrism.run(input, context)
    end

    test "context with string keys is NOT recognized by build_opts (returns :missing_secret_key error)" do
      # Note: build_opts uses Map.get(ctx, :api_key) without checking "api_key"
      # Thus passing context with string keys fails before making HTTP request
      input = %{}

      context = %{
        "api_key" => "context_string_key",
        "secret_key" => "context_string_secret"
      }

      assert {:error, :missing_secret_key} = SpotAccountPrism.run(input, context)
    end

    test "EXPOSURE BUG: input sandbox: false CANNOT override context sandbox: true due to || boolean expression" do
      # In build_opts:
      # Map.get(input, :sandbox) || Map.get(input, "sandbox") || Map.get(ctx, :sandbox, false)
      # When input is %{sandbox: false} and context is %{sandbox: true}, false || nil || true evaluates to true!
      Req.Test.expect(Lux.Coinbase.AdversarialLensesPrismsTest, fn conn ->
        assert conn.host =~ "sandbox" or conn.request_path =~ "sandbox" or conn.host == "api-public.sandbox.exchange.coinbase.com"
        Req.Test.json(conn, %{"accounts" => []})
      end)

      input = %{
        sandbox: false,
        api_key: "key",
        secret_key: "sec",
        req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialLensesPrismsTest}]
      }

      context = %{
        sandbox: true
      }

      # Because of the bug, this runs against sandbox even though input specified sandbox: false!
      assert {:ok, %{"accounts" => []}} = SpotAccountPrism.run(input, context)
    end
  end
end
