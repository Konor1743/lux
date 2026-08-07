defmodule Lux.Coinbase.ClientTest do
  use ExUnit.Case, async: true
  alias Lux.Coinbase.Client

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "get_base_url/1" do
    test "returns correct mainnet and sandbox URLs" do
      assert Client.get_base_url(false) == "https://api.coinbase.com"
      assert Client.get_base_url(true) == "https://api-public.sandbox.exchange.coinbase.com"
    end
  end

  describe "sign_prehash/2" do
    test "computes valid lower-case hex HMAC-SHA256 signature against reference vector" do
      timestamp = "1754582586"
      method = "GET"
      path = "/api/v3/brokerage/accounts"
      body = ""
      secret = "test_secret_key"

      prehash = timestamp <> method <> path <> body
      expected = :crypto.mac(:hmac, :sha256, secret, prehash) |> Base.encode16(case: :lower)

      assert Client.sign_prehash(prehash, secret) == expected
    end

    test "computes valid signature for POST request with JSON payload" do
      timestamp = "1754582586"
      method = "POST"
      path = "/api/v3/brokerage/orders"
      body = ~s({"client_order_id":"123","product_id":"BTC-USD","side":"BUY"})
      secret = "test_secret_key"

      prehash = timestamp <> method <> path <> body
      expected = :crypto.mac(:hmac, :sha256, secret, prehash) |> Base.encode16(case: :lower)

      assert Client.sign_prehash(prehash, secret) == expected
    end
  end

  describe "request/4 sandbox vs mainnet selection" do
    test "routes to sandbox URL when sandbox: true" do
      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        assert conn.host == "api-public.sandbox.exchange.coinbase.com"
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [sandbox: true, req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]]
      assert {:ok, %{"status" => "ok"}} = Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
    end

    test "routes to mainnet URL by default when sandbox: false" do
      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        assert conn.host == "api.coinbase.com"
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [sandbox: false, req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]]
      assert {:ok, %{"status" => "ok"}} = Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
    end
  end

  describe "request/4 with Req.Test" do
    test "executes unsigned GET request with query params" do
      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products"
        assert conn.query_string =~ "limit=10"
        Req.Test.json(conn, %{"products" => [%{"product_id" => "BTC-USD"}]})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]]

      assert {:ok, %{"products" => [%{"product_id" => "BTC-USD"}]}} =
               Client.request(:get, "/api/v3/brokerage/market/products", %{limit: 10}, opts)
    end

    test "executes signed GET request with auth headers and verifies signature" do
      timestamp = "1754582586"
      api_key = "test_api_key"
      secret_key = "test_secret_key"
      path = "/api/v3/brokerage/accounts"

      expected_prehash = timestamp <> "GET" <> path <> ""
      expected_sig = Client.sign_prehash(expected_prehash, secret_key)

      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == path

        headers_map = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers_map, "cb-access-key") == api_key
        assert Map.get(headers_map, "cb-access-timestamp") == timestamp
        assert Map.get(headers_map, "cb-access-sign") == expected_sig

        Req.Test.json(conn, %{"accounts" => [%{"uuid" => "acc-123"}]})
      end)

      opts = [
        signed: true,
        api_key: api_key,
        secret_key: secret_key,
        timestamp: timestamp,
        req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]
      ]

      assert {:ok, %{"accounts" => [%{"uuid" => "acc-123"}]}} =
               Client.request(:get, path, %{}, opts)
    end

    test "executes signed POST request with auth headers and verifies body signature" do
      timestamp = "1754582586"
      api_key = "test_api_key"
      secret_key = "test_secret_key"
      path = "/api/v3/brokerage/orders"
      body = %{"client_order_id" => "123", "product_id" => "BTC-USD", "side" => "BUY"}
      body_str = Jason.encode!(body)

      expected_prehash = timestamp <> "POST" <> path <> body_str
      expected_sig = Client.sign_prehash(expected_prehash, secret_key)

      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == path

        headers_map = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers_map, "cb-access-key") == api_key
        assert Map.get(headers_map, "cb-access-timestamp") == timestamp
        assert Map.get(headers_map, "cb-access-sign") == expected_sig

        Req.Test.json(conn, %{"success" => true, "order_id" => "ord-123"})
      end)

      opts = [
        signed: true,
        api_key: api_key,
        secret_key: secret_key,
        timestamp: timestamp,
        req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]
      ]

      assert {:ok, %{"success" => true, "order_id" => "ord-123"}} =
               Client.request(:post, path, body, opts)
    end

    test "returns missing_secret_key error when signed is true but secret_key is missing" do
      assert {:error, :missing_secret_key} =
               Client.request(:get, "/api/v3/brokerage/accounts", %{}, signed: true, secret_key: nil, api_key: "key")
    end

    test "returns error tuple on HTTP status failure (e.g. 401 Unauthorized)" do
      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "UNAUTHENTICATED", "message" => "Invalid API key"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]]

      assert {:error, %{status: 401, body: %{"error" => "UNAUTHENTICATED"}}} =
               Client.request(:get, "/api/v3/brokerage/accounts", %{}, opts)
    end
  end
end
