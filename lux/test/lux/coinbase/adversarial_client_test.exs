defmodule Lux.Coinbase.AdversarialClientTest do
  use ExUnit.Case, async: true
  alias Lux.Coinbase.Client

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "Adversarial Auth & Key Handling" do
    test "handles missing secret_key when signed: true" do
      assert {:error, :missing_secret_key} =
               Client.request(:get, "/api/v3/brokerage/accounts", %{}, signed: true, secret_key: nil)

      assert {:error, :missing_secret_key} =
               Client.request(:get, "/api/v3/brokerage/accounts", %{}, signed: true, secret_key: "")
    end

    test "handles missing api_key by using empty string in auth header" do
      timestamp = "1754582586"
      secret_key = "test_secret_key"
      path = "/api/v3/brokerage/accounts"

      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        headers_map = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers_map, "cb-access-key") == ""
        assert Map.get(headers_map, "cb-access-timestamp") == timestamp
        refute is_nil(Map.get(headers_map, "cb-access-sign"))

        Req.Test.json(conn, %{"accounts" => []})
      end)

      opts = [
        signed: true,
        api_key: nil,
        secret_key: secret_key,
        timestamp: timestamp,
        req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]
      ]

      assert {:ok, %{"accounts" => []}} = Client.request(:get, path, %{}, opts)
    end

    test "falls back to Application config or Environment variables when api_key/secret_key omitted from opts" do
      # Set application env temporarily
      Application.put_env(:lux, :api_keys, coinbase_api_key: "app_env_api_key", coinbase_secret_key: "app_env_secret_key")

      on_exit(fn ->
        Application.delete_env(:lux, :api_keys)
      end)

      timestamp = "1754582586"
      path = "/api/v3/brokerage/accounts"

      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        headers_map = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers_map, "cb-access-key") == "app_env_api_key"
        Req.Test.json(conn, %{"accounts" => []})
      end)

      opts = [
        signed: true,
        timestamp: timestamp,
        req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]
      ]

      assert {:ok, %{"accounts" => []}} = Client.request(:get, path, %{}, opts)
    end

    test "signs request with binary secret containing special characters and unicode" do
      secret_key = "secret_key_!@#$%^&*()_+~`|}{[]:;?><,./-="
      timestamp = "1754582586"
      path = "/api/v3/brokerage/accounts"

      expected_prehash = timestamp <> "GET" <> path <> ""
      expected_sig = Client.sign_prehash(expected_prehash, secret_key)

      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        headers_map = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers_map, "cb-access-sign") == expected_sig
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [
        signed: true,
        api_key: "key",
        secret_key: secret_key,
        timestamp: timestamp,
        req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]
      ]

      assert {:ok, %{"status" => "ok"}} = Client.request(:get, path, %{}, opts)
    end
  end

  describe "Adversarial Query Parameters Formatting" do
    test "formats query params with special characters, spaces, and duplicate keys" do
      params = [
        {:product_id, "BTC-USD"},
        {:product_id, "ETH-USD"},
        {:symbol, "DÓLAR & SOL"},
        {:query, "foo=bar&baz=1"}
      ]

      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        assert conn.query_string =~ "product_id=BTC-USD"
        assert conn.query_string =~ "product_id=ETH-USD"
        assert conn.query_string =~ "D%C3%93LAR"
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]
      assert {:ok, %{"status" => "ok"}} = Client.request(:get, "/api/v3/brokerage/market/products", params, opts)
    end

    test "appends params to path that already contains query string" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        assert conn.request_path == "/api/v3/brokerage/products"
        assert conn.query_string == "existing=1&new=2"
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]

      assert {:ok, %{"status" => "ok"}} =
               Client.request(:get, "/api/v3/brokerage/products?existing=1", %{new: 2}, opts)
    end

    test "handles empty map, empty list, and nil query params gracefully" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, 3, fn conn ->
        assert conn.query_string == ""
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]
      assert {:ok, %{"status" => "ok"}} = Client.request(:get, "/api/v3/brokerage/products", %{}, opts)
      assert {:ok, %{"status" => "ok"}} = Client.request(:get, "/api/v3/brokerage/products", [], opts)
      assert {:ok, %{"status" => "ok"}} = Client.request(:get, "/api/v3/brokerage/products", nil, opts)
    end
  end

  describe "Adversarial Body Payload Formatting" do
    test "formats JSON payload for POST/PUT/DELETE requests" do
      body = %{
        "order_configuration" => %{
          "limit_limit_gtc" => %{
            "base_size" => "0.01",
            "limit_price" => "50000.00"
          }
        },
        "product_id" => "BTC-USD",
        "side" => "BUY"
      }

      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        assert conn.method == "POST"
        {:ok, req_body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(req_body)
        assert decoded["product_id"] == "BTC-USD"
        Req.Test.json(conn, %{"success" => true})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]
      assert {:ok, %{"success" => true}} = Client.request(:post, "/api/v3/brokerage/orders", body, opts)
    end

    test "handles empty map body for POST request resulting in `{}` payload" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        {:ok, req_body, conn} = Plug.Conn.read_body(conn)
        assert req_body == "{}"
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]
      assert {:ok, %{"status" => "ok"}} = Client.request(:post, "/api/v3/brokerage/orders", %{}, opts)
    end

    test "handles pre-encoded JSON string body for POST request" do
      json_str = ~s({"client_order_id":"abc-123","product_id":"ETH-USD"})

      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        {:ok, req_body, conn} = Plug.Conn.read_body(conn)
        assert req_body == json_str
        Req.Test.json(conn, %{"status" => "ok"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]
      assert {:ok, %{"status" => "ok"}} = Client.request(:post, "/api/v3/brokerage/orders", json_str, opts)
    end
  end

  describe "HTTP Response Status Codes Handling (400, 401, 403, 404, 500, 503)" do
    test "returns error tuple on HTTP 400 Bad Request" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "INVALID_ARGUMENT", "message" => "Invalid product_id"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]

      assert {:error, %{status: 400, body: %{"error" => "INVALID_ARGUMENT"}}} =
               Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
    end

    test "returns error tuple on HTTP 401 Unauthorized" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "UNAUTHENTICATED", "message" => "Invalid API Key"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]

      assert {:error, %{status: 401, body: %{"error" => "UNAUTHENTICATED"}}} =
               Client.request(:get, "/api/v3/brokerage/accounts", %{}, opts)
    end

    test "returns error tuple on HTTP 403 Forbidden" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "PERMISSION_DENIED", "message" => "IP address not whitelisted"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]

      assert {:error, %{status: 403, body: %{"error" => "PERMISSION_DENIED"}}} =
               Client.request(:get, "/api/v3/brokerage/accounts", %{}, opts)
    end

    test "returns error tuple on HTTP 404 Not Found" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => "NOT_FOUND", "message" => "Endpoint not found"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}]]

      assert {:error, %{status: 404, body: %{"error" => "NOT_FOUND"}}} =
               Client.request(:get, "/api/v3/brokerage/nonexistent", %{}, opts)
    end

    test "returns error tuple on HTTP 500 Internal Server Error" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "INTERNAL_SERVER_ERROR", "message" => "An internal error occurred"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}, retry: false]]

      assert {:error, %{status: 500, body: %{"error" => "INTERNAL_SERVER_ERROR"}}} =
               Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
    end

    test "returns error tuple on HTTP 503 Service Unavailable" do
      Req.Test.expect(Lux.Coinbase.AdversarialClientTest, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "UNAVAILABLE", "message" => "Service is temporarily unavailable"})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.AdversarialClientTest}, retry: false]]

      assert {:error, %{status: 503, body: %{"error" => "UNAVAILABLE"}}} =
               Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
    end
  end
end
