# Milestone 1: YouTube HTTP Client & Integration Core Analysis Report

**Explorer**: Explorer 2 (Milestone 1)  
**Date**: 2026-08-17  
**Working Directory**: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_2`  
**Status**: Investigation & Architecture Complete  

---

## 1. Executive Summary

Milestone 1 lays the foundational communication and integration layer for YouTube API interactions within the Lux framework. This report provides the architectural blueprint, contract designs, code blueprints, and testing methodology for:
1. `Lux.Integrations.YouTube.Client` (`lib/lux/integrations/youtube/client.ex`): A resilient, Req-based HTTP client communicating with Google APIs (`https://www.googleapis.com/youtube/v3`). It manages Bearer auth headers, API key fallback, JSON payloads, query params, mock plug injection, Google-specific error structures (`quotaExceeded`, `rateLimitExceeded`), and automatic token refresh on HTTP 401 with a single retry.
2. `Lux.Integrations.YouTube` (`lib/lux/integrations/youtube.ex`): The core integration module providing standard `request_settings/0`, `headers/0`, `auth/0`, `add_auth_header/1` (supporting both `%Lux.Lens{}` and `%Plug.Conn{}`), and `base_url/0`.
3. `Lux.Config` additions (`lib/lux/config.ex` & `config/runtime.exs`): Safe and required accessors for YouTube Client ID, Client Secret, API Key, Access Token, and Refresh Token.
4. `Req.Test` Integration (`test/test_helper.exs` & `test/unit/lux/integrations/youtube/`): Mocking registration in `UnitAPICase` and a comprehensive test matrix.

---

## 2. Investigation of Existing HTTP Client Architecture in Lux

Across the Lux codebase (`lib/lux/integrations/discord/client.ex`, `lib/lux/integrations/telegram/client.ex`, `lib/lux/integrations/allora.ex`, `lib/lux/llm/*.ex`, and `lib/lux/lens.ex`), the HTTP client pattern follows a standardized, modular Req pipeline:

### 2.1 Req Pipeline & Mock Injection Pattern
```elixir
[
  method: method,
  url: @endpoint <> path,
  headers: headers,
  params: params,
  json: json
]
|> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
|> maybe_add_plug(opts[:plug])
|> Req.new()
|> Req.request()
```
- **Global / Test-Level Mocking**: In `test/test_helper.exs`, `UnitAPICase` injects `plug: {Req.Test, ModuleMock}` into `Application.put_env(:lux, Module, ...)`. This ensures all calls in unit tests default to `Req.Test` without live network calls.
- **Local / Per-Call Mocking**: When a test passes `plug: {Req.Test, __MODULE__}`, `maybe_add_plug/2` overrides the global mock with the test-specific mock plug.

### 2.2 Integration Module Pattern with Lenses
- Modules under `Lux.Integrations.*` (e.g. `Lux.Integrations.Discord`) export:
  - `request_settings/0`: Map with `:headers` and `:auth` specifications.
  - `headers/0`: Default HTTP headers list.
  - `auth/0`: Map with `%{type: :custom, auth_function: &__MODULE__.add_auth_header/1}`.
  - `add_auth_header/1`: Pattern-matched function updating either `%Lux.Lens{}` (updating `lens.headers` or `lens.params`) or `%Plug.Conn{}` (calling `Plug.Conn.put_req_header/3`).

---

## 3. Design of `Lux.Integrations.YouTube.Client`

### 3.1 Overview & Responsibilities
- **Endpoint**: `https://www.googleapis.com/youtube/v3`
- **Authentication**:
  - OAuth 2.0 Bearer token via `Authorization: Bearer <token>` header (preferred for live streaming, private data, chat posting).
  - API Key via `?key=<api_key>` query parameter fallback (for public data retrieval when no Bearer token is provided).
- **Auto-Refresh on 401**:
  - If a request yields HTTP 401, the client checks if `:auto_refresh` is enabled (default `true`) and `retry_count < 1`.
  - It resolves credentials (`refresh_token`, `client_id`, `client_secret`) from `opts` or `Lux.Config`.
  - It invokes `Lux.Integrations.YouTube.OAuth.refresh_token/2` (preserving any mock `:plug`).
  - Upon successful token refresh, it retries the original request with the updated token.
