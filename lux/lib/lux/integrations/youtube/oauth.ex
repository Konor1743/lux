defmodule Lux.Integrations.YouTube.OAuth do
  @moduledoc """
  OAuth 2.0 authentication client for Google and YouTube APIs.

  Handles authorization URL generation, exchanging authorization codes for access/refresh
  tokens, and refreshing expired access tokens using Req.
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
          optional(:include_granted_scopes) => String.t() | boolean(),
          optional(:login_hint) => String.t(),
          optional(:plug) => {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t())
        } | Keyword.t()

  @doc """
  Returns the default YouTube OAuth scopes.
  """
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @doc """
  Generates the Google OAuth 2.0 authorization URL.

  ## Options
  - `:client_id` - Google OAuth 2.0 Client ID (defaults to `Lux.Config.youtube_client_id()`)
  - `:redirect_uri` - Callback redirect URL (defaults to `Lux.Config.youtube_redirect_uri()`)
  - `:scope` - List of scopes or space-delimited string (defaults to `@default_scopes`)
  - `:response_type` - Response type (defaults to `"code"`)
  - `:access_type` - Access type (defaults to `"offline"`)
  - `:prompt` - Consent prompt (defaults to `"consent"`)
  - `:state` - State token for CSRF protection
  - `:include_granted_scopes` - Incremental authorization flag
  - `:login_hint` - Pre-fill user email/ID
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

  ## Options
  - `:client_id` - Google OAuth Client ID
  - `:client_secret` - Google OAuth Client Secret
  - `:redirect_uri` - Callback redirect URI
  - `:plug` - Req plug for testing
  """
  @spec exchange_code(String.t(), oauth_opts()) :: {:ok, token_map()} | {:error, term()}
  def exchange_code(code, opts \\ %{}) when is_binary(code) do
    opts_map = to_map(opts)

    client_id = opts_map[:client_id] || get_config(:youtube_client_id)
    client_secret = opts_map[:client_secret] || get_config(:youtube_client_secret)
    redirect_uri = opts_map[:redirect_uri] || get_config(:youtube_redirect_uri, "http://localhost:4000/oauth/callback")

    if is_nil(client_id) or client_id == "" or is_nil(client_secret) or client_secret == "" do
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

  ## Options
  - `:client_id` - Google OAuth Client ID
  - `:client_secret` - Google OAuth Client Secret
  - `:plug` - Req plug for testing
  """
  @spec refresh_token(String.t(), oauth_opts()) :: {:ok, token_map()} | {:error, term()}
  def refresh_token(refresh_token, opts \\ %{}) when is_binary(refresh_token) do
    opts_map = to_map(opts)

    client_id = opts_map[:client_id] || get_config(:youtube_client_id)
    client_secret = opts_map[:client_secret] || get_config(:youtube_client_secret)

    if is_nil(client_id) or client_id == "" or is_nil(client_secret) or client_secret == "" do
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

  defp handle_token_response({:ok, %{status: 200, body: body}}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, body}
    end
  end

  defp handle_token_response({:ok, %{status: _status, body: %{"error" => %{"message" => message}}}}) do
    {:error, {:oauth_error, "error", message}}
  end

  defp handle_token_response({:ok, %{status: _status, body: %{"error" => error} = body}}) when is_binary(error) do
    description = body["error_description"] || error
    {:error, {:oauth_error, error, description}}
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
  defp to_map(_), do: %{}

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
