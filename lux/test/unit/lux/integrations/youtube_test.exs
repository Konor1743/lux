defmodule Lux.Integrations.YouTubeTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube

  setup do
    orig_keys = Application.get_env(:lux, :api_keys, [])

    on_exit(fn ->
      Application.put_env(:lux, :api_keys, orig_keys)
    end)

    :ok
  end

  describe "common YouTube integration helpers" do
    test "base_url returns YouTube v3 endpoint" do
      assert YouTube.base_url() == "https://www.googleapis.com/youtube/v3"
    end

    test "headers returns standard JSON headers" do
      headers = YouTube.headers()
      assert {"Content-Type", "application/json"} in headers
      assert {"Accept", "application/json"} in headers
    end

    test "auth configuration returns custom auth function" do
      auth = YouTube.auth()
      assert auth.type == :custom
      assert is_function(auth.auth_function, 1)
    end

    test "request_settings returns map with headers and auth" do
      settings = YouTube.request_settings()
      assert is_list(settings.headers)
      assert settings.auth.type == :custom
    end
  end

  describe "add_auth_header/1 with Lux.Lens" do
    test "injects Bearer token header when access token is configured" do
      Application.put_env(:lux, :api_keys, youtube_access_token: "test_access_token_123")

      lens = %Lux.Lens{
        name: "TestLens",
        url: "https://www.googleapis.com/youtube/v3/liveBroadcasts",
        headers: [{"x-custom", "true"}],
        params: %{}
      }

      updated = YouTube.add_auth_header(lens)
      assert {"Authorization", "Bearer test_access_token_123"} in updated.headers
      assert {"x-custom", "true"} in updated.headers
    end

    test "handles nil headers when token is configured" do
      Application.put_env(:lux, :api_keys, youtube_access_token: "test_access_token_123")

      lens = %Lux.Lens{
        name: "TestLens",
        url: "https://www.googleapis.com/youtube/v3/liveBroadcasts",
        headers: nil,
        params: %{}
      }

      updated = YouTube.add_auth_header(lens)
      assert updated.headers == [{"Authorization", "Bearer test_access_token_123"}]
    end

    test "injects API key param when no token is present and params is map" do
      Application.put_env(:lux, :api_keys, youtube_access_token: nil, youtube_api_key: "api_key_456")

      lens = %Lux.Lens{
        name: "TestLens",
        url: "https://www.googleapis.com/youtube/v3/videos",
        headers: [],
        params: %{part: "snippet"}
      }

      updated = YouTube.add_auth_header(lens)
      assert updated.params == %{part: "snippet", key: "api_key_456"}
    end

    test "injects API key param when no token is present and params is keyword list" do
      Application.put_env(:lux, :api_keys, youtube_access_token: nil, youtube_api_key: "api_key_456")

      lens = %Lux.Lens{
        name: "TestLens",
        url: "https://www.googleapis.com/youtube/v3/videos",
        headers: [],
        params: [part: "snippet"]
      }

      updated = YouTube.add_auth_header(lens)
      assert Keyword.get(updated.params, :key) == "api_key_456"
    end

    test "injects API key param when params is nil" do
      Application.put_env(:lux, :api_keys, youtube_access_token: nil, youtube_api_key: "api_key_456")

      lens = %Lux.Lens{
        name: "TestLens",
        url: "https://www.googleapis.com/youtube/v3/videos",
        headers: [],
        params: nil
      }

      updated = YouTube.add_auth_header(lens)
      assert updated.params == %{key: "api_key_456"}
    end

    test "returns unmodified lens when neither token nor api_key is configured" do
      Application.put_env(:lux, :api_keys, youtube_access_token: nil, youtube_api_key: nil)

      lens = %Lux.Lens{
        name: "TestLens",
        url: "https://www.googleapis.com/youtube/v3/videos",
        headers: [],
        params: %{}
      }

      updated = YouTube.add_auth_header(lens)
      assert updated == lens
    end
  end

  describe "add_auth_header/1 with Plug.Conn" do
    test "injects authorization header when token is present" do
      Application.put_env(:lux, :api_keys, youtube_access_token: "conn_token_789")

      conn = Plug.Test.conn(:get, "/test")
      updated_conn = YouTube.add_auth_header(conn)
      assert Plug.Conn.get_req_header(updated_conn, "authorization") == ["Bearer conn_token_789"]
    end

    test "does not inject header when token is nil" do
      Application.put_env(:lux, :api_keys, youtube_access_token: nil)

      conn = Plug.Test.conn(:get, "/test")
      updated_conn = YouTube.add_auth_header(conn)
      assert Plug.Conn.get_req_header(updated_conn, "authorization") == []
    end
  end
end