- **Google API Error Parsing**:
  - Inspects `error.errors[].reason` and HTTP status codes:
    - `{403, "quotaExceeded"}` -> `{:error, {:quota_exceeded, details}}`
    - `{403, reason}` where `reason in ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"]` -> `{:error, {:rate_limited, details}}`
    - `{429, _}` -> `{:error, {:rate_limited, details}}`
    - `{401, _}` -> `{:error, :invalid_token}`
    - `{status, message}` -> `{:error, {status, message}}`

### 3.2 Typespecs and Request Options
```elixir
@type request_opts :: %{
  optional(:token) => String.t(),
  optional(:api_key) => String.t(),
  optional(:refresh_token) => String.t(),
  optional(:client_id) => String.t(),
  optional(:client_secret) => String.t(),
  optional(:params) => map() | keyword(),
  optional(:json) => map(),
  optional(:body) => term(),
  optional(:headers) => [{String.t(), String.t()}],
  optional(:plug) => {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()),
  optional(:auto_refresh) => boolean(),
  optional(:retry_count) => non_neg_integer()
}

@type client_error ::
  :invalid_token
  | {:token_refresh_failed, term()}
  | {:quota_exceeded, map()}
  | {:rate_limited, map()}
  | {pos_integer(), String.t() | map()}
  | term()
```

