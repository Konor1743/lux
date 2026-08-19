defmodule Lux.Integrations.YouTube.Client do
  @moduledoc """
  HTTP client for Google YouTube Data API v3 and Live Streaming API.

  Provides support for:
  - Bearer OAuth 2.0 and API Key authentication
  - Automatic token refresh on 401 Unauthorized with single retry
  - Google API specific error parsing via `Lux.Integrations.YouTube.Errors`
  - Plug-based test interception via `Req.Test`
  """

  require Logger

  alias Lux.Integrations.YouTube.Errors
  alias Lux.Integrations.YouTube.OAuth

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
  - `:body`: Raw request body
  - `:headers`: Extra HTTP headers list
  - `:plug`: Plug module/function for testing
  - `:auto_refresh`: Boolean flag to automatically refresh expired tokens on 401 (default `true`)
  - `:retry_count`: Internal counter for retries (default 0)

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
        json: opts_map[:json],
        retry: Map.get(opts_map, :retry, false)
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
              new_opts =
                opts_map
                |> Map.put(:token, new_token)
                |> Map.put(:retry_count, retry_count + 1)

              request(method, path, new_opts)

            {:error, _refresh_err} ->
              Errors.parse(response)
          end
        else
          Errors.parse(response)
        end

      {:ok, %{status: status, body: body, headers: headers}} ->
        Errors.parse(status, body, headers)

      {:ok, response} ->
        Errors.parse(response)

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
  defp build_url(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
        path

      path == "" ->
        @endpoint

      String.starts_with?(path, "/") ->
        @endpoint <> path

      true ->
        @endpoint <> "/" <> path
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
    base = [{"content-type", "application/json"}, {"accept", "application/json"}]

    base_with_auth =
      if token && token != "" do
        [{"authorization", "Bearer #{token}"} | base]
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
      has_key =
        Enum.any?(raw_params, fn
          {:key, _} -> true
          {"key", _} -> true
          _ -> false
        end)

      if has_key do
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
        %{
          client_id: client_id,
          client_secret: client_secret
        }
        |> maybe_add_opt(:plug, opts[:plug])

      case OAuth.refresh_token(refresh_token, oauth_opts) do
        {:ok, %{"access_token" => new_token}} when is_binary(new_token) ->
          {:ok, new_token}

        {:ok, %{access_token: new_token}} when is_binary(new_token) ->
          {:ok, new_token}

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :token_refresh_failed}
      end
    else
      {:error, :no_refresh_token}
    end
  end

  defp maybe_add_opt(map, _key, nil), do: map
  defp maybe_add_opt(map, key, val), do: Map.put(map, key, val)

  defp safe_config_access(func_name) do
    apply(Lux.Config, func_name, [])
  rescue
    _ -> nil
  end
end
