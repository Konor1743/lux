defmodule Lux.E2E.YouTubeIntegrationE2ETest do
  use ExUnit.Case, async: false

  alias Lux.Integrations.YouTube
  alias Lux.Integrations.YouTube.{Client, Errors, LiveBroadcasts, LiveChat, LiveStreams, OAuth}
  alias Lux.Integrations.YouTube.LiveChat.Poller

  # ============================================================================
  # Test Lenses and Prisms for Tier 3 / Tier 4 Integration Workflows
  # ============================================================================

  defmodule TestListBroadcastsLens do
    use Lux.Lens,
      name: "Test YouTube List Broadcasts Lens",
      description: "Fetches live broadcasts from YouTube API",
      url: "https://www.googleapis.com/youtube/v3/liveBroadcasts",
      method: :get,
      auth: Lux.Integrations.YouTube.auth(),
      headers: Lux.Integrations.YouTube.headers()

    def after_focus(%{"items" => items}) do
      parsed =
        Enum.map(items, fn item ->
          %{
            id: item["id"],
            title: get_in(item, ["snippet", "title"]),
            live_chat_id: get_in(item, ["snippet", "liveChatId"]),
            status: get_in(item, ["status", "lifeCycleStatus"])
          }
        end)

      {:ok, parsed}
    end

    def after_focus(other), do: {:ok, other}
  end

  defmodule TestGetChatMessagesLens do
    use Lux.Lens,
      name: "Test YouTube Get Chat Messages Lens",
      description: "Fetches chat messages from YouTube Live Chat",
      url: "https://www.googleapis.com/youtube/v3/liveChat/messages",
      method: :get,
      auth: Lux.Integrations.YouTube.auth(),
      headers: Lux.Integrations.YouTube.headers()

    def after_focus(%{"items" => items}) do
      messages =
        Enum.map(items, fn item ->
          %{
            id: item["id"],
            text:
              get_in(item, ["snippet", "textMessageDetails", "messageText"]) ||
                get_in(item, ["snippet", "displayMessage"]),
            author: get_in(item, ["authorDetails", "displayName"])
          }
        end)

      {:ok, messages}
    end

    def after_focus(other), do: {:ok, other}
  end

  defmodule TestCreateBroadcastPrism do
    use Lux.Prism,
      name: "Test Create Broadcast Prism",
      description: "Creates a new YouTube Live Broadcast",
      input_schema: %{
        type: :object,
        properties: %{
          title: %{type: :string},
          privacy_status: %{type: :string}
        },
        required: ["title"]
      }

    alias Lux.Integrations.YouTube.LiveBroadcasts

    def handler(input, _context) do
      case LiveBroadcasts.create_broadcast(input) do
        {:ok, broadcast} ->
          {:ok,
           %{
             id: broadcast["id"],
             title: get_in(broadcast, ["snippet", "title"]),
             live_chat_id: LiveBroadcasts.live_chat_id(broadcast),
             status: LiveBroadcasts.status(broadcast)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule TestSendMessagePrism do
    use Lux.Prism,
      name: "Test Send Chat Message Prism",
      description: "Posts a message to YouTube Live Chat",
      input_schema: %{
        type: :object,
        properties: %{
          live_chat_id: %{type: :string},
          message: %{type: :string}
        },
        required: ["live_chat_id", "message"]
      }

    alias Lux.Integrations.YouTube.LiveChat

    def handler(%{live_chat_id: chat_id, message: msg} = input, _context) do
      opts = Map.drop(input, [:live_chat_id, :message])

      case LiveChat.insert_message(chat_id, msg, opts) do
        {:ok, resp} ->
          {:ok, %{id: resp["id"] || "msg_default", status: :sent, text: msg}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule TestTransitionBroadcastPrism do
    use Lux.Prism,
      name: "Test Transition Broadcast Prism",
      description: "Transitions broadcast lifecycle state",
      input_schema: %{
        type: :object,
        properties: %{
          broadcast_id: %{type: :string},
          status: %{type: :string}
        },
        required: ["broadcast_id", "status"]
      }

    alias Lux.Integrations.YouTube.LiveBroadcasts

    def handler(%{broadcast_id: id, status: status} = input, _context) do
      opts = Map.drop(input, [:broadcast_id, :status])

      case LiveBroadcasts.transition_broadcast(id, status, opts) do
        {:ok, resp} ->
          {:ok, %{id: id, status: LiveBroadcasts.status(resp)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # Setup & Fixture Helpers
  # ============================================================================

  setup do
    Application.put_env(:lux, :req_options, plug: {Req.Test, Lux.Lens})
    Application.put_env(:lux, Lux.Integrations.YouTube.Client, plug: {Req.Test, YouTubeClientMock})
    Application.put_env(:lux, Lux.Integrations.YouTube.OAuth, plug: {Req.Test, YouTubeOAuthMock})

    Req.Test.verify_on_exit!()

    orig_keys = Application.get_env(:lux, :api_keys, [])

    on_exit(fn ->
      Application.put_env(:lux, :api_keys, orig_keys)
    end)

    :ok
  end

  defp broadcast_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveBroadcast",
        "etag" => "\"etag_broadcast_123\"",
        "id" => "bcast_101",
        "snippet" => %{
          "publishedAt" => "2026-08-17T18:00:00Z",
          "channelId" => "UC_chan_101",
          "title" => "AI Live Show",
          "description" => "Autonomous agent broadcast",
          "scheduledStartTime" => "2026-08-20T20:00:00Z",
          "scheduledEndTime" => "2026-08-20T22:00:00Z",
          "isDefaultBroadcast" => false,
          "liveChatId" => "chat_101"
        },
        "status" => %{
          "lifeCycleStatus" => "created",
          "privacyStatus" => "public",
          "recordingStatus" => "notRecording",
          "madeForKids" => false,
          "selfDeclaredMadeForKids" => false
        },
        "contentDetails" => %{
          "boundStreamId" => nil,
          "monitorStream" => %{
            "enableMonitorStream" => true,
            "broadcastStreamDelayMs" => 0,
            "embedHtml" => "<iframe src=\"https://youtube.com/embed/bcast_101\"></iframe>"
          },
          "enableEmbed" => true,
          "enableDvr" => true,
          "enableContentEncryption" => false,
          "startWithSlate" => false,
          "recordFromStart" => true,
          "enableClosedCaptions" => false,
          "latencyPreference" => "ultraLow",
          "enableAutoStart" => true,
          "enableAutoStop" => true
        }
      },
      overrides
    )
  end

  defp stream_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveStream",
        "etag" => "\"etag_stream_202\"",
        "id" => "stream_202",
        "snippet" => %{
          "publishedAt" => "2026-08-17T18:00:00Z",
          "channelId" => "UC_chan_101",
          "title" => "Primary RTMP Ingest",
          "description" => "Stream ingestion description",
          "isDefaultStream" => false
        },
        "cdn" => %{
          "ingestionType" => "rtmp",
          "ingestionInfo" => %{
            "streamName" => "live_key_secret_abc",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmps.youtube.com/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmps.youtube.com/live2?backup=1"
          },
          "resolution" => "1080p",
          "frameRate" => "60fps"
        },
        "status" => %{
          "streamStatus" => "active",
          "healthStatus" => %{
            "status" => "good"
          }
        },
        "contentDetails" => %{
          "closedCaptionsIngestionUrl" => "http://upload.youtube.com/closedcaption",
          "isReusable" => true
        }
      },
      overrides
    )
  end

  defp chat_message_fixture(id, text, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "id" => id,
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "chat_abc_123",
          "authorChannelId" => "UC_user_1",
          "publishedAt" => "2026-08-17T19:00:00Z",
          "displayMessage" => text,
          "textMessageDetails" => %{
            "messageText" => text
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_user_1",
          "displayName" => "AgentHost",
          "profileImageUrl" => "https://yt3.ggpht.com/avatar.jpg",
          "isVerified" => true,
          "isChatOwner" => true,
          "isChatSponsor" => false,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  defp chat_list_fixture(items, next_page_token \\ "tok_next", polling_interval_ms \\ 3000, offline_at \\ nil) do
    %{
      "kind" => "youtube#liveChatMessageListResponse",
      "etag" => "\"etag_chat_list\"",
      "nextPageToken" => next_page_token,
      "pollingIntervalMillis" => polling_interval_ms,
      "offlineAt" => offline_at,
      "pageInfo" => %{
        "totalResults" => length(items),
        "resultsPerPage" => 100
      },
      "items" => items
    }
  end

  # ============================================================================
  # TIER 1: FEATURE COVERAGE (T1-F1 TO T1-F6, 30 TESTS)
  # ============================================================================

  describe "Tier 1: Feature 1 - OAuth 2.0 Flow & Token Refresh" do
    test "T1-F1-01: Standard Authorization URL Generation" do
      url =
        OAuth.authorize_url(%{
          client_id: "test-client-id",
          redirect_uri: "https://example.com/cb",
          state: "csrf_token_123"
        })

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert uri.scheme == "https"
      assert uri.host == "accounts.google.com"
      assert uri.path == "/o/oauth2/v2/auth"
      assert query["client_id"] == "test-client-id"
      assert query["redirect_uri"] == "https://example.com/cb"
      assert query["response_type"] == "code"
      assert query["access_type"] == "offline"
      assert query["prompt"] == "consent"
      assert query["state"] == "csrf_token_123"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube.force-ssl"
      assert query["scope"] =~ "https://www.googleapis.com/auth/youtube.readonly"
    end

    test "T1-F1-02: Authorization URL with Custom Scopes & Options" do
      url =
        OAuth.authorize_url(%{
          client_id: "cid",
          scope: ["https://www.googleapis.com/auth/youtube.readonly"],
          login_hint: "user@lux.io",
          include_granted_scopes: "true"
        })

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert query["scope"] == "https://www.googleapis.com/auth/youtube.readonly"
      assert query["login_hint"] == "user@lux.io"
      assert query["include_granted_scopes"] == "true"
    end

    test "T1-F1-03: Authorization Code Exchange" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert conn.method == "POST"
        assert conn.request_path == "/token"
        assert params["code"] == "auth_code_xyz"
        assert params["grant_type"] == "authorization_code"
        assert params["client_id"] == "cid"
        assert params["client_secret"] == "sec"
        assert params["redirect_uri"] == "https://example.com/cb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "ya29.new_token",
            "refresh_token" => "1//refresh_xyz",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end)

      assert {:ok, tokens} =
               OAuth.exchange_code("auth_code_xyz",
                 client_id: "cid",
                 client_secret: "sec",
                 redirect_uri: "https://example.com/cb"
               )

      assert tokens["access_token"] == "ya29.new_token"
      assert tokens["refresh_token"] == "1//refresh_xyz"
      assert tokens["expires_in"] == 3600
    end

    test "T1-F1-04: Token Refresh Execution" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert conn.method == "POST"
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "1//refresh_token_123"
        assert params["client_id"] == "cid"
        assert params["client_secret"] == "sec"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "ya29.refreshed_token",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end)

      assert {:ok, tokens} =
               OAuth.refresh_token("1//refresh_token_123",
                 client_id: "cid",
                 client_secret: "sec"
               )

      assert tokens["access_token"] == "ya29.refreshed_token"
    end

    test "T1-F1-05: Application Config Fallback for OAuth Credentials" do
      Application.put_env(:lux, :api_keys,
        youtube_client_id: "cfg_cid",
        youtube_client_secret: "cfg_sec",
        youtube_redirect_uri: "https://cfg.example.com/cb"
      )

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["client_id"] == "cfg_cid"
        assert params["client_secret"] == "cfg_sec"
        assert params["redirect_uri"] == "https://cfg.example.com/cb"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "cfg_token", "expires_in" => 3600})
        )
      end)

      assert {:ok, tokens} = OAuth.exchange_code("auth_code_config")
      assert tokens["access_token"] == "cfg_token"
    end
  end

  describe "Tier 1: Feature 2 - YouTube API Client & Error Handling" do
    test "T1-F2-01: Client GET Request with Bearer Token Injection" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]
        assert conn.query_string =~ "part=snippet"
        assert conn.query_string =~ "mine=true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [%{"id" => "b1"}]
          })
        )
      end)

      assert {:ok, resp} =
               Client.get("/liveBroadcasts",
                 token: "test_access_token",
                 params: [part: "snippet", mine: true]
               )

      assert resp["kind"] == "youtube#liveBroadcastListResponse"
      assert length(resp["items"]) == 1
    end

    test "T1-F2-02: Client POST and PUT Requests with JSON Payload Encoding" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["snippet"]["title"] == "New Stream"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "b_created"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "PUT"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["snippet"]["title"] == "Updated Stream"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "b_created", "status" => "updated"}))
      end)

      assert {:ok, %{"id" => "b_created"}} =
               Client.post("/liveBroadcasts",
                 token: "tok",
                 json: %{snippet: %{title: "New Stream"}}
               )

      assert {:ok, %{"status" => "updated"}} =
               Client.put("/liveBroadcasts",
                 token: "tok",
                 json: %{id: "b_created", snippet: %{title: "Updated Stream"}}
               )
    end

    test "T1-F2-03: Client DELETE Request Execution" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=b_del_1"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, ""} = Client.delete("/liveBroadcasts", token: "tok", params: [id: "b_del_1"])
    end

    test "T1-F2-04: API Key Query Parameter Fallback When Token is Absent" do
      Application.put_env(:lux, :api_keys,
        youtube_access_token: nil,
        youtube_api_key: "ai_api_key_999"
      )

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert conn.query_string =~ "key=ai_api_key_999"
        assert conn.query_string =~ "part=snippet"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [%{"id" => "vid123"}]}))
      end)

      assert {:ok, resp} = Client.get("/videos", params: [part: "snippet", id: "vid123"])
      assert length(resp["items"]) == 1
    end

    test "T1-F2-05: Automatic Token Refresh on HTTP 401 Unauthorized" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expired_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{"error" => %{"code" => 401, "message" => "Invalid Credentials"}})
        )
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "new_refreshed_token", "expires_in" => 3600})
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer new_refreshed_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [%{"id" => "b1"}]}))
      end)

      assert {:ok, resp} =
               Client.get("/liveBroadcasts",
                 token: "expired_token",
                 refresh_token: "valid_refresh",
                 client_id: "cid",
                 client_secret: "sec",
                 auto_refresh: true
               )

      assert length(resp["items"]) == 1
    end
  end

  describe "Tier 1: Feature 3 - Live Broadcast Lifecycle & Management" do
    test "T1-F3-01: Create Live Broadcast with Full Configuration" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "part=snippet%2Cstatus%2CcontentDetails" or conn.query_string =~ "part="

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["title"] == "AI Live Show"
        assert decoded["snippet"]["scheduledStartTime"] == "2026-08-20T20:00:00Z"
        assert decoded["status"]["privacyStatus"] == "public"
        assert decoded["contentDetails"]["enableAutoStart"] == true
        assert decoded["contentDetails"]["latencyPreference"] == "ultraLow"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      assert {:ok, broadcast} =
               LiveBroadcasts.create_broadcast(
                 %{
                   title: "AI Live Show",
                   description: "Autonomous agent broadcast",
                   scheduled_start_time: "2026-08-20T20:00:00Z",
                   privacy_status: :public,
                   enable_auto_start: true,
                   enable_auto_stop: true,
                   enable_dvr: true,
                   latency_preference: :ultra_low
                 },
                 token: "tok"
               )

      assert broadcast["id"] == "bcast_101"
      assert LiveBroadcasts.live_chat_id(broadcast) == "chat_101"
    end

    test "T1-F3-02: Retrieve Single Broadcast by ID" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.query_string =~ "id=bcast_101"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [broadcast_fixture()]
          })
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.get_broadcast("bcast_101", token: "tok")
      assert bcast["id"] == "bcast_101"
      assert bcast["snippet"]["title"] == "AI Live Show"
    end

    test "T1-F3-03: List Live Broadcasts Filtered by Status" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.query_string =~ "broadcastStatus=active"
        assert conn.query_string =~ "mine=true"
        assert conn.query_string =~ "maxResults=10"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [broadcast_fixture(%{"id" => "b1"}), broadcast_fixture(%{"id" => "b2"})],
            "pageInfo" => %{"totalResults" => 2}
          })
        )
      end)

      assert {:ok, resp} =
               LiveBroadcasts.list_broadcasts([broadcast_status: :active, max_results: 10],
                 token: "tok"
               )

      assert length(resp["items"]) == 2
      assert resp["pageInfo"]["totalResults"] == 2
    end

    test "T1-F3-04: Update Live Broadcast Metadata" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "PUT"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["id"] == "bcast_101"
        assert decoded["snippet"]["title"] == "Updated Title"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "snippet" => %{
                "title" => "Updated Title",
                "description" => "Updated Desc",
                "liveChatId" => "chat_101"
              }
            })
          )
        )
      end)

      assert {:ok, updated} =
               LiveBroadcasts.update_broadcast(
                 %{id: "bcast_101", title: "Updated Title", description: "Updated Desc"},
                 token: "tok"
               )

      assert updated["snippet"]["title"] == "Updated Title"
    end

    test "T1-F3-05: Complete Broadcast Lifecycle Progression & Stream Binding" do
      # 1. Bind
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_101"
        assert conn.query_string =~ "streamId=stream_202"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "contentDetails" => %{"boundStreamId" => "stream_202"},
              "status" => %{"lifeCycleStatus" => "ready"}
            })
          )
        )
      end)

      # 2. Testing
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=testing"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"status" => %{"lifeCycleStatus" => "testing"}}))
        )
      end)

      # 3. Live
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"status" => %{"lifeCycleStatus" => "live"}}))
        )
      end)

      # 4. Complete
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"status" => %{"lifeCycleStatus" => "complete"}}))
        )
      end)

      assert {:ok, bound} =
               LiveBroadcasts.bind_broadcast("bcast_101", "stream_202", token: "tok")

      assert LiveBroadcasts.bound_stream_id(bound) == "stream_202"

      assert {:ok, testing} =
               LiveBroadcasts.transition_broadcast("bcast_101", :testing, token: "tok")

      assert LiveBroadcasts.testing?(testing)

      assert {:ok, live} =
               LiveBroadcasts.transition_broadcast("bcast_101", :live, token: "tok")

      assert LiveBroadcasts.active?(live)

      assert {:ok, complete} =
               LiveBroadcasts.transition_broadcast("bcast_101", :complete, token: "tok")

      assert LiveBroadcasts.complete?(complete)
    end
  end

  describe "Tier 1: Feature 4 - Live Stream Ingestion & Binding" do
    test "T1-F4-01: Create RTMP Live Stream Ingestion Resource" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveStreams"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["title"] == "Primary RTMP Ingest"
        assert decoded["cdn"]["ingestionType"] == "rtmp"
        assert decoded["cdn"]["resolution"] == "1080p"
        assert decoded["cdn"]["frameRate"] == "60fps"
        assert decoded["contentDetails"]["isReusable"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture()))
      end)

      assert {:ok, stream} =
               LiveStreams.create_stream(
                 %{
                   title: "Primary RTMP Ingest",
                   ingestion_type: "rtmp",
                   resolution: "1080p",
                   frame_rate: "60fps",
                   is_reusable: true
                 },
                 token: "tok"
               )

      assert LiveStreams.stream_key(stream) == "live_key_secret_abc"
      assert LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"
    end

    test "T1-F4-02: Retrieve Live Stream by ID & Extract Stream URLs" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=stream_202"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStreamListResponse",
            "items" => [stream_fixture()]
          })
        )
      end)

      assert {:ok, stream} = LiveStreams.get_stream("stream_202", token: "tok")
      assert LiveStreams.stream_url(stream, protocol: :rtmp) == "rtmp://a.rtmp.youtube.com/live2/live_key_secret_abc"
      assert LiveStreams.stream_url(stream, protocol: :rtmps) == "rtmps://a.rtmps.youtube.com/live2/live_key_secret_abc"
      assert LiveStreams.stream_url(stream, backup: true) == "rtmp://b.rtmp.youtube.com/live2/live_key_secret_abc?backup=1"
    end

    test "T1-F4-03: List Live Streams for Authenticated Channel" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "mine=true"
        assert conn.query_string =~ "maxResults=5"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [stream_fixture(%{"id" => "s1"}), stream_fixture(%{"id" => "s2"})],
            "nextPageToken" => "token_page_2"
          })
        )
      end)

      assert {:ok, resp} =
               LiveStreams.list_streams([mine: true, max_results: 5], token: "tok")

      assert length(resp["items"]) == 2
      assert resp["nextPageToken"] == "token_page_2"
    end

    test "T1-F4-04: Update Live Stream Settings" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "PUT"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["id"] == "stream_202"
        assert decoded["snippet"]["title"] == "Updated Stream Title"
        assert decoded["cdn"]["resolution"] == "720p"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            stream_fixture(%{
              "snippet" => %{"title" => "Updated Stream Title"},
              "cdn" => %{"resolution" => "720p"}
            })
          )
        )
      end)

      assert {:ok, updated} =
               LiveStreams.update_stream(
                 %{id: "stream_202", title: "Updated Stream Title", resolution: "720p"},
                 token: "tok"
               )

      assert updated["snippet"]["title"] == "Updated Stream Title"
    end

    test "T1-F4-05: Delete Live Stream Resource" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.query_string =~ "id=stream_202"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{id: "stream_202", deleted: true}} =
               LiveStreams.delete_stream("stream_202", token: "tok")
    end
  end

  describe "Tier 1: Feature 5 - Live Chat Reading & Poller" do
    test "T1-F5-01: List Live Chat Messages with Normalization" do
      msg = chat_message_fixture("m1", "Welcome to the stream!")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "liveChatId=chat_abc_123"
        assert conn.query_string =~ "maxResults=50"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg], "chat_page_2", 3000)))
      end)

      assert {:ok, parsed} =
               LiveChat.list_messages("chat_abc_123", max_results: 50, token: "tok")

      assert length(parsed.messages) == 1
      assert hd(parsed.messages).message_text == "Welcome to the stream!"
      assert hd(parsed.messages).is_chat_owner == true
      assert parsed.polling_interval_ms == 3000
      assert parsed.next_page_token == "chat_page_2"
    end

    test "T1-F5-02: Insert (Post) New Live Chat Message" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["liveChatId"] == "chat_abc_123"
        assert decoded["snippet"]["textMessageDetails"]["messageText"] == "Hello from Lux Agent!"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "msg_new_999",
            "snippet" => %{"displayMessage" => "Hello from Lux Agent!"}
          })
        )
      end)

      assert {:ok, resp} =
               LiveChat.insert_message("chat_abc_123", "Hello from Lux Agent!", token: "tok")

      assert resp["id"] == "msg_new_999"
    end

    test "T1-F5-03: Resolve liveChatId from Live Broadcast" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "id=bcast_101"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [%{"id" => "bcast_101", "snippet" => %{"liveChatId" => "chat_resolved_888"}}]
          })
        )
      end)

      assert {:ok, "chat_resolved_888"} = LiveChat.get_live_chat_id("bcast_101", token: "tok")
    end

    test "T1-F5-04: Poller GenServer Message Ingestion & Subscriber Notification" do
      msg1 = chat_message_fixture("m1", "Hi 1")
      msg2 = chat_message_fixture("m2", "Hi 2")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg1, msg2], "cursor_2", 3000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_poller_1",
          auto_start: false,
          subscriber: self(),
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, msgs} = Poller.poll_once(poller)
      assert length(msgs) == 2

      assert_receive {:live_chat_messages, "chat_poller_1", received_msgs}
      assert length(received_msgs) == 2

      status = Poller.get_status(poller)
      assert status.page_token == "cursor_2"
      assert status.message_count == 2
      assert status.poll_count == 1

      Poller.stop(poller)
    end

    test "T1-F5-05: Poller Dynamic Polling Interval Adjustment" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([], "c3", 8500)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_interval_test",
          default_interval_ms: 5000,
          min_interval_ms: 1000,
          max_interval_ms: 30_000,
          auto_start: false,
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, _} = Poller.poll_once(poller)
      assert Poller.get_status(poller).interval_ms == 8500

      Poller.stop(poller)
    end
  end

  describe "Tier 1: Feature 6 - Errors, Resiliency & Lenses/Prisms Execution" do
    test "T1-F6-01: HTTP 403 quotaExceeded Parsing & Classification" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota Exceeded",
          "errors" => [
            %{"domain" => "youtube.quota", "reason" => "quotaExceeded", "message" => "Quota Exceeded"}
          ]
        }
      }

      parsed = Errors.parse(403, body, [])
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "quotaExceeded"
      assert details.status == 403
      assert Errors.quota_exceeded?(parsed) == true
      assert Errors.retryable?(parsed) == false
    end

    test "T1-F6-02: HTTP 429 / 403 userRateLimitExceeded with Retry-After Header" do
      body = %{
        "error" => %{
          "code" => 403,
          "errors" => [%{"reason" => "userRateLimitExceeded"}]
        }
      }

      parsed = Errors.parse(403, body, [{"retry-after", "10"}])
      assert {:error, {:rate_limited, details}} = parsed
      assert details.retry_after == 10
      assert Errors.rate_limited?(parsed) == true
      assert Errors.retryable?(parsed) == true
    end

    test "T1-F6-03: with_retry/2 Backoff Execution on Transient Failures" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      work_fun = fn ->
        attempt = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

        if attempt < 3 do
          {:error, {:rate_limited, %{retry_after: 0, reason: "rateLimitExceeded", status: 429}}}
        else
          {:ok, :recovered}
        end
      end

      res = Errors.with_retry(work_fun, max_retries: 3, sleep_fun: fn _ -> :ok end)
      assert res == {:ok, :recovered}
      assert Agent.get(counter, & &1) == 3
      Agent.stop(counter)
    end

    test "T1-F6-04: Lux.Integrations.YouTube.add_auth_header/1 Lens Integration" do
      Application.put_env(:lux, :api_keys, youtube_access_token: "lens_token_abc")

      lens = %Lux.Lens{
        name: "YouTubeLens",
        url: "https://www.googleapis.com/youtube/v3/videos",
        headers: [{"x-agent", "1"}]
      }

      updated = YouTube.add_auth_header(lens)
      assert {"Authorization", "Bearer lens_token_abc"} in updated.headers
      assert {"x-agent", "1"} in updated.headers
    end

    test "T1-F6-05: Custom Auth & Request Settings in Lens Workflow" do
      settings = YouTube.request_settings()
      assert {"Content-Type", "application/json"} in settings.headers
      assert {"Accept", "application/json"} in settings.headers
      assert settings.auth.type == :custom
      assert settings.auth.auth_function == (&YouTube.add_auth_header/1)
    end
  end

  # ============================================================================
  # TIER 2: BOUNDARY & CORNER CASES (T2-F1 TO T2-F6, 30 TESTS)
  # ============================================================================

  describe "Tier 2: Feature 1 - OAuth 2.0 Boundary Cases" do
    test "T2-F1-01: Missing Credentials in exchange_code/2" do
      Application.put_env(:lux, :api_keys,
        youtube_client_id: nil,
        youtube_client_secret: nil
      )

      assert {:error, :missing_credentials} =
               OAuth.exchange_code("any_code", client_id: "", client_secret: nil)
    end

    test "T2-F1-02: Missing Refresh Token or Credentials in refresh_token/2" do
      Application.put_env(:lux, :api_keys,
        youtube_client_id: nil,
        youtube_client_secret: nil
      )

      assert {:error, :missing_credentials} =
               OAuth.refresh_token("valid_refresh_token", client_id: nil, client_secret: "")
    end

    test "T2-F1-03: OAuth Endpoint Returning HTTP 400 with invalid_grant Payload" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Code was already redeemed or expired."
          })
        )
      end)

      res = OAuth.exchange_code("expired_code", client_id: "cid", client_secret: "sec")
      assert res == {:error, {:oauth_error, "invalid_grant", "Code was already redeemed or expired."}}
    end

    test "T2-F1-04: authorize_url/1 with URI-Unsafe Special Characters in State & Scopes" do
      url =
        OAuth.authorize_url(%{
          client_id: "cid",
          state: "csrf&secret=1+2 3/4?foo=bar",
          login_hint: "user+tag@domain.com"
        })

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert query["state"] == "csrf&secret=1+2 3/4?foo=bar"
      assert query["login_hint"] == "user+tag@domain.com"
    end

    test "T2-F1-05: OAuth Endpoint Returning Non-JSON HTML Error Page" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          502,
          "<html><title>502 Bad Gateway</title><body>Gateway timeout</body></html>"
        )
      end)

      assert {:error, {502, "<html>" <> _}} =
               OAuth.refresh_token("tok", client_id: "cid", client_secret: "sec")
    end
  end

  describe "Tier 2: Feature 2 - Client Boundary & Error Resilience" do
    test "T2-F2-01: 401 Auto-Refresh Infinite Loop Prevention" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      res =
        Client.request(:get, "/liveBroadcasts",
          token: "bad_token",
          refresh_token: "expired_refresh",
          client_id: "cid",
          client_secret: "sec",
          auto_refresh: true
        )

      assert res == {:error, :invalid_token}
    end

    test "T2-F2-02: Client Handling Network Transport Error / Disconnection" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      res = Client.get("/liveBroadcasts", token: "tok")
      assert match?({:error, %Req.TransportError{reason: :econnrefused}}, res)
      assert Errors.retryable?(res) == true
    end

    test "T2-F2-03: Client Path Normalization with Slash-less and Absolute URLs" do
      Req.Test.expect(YouTubeClientMock, 3, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end)

      assert {:ok, _} = Client.get("liveBroadcasts", token: "tok")
      assert {:ok, _} = Client.get("/liveBroadcasts", token: "tok")
      assert {:ok, _} = Client.get("https://www.googleapis.com/youtube/v3/liveBroadcasts", token: "tok")
    end

    test "T2-F2-04: Client Receiving HTTP 500 / 503 Internal Server Error with HTML Body" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(503, "Backend server unavailable")
      end)

      res = Client.post("/liveBroadcasts", token: "tok", json: %{})
      assert match?({:error, {503, _}}, res)
      assert Errors.retryable?(res) == true
    end

    test "T2-F2-05: Client Request with Deep Nested Map and Unicode Ingestion Data" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["title"] == "Transmisión en vivo 🎥 日本語"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      res =
        Client.post("/liveBroadcasts",
          token: "tok",
          json: %{
            title: "Transmisión en vivo 🎥 日本語",
            nested: %{level1: %{level2: %{level3: %{val: 42}}}}
          }
        )

      assert {:ok, body} = res
      assert body["title"] == "Transmisión en vivo 🎥 日本語"
    end
  end

  describe "Tier 2: Feature 3 - Live Broadcast Boundary & Transition Errors" do
    test "T2-F3-01: Non-Existent Broadcast ID Returning {:error, :not_found}" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"kind" => "youtube#liveBroadcastListResponse", "items" => []})
        )
      end)

      assert {:error, :not_found} = LiveBroadcasts.get_broadcast("non_existent_bcast_id", token: "tok")
    end

    test "T2-F3-02: Invalid Transition Target Status Validation" do
      assert {:error, {:invalid_transition_status, :invalid_status}} =
               LiveBroadcasts.transition_broadcast("bcast_1", :invalid_status, token: "tok")

      assert {:error, {:invalid_transition_status, "paused"}} =
               LiveBroadcasts.transition_broadcast("bcast_1", "paused", token: "tok")
    end

    test "T2-F3-03: Missing or Blank Broadcast ID Across LiveBroadcasts Functions" do
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.get_broadcast("", token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.get_broadcast(nil, token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast("", token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.transition_broadcast("", :live, token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.bind_broadcast("", "s1", token: "tok")
    end

    test "T2-F3-04: Broadcast Unbinding with stream_id: nil or \"\"" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        refute conn.query_string =~ "streamId="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"contentDetails" => %{"boundStreamId" => nil}}))
        )
      end)

      assert {:ok, unbound} = LiveBroadcasts.bind_broadcast("bcast_101", nil, token: "tok")
      assert LiveBroadcasts.bound_stream_id(unbound) == nil
    end

    test "T2-F3-05: Live Broadcast Status Helper Resilience on Nil/Empty/Malformed Maps" do
      refute LiveBroadcasts.active?(nil)
      refute LiveBroadcasts.active?(%{})
      assert LiveBroadcasts.status(nil) == nil
      assert LiveBroadcasts.live_chat_id(%{}) == nil
      assert LiveBroadcasts.bound_stream_id(%{"contentDetails" => "malformed_string"}) == nil
    end
  end

  describe "Tier 2: Feature 4 - Live Stream Boundary & URL Formatting" do
    test "T2-F4-01: Non-Existent Live Stream ID Returning {:error, :not_found}" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"kind" => "youtube#liveStreamListResponse", "items" => []})
        )
      end)

      assert {:error, :not_found} = LiveStreams.get_stream("missing_stream_id", token: "tok")
    end

    test "T2-F4-02: Missing or Blank Stream ID Across LiveStreams Functions" do
      assert {:error, :missing_stream_id} = LiveStreams.get_stream("", token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.get_stream(nil, token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{id: ""}, token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.delete_stream("", token: "tok")
    end

    test "T2-F4-03: stream_url/2 Handling Ingestion Addresses with Query Parameters & Trailing Slashes" do
      stream =
        stream_fixture(%{
          "cdn" => %{
            "ingestionInfo" => %{
              "ingestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1&param=2/",
              "streamName" => "my_key"
            }
          }
        })

      url = LiveStreams.stream_url(stream)
      assert url == "rtmp://b.rtmp.youtube.com/live2/my_key?backup=1&param=2"
    end

    test "T2-F4-04: Stream Ingestion & Status Accessor Resilience on Malformed Data" do
      assert LiveStreams.stream_key(nil) == nil
      assert LiveStreams.stream_key(%{}) == nil
      assert LiveStreams.ingestion_address(%{"cdn" => nil}) == nil
      assert LiveStreams.stream_status(%{"status" => nil}) == nil
      assert LiveStreams.health_status(%{"status" => %{"healthStatus" => nil}}) == nil
    end

    test "T2-F4-05: Stream Creation Receiving HTTP 400 Bad Request Payload" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "Invalid ingestion type: webm",
              "errors" => [%{"reason" => "invalidIngestionType"}]
            }
          })
        )
      end)

      assert {:error, {400, "Invalid ingestion type: webm"}} =
               LiveStreams.create_stream(%{ingestion_type: "webm"}, token: "tok")
    end
  end

  describe "Tier 2: Feature 5 - Live Chat Boundary & Poller Resilience" do
    test "T2-F5-01: Missing or Blank live_chat_id in list_messages/2" do
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages("", token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(nil, token: "tok")
    end

    test "T2-F5-02: Missing or Blank Message Text / Chat ID in insert_message/3" do
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat1", "", token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat1", nil, token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "Hello", token: "tok")
    end

    test "T2-F5-03: get_live_chat_id/2 When Chat is Disabled on Broadcast" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"items" => [broadcast_fixture(%{"snippet" => %{"liveChatId" => nil}})]})
        )
      end)

      assert {:error, :no_live_chat_id} = LiveChat.get_live_chat_id("bcast_no_chat", token: "tok")
    end

    test "T2-F5-04: Poller Handling Broadcast Termination Signal (offlineAt)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(chat_list_fixture([], "c_end", 3000, "2026-08-20T22:00:00Z"))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_ended_test",
          subscriber: self(),
          auto_start: false,
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, _} = Poller.poll_once(poller)

      assert_receive {:live_chat_ended, "chat_ended_test", %{offline_at: "2026-08-20T22:00:00Z"}}
      status = Poller.get_status(poller)
      assert status.status == :ended
      assert status.offline_at == "2026-08-20T22:00:00Z"

      Poller.stop(poller)
    end

    test "T2-F5-05: Poller Dead Subscriber Cleanup via Process Monitor" do
      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_sub_cleanup",
          auto_start: false,
          token: "tok"
        )

      temp_sub =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Poller.subscribe(poller, temp_sub)
      assert Poller.get_status(poller).subscribers_count == 1

      Process.exit(temp_sub, :kill)
      :timer.sleep(50)

      assert Poller.get_status(poller).subscribers_count == 0
      Poller.stop(poller)
    end
  end

  describe "Tier 2: Feature 6 - Quota/Rate Limit Boundary & Non-Retry Logic" do
    test "T2-F6-01: Quota Exhaustion Extraction from Varied Google Error Formats" do
      b1 = %{"error" => "QUOTA_EXCEEDED"}
      b2 = %{"error" => %{"errors" => [%{"reason" => "dailyLimitExceeded"}]}}
      b3 = %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}

      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b1, [])
      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b2, [])
      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b3, [])
    end

    test "T2-F6-02: Rate Limit Parsing with Malformed, Negative, or Absent Retry-After Header" do
      assert {:error, {:rate_limited, d1}} = Errors.parse(429, %{}, [{"retry-after", "-5"}])
      assert d1.retry_after == nil

      assert {:error, {:rate_limited, d2}} = Errors.parse(429, %{}, [{"retry-after", "invalid"}])
      assert d2.retry_after == nil

      assert {:error, {:rate_limited, d3}} = Errors.parse(429, %{}, [])
      assert d3.retry_after == nil
    end

    test "T2-F6-03: with_retry/2 Max Retries Exhaustion on Persistent 503" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      work_fun = fn ->
        Agent.update(counter, &(&1 + 1))
        {:error, {503, "Service Unavailable"}}
      end

      res = Errors.with_retry(work_fun, max_retries: 3, sleep_fun: fn _ -> :ok end)
      assert res == {:error, {503, "Service Unavailable"}}
      assert Agent.get(counter, & &1) == 4
      Agent.stop(counter)
    end

    test "T2-F6-04: with_retry/2 Immediate Non-Retry on Non-Retryable 400 & 403 Quota" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      work_fun = fn ->
        Agent.update(counter, &(&1 + 1))
        {:error, {:quota_exceeded, %{reason: "quotaExceeded"}}}
      end

      res = Errors.with_retry(work_fun, max_retries: 3, sleep_fun: fn _ -> :ok end)
      assert {:error, {:quota_exceeded, _}} = res
      assert Agent.get(counter, & &1) == 1
      Agent.stop(counter)
    end

    test "T2-F6-05: add_auth_header/1 Preservation of Pre-existing Lens Params and Headers" do
      Application.put_env(:lux, :api_keys,
        youtube_access_token: nil,
        youtube_api_key: "api_k_123"
      )

      lens = %Lux.Lens{
        params: %{part: "snippet", custom_key: "custom_val"},
        headers: [{"authorization", "CustomAuth"}]
      }

      updated = YouTube.add_auth_header(lens)
      assert updated.params[:key] == "api_k_123"
      assert updated.params[:custom_key] == "custom_val"
      assert {"authorization", "CustomAuth"} in updated.headers
    end
  end

  # ============================================================================
  # TIER 3: CROSS-FEATURE COMBINATIONS (T3-PAIR-01 TO T3-PAIR-10, 10 TESTS)
  # ============================================================================

  describe "Tier 3: Cross-Feature Pairwise Combinations" do
    test "T3-PAIR-01: F1 (OAuth) + F2 (Client) - Code Exchange & Auto 401 Refresh" do
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "tok_v1",
            "refresh_token" => "ref_v1",
            "expires_in" => 3600
          })
        )
      end)

      assert {:ok, tokens} =
               OAuth.exchange_code("auth_code_init",
                 client_id: "client_123",
                 client_secret: "secret_456"
               )

      # Expired token 401 -> OAuth refresh -> 200 OK
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_v1"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{"error" => %{"code" => 401, "message" => "Token expired"}})
        )
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "tok_v2", "expires_in" => 3600})
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_v2"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [%{"id" => "bcast_101"}]}))
      end)

      assert {:ok, resp} =
               Client.get("/liveBroadcasts",
                 token: tokens["access_token"],
                 refresh_token: tokens["refresh_token"],
                 client_id: "client_123",
                 client_secret: "secret_456"
               )

      assert length(resp["items"]) == 1
    end

    test "T3-PAIR-02: F3 (LiveBroadcasts) + F4 (LiveStreams) - Broadcast & Stream Lifecycle Binding" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_201",
              "status" => %{"lifeCycleStatus" => "created"},
              "snippet" => %{"liveChatId" => "chat_201"},
              "contentDetails" => %{"boundStreamId" => nil}
            })
          )
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            stream_fixture(%{
              "id" => "stream_201",
              "cdn" => %{
                "ingestionType" => "rtmp",
                "ingestionInfo" => %{
                  "streamName" => "key_xyz",
                  "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
                  "rtmpsIngestionAddress" => "rtmps://a.rtmps.youtube.com/live2"
                }
              }
            })
          )
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_201"
        assert conn.query_string =~ "streamId=stream_201"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_201",
              "contentDetails" => %{"boundStreamId" => "stream_201"},
              "status" => %{"lifeCycleStatus" => "ready"}
            })
          )
        )
      end)

      assert {:ok, bcast} =
               LiveBroadcasts.create_broadcast(
                 %{title: "Main Stage", privacy_status: :unlisted},
                 token: "tok_valid"
               )

      assert {:ok, stream} =
               LiveStreams.create_stream(
                 %{title: "1080p Stream", ingestion_type: "rtmp"},
                 token: "tok_valid"
               )

      assert {:ok, bound} =
               LiveBroadcasts.bind_broadcast(bcast["id"], stream["id"], token: "tok_valid")

      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key_xyz"
      assert LiveStreams.stream_url(stream, protocol: :rtmps) == "rtmps://a.rtmps.youtube.com/live2/key_xyz"
      assert LiveBroadcasts.bound_stream_id(bound) == "stream_201"
      assert LiveBroadcasts.status(bound) == "ready"
    end

    test "T3-PAIR-03: F3 (LiveBroadcasts) + F5 (LiveChat) - Transition to Live & Poller Attachment" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=testing"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"id" => "bcast_301", "status" => %{"lifeCycleStatus" => "testing"}}))
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_301",
              "status" => %{"lifeCycleStatus" => "live"},
              "snippet" => %{"liveChatId" => "chat_301"}
            })
          )
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_301"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              broadcast_fixture(%{
                "id" => "bcast_301",
                "snippet" => %{"liveChatId" => "chat_301"}
              })
            ]
          })
        )
      end)

      assert {:ok, _} = LiveBroadcasts.transition_broadcast("bcast_301", :testing, token: "tok_valid")
      assert {:ok, live_bcast} = LiveBroadcasts.transition_broadcast("bcast_301", :live, token: "tok_valid")
      assert LiveBroadcasts.active?(live_bcast)

      assert {:ok, chat_id} = LiveChat.get_live_chat_id_for_broadcast("bcast_301", token: "tok_valid")
      assert chat_id == "chat_301"

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          subscriber: self(),
          auto_start: false,
          token: "tok_valid"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      msg1 = chat_message_fixture("m1", "Broadcast live now!")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg1], "tok_page2", 3000)))
      end)

      assert {:ok, msgs} = Poller.poll_once(poller)
      assert length(msgs) == 1
      assert_receive {:live_chat_messages, "chat_301", _}

      Poller.stop(poller)
    end

    test "T3-PAIR-04: F5 (LiveChat) + F6 (Resiliency) - Poller 429 Throttle & 403 Quota Recovery" do
      # 1. 429 Rate Limit
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "rateLimitExceeded"}]}})
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_401",
          subscriber: self(),
          auto_start: false,
          token: "tok_valid"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_401", {:rate_limited, %{retry_after: 2}}}
      assert Poller.get_status(poller).consecutive_errors == 1

      # 2. 403 Quota Exhaustion
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "quotaExceeded"}]}})
        )
      end)

      assert {:error, {:quota_exceeded, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_401", {:quota_exceeded, %{reason: "quotaExceeded"}}}
      assert Poller.get_status(poller).consecutive_errors == 2

      # 3. Recovery 200 OK
      msg = chat_message_fixture("m_rec", "Recovered!")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg], "tok_page_3", 3000)))
      end)

      assert {:ok, [rec_msg]} = Poller.poll_once(poller)
      assert rec_msg.message_text == "Recovered!"
      assert_receive {:live_chat_messages, "chat_401", _}

      status = Poller.get_status(poller)
      assert status.consecutive_errors == 0
      assert status.message_count == 1

      Poller.stop(poller)
    end

    test "T3-PAIR-05: F2 (Client) + L/P (Lenses & Prisms) - Lens Querying to Prism Chat Action" do
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              broadcast_fixture(%{
                "id" => "bcast_501",
                "snippet" => %{"title" => "Live Q&A", "liveChatId" => "chat_501"}
              })
            ]
          })
        )
      end)

      assert {:ok, [bcast]} = TestListBroadcastsLens.focus(%{broadcast_status: :active})
      assert bcast.live_chat_id == "chat_501"

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "msg_501",
            "snippet" => %{"displayMessage" => "Agent active"}
          })
        )
      end)

      assert {:ok, result} =
               TestSendMessagePrism.run(%{
                 live_chat_id: bcast.live_chat_id,
                 message: "Agent active",
                 token: "tok"
               })

      assert result.id == "msg_501"
      assert result.status == :sent
    end

    test "T3-PAIR-06: F1 (OAuth) + F3 (LiveBroadcasts) - Mid-Lifecycle Token Expiration during Transition" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"status" => %{"lifeCycleStatus" => "testing"}}))
        )
      end)

      assert {:ok, _} =
               LiveBroadcasts.transition_broadcast("bcast_601", :testing,
                 token: "tok_old",
                 refresh_token: "ref_tok",
                 client_id: "cid",
                 client_secret: "sec"
               )

      # 401 Unauthorized on next step
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "tok_new", "expires_in" => 3600})
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_new"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"status" => %{"lifeCycleStatus" => "live"}}))
        )
      end)

      assert {:ok, live_bcast} =
               LiveBroadcasts.transition_broadcast("bcast_601", :live,
                 token: "tok_old",
                 refresh_token: "ref_tok",
                 client_id: "cid",
                 client_secret: "sec"
               )

      assert LiveBroadcasts.active?(live_bcast)
    end

    test "T3-PAIR-07: F4 (LiveStreams) + F6 (Resiliency) - Stream Creation with Transient 503 Retry" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          503,
          Jason.encode!(%{"error" => %{"code" => 503, "message" => "Backend timeout"}})
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture(%{"id" => "stream_701"})))
      end)

      res =
        Errors.with_retry(
          fn ->
            LiveStreams.create_stream(%{title: "Resilient Stream"}, token: "tok")
          end,
          max_retries: 2,
          sleep_fun: fn _ -> :ok end
        )

      assert {:ok, stream} = res
      assert stream["id"] == "stream_701"
      assert LiveStreams.stream_key(stream) == "live_key_secret_abc"
    end

    test "T3-PAIR-08: F3 + F5 + F4 - Full Teardown & Broadcast Termination Signal Propagation" do
      # 1. Complete Broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"id" => "bcast_801", "status" => %{"lifeCycleStatus" => "complete"}}))
        )
      end)

      assert {:ok, _} = LiveBroadcasts.transition_broadcast("bcast_801", :complete, token: "tok")

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_801",
          subscriber: self(),
          auto_start: false,
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      # 2. Poller detects offlineAt
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(chat_list_fixture([], "c_done", 3000, "2026-08-17T21:00:00Z"))
        )
      end)

      assert {:ok, _} = Poller.poll_once(poller)
      assert_receive {:live_chat_ended, "chat_801", %{offline_at: "2026-08-17T21:00:00Z"}}
      assert Poller.get_status(poller).status == :ended

      # 3. Teardown stream and broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveStreams"

        conn |> Plug.Conn.send_resp(204, "")
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{deleted: true}} = LiveStreams.delete_stream("stream_801", token: "tok")
      assert {:ok, %{deleted: true}} = LiveBroadcasts.delete_broadcast("bcast_801", token: "tok")
      assert :ok = Poller.stop(poller)
    end

    test "T3-PAIR-09: F1 (OAuth) + F5 (LiveChat) - Live Chat Message Insertion with Expired Token" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer exp_tok"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "new_tok", "expires_in" => 3600})
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer new_tok"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "msg_901",
            "snippet" => %{"displayMessage" => "Message 1"}
          })
        )
      end)

      assert {:ok, resp} =
               LiveChat.insert_message("chat_901", "Message 1",
                 token: "exp_tok",
                 refresh_token: "ref_tok",
                 client_id: "cid",
                 client_secret: "sec"
               )

      assert resp["id"] == "msg_901"
      assert resp["snippet"]["displayMessage"] == "Message 1"
    end

    test "T3-PAIR-10: F2 + F3 + F4 - Concurrent Batch Fetching of Broadcasts and Streams" do
      # Set up mock to handle concurrent requests
      Req.Test.stub(YouTubeClientMock, fn conn ->
        case conn.request_path do
          "/youtube/v3/liveBroadcasts" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"items" => [broadcast_fixture()]})
            )

          "/youtube/v3/liveStreams" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"items" => [stream_fixture()]})
            )
        end
      end)

      tasks =
        1..4
        |> Enum.map(fn idx ->
          Task.async(fn ->
            if rem(idx, 2) == 0 do
              LiveBroadcasts.list_broadcasts([mine: true], token: "tok")
            else
              LiveStreams.list_streams([mine: true], token: "tok")
            end
          end)
        end)

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, fn res -> match?({:ok, _}, res) end)
    end
  end

  # ============================================================================
  # TIER 4: REAL-WORLD APPLICATION SCENARIOS (T4-SCENARIO-01 TO 05, 5 TESTS)
  # ============================================================================

  describe "Tier 4: Real-World Multi-Step Production Scenarios" do
    test "T4-SCENARIO-01: Complete Live Stream Production Workflow (9-Phase Production Lifecycle)" do
      # Phase 1: Auth Initial Exchange
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "prod_tok_1",
            "refresh_token" => "prod_ref_1",
            "expires_in" => 3600
          })
        )
      end)

      assert {:ok, tokens} =
               OAuth.exchange_code("code_prod_101", client_id: "cid", client_secret: "sec")

      token = tokens["access_token"]

      # Phase 2: Stream Provisioning
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            stream_fixture(%{
              "id" => "prod_stream_1",
              "cdn" => %{
                "ingestionType" => "rtmp",
                "ingestionInfo" => %{
                  "streamName" => "key_prod_1",
                  "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2"
                }
              }
            })
          )
        )
      end)

      assert {:ok, stream} =
               LiveStreams.create_stream(
                 %{title: "4K Keynote", ingestion_type: "rtmp", resolution: "1080p"},
                 token: token
               )

      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key_prod_1"

      # Phase 3: Broadcast Scheduling
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "prod_bcast_1",
              "snippet" => %{"title" => "Lux 2026 Keynote", "liveChatId" => "prod_chat_1"},
              "status" => %{"lifeCycleStatus" => "created"}
            })
          )
        )
      end)

      assert {:ok, bcast} =
               LiveBroadcasts.create_broadcast(
                 %{
                   title: "Lux 2026 Keynote",
                   scheduled_start_time: "2026-08-17T20:00:00Z",
                   privacy_status: :unlisted
                 },
                 token: token
               )

      assert bcast["id"] == "prod_bcast_1"

      # Phase 4: Stream Binding
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "prod_bcast_1",
              "contentDetails" => %{"boundStreamId" => "prod_stream_1"},
              "status" => %{"lifeCycleStatus" => "ready"}
            })
          )
        )
      end)

      assert {:ok, bound} = LiveBroadcasts.bind_broadcast("prod_bcast_1", "prod_stream_1", token: token)
      assert LiveBroadcasts.status(bound) == "ready"

      # Phase 5: Pre-Flight Testing
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=testing"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"id" => "prod_bcast_1", "status" => %{"lifeCycleStatus" => "testing"}}))
        )
      end)

      assert {:ok, testing_bcast} = LiveBroadcasts.transition_broadcast("prod_bcast_1", :testing, token: token)
      assert LiveBroadcasts.testing?(testing_bcast)

      # Phase 6: Going Live
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "prod_bcast_1",
              "status" => %{"lifeCycleStatus" => "live"},
              "snippet" => %{"liveChatId" => "prod_chat_1"}
            })
          )
        )
      end)

      assert {:ok, live_bcast} = LiveBroadcasts.transition_broadcast("prod_bcast_1", :live, token: token)
      assert LiveBroadcasts.active?(live_bcast)

      # Phase 7: Chat Ingestion & Announcement
      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "prod_chat_1",
          subscriber: self(),
          auto_start: false,
          token: token
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      msg1 = chat_message_fixture("m_p1", "Can't wait for keynote!")
      msg2 = chat_message_fixture("m_p2", "Audio is crisp!")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.method == "GET"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg1, msg2], "tok_p2", 3000)))
      end)

      assert {:ok, msgs} = Poller.poll_once(poller)
      assert length(msgs) == 2
      assert_receive {:live_chat_messages, "prod_chat_1", _}

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "msg_announcement",
            "snippet" => %{"displayMessage" => "Welcome to the Keynote!"}
          })
        )
      end)

      assert {:ok, _} =
               LiveChat.insert_message("prod_chat_1", "Welcome to the Keynote!", token: token)

      # Phase 8: Broadcast Completion
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"id" => "prod_bcast_1", "status" => %{"lifeCycleStatus" => "complete"}}))
        )
      end)

      assert {:ok, comp_bcast} = LiveBroadcasts.transition_broadcast("prod_bcast_1", :complete, token: token)
      assert LiveBroadcasts.complete?(comp_bcast)

      # Phase 9: Teardown & Verification
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(chat_list_fixture([], "tok_end", 3000, "2026-08-17T21:30:00Z"))
        )
      end)

      assert {:ok, _} = Poller.poll_once(poller)
      assert_receive {:live_chat_ended, "prod_chat_1", %{offline_at: "2026-08-17T21:30:00Z"}}
      assert Poller.get_status(poller).status == :ended

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveStreams"
        conn |> Plug.Conn.send_resp(204, "")
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        conn |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{deleted: true}} = LiveStreams.delete_stream("prod_stream_1", token: token)
      assert {:ok, %{deleted: true}} = LiveBroadcasts.delete_broadcast("prod_bcast_1", token: token)
      Poller.stop(poller)
    end

    test "T4-SCENARIO-02: Automated Chat Bot & Live Moderation Workflow" do
      m_cmd = chat_message_fixture("m_cmd", "!help", %{"authorDetails" => %{"displayName" => "Alice"}})
      m_spam = chat_message_fixture("m_spam", "BUY CHEAP COINS http://scam.net", %{"authorDetails" => %{"displayName" => "SpamBot"}})

      m_super =
        chat_message_fixture("m_super", "Great stream!", %{
          "snippet" => %{
            "type" => "superChatEvent",
            "superChatDetails" => %{
              "amountMicros" => 10_000_000,
              "currency" => "USD",
              "amountDisplayString" => "$10.00",
              "userComment" => "Great stream!"
            }
          },
          "authorDetails" => %{"displayName" => "Bob"}
        })

      m_regular = chat_message_fixture("m_chat", "Hello everyone!", %{"authorDetails" => %{"displayName" => "Charlie"}})

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([m_cmd, m_spam, m_super, m_regular], "cursor_mod_2", 3000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_mod_202",
          subscriber: self(),
          auto_start: false,
          token: "tok_mod"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, messages} = Poller.poll_once(poller)
      assert length(messages) == 4

      # Moderation agent logic
      actions_taken =
        Enum.map(messages, fn msg ->
          cond do
            msg.message_text == "!help" ->
              Req.Test.expect(YouTubeClientMock, fn conn ->
                {:ok, body, conn} = Plug.Conn.read_body(conn)
                decoded = Jason.decode!(body)
                assert decoded["snippet"]["textMessageDetails"]["messageText"] =~ "Commands"

                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "resp_help"}))
              end)

              LiveChat.insert_message("chat_mod_202", "@Alice Bot Commands: !help, !schedule, !about", token: "tok_mod")
              :command_replied

            msg.message_text =~ "http://" or msg.message_text =~ "scam" ->
              :spam_flagged

            LiveChat.super_chat?(msg) ->
              amount = LiveChat.super_chat_amount(msg)

              Req.Test.expect(YouTubeClientMock, fn conn ->
                {:ok, body, conn} = Plug.Conn.read_body(conn)
                decoded = Jason.decode!(body)
                assert decoded["snippet"]["textMessageDetails"]["messageText"] =~ "$10.00"

                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "resp_super"}))
              end)

              LiveChat.insert_message("chat_mod_202", "Thank you Bob for the #{amount} Super Chat!", token: "tok_mod")
              :super_chat_acknowledged

            true ->
              :regular_recorded
          end
        end)

      assert actions_taken == [:command_replied, :spam_flagged, :super_chat_acknowledged, :regular_recorded]

      # Subsequent poll with empty delta
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=cursor_mod_2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([], "cursor_mod_3", 3000)))
      end)

      assert {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).page_token == "cursor_mod_3"

      Poller.stop(poller)
    end

    test "T4-SCENARIO-03: Token Expiration and Resilient Recovery During Active Broadcast" do
      opts = [
        token: "tok_expired_init",
        refresh_token: "ref_valid_303",
        client_id: "client_303",
        client_secret: "sec_303",
        auto_refresh: true
      ]

      # 1. Background Poller triggers 401
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_expired_init"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      # OAuth token refresh
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "tok_refreshed_303", "expires_in" => 3600})
        )
      end)

      # Poller retried request with new token
      msg = chat_message_fixture("m_rec_303", "Live stream message")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_refreshed_303"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg], "c_303_next", 3000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_303",
          subscriber: self(),
          auto_start: false,
          client_opts: opts
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      Req.Test.allow(YouTubeOAuthMock, self(), poller)

      assert {:ok, msgs} = Poller.poll_once(poller)
      assert length(msgs) == 1

      # 2. Foreground operator broadcast query using refreshed token
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_refreshed_303"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [broadcast_fixture(%{"id" => "bcast_303", "status" => %{"lifeCycleStatus" => "live"}})]
          })
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.get_broadcast("bcast_303", token: "tok_refreshed_303")
      assert LiveBroadcasts.active?(bcast)

      # 3. Next poller cycle works cleanly with zero errors
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_expired_init"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([], "c_303_final", 3000)))
      end)

      assert {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).consecutive_errors == 0

      Poller.stop(poller)
    end

    test "T4-SCENARIO-04: Quota Degradation & Rate Limit Backoff Handling during Peak Chat Traffic" do
      # Stage 1: 429 Rate Limit
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "rateLimitExceeded"}]}})
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_burst_404",
          subscriber: self(),
          auto_start: false,
          token: "tok_burst",
          default_interval_ms: 1000
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_burst_404", {:rate_limited, %{retry_after: 2}}}
      assert Poller.get_status(poller).consecutive_errors == 1

      # Stage 2: 403 Quota Exhaustion
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "quotaExceeded"}]}})
        )
      end)

      assert {:error, {:quota_exceeded, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_burst_404", {:quota_exceeded, _}}
      assert Poller.get_status(poller).consecutive_errors == 2

      # Stage 3: Limit Reset & Backlog Delivery (10 queued messages)
      backlog = Enum.map(1..10, fn i -> chat_message_fixture("m_burst_#{i}", "Burst message #{i}") end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture(backlog, "cursor_recovered", 5000)))
      end)

      assert {:ok, delivered} = Poller.poll_once(poller)
      assert length(delivered) == 10
      assert_receive {:live_chat_messages, "chat_burst_404", received}
      assert length(received) == 10

      status = Poller.get_status(poller)
      assert status.consecutive_errors == 0
      assert status.message_count == 10
      assert status.interval_ms == 5000

      Poller.stop(poller)
    end

    test "T4-SCENARIO-05: Full Autonomous Lux Agent Orchestration with Lenses and Prisms" do
      # Step 1: Create Broadcast via Prism
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_agent_505",
              "snippet" => %{"title" => "Autonomous Agent Stream", "liveChatId" => "chat_agent_505"},
              "status" => %{"lifeCycleStatus" => "upcoming"}
            })
          )
        )
      end)

      assert {:ok, bcast_res} =
               TestCreateBroadcastPrism.run(%{
                 title: "Autonomous Agent Stream",
                 privacy_status: "unlisted",
                 token: "tok_agent"
               })

      assert bcast_res.id == "bcast_agent_505"
      assert bcast_res.live_chat_id == "chat_agent_505"

      # Step 2: Query via Lens
      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              broadcast_fixture(%{
                "id" => "bcast_agent_505",
                "snippet" => %{"title" => "Autonomous Agent Stream", "liveChatId" => "chat_agent_505"},
                "status" => %{"lifeCycleStatus" => "upcoming"}
              })
            ]
          })
        )
      end)

      assert {:ok, [lens_item]} = TestListBroadcastsLens.focus(%{broadcast_status: :upcoming})
      assert lens_item.id == "bcast_agent_505"

      # Step 3: Transition to Live via Prism
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_agent_505",
              "status" => %{"lifeCycleStatus" => "live"}
            })
          )
        )
      end)

      assert {:ok, %{status: "live"}} =
               TestTransitionBroadcastPrism.run(%{
                 broadcast_id: "bcast_agent_505",
                 status: :live,
                 token: "tok_agent"
               })

      # Step 4: Read Chat via Lens
      msg_init = chat_message_fixture("m_ag_0", "Stream started.")

      Req.Test.expect(Lux.Lens, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg_init])))
      end)

      assert {:ok, [chat_item]} =
               TestGetChatMessagesLens.focus(%{live_chat_id: "chat_agent_505"})

      assert chat_item.text == "Stream started."

      # Step 5: Send Announcement via Prism
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "msg_ag_1",
            "snippet" => %{"displayMessage" => "Autonomous Agent has started streaming."}
          })
        )
      end)

      assert {:ok, sent} =
               TestSendMessagePrism.run(%{
                 live_chat_id: "chat_agent_505",
                 message: "Autonomous Agent has started streaming.",
                 token: "tok_agent"
               })

      assert sent.id == "msg_ag_1"
      assert sent.status == :sent
    end
  end
end
