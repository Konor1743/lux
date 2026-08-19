defmodule Lux.Integrations.YouTube.ClientTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.Client

  setup do
    Req.Test.verify_on_exit!()
    orig_keys = Application.get_env(:lux, :api_keys, [])
    on_exit(fn ->
      Application.put_env(:lux, :api_keys, orig_keys)
    end)
    :ok
  end

  describe "HTTP methods" do
    test "makes GET request with bearer token" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer custom_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [%{"id" => "broadcast_1"}]
          })
        )
      end)

      assert {:ok, resp} = Client.get("/liveBroadcasts", token: "custom_token")
      assert resp["kind"] == "youtube#liveBroadcastListResponse"
      assert length(resp["items"]) == 1
    end

    test "makes GET request with absolute URL and custom headers" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["custom_val"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, resp} =
               Client.get("https://www.googleapis.com/youtube/v3/videos",
                 token: "tok",
                 headers: [{"x-custom", "custom_val"}]
               )

      assert resp["ok"] == true
    end

    test "makes GET request with path without leading slash" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, resp} = Client.get("liveBroadcasts", token: "tok")
      assert resp["ok"] == true
    end

    test "makes POST request with JSON body" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert decoded["snippet"]["title"] == "New Live Stream"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "new_broadcast_id",
            "snippet" => %{"title" => "New Live Stream"}
          })
        )
      end)

      payload = %{snippet: %{title: "New Live Stream"}}
      assert {:ok, resp} = Client.post("/liveBroadcasts", token: "tok", json: payload)
      assert resp["id"] == "new_broadcast_id"
    end

    test "makes POST request with raw body" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "raw_binary_content"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "uploaded"}))
      end)

      assert {:ok, resp} = Client.post("/upload", token: "tok", body: "raw_binary_content")
      assert resp["id"] == "uploaded"
    end

    test "makes PUT and DELETE requests" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "updated_id"}))
      end)

      assert {:ok, %{"id" => "updated_id"}} = Client.put("/liveBroadcasts", token: "tok", json: %{id: "updated_id"})

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, ""} = Client.delete("/liveBroadcasts", token: "tok", params: [id: "updated_id"])
    end
  end

  describe "query parameters and API key fallback" do
    test "appends query parameters properly" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "part=snippet"
        assert conn.query_string =~ "broadcastStatus=all"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, %{"items" => []}} =
               Client.get("/liveBroadcasts",
                 token: "tok",
                 params: %{part: "snippet", broadcastStatus: "all"}
               )
    end

    test "falls back to API key in params when token is absent" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/channels"
        assert conn.query_string =~ "key=my_public_api_key"
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, %{"items" => []}} =
               Client.get("/channels",
                 token: nil,
                 api_key: "my_public_api_key",
                 params: %{part: "snippet"}
               )
    end

    test "does not duplicate key parameter if already in params" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "key=existing_key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, _} =
               Client.get("/channels",
                 token: nil,
                 api_key: "fallback_key",
                 params: [key: "existing_key"]
               )
    end

    test "falls back to Config when token and api_key not in opts" do
      Application.put_env(:lux, :api_keys, youtube_access_token: "cfg_tok", youtube_api_key: "cfg_key")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer cfg_tok"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, %{"items" => []}} = Client.get("/channels")
    end
  end

  describe "auto-refresh token handling on 401" do
    test "retries request with refreshed token upon 401 (string map response)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expired_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => %{
              "code" => 401,
              "message" => "Invalid Credentials"
            }
          })
        )
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "my_refresh_token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "newly_refreshed_access_token",
            "expires_in" => 3599
          })
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer newly_refreshed_access_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"success" => true, "data" => "broadcasts"})
        )
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "my_refresh_token",
        client_id: "test_cid",
        client_secret: "test_csec",
        auto_refresh: true
      }

      assert {:ok, resp} = Client.get("/liveBroadcasts", opts)
      assert resp["success"] == true
    end

    test "retries request with refreshed token when OAuth returns atom map" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "atom_refreshed"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer atom_refreshed"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, %{"ok" => true}} =
               Client.get("/liveBroadcasts",
                 token: "old",
                 refresh_token: "rt",
                 client_id: "cid",
                 client_secret: "csec"
               )
    end

    test "returns :invalid_token when auto_refresh is disabled" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => %{"code" => 401, "message" => "Invalid Credentials"}
          })
        )
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "my_refresh_token",
        auto_refresh: false
      }

      assert {:error, :invalid_token} = Client.get("/liveBroadcasts", opts)
    end

    test "returns :invalid_token when no refresh token configured" do
      Application.put_env(:lux, :api_keys, youtube_refresh_token: nil)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      assert {:error, :invalid_token} = Client.get("/liveBroadcasts", token: "expired", refresh_token: nil)
    end

    test "returns :invalid_token when token refresh fails" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => "invalid_grant", "error_description" => "Token revoked"})
        )
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "bad_refresh_token",
        client_id: "cid",
        client_secret: "csec"
      }

      assert {:error, :invalid_token} = Client.get("/liveBroadcasts", opts)
    end

    test "returns :invalid_token when token refresh returns unexpected payload" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"something_else" => 123}))
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "refresh_tok",
        client_id: "cid",
        client_secret: "csec"
      }

      assert {:error, :invalid_token} = Client.get("/liveBroadcasts", opts)
    end
  end

  describe "error handling" do
    test "handles 403 quotaExceeded" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "The request cannot be completed because you have exceeded your quota.",
              "errors" => [
                %{
                  "domain" => "youtube.quota",
                  "message" => "The request cannot be completed because you have exceeded your quota.",
                  "reason" => "quotaExceeded"
                }
              ]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} = Client.get("/liveBroadcasts", token: "tok")
      assert details.reason == "quotaExceeded"
      assert details.status == 403
    end

    test "handles 403 rateLimitExceeded" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "60")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "Rate Limit Exceeded",
              "errors" => [%{"reason" => "userRateLimitExceeded"}]
            }
          })
        )
      end)

      assert {:error, {:rate_limited, details}} = Client.get("/liveBroadcasts", token: "tok")
      assert details.reason == "userRateLimitExceeded"
      assert details.retry_after == 60
    end

    test "handles generic 404 not found" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{
            "error" => %{"message" => "Broadcast not found"}
          })
        )
      end)

      assert {:error, {404, "Broadcast not found"}} = Client.get("/liveBroadcasts/999", token: "tok")
    end

    test "handles transport error" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.get("/channels", token: "tok", retry: false)
    end
  end

  describe "custom plug isolation" do
    test "routes to custom test plug" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/youtube/v3/channels"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"channel" => "test"}))
      end)

      assert {:ok, %{"channel" => "test"}} =
               Client.get("/channels", plug: {Req.Test, __MODULE__}, token: "tok")
    end
  end
end
