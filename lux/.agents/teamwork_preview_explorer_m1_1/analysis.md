# Coinbase REST Client & Rate Limiter Architecture Analysis (Milestone 1)

## Executive Summary
This document provides a comprehensive architectural analysis and implementation blueprint for integrating the Coinbase Advanced Trade REST API into the `Lux` Elixir framework (`Spectral-Finance/lux`). It builds upon the design patterns established in the existing `Lux.Binance` module while accounting for Coinbase's distinct HMAC-SHA256 authentication header requirements and rate limiting mechanisms.

---

## 1. Existing Binance Implementation Analysis

The existing Binance REST integration in `lib/lux/binance/` consists of three core components:

### 1.1 `Lux.Binance.Auth` (`lib/lux/binance/auth.ex`)
- **Authentication Model**: Query parameter / Body signing using HMAC-SHA256.
- **Timestamping**: Uses millisecond Unix timestamps (`timestamp`) with a default `recvWindow` of 5000 ms.
- **Signature Placement**: The signature is appended as the final parameter (`&signature=<hex_hash>`) in the query string or URL-encoded form payload.
- **Header Management**: Injects `X-MBX-APIKEY` header for authenticated endpoints.

### 1.2 `Lux.Binance.Client` (`lib/lux/binance/client.ex`)
- **HTTP Engine**: Built on `Req` (~> 0.5.0).
- **Environment & Market Differentiation**: Supports `:spot` and `:futures` markets across mainnet and testnet environments.
- **Credential Fallback Cascade**: Checks explicitly passed options -> `System.get_env/1` -> `Application.get_env(:lux, :api_keys)`.
- **Middleware Pipeline**: Attaches `Lux.Binance.RateLimiter` middleware via `Req.Request.append_request_steps/2` and `append_response_steps/2`.
- **Req.Test Compatibility**: Accepts `:req_options` (e.g., `plug: {Req.Test, Lux.Binance.ClientTest}`) to enable fast, deterministic unit tests without network IO.

### 1.3 `Lux.Binance.RateLimiter` (`lib/lux/binance/rate_limiter.ex`)
- **Storage**: GenServer managing a public ETS table (`:lux_binance_rate_limiter`) with read/write concurrency enabled.
- **Weight Tracking**: Records header `x-mbx-used-weight-1m` (Spot) and `x-fapi-used-weight-1m` (Futures).
- **Backoff Enforcement**: Handles HTTP status `429` (Rate Limit Exceeded) and `418` (Teapot/IP Ban). Parses `retry-after` header in seconds to calculate `backoff_until` timestamp in milliseconds.
- **Middleware Logic**:
  - Pre-request step checks `backoff_until`. If active, either sleeps `wait_ms` (when `:binance_auto_backoff` is `true`) or halts request with a `429` status response.
  - Post-response step extracts response headers and status to update ETS state.

---

## 2. Coinbase Advanced Trade REST API Specifications

### 2.1 Authentication Specifications
Coinbase Advanced Trade API (and Coinbase v3 REST APIs) requires HTTP header-based authentication using HMAC-SHA256 signatures:

1. **Required Headers**:
   - `CB-ACCESS-KEY`: The API key string.
   - `CB-ACCESS-SIGN`: Hex-encoded HMAC-SHA256 signature string (lowercase).
   - `CB-ACCESS-TIMESTAMP`: Current UTC Unix timestamp in **seconds** as a string (e.g. `"1754582586"`).
   - `Content-Type`: `"application/json"` for POST/PUT/DELETE requests.

2. **Signature Calculation (`CB-ACCESS-SIGN`)**:
   - **Prehash String**:
     ```elixir
     prehash = timestamp <> String.upcase(to_string(method)) <> request_path <> body
     ```
     - `timestamp`: Unix time in seconds as string (`to_string(System.system_time(:second))`).
     - `method`: Upper-case HTTP method (`"GET"`, `"POST"`, `"DELETE"`).
     - `request_path`: Full URL path including query string if present (e.g., `"/api/v3/brokerage/accounts"` or `"/api/v3/brokerage/orders/historical/fills?product_id=BTC-USD"`).
     - `body`: Raw JSON string payload for POST/PUT/DELETE requests, or empty string `""` for GET/DELETE requests without body.
   - **HMAC Computation**:
     ```elixir
     signature = :crypto.mac(:hmac, :sha256, secret_key, prehash) |> Base.encode16(case: :lower)
     ```