### 3.3 Proposed Code Blueprint for `Lux.Integrations.YouTube.Client`
```elixir
defmodule Lux.Integrations.YouTube.Client do
  @moduledoc """
  HTTP client for Google YouTube Data API v3 and Live Streaming API.

  Provides support for:
  - Bearer OAuth 2.0 and API Key authentication
  - Automatic token refresh on 401 Unauthorized with single retry
  - Google API specific error parsing (quotaExceeded, rateLimitExceeded)
  - Plug-based test interception via Req.Test
  """

  require Logger

  @endpoint "https://www.googleapis.com/youtube/v3"

  @type request_opts :: %{
    optional(:token) => String.t(),
    optional(:api_key) => String.t(),
    optional(:refresh_token) => String.t(),
    optional(:client_id) => String.t(),
    optional(:client_secret) => String.t(),
    optional(:params) => map() | keyword(),
    optional(:json) => map(),
    optional(:body) => term(),
    optional(:headers) => [{String.t(), String.t()}],
    optional(:plug) => {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()),
    optional(:auto_refresh) => boolean(),
    optional(:retry_count) => non_neg_integer()
  }

  @doc """
  Makes an HTTP request to the YouTube API.

  ## Parameters
  - `method`: Atom representing HTTP method (`:get`, `:post`, `:put`, `:delete`, `:patch`)
  - `path`: API resource path (e.g. `"/liveBroadcasts"`, `"/liveChat/messages"`)
  - `opts`: Request options map or keyword list

  ## Options
  - `:token`: OAuth 2.0 Access Token (defaults to `Lux.Config.youtube_access_token()`)
  - `:api_key`: YouTube API Key (defaults to `Lux.Config.youtube_api_key()` if no token)
  - `:refresh_token`: OAuth 2.0 Refresh Token (defaults to `Lux.Config.youtube_refresh_token()`)
  - `:client_id`: OAuth 2.0 Client ID (defaults to `Lux.Config.youtube_client_id()`)
  - `:client_secret`: OAuth 2.0 Client Secret (defaults to `Lux.Config.youtube_client_secret()`)
  - `:params`: Query parameters map or keyword list (e.g. `%{part: "snippet", mine: true}`)
  - `:json`: JSON request body map
  - `:headers`: Extra HTTP headers list
  - `:plug`: Plug module/function for testing
  - `:auto_refresh`: Boolean flag to automatically refresh expired tokens on 401 (default `true`)

  ## Returns
  - `{:ok, body}` on 2xx responses
  - `{:error, {:quota_exceeded, details}}` on HTTP 403 quota exceeded
  - `{:error, {:rate_limited, details}}` on HTTP 403/429 rate limit exceeded
  - `{:error, :invalid_token}` on HTTP 401 unauthorized
  - `{:error, {status, message}}` on other API errors
  - `{:error, reason}` on network/transport errors
  """
  @spec request(atom(), String.t(), request_opts() | keyword()) :: {:ok, term()} | {:error, term()}
  def request(method, path, opts \\ %{}) do
    opts_map = normalize_opts(opts)
    auto_refresh = Map.get(opts_map, :auto_refresh, true)
    retry_count = Map.get(opts_map, :retry_count, 0)

    token = resolve_token(opts_map)
    api_key = resolve_api_key(opts_map)

    headers = build_headers(token, opts_map[:headers])
    params = build_params(api_key, token, opts_map[:params])

    req_options =
      [
        method: method,
        url: build_url(path),
        headers: headers,
        params: params,
        json: opts_map[:json]
      ]
      |> maybe_put_body(opts_map[:body])
      |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
      |> maybe_add_plug(opts_map[:plug])

    case Req.new(req_options) |> Req.request() do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response.body}

      {:ok, %{status: 401} = response} ->
        if auto_refresh and retry_count < 1 do
          case attempt_token_refresh(opts_map) do
            {:ok, new_token} ->
              opts_map
              |> Map.put(:token, new_token)
              |> Map.put(:retry_count, retry_count + 1)
              |> request(method, path)

            {:error, _refresh_err} ->
              handle_error_response(response)
          end
        else
          handle_error_response(response)
        end

      {:ok, response} ->
        handle_error_response(response)

      {:error, error} ->
        {:error, error}
    end
  end

  # HTTP verb convenience wrappers
  @spec get(String.t(), request_opts() | keyword()) :: {:ok, term()} | {:error, term()}
  def get(path, opts \\ %{}), do: request(:get, path, opts)

  @spec post(String.t(), request_opts() | keyword()) :: {:ok, term()} | {:error, term()}
  def post(path, opts \\ %{}), do: request(:post, path, opts)

  @spec put(String.t(), request_opts() | keyword()) :: {:ok, term()} | {:error, term()}
  def put(path, opts \\ %{}), do: request(:put, path, opts)

  @spec delete(String.t(), request_opts() | keyword()) :: {:ok, term()} | {:error, term()}
  def delete(path, opts \\ %{}), do: request(:delete, path, opts)

  # Internal helpers
  defp build_url(path) do
    if String.starts_with?(path, "http") do
      path
    else
      @endpoint <> path
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_), do: %{}

  defp resolve_token(opts) do
    cond do
      is_binary(opts[:token]) and opts[:token] != "" -> opts[:token]
      true -> safe_config_access(:youtube_access_token)
    end
  end

  defp resolve_api_key(opts) do
    cond do
      is_binary(opts[:api_key]) and opts[:api_key] != "" -> opts[:api_key]
      true -> safe_config_access(:youtube_api_key)
    end
  end

  defp build_headers(token, extra_headers) do
    base = [{"Content-Type", "application/json"}, {"Accept", "application/json"}]

    base_with_auth =
      if token && token != "" do
        [{"Authorization", "Bearer #{token}"} | base]
      else
        base
      end

    if extra_headers && is_list(extra_headers) do
      base_with_auth ++ extra_headers
    else
      base_with_auth
    end
  end

  defp build_params(api_key, token, params) do
    raw_params =
      cond do
        is_map(params) -> Map.to_list(params)
        is_list(params) -> params
        true -> []
      end

    # If no token is provided and API key is available, add key param
    if (is_nil(token) or token == "") and api_key && api_key != "" do
      if Keyword.has_key?(raw_params, :key) or Keyword.has_key?(raw_params, "key") do
        raw_params
      else
        [{:key, api_key} | raw_params]
      end
    else
      raw_params
    end
  end

  defp maybe_put_body(req_options, nil), do: req_options
  defp maybe_put_body(req_options, body), do: Keyword.put(req_options, :body, body)

  defp maybe_add_plug(options, nil), do: options
  defp maybe_add_plug(options, plug), do: Keyword.put(options, :plug, plug)

  defp attempt_token_refresh(opts) do
    refresh_token = opts[:refresh_token] || safe_config_access(:youtube_refresh_token)
    client_id = opts[:client_id] || safe_config_access(:youtube_client_id)
    client_secret = opts[:client_secret] || safe_config_access(:youtube_client_secret)

    if refresh_token && refresh_token != "" do
      oauth_opts =
        [
          client_id: client_id,
          client_secret: client_secret
        ]
        |> maybe_add_opt(:plug, opts[:plug])

      case Lux.Integrations.YouTube.OAuth.refresh_token(refresh_token, oauth_opts) do
        {:ok, %{"access_token" => new_token}} -> {:ok, new_token}
        {:ok, %{access_token: new_token}} -> {:ok, new_token}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :token_refresh_failed}
      end
    else
      {:error, :no_refresh_token}
    end
  end

  defp maybe_add_opt(keyword, _key, nil), do: keyword
  defp maybe_add_opt(keyword, key, val), do: Keyword.put(keyword, key, val)

  defp handle_error_response(%{status: status, body: %{"error" => error_data}} = _response) do
    errors = error_data["errors"] || []
    first_error = List.first(errors) || %{}
    reason = first_error["reason"]
    message = error_data["message"] || first_error["message"] || "HTTP #{status} error"

    case {status, reason} do
      {401, _} ->
        {:error, :invalid_token}

      {403, "quotaExceeded"} ->
        {:error, {:quota_exceeded, %{status: 403, reason: reason, message: message, errors: errors}}}

      {403, reason} when reason in ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"] ->
        {:error, {:rate_limited, %{status: 403, reason: reason, message: message, errors: errors}}}

      {429, _} ->
        {:error, {:rate_limited, %{status: 429, reason: "tooManyRequests", message: message, errors: errors}}}

      {status, _} ->
        {:error, {status, message}}
    end
  end

  defp handle_error_response(%{status: 401}), do: {:error, :invalid_token}
  defp handle_error_response(%{status: status, body: %{"message" => message}}), do: {:error, {status, message}}
  defp handle_error_response(%{status: status, body: body}) when is_binary(body), do: {:error, {status, body}}
  defp handle_error_response(%{status: status, body: body}), do: {:error, {status, body}}

  defp safe_config_access(func_name) do
    apply(Lux.Config, func_name, [])
  rescue
    _ -> nil
  end
end
```

