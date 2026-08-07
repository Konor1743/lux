defmodule Lux.Coinbase.Client do
  @moduledoc """
  Core HTTP Client for Coinbase Advanced Trade REST API using Req.

  Provides support for:
  - Mainnet (`https://api.coinbase.com`) and Sandbox (`https://api-public.sandbox.exchange.coinbase.com`) environments.
  - Header-based HMAC-SHA256 authentication (`CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`).
  - Req client execution with configurable options.

  ## Examples

      # Public market products request
      iex> Lux.Coinbase.Client.request(:get, "/api/v3/brokerage/market/products")
      {:ok, %{"products" => [...]}}

      # Signed accounts request
      iex> Lux.Coinbase.Client.request(:get, "/api/v3/brokerage/accounts", %{}, signed: true, api_key: "key", secret_key: "secret")
      {:ok, %{"accounts" => [...]}}
  """

  alias Lux.Coinbase.RateLimiter

  @type method :: :get | :post | :put | :delete | String.t()

  @mainnet_url "https://api.coinbase.com"
  @sandbox_url "https://api-public.sandbox.exchange.coinbase.com"

  @doc """
  Executes an HTTP request against the Coinbase Advanced Trade REST API.

  ## Options
    - `:signed` - Boolean, whether to sign the request with HMAC-SHA256 (default: `false`).
    - `:sandbox` or `:testnet` - Boolean, use sandbox URLs (default: `false`).
    - `:api_key` - API key string.
    - `:secret_key` - API secret key string.
    - `:timestamp` - Custom UTC Unix timestamp string or integer for deterministic signing/testing.
    - `:req_options` - Keyword list passed to `Req` (e.g. `plug: {Req.Test, ...}`).
  """
  @spec request(method(), String.t(), map() | keyword() | binary(), keyword()) ::
          {:ok, map() | list()} | {:error, term()}
  def request(method, path, params_or_body \\ %{}, opts \\ []) do
    sandbox? = Keyword.get(opts, :sandbox, Keyword.get(opts, :testnet, false))
    base_url = get_base_url(sandbox?)

    api_key = get_api_key(opts)
    secret_key = get_secret_key(opts)
    signed? = Keyword.get(opts, :signed, Keyword.get(opts, :signed?, false))

    cond do
      signed? and (is_nil(secret_key) or secret_key == "") ->
        {:error, :missing_secret_key}

      signed? ->
        timestamp = get_timestamp(opts)
        {request_path, body_str, req_body_opt} = prepare_payload(method, path, params_or_body)
        method_str = method |> to_string() |> String.upcase()
        prehash = timestamp <> method_str <> request_path <> body_str
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

  defp get_timestamp(opts) do
    case Keyword.get(opts, :timestamp) do
      nil -> to_string(System.system_time(:second))
      val -> to_string(val)
    end
  end

  defp prepare_payload(method, path, params_or_body) do
    method_atom = method |> to_string() |> String.downcase() |> String.to_atom()

    case method_atom do
      :get ->
        qs = build_query_string(params_or_body)
        request_path = append_query_string(path, qs)
        {request_path, "", nil}

      _other ->
        body_str = build_body_string(params_or_body)
        req_body = if body_str == "", do: nil, else: body_str
        {path, body_str, req_body}
    end
  end

  defp build_query_string(params) when is_map(params) or is_list(params) do
    if Enum.empty?(params) do
      ""
    else
      URI.encode_query(params)
    end
  end

  defp build_query_string(_), do: ""

  defp append_query_string(path, ""), do: path

  defp append_query_string(path, qs) do
    if String.contains?(path, "?") do
      "#{path}&#{qs}"
    else
      "#{path}?#{qs}"
    end
  end

  defp build_body_string(body) when is_binary(body), do: body

  defp build_body_string(body) when is_map(body) or is_list(body) do
    if Enum.empty?(body) and is_map(body) do
      "{}"
    else
      Jason.encode!(body)
    end
  end

  defp build_body_string(_), do: ""

  defp build_auth_headers(api_key, signature, timestamp) do
    [
      {"CB-ACCESS-KEY", api_key || ""},
      {"CB-ACCESS-SIGN", signature},
      {"CB-ACCESS-TIMESTAMP", timestamp},
      {"Content-Type", "application/json"}
    ]
  end

  defp do_request(method, base_url, request_path, body_opt, headers, opts) do
    method_atom = method |> to_string() |> String.downcase() |> String.to_atom()

    user_req_opts = Keyword.get(opts, :req_options, [])
    app_req_opts = Application.get_env(:lux, :req_options, [])
    merged_req_opts = Keyword.merge(app_req_opts, user_req_opts)

    custom_keys = [:coinbase_auto_backoff, :retry_delay_multiplier]

    custom_opts =
      merged_req_opts
      |> Keyword.take(custom_keys)
      |> Keyword.merge(Keyword.take(opts, custom_keys))

    standard_req_opts =
      [base_url: base_url, headers: headers]
      |> Keyword.merge(Keyword.drop(merged_req_opts, custom_keys))

    req =
      Req.new(standard_req_opts)
      |> Req.Request.register_options(custom_keys)
      |> Req.Request.merge_options(custom_opts)
      |> RateLimiter.attach()

    call_opts = [method: method_atom, url: request_path]
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
    opts[:api_key] ||
      System.get_env("COINBASE_API_KEY") ||
      get_app_config(:coinbase_api_key)
  end

  defp get_secret_key(opts) do
    opts[:secret_key] ||
      System.get_env("COINBASE_SECRET_KEY") ||
      get_app_config(:coinbase_secret_key)
  end

  defp get_app_config(key) do
    case Application.get_env(:lux, :api_keys) do
      list when is_list(list) -> Keyword.get(list, key)
      _ -> nil
    end
  end
end