### 2.2 Rate Limiting Specifications
- **Status Code**: Returns HTTP `429 Too Many Requests` when limits are exceeded.
- **Headers**:
  - `retry-after`: Seconds to wait before retrying.
  - `cb-ratelimit-limit`: Max permitted requests per window.
  - `cb-ratelimit-remaining`: Quota remaining in current window.
  - `cb-ratelimit-reset`: Unix timestamp when current rate window resets.

---

## 3. Side-by-Side Architectural Comparison

| Aspect | Binance REST (`Lux.Binance`) | Coinbase REST (`Lux.Coinbase`) |
| :--- | :--- | :--- |
| **Auth Location** | Query params / Body (`timestamp`, `recvWindow`, `signature`) | HTTP Headers (`CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`) |
| **Timestamp Unit** | Milliseconds (`System.system_time(:millisecond)`) | Seconds (`System.system_time(:second)`) |
| **Prehash Formula** | `sorted_query_string_or_body` | `timestamp <> method <> request_path <> body` |
| **API Key Header** | `X-MBX-APIKEY` | `CB-ACCESS-KEY` |
| **Signature Header**| Passed in query parameter `signature=` | `CB-ACCESS-SIGN` |
| **Base URLs** | Spot: `api.binance.com`, Futures: `fapi.binance.com` | Mainnet: `https://api.coinbase.com`, Sandbox: `https://api-public.sandbox.exchange.coinbase.com` |
| **Rate Limit Headers**| `x-mbx-used-weight-1m`, `x-fapi-used-weight-1m` | `cb-ratelimit-limit`, `cb-ratelimit-remaining`, `cb-ratelimit-reset` |
| **HTTP Client** | `Req` plugin with custom steps | `Req` plugin with custom steps |
| **Rate Limiter Storage**| ETS table (`:lux_binance_rate_limiter`) | ETS table (`:lux_coinbase_rate_limiter`) |

---

## 4. Module Designs & Blueprints

### 4.1 `Lux.Coinbase.Client` (`lib/lux/coinbase/client.ex`)

