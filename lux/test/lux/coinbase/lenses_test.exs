defmodule Lux.Coinbase.LensesTest do
  use ExUnit.Case, async: true

  alias Lux.Lenses.Coinbase.CoinbaseTickerPriceLens
  alias Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens
  alias Lux.Coinbase.WebSocket.Client, as: WSClient

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "Lens registration and schema" do
    test "CoinbaseTickerPriceLens registers view and schema correctly" do
      view = CoinbaseTickerPriceLens.view()
      assert %Lux.Lens{} = view
      assert view.name == "Coinbase Ticker Price Lens"
      assert view.method == :get
      assert view.url == "https://api.coinbase.com/api/v3/brokerage/market/products"
      assert is_map(view.schema)
      assert Map.has_key?(view.schema.properties, :product_id)
      assert Map.has_key?(view.schema.properties, :symbol)
    end

    test "CoinbaseExchangeInfoLens registers view and schema correctly" do
      view = CoinbaseExchangeInfoLens.view()
      assert %Lux.Lens{} = view
      assert view.name == "Coinbase Exchange Info Lens"
      assert view.method == :get
      assert view.url == "https://api.coinbase.com/api/v3/brokerage/market/products"
      assert is_map(view.schema)
      assert Map.has_key?(view.schema.properties, :product_id)
    end
  end

  describe "Snapshot queries via REST API mocking" do
    test "CoinbaseTickerPriceLens.focus/2 queries ticker price with product_id" do
      Req.Test.expect(Lux.Coinbase.LensesTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products/BTC-USD/ticker"
        Req.Test.json(conn, %{"price" => "95120.50", "product_id" => "BTC-USD"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.LensesTest}]]

      assert {:ok, %{"price" => "95120.50", "product_id" => "BTC-USD"}} =
               CoinbaseTickerPriceLens.focus(%{product_id: "BTC-USD"}, opts)
    end

    test "CoinbaseTickerPriceLens.focus/2 accepts symbol key alias" do
      Req.Test.expect(Lux.Coinbase.LensesTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products/ETH-USD/ticker"
        Req.Test.json(conn, %{"price" => "3500.00", "product_id" => "ETH-USD"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.LensesTest}]]

      assert {:ok, %{"price" => "3500.00", "product_id" => "ETH-USD"}} =
               CoinbaseTickerPriceLens.focus(%{symbol: "ETH-USD"}, opts)
    end

    test "CoinbaseTickerPriceLens.focus/2 returns error on missing product_id" do
      assert {:error, :missing_product_id} = CoinbaseTickerPriceLens.focus(%{})
    end

    test "CoinbaseExchangeInfoLens.focus/2 queries specific product exchange info" do
      Req.Test.expect(Lux.Coinbase.LensesTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products/BTC-USD"

        Req.Test.json(conn, %{
          "product_id" => "BTC-USD",
          "status" => "online",
          "base_currency" => "BTC",
          "quote_currency" => "USD"
        })
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.LensesTest}]]

      assert {:ok, %{"product_id" => "BTC-USD", "status" => "online"}} =
               CoinbaseExchangeInfoLens.focus(%{product_id: "BTC-USD"}, opts)
    end

    test "CoinbaseExchangeInfoLens.focus/2 queries all products when product_id is omitted" do
      Req.Test.expect(Lux.Coinbase.LensesTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products"

        Req.Test.json(conn, %{
          "products" => [
            %{"product_id" => "BTC-USD", "status" => "online"},
            %{"product_id" => "ETH-USD", "status" => "online"}
          ]
        })
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.LensesTest}]]

      assert {:ok, %{"products" => [%{"product_id" => "BTC-USD"}, %{"product_id" => "ETH-USD"}]}} =
               CoinbaseExchangeInfoLens.focus(%{}, opts)
    end
  end

  describe "WebSocket Client, frame parsing, and signal generation" do
    test "starts WS client, handles subscriptions and emits signals on incoming frame" do
      {:ok, pid} =
        WSClient.start_link(
          subscriber: self(),
          subscriptions: [%{channel: "ticker", product_ids: ["BTC-USD"]}]
        )

      assert_receive {:ws_subscribed, %{"type" => "subscribe", "channel" => "ticker"}}, 1000

      assert :ok == WSClient.subscribe(pid, "status", ["BTC-USD"])

      assert_receive {:ws_subscribed,
                      %{"type" => "subscribe", "channel" => "status", "product_ids" => ["BTC-USD"]}},
                     3000

      ticker_frame =
        Jason.encode!(%{
          "channel" => "ticker",
          "timestamp" => "2026-08-07T21:00:00.000Z",
          "sequence_num" => 102,
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
                  "best_bid" => "95120.00",
                  "best_ask" => "95121.00"
                }
              ]
            }
          ]
        })

      WSClient.handle_incoming_frame(pid, ticker_frame)

      assert_receive {:ws_event, %{"channel" => "ticker"}}, 3000

      assert_receive {:signal,
                      %Lux.Signal{
                        payload: %{
                          "channel" => "ticker",
                          "events" => [%{"tickers" => [%{"price" => "95120.50"}]}]
                        }
                      }},
                     3000

      assert_receive {:event, "ticker", %{"channel" => "ticker"}}, 3000
    end

    test "handles corrupted WS JSON frame without process termination" do
      {:ok, pid} = WSClient.start_link(subscriber: self())
      WSClient.handle_incoming_frame(pid, "CORRUPTED_JSON_PAYLOAD{{{")

      assert Process.alive?(pid)
    end
  end

  describe "WebSocket frame normalization in Lenses" do
    test "CoinbaseTickerPriceLens normalizes Advanced Trade WS ticker event" do
      frame = %{
        "channel" => "ticker",
        "timestamp" => "2026-08-07T21:00:00.000Z",
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
                "best_bid" => "95120.00",
                "best_ask" => "95121.00"
              }
            ]
          }
        ]
      }

      assert {:ok,
              %{
                "product_id" => "BTC-USD",
                "price" => "95120.50",
                "volume_24h" => "12345.67",
                "best_bid" => "95120.00",
                "best_ask" => "95121.00"
              }} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
    end

    test "CoinbaseTickerPriceLens normalizes Exchange Feed WS ticker event" do
      frame = %{
        "type" => "ticker",
        "product_id" => "BTC-USD",
        "price" => "95120.50",
        "volume_24h" => "12345.67",
        "low_24h" => "94000.00",
        "high_24h" => "96000.00",
        "best_bid" => "95120.00",
        "best_ask" => "95121.00",
        "time" => "2026-08-07T21:00:00.000Z"
      }

      assert {:ok,
              %{
                "product_id" => "BTC-USD",
                "price" => "95120.50",
                "volume_24h" => "12345.67",
                "timestamp" => "2026-08-07T21:00:00.000Z"
              }} = CoinbaseTickerPriceLens.normalize_ws_frame(frame)
    end

    test "CoinbaseExchangeInfoLens normalizes Advanced Trade WS status event" do
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
                "quote_increment" => "0.01"
              }
            ]
          }
        ]
      }

      assert {:ok,
              %{
                "product_id" => "BTC-USD",
                "status" => "online",
                "base_currency" => "BTC",
                "quote_currency" => "USD"
              }} = CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
    end

    test "CoinbaseExchangeInfoLens normalizes Exchange Feed WS status event" do
      frame = %{
        "type" => "status",
        "products" => [
          %{
            "id" => "BTC-USD",
            "status" => "online",
            "base_currency" => "BTC",
            "quote_currency" => "USD"
          }
        ]
      }

      assert {:ok,
              %{
                "products" => [
                  %{
                    "product_id" => "BTC-USD",
                    "status" => "online",
                    "base_currency" => "BTC"
                  }
                ]
              }} = CoinbaseExchangeInfoLens.normalize_ws_frame(frame)
    end

    test "returns error for unsupported frames" do
      assert {:error, {:unsupported_frame, %{"channel" => "unknown"}}} =
               CoinbaseTickerPriceLens.normalize_ws_frame(%{"channel" => "unknown"})

      assert {:error, {:unsupported_frame, %{"channel" => "unknown"}}} =
               CoinbaseExchangeInfoLens.normalize_ws_frame(%{"channel" => "unknown"})
    end
  end
end
