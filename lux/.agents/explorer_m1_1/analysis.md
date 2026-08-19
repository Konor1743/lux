# Deep Investigation & Architectural Design: Google OAuth 2.0 for YouTube API

**Agent**: Explorer 1 (Milestone 1)  
**Target Module**: `Lux.Integrations.YouTube.OAuth`  
**Related Modules**: `Lux.Config`, `Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube`  
**Date**: 2026-08-17  

---

## 1. Executive Summary

This report establishes the complete specification and design for Google OAuth 2.0 authentication within the Lux framework for YouTube API and YouTube Live Streaming capabilities.

Google OAuth 2.0 uses standard authorization code grant flow with offline access to acquire long-lived `refresh_token`s and short-lived `access_token`s (valid for 3600 seconds). The `Lux.Integrations.YouTube.OAuth` module handles URL generation, authorization code exchange, and token refresh using `Req`. It fully supports isolated unit testing via `Req.Test` plug injection.

---

## 2. Google OAuth 2.0 Architecture & Protocol Specification

### 2.1 Protocol Flow

```
+-------------+                                +--------------------+
|  End User   |                                |  Google Auth Srv   |
+------+------+                                +---------+----------+
       | 1. Visit authorize_url                           |
       |------------------------------------------------>|
       | 2. User consents & authorizes scopes             |
       |                                                 |
       | 3. Redirect back with code                      |
       |<------------------------------------------------|
       |
+------v------+                                +--------------------+
| Lux App /   | 4. exchange_code(code, opts)   | Google Token Srv   |
| OAuth Module|------------------------------->| oauth2.googleapis  |
+------+------+                                +---------+----------+
       | 5. Return access_token & refresh_token          |
       |<------------------------------------------------|
       |
       | 6. API call with Bearer <access_token>          | YouTube Data API v3
       |------------------------------------------------>|
       |
       | 7. On 401 / Expiry: refresh_token(token, opts)  |
       |------------------------------------------------>|
       | 8. Return new access_token                      |
       |<------------------------------------------------|
```

### 2.2 Exact Endpoints

| Purpose | URL Endpoint | HTTP Method | Content-Type |
|---|---|---|---|
| **Authorization URL** | `https://accounts.google.com/o/oauth2/v2/auth` | `GET` | N/A (Browser redirect) |
| **Token Exchange & Refresh** | `https://oauth2.googleapis.com/token` | `POST` | `application/x-www-form-urlencoded` |
| **Token Revocation** *(optional)* | `https://oauth2.googleapis.com/revoke` | `POST` | `application/x-www-form-urlencoded` |

### 2.3 Required Scopes for YouTube & Live Streaming

Google requires specific OAuth scopes depending on the YouTube operations being performed:

1. **`https://www.googleapis.com/auth/youtube`** (Full Management):
   - Required for creating, updating, binding, and transitioning Live Broadcasts and Live Streams.
   - Required for managing channel assets and streaming infrastructure.
2. **`https://www.googleapis.com/auth/youtube.force-ssl`** (SSL/Secure Management):
   - Required for reading and writing YouTube Live Chat messages (`liveChatMessages` endpoint), live chat moderation, and comments.
3. **`https://www.googleapis.com/auth/youtube.readonly`** (Read-Only Access):
   - Useful for inspecting broadcasts, streams, and channel details without write permissions.

**Default Scope Set**:
`["https://www.googleapis.com/auth/youtube", "https://www.googleapis.com/auth/youtube.force-ssl", "https://www.googleapis.com/auth/youtube.readonly"]`

When passed to Google, scopes must be joined by a single space character (`" "`).

---

## 3. Detailed Specification of `Lux.Integrations.YouTube.OAuth`

### 3.1 Function Specifications

#### 1. `authorize_url(opts \\ %{}) :: String.t()`
Generates the Google OAuth 2.0 authorization URL for redirecting users or initiating consent.

- **Options (`opts`)**:
  - `:client_id` (string) — Google OAuth 2.0 Client ID (default: `Lux.Config.youtube_client_id()` or nil).
  - `:redirect_uri` (string) — Callback URL (default: `Lux.Config.youtube_redirect_uri()` or `"http://localhost:4000/oauth/callback"`).
  - `:scope` (list or string) — List of scopes or space-delimited string (default: all 3 YouTube scopes).
  - `:response_type` (string) — Defaults to `"code"`.
  - `:access_type` (string) — Defaults to `"offline"` (critical to receive `refresh_token`).
  - `:prompt` (string) — Defaults to `"consent"` (forces consent screen to ensure `refresh_token` issuance).
  - `:state` (string, optional) — Anti-CSRF token or state payload.
  - `:include_granted_scopes` (string or boolean, optional) — e.g. `"true"`.
  - `:login_hint` (string, optional) — Pre-fill email.