---

## 4. Design of `Lux.Integrations.YouTube`

### 4.1 Overview & Responsibilities
- High-level integration module compatible with `Lux.Lens` and `Lux.Prism`.
- Exports `request_settings/0`, `headers/0`, `auth/0`, `add_auth_header/1`, and `base_url/0`.
- Seamlessly attaches OAuth Bearer tokens or API keys to lenses and plugs.

### 4.2 Proposed Code Blueprint for `Lux.Integrations.YouTube`
```elixir
defmodule Lux.Integrations.YouTube do
  @moduledoc """
  Common settings and functions for YouTube Data API v3 and Live Streaming integration.
  """

  @doc """
  Returns the base endpoint URL for YouTube Data API v3.
  """
  @spec base_url() :: String.t()
  def base_url, do: "https://www.googleapis.com/youtube/v3"

  @doc """
  Common request settings for YouTube API calls in Lenses.
  """
  @spec request_settings() :: map()
  def request_settings do
    %{
      headers: headers(),
      auth: auth()
    }
  end

  @doc """
  Common default headers for YouTube API calls.
  """
  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end

  @doc """
  Common authentication configuration for YouTube API calls.
  Used by `Lux.Lens` to invoke custom auth injection.
  """
  @spec auth() :: map()
  def auth do
    %{
      type: :custom,
      auth_function: &__MODULE__.add_auth_header/1
    }
  end

  @doc """
  Adds YouTube authorization credentials to a `Lux.Lens` struct.
  Prioritizes Bearer token header; falls back to `:key` query parameter if API key configured.
  """
  @spec add_auth_header(Lux.Lens.t()) :: Lux.Lens.t()
  def add_auth_header(%Lux.Lens{} = lens) do
    token =
      try do
        Lux.Config.youtube_access_token()
      rescue
        _ -> nil
      end

    if token && token != "" do
      %{lens | headers: lens.headers ++ [{"Authorization", "Bearer #{token}"}]}
    else
      api_key =
        try do
          Lux.Config.youtube_api_key()
        rescue
          _ -> nil
        end

      if api_key && api_key != "" do
        %{lens | params: Map.put(lens.params, :key, api_key)}
      else
        lens
      end
    end
  end

  @doc """
  Adds YouTube authorization credentials to a `Plug.Conn` struct.
  """
  @spec add_auth_header(Plug.Conn.t()) :: Plug.Conn.t()
  def add_auth_header(%Plug.Conn{} = conn) do
    token =
      try do
        Lux.Config.youtube_access_token()
      rescue
        _ -> nil
      end

    if token && token != "" do
      Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
    else
      conn
    end
  end
end
```

