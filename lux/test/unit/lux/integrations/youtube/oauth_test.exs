defmodule Lux.Integrations.YouTube.OAuthTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.OAuth

  setup do
    Req.Test.verify_on_exit!()
    orig_keys = Application.get_env(:lux, :api_keys, [])
    on_exit(fn ->
      Application.put_env(:lux, :api_keys, orig_keys)
    end)
    :ok
  end

  describe "default_scopes/0" do
    test "returns list of YouTube scopes" do
      scopes = OAuth.default_scopes()
      assert is_list(scopes)
      assert "https://www.googleapis.com/auth/youtube" in scopes
      assert "https://www.googleapis.com/auth/youtube.force-ssl" in scopes
      assert "https://www.googleapis.com/auth/youtube.readonly" in scopes
    end
  end

  describe "authorize_url/1" do
    test "generates standard authorization URL with default scopes" do
      url =
        OAuth.authorize_url(%{
          client_id: "test-client-id",
          redirect_uri: "https://example.com/oauth/callback",
          state: "xyz123",
          login_hint: "user@example.com",
          include_granted_scopes: "true"
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
      assert query["login_hint"] == "user@example.com"
      assert query["include_granted_scopes"] == "true"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube.force-ssl"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube.readonly"
    end

    test "allows custom scopes as a list" do
      url =
        OAuth.authorize_url(%{
          client_id: "test-client-id",
          scope: ["https://www.googleapis.com/auth/youtube.readonly"]
        })

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      assert query["scope"] == "https://www.googleapis.com/auth/youtube.readonly"
    end

    test "allows custom scopes as a string" do
      url =
        OAuth.authorize_url(%{
          client_id: "test-client-id",
          scope: "https://www.googleapis.com/auth/youtube"
        })

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      assert query["scope"] == "https://www.googleapis.com/auth/youtube"
    end

    test "accepts keyword list options" do
      url =
        OAuth.authorize_url(
          client_id: "test-client-id",
          redirect_uri: "https://example.com/cb",
          state: "state999"
        )

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      assert query["client_id"] == "test-client-id"
      assert query["redirect_uri"] == "https://example.com/cb"
      assert query["state"] == "state999"
    end

    test "falls back to Lux.Config when client_id is not in opts" do
      Application.put_env(:lux, :api_keys,
        youtube_client_id: "config_cid",
        youtube_redirect_uri: "https://config.example.com/cb"
      )

      url = OAuth.authorize_url()
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert query["client_id"] == "config_cid"
      assert query["redirect_uri"] == "https://config.example.com/cb"
    end
  end

  describe "exchange_code/2" do
    test "successfully exchanges code for tokens" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert conn.method == "POST"
        assert conn.request_path == "/token"
        assert params["code"] == "auth_code_123"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"
        assert params["redirect_uri"] == "http://localhost:4000/callback"
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
        redirect_uri: "http://localhost:4000/callback"
      }

      assert {:ok, result} = OAuth.exchange_code("auth_code_123", opts)
      assert result["access_token"] == "ya29.mock_access_token"
      assert result["refresh_token"] == "1//04mock_refresh_token"
      assert result["expires_in"] == 3599
      assert result["token_type"] == "Bearer"
    end

    test "handles string response body decoding" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{\"access_token\": \"str_token\"}")
      end)

      opts = %{client_id: "cid", client_secret: "csec"}
      assert {:ok, %{"access_token" => "str_token"}} = OAuth.exchange_code("code", opts)
    end

    test "handles custom plug option" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["code"] == "custom_code"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "custom_token"}))
      end)

      opts = %{
        client_id: "cid",
        client_secret: "csec",
        plug: {Req.Test, __MODULE__}
      }

      assert {:ok, %{"access_token" => "custom_token"}} = OAuth.exchange_code("custom_code", opts)
    end

    test "falls back to Lux.Config when credentials not in opts" do
      Application.put_env(:lux, :api_keys,
        youtube_client_id: "config_cid",
        youtube_client_secret: "config_csec",
        youtube_redirect_uri: "http://localhost:4000/cb"
      )

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["client_id"] == "config_cid"
        assert params["client_secret"] == "config_csec"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "ok"}))
      end)

      assert {:ok, %{"access_token" => "ok"}} = OAuth.exchange_code("auth_code")
    end

    test "returns error when credentials are missing" do
      Application.put_env(:lux, :api_keys, youtube_client_id: nil, youtube_client_secret: nil)
      assert {:error, :missing_credentials} =
               OAuth.exchange_code("code", %{client_id: nil, client_secret: nil})
    end

    test "handles error response from Google OAuth endpoint with message object" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{"message" => "Bad Request Error"}
          })
        )
      end)

      opts = %{client_id: "test_client_id", client_secret: "test_client_secret"}
      assert {:error, {:oauth_error, "error", "Bad Request Error"}} =
               OAuth.exchange_code("invalid_code", opts)
    end

    test "handles error response from Google OAuth endpoint with error and error_description" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
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
        client_secret: "test_client_secret"
      }

      assert {:error, {:oauth_error, "invalid_grant", "Bad Request"}} =
               OAuth.exchange_code("invalid_code", opts)
    end
  end

  describe "refresh_token/2" do
    test "successfully refreshes access token" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert conn.method == "POST"
        assert conn.request_path == "/token"
        assert params["refresh_token"] == "valid_refresh_token"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"
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
        client_secret: "test_client_secret"
      }

      assert {:ok, result} = OAuth.refresh_token("valid_refresh_token", opts)
      assert result["access_token"] == "ya29.new_access_token"
      assert result["expires_in"] == 3599
    end

    test "refreshes access token using Config when opts omitted" do
      Application.put_env(:lux, :api_keys,
        youtube_client_id: "cfg_cid",
        youtube_client_secret: "cfg_csec"
      )

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["client_id"] == "cfg_cid"
        assert params["client_secret"] == "cfg_csec"

        conn
        |> Plug.Conn.send_resp(200, "non-json-token-response")
      end)

      assert {:ok, "non-json-token-response"} = OAuth.refresh_token("valid_refresh_token")
    end

    test "returns error when credentials are missing" do
      Application.put_env(:lux, :api_keys, youtube_client_id: nil, youtube_client_secret: nil)
      assert {:error, :missing_credentials} =
               OAuth.refresh_token("refresh_tok", %{client_id: nil, client_secret: nil})
    end

    test "handles revoked refresh token" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
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
        client_secret: "test_client_secret"
      }

      assert {:error, {:oauth_error, "invalid_grant", "Token has been expired or revoked."}} =
               OAuth.refresh_token("revoked_refresh_token", opts)
    end

    test "handles generic non-200 response" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.send_resp(500, "Internal Server Error")
      end)

      opts = %{client_id: "cid", client_secret: "csec"}
      assert {:error, {500, "Internal Server Error"}} = OAuth.refresh_token("rt", opts)
    end

    test "handles transport error" do
      Req.Test.stub(YouTubeOAuthMock, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      opts = %{client_id: "cid", client_secret: "csec"}
      assert {:error, %Req.TransportError{reason: :nxdomain}} = OAuth.refresh_token("rt", opts)
    end
  end
end