- **Query Param Construction**:
  Uses `URI.encode_query/1` or `URI.new!` to safely assemble query parameters.

- **Example Output**:
  ```
  https://accounts.google.com/o/oauth2/v2/auth?access_type=offline&client_id=CLIENT_ID&prompt=consent&redirect_uri=http%3A%2F%2Flocalhost%3A4000%2Foauth%2Fcallback&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube.force-ssl+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube.readonly
  ```

---

#### 2. `exchange_code(code, opts \\ %{}) :: {:ok, token_map()} | {:error, term()}`
Exchanges an authorization code obtained from the redirect for an access token and refresh token.

- **Parameters**:
  - `code` (string, required) — The authorization code returned by Google.
  - `opts` (map or keyword list) — Options containing:
    - `:client_id` — Client ID (fallback to `Lux.Config.youtube_client_id()`).
    - `:client_secret` — Client secret (fallback to `Lux.Config.youtube_client_secret()`).
    - `:redirect_uri` — Redirect URI (fallback to `Lux.Config.youtube_redirect_uri()`).
    - `:plug` — Req plug for testing (e.g. `{Req.Test, Lux.Integrations.YouTube.OAuthMock}`).

- **Request Body (Form URL-encoded)**:
  ```elixir
  %{
    "code" => code,
    "client_id" => client_id,
    "client_secret" => client_secret,
    "redirect_uri" => redirect_uri,
    "grant_type" => "authorization_code"
  }
  ```

- **Successful Response (200 OK)**:
  ```elixir
  {:ok, %{
    "access_token" => "ya29.a0AfH6...",
    "expires_in" => 3599,
    "refresh_token" => "1//04...",
    "scope" => "https://www.googleapis.com/auth/youtube https://www.googleapis.com/auth/youtube.force-ssl",
    "token_type" => "Bearer"
  }}
  ```

- **Error Responses**:
  - Google error JSON (`status: 400/401`): `{:error, {:oauth_error, %{"error" => "invalid_grant", "error_description" => "Bad Request"}}}`
  - Missing credentials: `{:error, :missing_credentials}`
  - Network transport errors: `{:error, term()}`

---

#### 3. `refresh_token(refresh_token, opts \\ %{}) :: {:ok, token_map()} | {:error, term()}`
Refreshes an expired access token using a valid `refresh_token`.

- **Parameters**:
  - `refresh_token` (string, required) — The Google OAuth refresh token.
  - `opts` (map or keyword list) — Options containing:
    - `:client_id` — Client ID (fallback to `Lux.Config.youtube_client_id()`).
    - `:client_secret` — Client secret (fallback to `Lux.Config.youtube_client_secret()`).
    - `:plug` — Req plug for testing.

- **Request Body (Form URL-encoded)**:
  ```elixir
  %{
    "client_id" => client_id,
    "client_secret" => client_secret,
    "grant_type" => "refresh_token",
    "refresh_token" => refresh_token
  }
  ```

- **Successful Response (200 OK)**:
  ```elixir
  {:ok, %{
    "access_token" => "ya29.a0AfH6...",
    "expires_in" => 3599,
    "scope" => "https://www.googleapis.com/auth/youtube ...",
    "token_type" => "Bearer"
  }}
  ```

- **Error Responses**:
  - Google error JSON: `{:error, {:oauth_error, %{"error" => "invalid_grant", "error_description" => "Token has been expired or revoked."}}}`
  - Missing credentials: `{:error, :missing_credentials}`
  - Network transport errors: `{:error, term()}`

---

## 4. Code Structure & Proposed Implementation

### 4.1 Module: `Lux.Integrations.YouTube.OAuth` (`lib/lux/integrations/youtube/oauth.ex`)