---

## 5. Configuration Architecture (`Lux.Config` & `runtime.exs`)

### 5.1 `Lux.Config` Additions
Add the following functions to `lib/lux/config.ex`:
```elixir
  @doc """
  Gets the YouTube OAuth Client ID from configuration.
  Raises if the key is not configured.
  """
  @spec youtube_client_id() :: api_key()
  def youtube_client_id do
    get_required_key(:api_keys, :youtube_client_id)
  end

  @doc """
  Gets the YouTube OAuth Client Secret from configuration.
  Raises if the key is not configured.
  """
  @spec youtube_client_secret() :: api_key()
  def youtube_client_secret do
    get_required_key(:api_keys, :youtube_client_secret)
  end

  @doc """
  Gets the YouTube Data API Key from configuration.
  Raises if the key is not configured.
  """
  @spec youtube_api_key() :: api_key()
  def youtube_api_key do
    get_required_key(:api_keys, :youtube_api_key)
  end

  @doc """
  Gets the configured YouTube OAuth Access Token.
  Returns nil if not configured.
  """
  @spec youtube_access_token() :: api_key() | nil
  def youtube_access_token do
    get_optional_key(:api_keys, :youtube_access_token)
  end

  @doc """
  Gets the configured YouTube OAuth Refresh Token.
  Returns nil if not configured.
  """
  @spec youtube_refresh_token() :: api_key() | nil
  def youtube_refresh_token do
    get_optional_key(:api_keys, :youtube_refresh_token)
  end

  defp get_optional_key(group, key) do
    case Application.fetch_env(:lux, group) do
      {:ok, config} when is_list(config) -> Keyword.get(config, key)
      _ -> nil
    end
  end
```

### 5.2 `config/runtime.exs` Additions
In `config/runtime.exs`, inside the `if config_env() in [:dev, :test]` block under `config :lux, :api_keys`:
```elixir
    youtube_client_id: env!("YOUTUBE_CLIENT_ID", :string!, required: false),
    youtube_client_secret: env!("YOUTUBE_CLIENT_SECRET", :string!, required: false),
    youtube_api_key: env!("YOUTUBE_API_KEY", :string!, required: false),
    youtube_access_token: env!("YOUTUBE_ACCESS_TOKEN", :string!, required: false),
    youtube_refresh_token: env!("YOUTUBE_REFRESH_TOKEN", :string!, required: false),
```

---

## 6. `Req.Test` Mocking Architecture & Test Strategy

### 6.1 `test/test_helper.exs` Integration
In `UnitAPICase`:
1. Alias `Lux.Integrations.YouTube.Client, as: YouTubeClient` and `Lux.Integrations.YouTube.OAuth, as: YouTubeOAuth`.
2. In `setup`, register default plug mocks:
   ```elixir
   Application.put_env(:lux, YouTubeClient, plug: {Req.Test, YouTubeClientMock})
   Application.put_env(:lux, YouTubeOAuth, plug: {Req.Test, YouTubeOAuthMock})
   ```

