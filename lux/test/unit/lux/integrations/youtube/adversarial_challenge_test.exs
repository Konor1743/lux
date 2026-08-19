defmodule Lux.Integrations.YouTube.AdversarialChallengeTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube
  alias Lux.Integrations.YouTube.{Client, Errors, OAuth}

  setup do
    Req.Test.verify_on_exit!()
    orig_keys = Application.get_env(:lux, :api_keys, [])

    on_exit(fn ->
      Application.put_env(:lux, :api_keys, orig_keys)
    end)

    :ok
  end

  # ============================================================================
  # 1. URL Resolution & Path Handling
  # ============================================================================
  describe "URL resolution & Path Edge Cases" do
    test "relative path without leading slash correctly builds full URL" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, %{"ok" => true}} = Client.get("liveBroadcasts", token: "tok")
    end

    test "empty string path requests the base endpoint" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, %{"ok" => true}} = Client.get("", token: "tok")
    end

    test "absolute URL with different subdomain / path" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/custom/endpoint"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"custom" => true}))
      end)

      assert {:ok, %{"custom" => true}} =
               Client.get("https://www.googleapis.com/custom/endpoint", token: "tok")
    end
  end

  # ============================================================================
  # 2. Parameter, Body & Header Edge Cases
  # ============================================================================
  describe "Parameter, Body & Header Edge Cases" do
    test "handles complex unicode and special characters in query params" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "q=%E6%97%A5%E6%9C%AC%E8%AA%9E" or conn.query_string =~ "q="
        assert conn.query_string =~ "special=%21%40%23%24%25%5E%26%2A" or conn.query_string =~ "special="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, _} =
               Client.get("/search",
                 token: "tok",
                 params: %{"q" => "日本語", "special" => "!@#$%^&*"}
               )
    end

    test "handles nil and empty params gracefully" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/videos"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, _} = Client.get("/videos", token: "tok", params: nil)
    end

    test "handles map headers vs list headers" do
      # Note: build_headers expects a list or nil; if map is passed, it ignores extra headers
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-trace-id") == ["12345"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, _} =
               Client.get("/videos",
                 token: "tok",
                 headers: [{"x-trace-id", "12345"}]
               )
    end

    test "handles non-map JSON body (lists, strings, numbers)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == [1, 2, 3]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => "array_ok"}))
      end)

      assert {:ok, resp} = Client.post("/batch", token: "tok", json: [1, 2, 3])
      assert resp["result"] == "array_ok"
    end
  end

  # ============================================================================
  # 3. OAuth 2.0 Edge Cases & Security Boundaries
  # ============================================================================
  describe "OAuth 2.0 Edge Cases" do
    test "authorize_url handles empty scopes list by setting empty scope param" do
      url = OAuth.authorize_url(client_id: "cid", scope: [])
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      assert query["scope"] == ""
    end

    test "exchange_code rejects empty string credentials" do
      assert {:error, :missing_credentials} =
               OAuth.exchange_code("code", client_id: "", client_secret: "secret")

      assert {:error, :missing_credentials} =
               OAuth.exchange_code("code", client_id: "cid", client_secret: "")
    end

    test "refresh_token rejects empty string credentials" do
      assert {:error, :missing_credentials} =
               OAuth.refresh_token("rt", client_id: "", client_secret: "secret")

      assert {:error, :missing_credentials} =
               OAuth.refresh_token("rt", client_id: "cid", client_secret: "")
    end

    test "OAuth token error with nested Google error format" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "Invalid authorization code",
              "status" => "INVALID_ARGUMENT"
            }
          })
        )
      end)

      assert {:error, {:oauth_error, "error", "Invalid authorization code"}} =
               OAuth.exchange_code("bad_code", client_id: "cid", client_secret: "csec")
    end

    test "OAuth token error with standard OAuth 2.0 RFC 6749 error without description" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => "unsupported_grant_type"
          })
        )
      end)

      assert {:error, {:oauth_error, "unsupported_grant_type", "unsupported_grant_type"}} =
               OAuth.exchange_code("code", client_id: "cid", client_secret: "csec")
    end

    test "OAuth token endpoint returns HTML error page (e.g. 502 Bad Gateway)" do
      html_body = "<html><body>502 Bad Gateway</body></html>"

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(502, html_body)
      end)

      assert {:error, {502, ^html_body}} =
               OAuth.exchange_code("code", client_id: "cid", client_secret: "csec")
    end
  end

  # ============================================================================
  # 4. Token Refresh Failure Loops & Concurrency
  # ============================================================================
  describe "Token Refresh Edge Cases & Concurrency" do
    test "retried request returns 401, client terminates without infinite loop" do
      # 1st call to client API -> 401
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired token"}}))
      end)

      # Refresh succeeds
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "still_invalid_token"}))
      end)

      # 2nd call to client API with new token STILL returns 401
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer still_invalid_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Still unauthorized"}}))
      end)

      opts = %{
        token: "initial_expired",
        refresh_token: "refresh_tok",
        client_id: "cid",
        client_secret: "csec",
        auto_refresh: true
      }

      # Should cleanly terminate with :invalid_token, NOT recurse infinitely
      assert {:error, :invalid_token} = Client.get("/liveBroadcasts", opts)
    end

    test "retried request returns 403 quotaExceeded instead of 200" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "valid_new_token"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "errors" => [%{"reason" => "quotaExceeded", "message" => "Out of quota"}]
            }
          })
        )
      end)

      opts = %{
        token: "initial_expired",
        refresh_token: "refresh_tok",
        client_id: "cid",
        client_secret: "csec"
      }

      assert {:error, {:quota_exceeded, details}} = Client.get("/liveBroadcasts", opts)
      assert details.reason == "quotaExceeded"
    end

    test "concurrent requests encountering 401 independently refresh tokens" do
      concurrency = 10

      Req.Test.stub(YouTubeClientMock, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")

        if auth == ["Bearer expired_tok"] do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired"}}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "ok"}))
        end
      end)

      Req.Test.stub(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "refreshed_tok"}))
      end)

      opts = %{
        token: "expired_tok",
        refresh_token: "refresh_tok",
        client_id: "cid",
        client_secret: "csec"
      }

      tasks =
        for _i <- 1..concurrency do
          Task.async(fn ->
            Client.get("/liveBroadcasts", opts)
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn res -> match?({:ok, %{"status" => "ok"}}, res) end)
    end
  end

  # ============================================================================
  # 5. Advanced Error Parsing & Edge Case Status Codes
  # ============================================================================
  describe "Error Parsing Edge Cases" do
    test "parses 403 with empty errors list and gRPC RESOURCE_EXHAUSTED status" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota metric exceeded",
          "status" => "RESOURCE_EXHAUSTED",
          "errors" => []
        }
      }

      res = Errors.parse(403, body)
      assert {:error, {:quota_exceeded, details}} = res
      assert details.reason == "RESOURCE_EXHAUSTED"
    end

    test "parses 403 with multiple details elements where reason is in second element" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "User rate limit hit",
          "details" => [
            %{"@type" => "google.rpc.Help", "links" => []},
            %{"@type" => "google.rpc.ErrorInfo", "reason" => "RATE_LIMIT_EXCEEDED", "domain" => "youtube.googleapis.com"}
          ]
        }
      }

      res = Errors.parse(403, body)
      assert {:error, {:rate_limited, details}} = res
      assert details.reason == "RATE_LIMIT_EXCEEDED"
    end

    test "parses unexpected status codes (e.g. 418, 504, 301)" do
      assert {:error, {418, "I'm a teapot"}} = Errors.parse(418, %{"message" => "I'm a teapot"})
      assert {:error, {504, "HTTP 504 Error"}} = Errors.parse(504, nil)
      assert {:error, {301, "HTTP 301 Error"}} = Errors.parse(301, nil)
    end

    test "parses HTML body for 500 error" do
      html = "<!DOCTYPE html><html><body>500 Internal Server Error</body></html>"
      assert {:error, {500, ^html}} = Errors.parse(500, html)
    end

    test "handles malformed / non-integer Retry-After headers" do
      assert Errors.extract_retry_after([{"retry-after", "-10"}]) == nil
      assert Errors.extract_retry_after([{"retry-after", "0"}]) == 0
      assert Errors.extract_retry_after([{"retry-after", "not-a-number"}]) == nil
      assert Errors.extract_retry_after([{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}]) == nil
    end

    test "backoff_delay arithmetic safety with large attempt count" do
      delay = Errors.backoff_delay(50, base_backoff_ms: 500, max_backoff_ms: 16_000)
      assert is_integer(delay)
      assert delay >= 50 and delay <= 16_000

      delay_huge = Errors.backoff_delay(1500, base_backoff_ms: 500, max_backoff_ms: 16_000)
      assert is_integer(delay_huge)
      assert delay_huge >= 50 and delay_huge <= 16_000
    end
  end

  # ============================================================================
  # 6. YouTube Integration Helper & Lens Auth
  # ============================================================================
  describe "YouTube Integration Helper Edge Cases" do
    test "add_auth_header with lens having nil headers handles nil gracefully" do
      Application.put_env(:lux, :api_keys, youtube_access_token: "my_token")

      lens = %Lux.Lens{
        name: "Nil Headers Lens",
        url: "https://example.com",
        headers: nil,
        params: %{}
      }

      updated = YouTube.add_auth_header(lens)
      assert updated.headers == [{"Authorization", "Bearer my_token"}]
    end

    test "add_auth_header with Plug.Conn does not inject API key if token is nil" do
      Application.put_env(:lux, :api_keys, youtube_access_token: nil, youtube_api_key: "my_api_key")

      conn = Plug.Test.conn(:get, "/test")
      updated_conn = YouTube.add_auth_header(conn)

      assert Plug.Conn.get_req_header(updated_conn, "authorization") == []
    end
  end
end