```elixir
defmodule Lux.Integrations.YouTube.OAuth do
  @moduledoc """
  OAuth 2.0 authentication client for Google & YouTube APIs.

  Handles authorization URL generation, exchanging authorization codes for access/refresh
  tokens, and refreshing expired access tokens.
  """

  require Logger

  @auth_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"

  @scope_youtube "https://www.googleapis.com/auth/youtube"
  @scope_youtube_force_ssl "https://www.googleapis.com/auth/youtube.force-ssl"
  @scope_youtube_readonly "https://www.googleapis.com/auth/youtube.readonly"

  @default_scopes [
    @scope_youtube,
    @scope_youtube_force_ssl,
    @scope_youtube_readonly
  ]

  @type token_map :: %{
          required(String.t()) => term()
        }

  @type oauth_opts :: %{
          optional(:client_id) => String.t(),
          optional(:client_secret) => String.t(),
          optional(:redirect_uri) => String.t(),
          optional(:scope) => [String.t()] | String.t(),
          optional(:state) => String.t(),
          optional(:access_type) => String.t(),
          optional(:prompt) => String.t(),
          optional(:response_type) => String.t(),
          optional(:plug) => {module(), term()}
        } | Keyword.t()

  @doc """
  Returns the default YouTube OAuth scopes.
  """
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @doc """
  Generates the Google OAuth 2.0 authorization URL.
  """
  @spec authorize_url(oauth_opts()) :: String.t()
  def authorize_url(opts \\ %{}) do
    opts_map = to_map(opts)

    client_id = opts_map[:client_id] || get_config(:youtube_client_id)
    redirect_uri = opts_map[:redirect_uri] || get_config(:youtube_redirect_uri, "http://localhost:4000/oauth/callback")
    scope = format_scope(opts_map[:scope] || @default_scopes)
    response_type = opts_map[:response_type] || "code"
    access_type = opts_map[:access_type] || "offline"
    prompt = opts_map[:prompt] || "consent"

    params =
      %{
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => response_type,
        "scope" => scope,
        "access_type" => access_type,
        "prompt" => prompt
      }
      |> maybe_put("state", opts_map[:state])
      |> maybe_put("include_granted_scopes", opts_map[:include_granted_scopes])
      |> maybe_put("login_hint", opts_map[:login_hint])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> URI.encode_query()

    @auth_endpoint <> "?" <> params
  end

  @doc """
  Exchanges an authorization code for access and refresh tokens.
  """
  @spec exchange_code(String.t(), oauth_opts()) :: {:ok, token_map()} | {:error, term()}
  def exchange_code(code, opts \\ %{}) when is_binary(code) do
    opts_map = to_map(opts)

    client_id = opts_map[:client_id] || get_config(:youtube_client_id)
    client_secret = opts_map[:client_secret] || get_config(:youtube_client_secret)
    redirect_uri = opts_map[:redirect_uri] || get_config(:youtube_redirect_uri, "http://localhost:4000/oauth/callback")

    if is_nil(client_id) or is_nil(client_secret) do
      {:error, :missing_credentials}
    else
      form_body = %{
        "code" => code,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "redirect_uri" => redirect_uri,
        "grant_type" => "authorization_code"
      }

      execute_token_request(form_body, opts_map)
    end
  end

  @doc """
  Refreshes an access token using a refresh token.
  """
  @spec refresh_token(String.t(), oauth_opts()) :: {:ok, token_map()} | {:error, term()}
  def refresh_token(refresh_token, opts \\ %{}) when is_binary(refresh_token) do
    opts_map = to_map(opts)

    client_id = opts_map[:client_id] || get_config(:youtube_client_id)
    client_secret = opts_map[:client_secret] || get_config(:youtube_client_secret)

    if is_nil(client_id) or is_nil(client_secret) do
      {:error, :missing_credentials}
    else
      form_body = %{
        "client_id" => client_id,
        "client_secret" => client_secret,
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      }

      execute_token_request(form_body, opts_map)
    end
  end

  # Private Helpers

  defp execute_token_request(form_body, opts) do
    [
      method: :post,
      url: @token_endpoint,
      form: form_body,
      headers: [{"accept", "application/json"}]
    ]
    |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
    |> maybe_add_plug(opts[:plug])
    |> Req.new()
    |> Req.request()
    |> handle_token_response()
  end

  defp handle_token_response({:ok, %{status: 200, body: body}}) when is_map(body) do
    {:ok, body}
  end

  defp handle_token_response({:ok, %{status: status, body: %{"error" => error} = body}}) do
    description = body["error_description"]
    {:error, {:oauth_error, error, description || status}}
  end

  defp handle_token_response({:ok, %{status: status, body: body}}) do
    {:error, {status, body}}
  end

  defp handle_token_response({:error, error}) do
    {:error, error}
  end

  defp format_scope(scopes) when is_list(scopes), do: Enum.join(scopes, " ")
  defp format_scope(scope) when is_binary(scope), do: scope

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))

  defp maybe_add_plug(options, nil), do: options
  defp maybe_add_plug(options, plug), do: Keyword.put(options, :plug, plug)

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)

  defp get_config(key, default \\ nil) do
    case key do
      :youtube_client_id ->
        try do
          Lux.Config.youtube_client_id()
        rescue
          _ -> default
        end

      :youtube_client_secret ->
        try do
          Lux.Config.youtube_client_secret()
        rescue
          _ -> default
        end

      :youtube_redirect_uri ->
        try do
          Lux.Config.youtube_redirect_uri()
        rescue
          _ -> default
        end

      _ ->
        default
    end
  end
end
```

