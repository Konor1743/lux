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
  Adds YouTube authorization credentials to a `Lux.Lens` or `Plug.Conn` struct.
  Prioritizes Bearer token header; falls back to `:key` query parameter if API key is configured.
  """
  @spec add_auth_header(Lux.Lens.t() | Plug.Conn.t()) :: Lux.Lens.t() | Plug.Conn.t()
  def add_auth_header(%Lux.Lens{} = lens) do
    token =
      try do
        Lux.Config.youtube_access_token()
      rescue
        _ -> nil
      end

    if token && token != "" do
      existing_headers = lens.headers || []
      %{lens | headers: existing_headers ++ [{"Authorization", "Bearer #{token}"}]}
    else
      api_key =
        try do
          Lux.Config.youtube_api_key()
        rescue
          _ -> nil
        end

      if api_key && api_key != "" do
        params =
          cond do
            is_map(lens.params) -> Map.put(lens.params, :key, api_key)
            is_list(lens.params) -> Keyword.put(lens.params, :key, api_key)
            true -> %{key: api_key}
          end

        %{lens | params: params}
      else
        lens
      end
    end
  end

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