```elixir
defmodule Lux.Coinbase.Client do
  @moduledoc """
  Core HTTP Client for Coinbase Advanced Trade REST API using Req.

  Provides support for:
  - Mainnet (`https://api.coinbase.com`) and Sandbox (`https://api-public.sandbox.exchange.coinbase.com`) environments.
  - Header-based HMAC-SHA256 authentication (`CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`).
  - Automatic rate limit tracking and HTTP 429 backoff middleware via `Lux.Coinbase.RateLimiter`.
  """

  alias Lux.Coinbase.RateLimiter

  @type method :: :get | :post | :put | :delete

  @mainnet_url "https://api.coinbase.com"
  @sandbox_url "https://api-public.sandbox.exchange.coinbase.com"

  @doc """
  Executes an HTTP request against the Coinbase Advanced Trade REST API.
  """
  @spec request(method(), String.t(), map() | keyword() | binary(), keyword()) ::
          {:ok, map() | list()} | {:error, term()}
  def request(method, path, params_or_body \\ %{}, opts \\ []) do
    sandbox? = Keyword.get(opts, :sandbox, Keyword.get(opts, :testnet, false))
    base_url = get_base_url(sandbox?)

    api_key = get_api_key(opts)
    secret_key = get_secret_key(opts)
    signed? = Keyword.get(opts, :signed, false)

    cond do
      signed? and (is_nil(secret_key) or secret_key == "") ->
        {:error, :missing_secret_key}

      signed? ->
        timestamp = to_string(System.system_time(:second))
        {request_path, body_str, req_body_opt} = prepare_payload(method, path, params_or_body)
        prehash = timestamp <> String.upcase(to_string(method)) <> request_path <> body_str
        signature = sign_prehash(prehash, secret_key)
        headers = build_auth_headers(api_key, signature, timestamp)

        do_request(method, base_url, request_path, req_body_opt, headers, opts)

      true ->
        {request_path, _body_str, req_body_opt} = prepare_payload(method, path, params_or_body)
        headers = [{"Content-Type", "application/json"}]
        do_request(method, base_url, request_path, req_body_opt, headers, opts)
    end
  end

  @doc """
  Returns the base URL for mainnet or sandbox environment.
  """
  @spec get_base_url(boolean()) :: String.t()
  def get_base_url(true), do: @sandbox_url
  def get_base_url(false), do: @mainnet_url

  @doc """
  Generates lower-case hex HMAC-SHA256 signature for a prehash string.
  """
  @spec sign_prehash(binary(), binary()) :: binary()
  def sign_prehash(prehash, secret_key) when is_binary(prehash) and is_binary(secret_key) do
    :crypto.mac(:hmac, :sha256, secret_key, prehash)
    |> Base.encode16(case: :lower)
  end

  # Helper functions

  defp prepare_payload(:get, path, params) when is_map(params) or is_list(params) do
    qs = URI.encode_query(params)
    request_path = if qs == "", do: path, else: (if String.contains?(path, "?"), do: "#{path}&#{qs}", else: "#{path}?#{qs}")
    {request_path, "", nil}
  end

  defp prepare_payload(method, path, body) when method in [:post, :put, :delete] do
    body_str =
      cond do
        is_binary(body) -> body
        is_map(body) or is_list(body) -> Jason.encode!(body)
        true -> ""
      end

    {path, body_str, body_str}
  end

  defp prepare_payload(_method, path, _params), do: {path, "", nil}

  defp build_auth_headers(api_key, signature, timestamp) do
    [
      {"CB-ACCESS-KEY", api_key || ""},
      {"CB-ACCESS-SIGN", signature},
      {"CB-ACCESS-TIMESTAMP", timestamp},
      {"Content-Type", "application/json"}
    ]
  end

  defp do_request(method, base_url, request_path, body_opt, headers, opts) do
    base_req_opts =
      [
        base_url: base_url,
        headers: headers
      ]
      |> Keyword.merge(Application.get_env(:lux, :req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    req =
      Req.new(base_req_opts)
      |> Req.Request.register_options([:coinbase_auto_backoff, :retry_delay_multiplier])
      |> RateLimiter.attach()

    call_opts = [method: method, url: request_path]
    call_opts = if body_opt, do: Keyword.put(call_opts, :body, body_opt), else: call_opts

    case Req.request(req, call_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_api_key(opts) do
    opts[:api_key] || System.get_env("COINBASE_API_KEY") || get_app_config(:coinbase_api_key)
  end

  defp get_secret_key(opts) do
    opts[:secret_key] || System.get_env("COINBASE_SECRET_KEY") || get_app_config(:coinbase_secret_key)
  end

  defp get_app_config(key) do
    case Application.get_env(:lux, :api_keys) do
      list when is_list(list) -> Keyword.get(list, key)
      _ -> nil
    end
  end
end
```

---

### 4.2 `Lux.Coinbase.RateLimiter` (`lib/lux/coinbase/rate_limiter.ex`)

```elixir
defmodule Lux.Coinbase.RateLimiter do
  @moduledoc """
  Rate Limiter GenServer and Req middleware for Coinbase API limits.

  Tracks quota metrics (`cb-ratelimit-limit`, `cb-ratelimit-remaining`, `cb-ratelimit-reset`)
  and backoff windows triggered by 429 (Rate Limit Exceeded) status codes.
  """

  use GenServer
  require Logger

  @table :lux_coinbase_rate_limiter

  defstruct limit: 0,
            remaining: 0,
            reset: 0,
            backoff_until: 0

  # API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec check_rate_limit() :: :ok | {:error, {:rate_limited, integer()}}
  def check_rate_limit do
    now = System.system_time(:millisecond)
    backoff_until = get_backoff_until()

    if now < backoff_until do
      {:error, {:rate_limited, backoff_until - now}}
    else
      :ok
    end
  end

  @spec record_response(list() | map(), integer()) :: :ok
  def record_response(headers, status_code) do
    headers_map = normalize_headers(headers)
    now = System.system_time(:millisecond)

    if status_code == 429 do
      retry_after_sec = parse_header_int(headers_map, "retry-after", 60)
      backoff_until = now + retry_after_sec * 1000
      set_backoff_until(backoff_until)
      Logger.warning("Coinbase API rate limit hit (HTTP 429). Backoff until #{backoff_until} (#{retry_after_sec}s)")
    end

    if limit_str = Map.get(headers_map, "cb-ratelimit-limit") do
      case Integer.parse(limit_str) do
        {limit, _} -> set_ets_value(:cb_ratelimit_limit, limit)
        :error -> :ok
      end
    end

    if remaining_str = Map.get(headers_map, "cb-ratelimit-remaining") do
      case Integer.parse(remaining_str) do
        {remaining, _} -> set_ets_value(:cb_ratelimit_remaining, remaining)
        :error -> :ok
      end
    end

    if reset_str = Map.get(headers_map, "cb-ratelimit-reset") do
      case Integer.parse(reset_str) do
        {reset_val, _} -> set_ets_value(:cb_ratelimit_reset, reset_val)
        :error -> :ok
      end
    end

    :ok
  end

  @spec get_remaining_quota() :: integer()
  def get_remaining_quota do
    get_ets_value(:cb_ratelimit_remaining, 0)
  end

  @spec get_backoff_until() :: integer()
  def get_backoff_until do
    get_ets_value(:backoff_until, 0)
  end

  def reset do
    if ets_exists?() do
      :ets.insert(@table, {:cb_ratelimit_limit, 0})
      :ets.insert(@table, {:cb_ratelimit_remaining, 0})
      :ets.insert(@table, {:cb_ratelimit_reset, 0})
      :ets.insert(@table, {:backoff_until, 0})
    end
    :ok
  end

  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = request) do
    request
    |> Req.Request.register_options([:coinbase_auto_backoff, :retry_delay_multiplier])
    |> Req.Request.append_request_steps(coinbase_rate_limit_check: &pre_request_step/1)
    |> Req.Request.append_response_steps(coinbase_rate_limit_record: &post_response_step/1)
  end

  # Middleware steps

  defp pre_request_step(%Req.Request{} = request) do
    auto_backoff = request.options[:coinbase_auto_backoff] != false

    case check_rate_limit() do
      :ok ->
        request

      {:error, {:rate_limited, wait_ms}} ->
        if auto_backoff and wait_ms > 0 do
          delay_mult = request.options[:retry_delay_multiplier] || 1.0
          actual_sleep = round(wait_ms * delay_mult)
          if actual_sleep > 0 do
            Process.sleep(actual_sleep)
          end
          request
        else
          resp = %Req.Response{
            status: 429,
            body: %{"message" => "Rate limit backoff active", "wait_ms" => wait_ms}
          }

          Req.Request.halt(request, resp)
        end
    end
  end

  defp post_response_step({request, response}) do
    record_response(response.headers, response.status)
    {request, response}
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    create_table_if_not_exists()
    {:ok, %__MODULE__{}}
  end

  # Helper functions for ETS operations

  defp create_table_if_not_exists do
    unless ets_exists?() do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      :ets.insert(@table, {:cb_ratelimit_limit, 0})
      :ets.insert(@table, {:cb_ratelimit_remaining, 0})
      :ets.insert(@table, {:cb_ratelimit_reset, 0})
      :ets.insert(@table, {:backoff_until, 0})
    end
  end

  defp ets_exists? do
    :ets.whereis(@table) != :undefined
  end

  defp get_ets_value(key, default) do
    create_table_if_not_exists()
    case :ets.lookup(@table, key) do
      [{^key, val}] -> val
      [] -> default
    end
  rescue
    _ -> default
  end

  defp set_ets_value(key, value) do
    create_table_if_not_exists()
    :ets.insert(@table, {key, value})
  end

  defp set_backoff_until(timestamp) do
    set_ets_value(:backoff_until, timestamp)
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    |> Map.new()
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.map(fn {k, v} ->
      val = if is_list(v), do: Enum.join(v, ", "), else: to_string(v)
      {String.downcase(to_string(k)), val}
    end)
    |> Map.new()
  end

  defp parse_header_int(headers_map, header_name, default) do
    case Map.get(headers_map, header_name) do
      nil -> default
      val ->
        case Integer.parse(to_string(val)) do
          {int_val, _} -> int_val
          :error -> default
        end
    end
  end
end
```

---

### 4.3 `test/lux/coinbase/client_test.exs`

```elixir
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
    test "computes valid lower-case hex HMAC-SHA256 signature" do
      prehash = "1754582586GET/api/v3/brokerage/accounts"
      secret = "test_secret_key"
      expected = :crypto.mac(:hmac, :sha256, secret, prehash) |> Base.encode16(case: :lower)

      assert Client.sign_prehash(prehash, secret) == expected
    end
  end

  describe "request/4 with Req.Test" do
    test "executes GET request to Coinbase API" do
      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v3/brokerage/market/products"
        Req.Test.json(conn, %{"products" => [%{"product_id" => "BTC-USD"}]})
      end)

      opts = [req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]]

      assert {:ok, %{"products" => [%{"product_id" => "BTC-USD"}]}} =
               Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
    end

    test "executes signed POST request with auth headers" do
      Req.Test.expect(Lux.Coinbase.ClientTest, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v3/brokerage/orders"

        headers_map = conn.req_headers |> Enum.into(%{})
        assert Map.get(headers_map, "cb-access-key") == "test_api_key"
        assert Map.has_key?(headers_map, "cb-access-sign")
        assert Map.has_key?(headers_map, "cb-access-timestamp")

        Req.Test.json(conn, %{"success" => true, "order_id" => "ord-123"})
      end)

      body = %{"client_order_id" => "123", "product_id" => "BTC-USD", "side" => "BUY"}

      opts = [
        signed: true,
        api_key: "test_api_key",
        secret_key: "test_secret_key",
        req_options: [plug: {Req.Test, Lux.Coinbase.ClientTest}]
      ]

      assert {:ok, %{"success" => true, "order_id" => "ord-123"}} =
               Client.request(:post, "/api/v3/brokerage/orders", body, opts)
    end

    test "returns missing_secret_key error when signed is true but secret_key is missing" do
      assert {:error, :missing_secret_key} =
               Client.request(:get, "/api/v3/brokerage/accounts", %{}, signed: true, secret_key: nil, api_key: nil)
    end

    test "returns error tuple on HTTP status failure" do
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
```

---

### 4.4 `test/lux/coinbase/rate_limiter_test.exs`

```elixir
defmodule Lux.Coinbase.RateLimiterTest do
  use ExUnit.Case, async: false
  alias Lux.Coinbase.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  describe "record_response/2 & check_rate_limit/0" do
    test "initially allows requests without backoff" do
      assert RateLimiter.check_rate_limit() == :ok
    end

    test "records quota headers" do
      headers = [
        {"cb-ratelimit-limit", "30"},
        {"cb-ratelimit-remaining", "25"},
        {"cb-ratelimit-reset", "1754582600"}
      ]

      RateLimiter.record_response(headers, 200)
      assert RateLimiter.get_remaining_quota() == 25
    end

    test "triggers backoff when receiving HTTP 429 with Retry-After header" do
      headers = [{"retry-after", "10"}, {"cb-ratelimit-remaining", "0"}]
      RateLimiter.record_response(headers, 429)

      assert {:error, {:rate_limited, wait_ms}} = RateLimiter.check_rate_limit()
      assert wait_ms > 0 and wait_ms <= 10_000
    end
  end

  describe "attach/1 Req middleware" do
    test "attaches pre and post steps to Req request" do
      req = Req.new()
      attached = RateLimiter.attach(req)

      refute req == attached
    end
  end
end
```

---

## 5. Verification Plan

1. **Unit Test Execution**:
   Run `mix test test/lux/coinbase/` once files are created in Milestone 2 & 3.
2. **Req.Test Validation**:
   Ensure all tests execute deterministically without hitting external network endpoints.
3. **Format & Credo Compliance**:
   Run `mix format` and `mix credo --strict` across `lib/lux/coinbase/` and `test/lux/coinbase/`.