---

## 5. Configuration Strategy (`Lux.Config` & `runtime.exs`)

### 5.1 Additions to `lib/lux/config.ex`

```elixir
  @doc """
  Gets the YouTube Client ID from configuration.
  Raises if the key is not configured.
  """
  @spec youtube_client_id() :: api_key()
  def youtube_client_id do
    get_required_key(:api_keys, :youtube_client_id)
  end

  @doc """
  Gets the YouTube Client Secret from configuration.
  Raises if the key is not configured.
  """
  @spec youtube_client_secret() :: api_key()
  def youtube_client_secret do
    get_required_key(:api_keys, :youtube_client_secret)
  end

  @doc """
  Gets the YouTube Redirect URI from configuration.
  Returns default if not configured.
  """
  @spec youtube_redirect_uri() :: String.t()
  def youtube_redirect_uri do
    :lux
    |> Application.fetch_env!(:api_keys)
    |> Keyword.get(:youtube_redirect_uri, "http://localhost:4000/oauth/callback")
  end

  @doc """
  Gets the YouTube Refresh Token from configuration.
  Raises if not configured.
  """
  @spec youtube_refresh_token() :: api_key()
  def youtube_refresh_token do
    get_required_key(:api_keys, :youtube_refresh_token)
  end

  @doc """
  Gets the YouTube API Key (public data key) from configuration.
  Raises if not configured.
  """
  @spec youtube_api_key() :: api_key()
  def youtube_api_key do
    get_required_key(:api_keys, :youtube_api_key)
  end
```

### 5.2 Environment Variables in `config/runtime.exs`

```elixir
  config :lux, :api_keys,
    # ... existing keys ...
    youtube_client_id: env!("YOUTUBE_CLIENT_ID", :string!, required: false),
    youtube_client_secret: env!("YOUTUBE_CLIENT_SECRET", :string!, required: false),
    youtube_redirect_uri: env!("YOUTUBE_REDIRECT_URI", :string!, "http://localhost:4000/oauth/callback"),
    youtube_refresh_token: env!("YOUTUBE_REFRESH_TOKEN", :string!, required: false),
    youtube_api_key: env!("YOUTUBE_API_KEY", :string!, required: false),
    integration_youtube_client_id: env!("INTEGRATION_YOUTUBE_CLIENT_ID", :string!, required: false),
    integration_youtube_client_secret: env!("INTEGRATION_YOUTUBE_CLIENT_SECRET", :string!, required: false),
    integration_youtube_refresh_token: env!("INTEGRATION_YOUTUBE_REFRESH_TOKEN", :string!, required: false)
```

---

## 6. Testing Strategy & `Req.Test` Mocking

### 6.1 Unit Test Template (`test/unit/lux/integrations/youtube/oauth_test.exs`)