### 6.2 Test Matrix for `test/unit/lux/integrations/youtube/client_test.exs`
The unit tests must thoroughly cover every code branch with zero network calls:

| Test Case | Scenario | Verification |
|-----------|----------|--------------|
| `test_get_with_bearer_token` | GET `/liveBroadcasts` with `token: "test_token"` | Asserts GET method, `/youtube/v3/liveBroadcasts` path, `Authorization: Bearer test_token` header, decodes JSON |
| `test_post_with_json_body` | POST `/liveBroadcasts` with `json: %{snippet: ...}` | Asserts POST method, JSON payload parsed correctly, returns 200 response |
| `test_put_and_delete` | PUT `/liveBroadcasts` and DELETE `/liveBroadcasts?id=123` | Asserts PUT and DELETE HTTP verbs |
| `test_query_params` | GET with `params: %{part: "snippet,status", mine: true}` | Asserts query params appended correctly |
| `test_api_key_fallback` | No Bearer token provided, `api_key: "my_key"` | Asserts `key=my_key` appended to query params |
| `test_auto_refresh_on_401_success` | Initial request yields 401; `OAuth.refresh_token` returns new token; retry succeeds | Intercepts 401, verifies OAuth refresh call, asserts request retried with new Bearer token and returns 200 |
| `test_auto_refresh_on_401_failure` | Initial request yields 401; `OAuth.refresh_token` fails | Returns `{:error, :invalid_token}` without infinite looping |
| `test_auto_refresh_disabled` | Request with `auto_refresh: false` yields 401 | Returns `{:error, :invalid_token}` immediately without calling refresh |
| `test_quota_exceeded_403` | Google returns 403 `quotaExceeded` JSON | Returns `{:error, {:quota_exceeded, %{reason: "quotaExceeded", status: 403, ...}}}` |
| `test_rate_limited_403_and_429` | Google returns `userRateLimitExceeded` or 429 | Returns `{:error, {:rate_limited, ...}}` |
| `test_generic_error_handling` | Returns 404 liveBroadcastNotFound or 500 | Returns `{:error, {status, message}}` |
| `test_custom_plug_isolation` | Pass `plug: {Req.Test, __MODULE__}` in opts | Asserts request routed to custom plug |

### 6.3 Test Matrix for `test/unit/lux/integrations/youtube_test.exs`
- `headers/0`: Asserts `Content-Type: application/json` and `Accept: application/json`.
- `auth/0`: Asserts `%{type: :custom, auth_function: ...}`.
- `request_settings/0`: Asserts combined headers and auth map.
- `add_auth_header/1` with `%Lux.Lens{}`: Verifies Bearer header addition and API key param addition.
- `add_auth_header/1` with `%Plug.Conn{}`: Verifies `authorization` header addition.
- `base_url/0`: Asserts `"https://www.googleapis.com/youtube/v3"`.

---

## 7. Implementation Guidelines for Implementer Worker

1. **Step 1: Configuration**:
   - Update `lib/lux/config.ex` with YouTube getters.
   - Update `config/runtime.exs` with YouTube environment variables.
2. **Step 2: Core Integration Module**:
   - Implement `lib/lux/integrations/youtube.ex`.
3. **Step 3: YouTube Client**:
   - Implement `lib/lux/integrations/youtube/client.ex`.
4. **Step 4: Test Infrastructure & Helper**:
   - Update `test/test_helper.exs` with `YouTubeClient` and `YouTubeOAuth` mocks.
5. **Step 5: Unit Test Suites**:
   - Implement `test/unit/lux/integrations/youtube/client_test.exs`.
   - Implement `test/unit/lux/integrations/youtube_test.exs`.
6. **Step 6: Verification**:
   - Run `mix test test/unit/lux/integrations/youtube/`
   - Run `mix compile --warnings-as-errors`
   - Ensure clean compilation and 100% test pass rate.