```elixir
defmodule Lux.Integrations.YouTube.OAuthTest do
  use UnitAPICase, async: true

  alias Lux.Integrations.YouTube.OAuth

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "authorize_url/1" do
    test "generates standard authorization URL with default scopes" do
      url =
        OAuth.authorize_url(%{
          client_id: "test-client-id",
          redirect_uri: "https://example.com/oauth/callback",
          state: "xyz123"
        })

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert uri.scheme == "https"
      assert uri.host == "accounts.google.com"
      assert uri.path == "/o/oauth2/v2/auth"
      assert query["client_id"] == "test-client-id"
      assert query["redirect_uri"] == "https://example.com/oauth/callback"
      assert query["response_type"] == "code"
      assert query["access_type"] == "offline"
      assert query["prompt"] == "consent"
      assert query["state"] == "xyz123"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube.force-ssl"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube.readonly"
    end

    test "allows custom scopes as list or string" do
      url =
        OAuth.authorize_url(%{
          client_id: "test-client-id",
          scope: ["https://www.googleapis.com/auth/youtube.readonly"]
        })

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      assert query["scope"] == "https://www.googleapis.com/auth/youtube.readonly"
    end
  end

  describe "exchange_code/2" do
    test "successfully exchanges code for tokens" do
      Req.Test.expect(Lux.Integrations.YouTube.OAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert conn.method == "POST"
        assert conn.request_path == "/token"
        assert params["code"] == "auth_code_123"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"
        assert params["grant_type"] == "authorization_code"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "ya29.mock_access_token",
            "expires_in" => 3599,
            "refresh_token" => "1//04mock_refresh_token",
            "scope" => "https://www.googleapis.com/auth/youtube",
            "token_type" => "Bearer"
          })
        )
      end)

      opts = %{
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        redirect_uri: "http://localhost:4000/callback",
        plug: {Req.Test, Lux.Integrations.YouTube.OAuthMock}
      }

      assert {:ok, result} = OAuth.exchange_code("auth_code_123", opts)
      assert result["access_token"] == "ya29.mock_access_token"
      assert result["refresh_token"] == "1//04mock_refresh_token"
      assert result["expires_in"] == 3599
    end

    test "handles error response from Google" do
      Req.Test.expect(Lux.Integrations.YouTube.OAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Bad Request"
          })
        )
      end)

      opts = %{
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        plug: {Req.Test, Lux.Integrations.YouTube.OAuthMock}
      }

      assert {:error, {:oauth_error, "invalid_grant", "Bad Request"}} =
               OAuth.exchange_code("invalid_code", opts)
    end
  end

  describe "refresh_token/2" do
    test "successfully refreshes access token" do
      Req.Test.expect(Lux.Integrations.YouTube.OAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert conn.method == "POST"
        assert conn.request_path == "/token"
        assert params["refresh_token"] == "valid_refresh_token"
        assert params["grant_type"] == "refresh_token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "ya29.new_access_token",
            "expires_in" => 3599,
            "scope" => "https://www.googleapis.com/auth/youtube",
            "token_type" => "Bearer"
          })
        )
      end)

      opts = %{
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        plug: {Req.Test, Lux.Integrations.YouTube.OAuthMock}
      }

      assert {:ok, result} = OAuth.refresh_token("valid_refresh_token", opts)
      assert result["access_token"] == "ya29.new_access_token"
      assert result["expires_in"] == 3599
    end

    test "handles revoked refresh token" do
      Req.Test.expect(Lux.Integrations.YouTube.OAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Token has been expired or revoked."
          })
        )
      end)

      opts = %{
        client_id: "test_client_id",
        client_secret: "test_client_secret",
        plug: {Req.Test, Lux.Integrations.YouTube.OAuthMock}
      }

      assert {:error, {:oauth_error, "invalid_grant", "Token has been expired or revoked."}} =
               OAuth.refresh_token("revoked_refresh_token", opts)
    end
  end
end
```

### 6.2 Test Helper Registration

In `test/test_helper.exs`:
```elixir
Application.put_env(:lux, Lux.Integrations.YouTube.OAuth, plug: {Req.Test, Lux.Integrations.YouTube.OAuthMock})
```

---

## 7. Actionable Implementation Checklist for Implementer

1. **`lib/lux/config.ex`**:
   - Add `youtube_client_id/0`, `youtube_client_secret/0`, `youtube_redirect_uri/0`, `youtube_refresh_token/0`, `youtube_api_key/0`.
2. **`config/runtime.exs`**:
   - Add environment variables with safe defaults or optional parsing (`required: false`).
3. **`lib/lux/integrations/youtube/oauth.ex`**:
   - Implement `Lux.Integrations.YouTube.OAuth` following the design in Section 4.1.
4. **`test/test_helper.exs`**:
   - Add `Lux.Integrations.YouTube.OAuth` mock configuration in `UnitAPICase` setup block.
5. **`test/unit/lux/integrations/youtube/oauth_test.exs`**:
   - Implement full test suite covering URL generation, custom scopes, state param, code exchange success & errors, and token refresh success & errors.
6. **Compile & Verification**:
   - Run `mix compile --warnings-as-errors`
   - Run `mix test test/unit/lux/integrations/youtube/oauth_test.exs`

---
