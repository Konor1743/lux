defmodule Lux.Integrations.YouTube.LiveStreamingAdversarialTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{LiveBroadcasts, LiveStreams}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  # ============================================================================
  # 1. Lifecycle State Transitions & Invalid Transition Stress Testing
  # ============================================================================
  describe "Lifecycle State Transitions & Invalid Transitions" do
    test "valid lifecycle transitions: :testing, :live, :complete (atom and string forms)" do
      for {status, expected_status_str} <- [
            {:testing, "testing"},
            {"testing", "testing"},
            {:live, "live"},
            {"live", "live"},
            {:complete, "complete"},
            {"complete", "complete"}
          ] do
        Req.Test.expect(YouTubeClientMock, fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
          assert conn.query_string =~ "broadcastStatus=#{expected_status_str}"
          assert conn.query_string =~ "id=bcast_trans_101"
          assert conn.query_string =~ "part=status%2Csnippet%2CcontentDetails" or conn.query_string =~ "part="

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "kind" => "youtube#liveBroadcast",
              "id" => "bcast_trans_101",
              "status" => %{"lifeCycleStatus" => expected_status_str}
            })
          )
        end)

        assert {:ok, broadcast} =
                 LiveBroadcasts.transition_broadcast("bcast_trans_101", status, token: "tok")

        assert LiveBroadcasts.status(broadcast) == expected_status_str
      end
    end

    test "rejects invalid transition statuses before making HTTP call" do
      invalid_statuses = [
        :unknown,
        :created,
        :ready,
        :test_starting,
        :live_starting,
        :abandoned,
        "CREATED",
        "READY",
        "LIVE",
        "TESTING",
        "COMPLETE",
        "",
        nil,
        12345,
        %{status: "live"},
        [:testing]
      ]

      for invalid <- invalid_statuses do
        assert {:error, {:invalid_transition_status, ^invalid}} =
                 LiveBroadcasts.transition_broadcast("bcast_123", invalid, token: "tok")
      end
    end

    test "rejects missing or empty broadcast ID for transition_broadcast" do
      for invalid_id <- [nil, "", 12345, :atom_id, %{id: "123"}] do
        assert {:error, :missing_broadcast_id} =
                 LiveBroadcasts.transition_broadcast(invalid_id, :live, token: "tok")
      end
    end

    test "handles YouTube API error when attempting terminal state transition (e.g. completed -> live)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "The broadcast has already completed and cannot transition to live.",
              "errors" => [
                %{
                  "domain" => "youtube.liveBroadcast",
                  "reason" => "invalidTransition",
                  "message" => "The broadcast has already completed and cannot transition to live."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {400, message}} =
               LiveBroadcasts.transition_broadcast("bcast_completed_999", :live, token: "tok")

      assert message =~ "broadcast has already completed"
    end

    test "handles redundant transition error (e.g. live -> live)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "The broadcast is already in the requested state.",
              "errors" => [
                %{
                  "domain" => "youtube.liveBroadcast",
                  "reason" => "redundantTransition",
                  "message" => "The broadcast is already in the requested state."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {400, msg}} =
               LiveBroadcasts.transition_broadcast("bcast_live_123", :live, token: "tok")

      assert msg =~ "already in the requested state"
    end

    test "handles 403 liveStreamingNotEnabled on transition" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "The user is not enabled for live streaming.",
              "errors" => [
                %{
                  "domain" => "youtube.liveBroadcast",
                  "reason" => "liveStreamingNotEnabled",
                  "message" => "The user is not enabled for live streaming."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {403, msg}} =
               LiveBroadcasts.transition_broadcast("bcast_unauthorized", :live, token: "tok")

      assert msg =~ "not enabled for live streaming"
    end
  end

  # ============================================================================
  # 2. Stream Bind/Unbind Collisions & Concurrency Stress Testing
  # ============================================================================
  describe "Stream Bind and Unbind Collisions" do
    test "binds broadcast to live stream ID" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_bind_1"
        assert conn.query_string =~ "streamId=stream_active_99"
        assert conn.query_string =~ "part=id%2Csnippet%2CcontentDetails%2Cstatus" or conn.query_string =~ "part="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_bind_1",
            "contentDetails" => %{
              "boundStreamId" => "stream_active_99"
            }
          })
        )
      end)

      assert {:ok, bcast} =
               LiveBroadcasts.bind_broadcast("bcast_bind_1", "stream_active_99", token: "tok")

      assert LiveBroadcasts.bound_stream_id(bcast) == "stream_active_99"
    end

    test "unbinds broadcast by passing nil or empty stream_id" do
      for unbind_arg <- [nil, ""] do
        Req.Test.expect(YouTubeClientMock, fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
          assert conn.query_string =~ "id=bcast_bind_1"
          refute conn.query_string =~ "streamId="

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "kind" => "youtube#liveBroadcast",
              "id" => "bcast_bind_1",
              "contentDetails" => %{
                "boundStreamId" => nil
              }
            })
          )
        end)

        assert {:ok, bcast} =
                 LiveBroadcasts.bind_broadcast("bcast_bind_1", unbind_arg, token: "tok")

        assert LiveBroadcasts.bound_stream_id(bcast) == nil
      end
    end

    test "rejects missing broadcast_id for bind_broadcast before network request" do
      for invalid_id <- [nil, "", 12345, :atom_id] do
        assert {:error, :missing_broadcast_id} =
                 LiveBroadcasts.bind_broadcast(invalid_id, "stream_123", token: "tok")
      end
    end

    test "handles stream binding collision (stream already bound to another broadcast)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "Stream is already bound to another broadcast.",
              "errors" => [
                %{
                  "domain" => "youtube.liveBroadcast",
                  "reason" => "streamAlreadyBound",
                  "message" => "Stream is already bound to another broadcast."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {400, msg}} =
               LiveBroadcasts.bind_broadcast("bcast_conflict", "stream_already_used", token: "tok")

      assert msg =~ "already bound"
    end

    test "handles stream not found error during bind" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{
            "error" => %{
              "code" => 404,
              "message" => "Live stream not found.",
              "errors" => [
                %{
                  "domain" => "youtube.liveStream",
                  "reason" => "streamNotFound",
                  "message" => "Live stream not found."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {404, msg}} =
               LiveBroadcasts.bind_broadcast("bcast_123", "stream_nonexistent", token: "tok")

      assert msg =~ "not found"
    end

    test "concurrent bind calls against independent broadcasts" do
      concurrency = 8

      Req.Test.stub(YouTubeClientMock, fn conn ->
        query = URI.decode_query(conn.query_string)
        bcast_id = query["id"]
        stream_id = query["streamId"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => bcast_id,
            "contentDetails" => %{"boundStreamId" => stream_id}
          })
        )
      end)

      tasks =
        for i <- 1..concurrency do
          Task.async(fn ->
            LiveBroadcasts.bind_broadcast("bcast_concurrent_#{i}", "stream_concurrent_#{i}", token: "tok")
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert length(results) == concurrency

      Enum.each(Enum.with_index(results, 1), fn {{:ok, bcast}, idx} ->
        assert bcast["id"] == "bcast_concurrent_#{idx}"
        assert LiveBroadcasts.bound_stream_id(bcast) == "stream_concurrent_#{idx}"
      end)
    end
  end

  # ============================================================================
  # 3. Empty List Responses & Not Found Handling
  # ============================================================================
  describe "Empty List Responses & Not Found Edge Cases" do
    test "get_broadcast returns {:error, :not_found} when items is empty list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_nonexistent"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "etag" => "\"etag_empty\"",
            "pageInfo" => %{"totalResults" => 0, "resultsPerPage" => 25},
            "items" => []
          })
        )
      end)

      assert {:error, :not_found} = LiveBroadcasts.get_broadcast("bcast_nonexistent", token: "tok")
    end

    test "get_stream returns {:error, :not_found} when items is empty list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=stream_nonexistent"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStreamListResponse",
            "etag" => "\"etag_empty\"",
            "pageInfo" => %{"totalResults" => 0, "resultsPerPage" => 25},
            "items" => []
          })
        )
      end)

      assert {:error, :not_found} = LiveStreams.get_stream("stream_nonexistent", token: "tok")
    end

    test "list_broadcasts returns {:ok, response} when items is empty list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "pageInfo" => %{"totalResults" => 0, "resultsPerPage" => 25},
            "items" => []
          })
        )
      end)

      assert {:ok, %{"items" => []} = resp} = LiveBroadcasts.list_broadcasts(%{}, token: "tok")
      assert resp["pageInfo"]["totalResults"] == 0
    end

    test "list_streams returns {:ok, response} when items is empty list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStreamListResponse",
            "pageInfo" => %{"totalResults" => 0, "resultsPerPage" => 25},
            "items" => []
          })
        )
      end)

      assert {:ok, %{"items" => []} = resp} = LiveStreams.list_streams(%{}, token: "tok")
      assert resp["pageInfo"]["totalResults"] == 0
    end

    test "get_broadcast / get_stream with missing or invalid ID argument" do
      for invalid_id <- [nil, "", 0, :bcast_id, %{}] do
        assert {:error, :missing_broadcast_id} = LiveBroadcasts.get_broadcast(invalid_id, token: "tok")
        assert {:error, :missing_stream_id} = LiveStreams.get_stream(invalid_id, token: "tok")
      end
    end
  end

  # ============================================================================
  # 4. Missing CDN Ingestion Keys & Stream Key / URL Extraction Stress Testing
  # ============================================================================
  describe "Missing CDN Ingestion Keys & Ingestion Extraction Edge Cases" do
    test "stream_key handles nil, empty map, missing cdn, missing ingestionInfo, and nil key" do
      assert LiveStreams.stream_key(nil) == nil
      assert LiveStreams.stream_key(%{}) == nil
      assert LiveStreams.stream_key(%{"cdn" => nil}) == nil
      assert LiveStreams.stream_key(%{"cdn" => %{}}) == nil
      assert LiveStreams.stream_key(%{"cdn" => %{"ingestionInfo" => nil}}) == nil
      assert LiveStreams.stream_key(%{"cdn" => %{"ingestionInfo" => %{}}}) == nil
      assert LiveStreams.stream_key(%{"cdn" => %{"ingestionInfo" => %{"streamName" => nil}}}) == nil
      assert LiveStreams.stream_key(%{"cdn" => %{"ingestionInfo" => %{"streamName" => ""}}}) == ""
      assert LiveStreams.stream_key(%{cdn: %{ingestion_info: %{stream_name: "valid_key"}}}) == "valid_key"
      assert LiveStreams.stream_key(%{cdn: %{ingestionInfo: %{streamName: "valid_key_camel"}}}) == "valid_key_camel"
      assert LiveStreams.stream_key(%{"ingestionInfo" => %{"streamName" => "direct_info"}}) == "direct_info"
    end

    test "ingestion_address and backup address extractors handle missing and partial keys" do
      assert LiveStreams.ingestion_address(nil) == nil
      assert LiveStreams.ingestion_address(%{}) == nil
      assert LiveStreams.backup_ingestion_address(nil) == nil
      assert LiveStreams.rtmps_ingestion_address(nil) == nil
      assert LiveStreams.rtmps_backup_ingestion_address(nil) == nil

      stream = %{
        "cdn" => %{
          "ingestionInfo" => %{
            "streamName" => "key123",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmp.youtube.com/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmp.youtube.com/live2?backup=1"
          }
        }
      }

      assert LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"
      assert LiveStreams.backup_ingestion_address(stream) == "rtmp://b.rtmp.youtube.com/live2?backup=1"
      assert LiveStreams.rtmps_ingestion_address(stream) == "rtmps://a.rtmp.youtube.com/live2"
      assert LiveStreams.rtmps_backup_ingestion_address(stream) == "rtmps://b.rtmp.youtube.com/live2?backup=1"
    end

    test "stream_url constructs full RTMP/RTMPS URL with trailing slashes, query strings, and backup flags" do
      stream = %{
        "cdn" => %{
          "ingestionInfo" => %{
            "streamName" => "key-abc-123",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2/",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmps.youtube.com/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmps.youtube.com/live2?backup=1"
          }
        }
      }

      # Primary RTMP (trims trailing slash)
      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key-abc-123"

      # Backup RTMP (preserves query params at end)
      assert LiveStreams.stream_url(stream, backup: true) ==
               "rtmp://b.rtmp.youtube.com/live2/key-abc-123?backup=1"

      # Primary RTMPS
      assert LiveStreams.stream_url(stream, protocol: :rtmps) ==
               "rtmps://a.rtmps.youtube.com/live2/key-abc-123"

      # Backup RTMPS (preserves query params at end)
      assert LiveStreams.stream_url(stream, protocol: :rtmps, backup: true) ==
               "rtmps://b.rtmps.youtube.com/live2/key-abc-123?backup=1"
    end

    test "stream_url returns nil when stream, address, or streamName is nil or blank" do
      assert LiveStreams.stream_url(nil) == nil
      assert LiveStreams.stream_url(%{}) == nil

      no_key = %{"cdn" => %{"ingestionInfo" => %{"ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2"}}}
      assert LiveStreams.stream_url(no_key) == nil

      blank_key = %{"cdn" => %{"ingestionInfo" => %{"streamName" => "", "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2"}}}
      assert LiveStreams.stream_url(blank_key) == nil

      no_addr = %{"cdn" => %{"ingestionInfo" => %{"streamName" => "key123"}}}
      assert LiveStreams.stream_url(no_addr) == nil

      blank_addr = %{"cdn" => %{"ingestionInfo" => %{"streamName" => "key123", "ingestionAddress" => ""}}}
      assert LiveStreams.stream_url(blank_addr) == nil
    end

    test "stream status, health status, active?, ready?, error? evaluation" do
      assert LiveStreams.stream_status(nil) == nil
      assert LiveStreams.health_status(nil) == nil
      assert LiveStreams.active?(nil) == false
      assert LiveStreams.ready?(nil) == false
      assert LiveStreams.error?(nil) == false

      # Active stream with good health
      active_stream = %{
        "status" => %{
          "streamStatus" => "active",
          "healthStatus" => %{"status" => "good"}
        }
      }
      assert LiveStreams.stream_status(active_stream) == "active"
      assert LiveStreams.health_status(active_stream) == "good"
      assert LiveStreams.active?(active_stream) == true
      assert LiveStreams.ready?(active_stream) == true
      assert LiveStreams.error?(active_stream) == false

      # Ready stream with noData
      ready_stream = %{
        "status" => %{
          "streamStatus" => "ready",
          "healthStatus" => %{"status" => "noData"}
        }
      }
      assert LiveStreams.active?(ready_stream) == false
      assert LiveStreams.ready?(ready_stream) == true
      assert LiveStreams.error?(ready_stream) == false

      # Error stream status
      error_stream_1 = %{
        "status" => %{
          "streamStatus" => "error",
          "healthStatus" => %{"status" => "noData"}
        }
      }
      assert LiveStreams.error?(error_stream_1) == true

      # Active stream with bad health status
      error_stream_2 = %{
        "status" => %{
          "streamStatus" => "active",
          "healthStatus" => %{"status" => "bad"}
        }
      }
      assert LiveStreams.error?(error_stream_2) == true
      assert LiveStreams.active?(error_stream_2) == true
    end
  end

  # ============================================================================
  # 5. Broadcast Helper Accessors & Watch URL Stress Testing
  # ============================================================================
  describe "Broadcast Helper Accessors & Watch URL" do
    test "accessors handle nil and empty structures without raising" do
      assert LiveBroadcasts.bound_stream_id(nil) == nil
      assert LiveBroadcasts.bound_stream_id(%{}) == nil
      assert LiveBroadcasts.live_chat_id(nil) == nil
      assert LiveBroadcasts.live_chat_id(%{}) == nil
      assert LiveBroadcasts.status(nil) == nil
      assert LiveBroadcasts.status(%{}) == nil
      assert LiveBroadcasts.life_cycle_status(nil) == nil
      assert LiveBroadcasts.active?(nil) == false
      assert LiveBroadcasts.testing?(nil) == false
      assert LiveBroadcasts.complete?(nil) == false
      assert LiveBroadcasts.upcoming?(nil) == false
      assert LiveBroadcasts.broadcast_url(nil) == nil
      assert LiveBroadcasts.broadcast_url("") == nil
      assert LiveBroadcasts.broadcast_url(%{}) == nil
    end

    test "broadcast lifecycle state predicates" do
      for {status_val, is_active, is_testing, is_complete, is_upcoming} <- [
            {"live", true, false, false, false},
            {"testing", false, true, false, false},
            {"testStarting", false, true, false, false},
            {"complete", false, false, true, false},
            {"created", false, false, false, true},
            {"ready", false, false, false, true},
            {"revoked", false, false, false, false}
          ] do
        bcast = %{"status" => %{"lifeCycleStatus" => status_val}}
        assert LiveBroadcasts.active?(bcast) == is_active
        assert LiveBroadcasts.testing?(bcast) == is_testing
        assert LiveBroadcasts.complete?(bcast) == is_complete
        assert LiveBroadcasts.upcoming?(bcast) == is_upcoming
      end
    end

    test "broadcast_url builds valid watch URL from string ID, atom map, or string map" do
      assert LiveBroadcasts.broadcast_url("abc123xyz") == "https://www.youtube.com/watch?v=abc123xyz"
      assert LiveBroadcasts.broadcast_url(%{"id" => "abc123xyz"}) == "https://www.youtube.com/watch?v=abc123xyz"
      assert LiveBroadcasts.broadcast_url(%{id: "abc123xyz"}) == "https://www.youtube.com/watch?v=abc123xyz"
    end
  end

  # ============================================================================
  # 6. Malformed Query Params, Options & Parameter Permutations
  # ============================================================================
  describe "Malformed Query Params & Options Permutations" do
    test "list_broadcasts with list of IDs formats comma-separated id param and omits mine" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=id1%2Cid2%2Cid3" or conn.query_string =~ "id=id1,id2,id3"
        refute conn.query_string =~ "mine="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, _} =
               LiveBroadcasts.list_broadcasts(%{id: ["id1", "id2", "id3"]}, token: "tok")
    end

    test "list_streams with list of IDs formats comma-separated id param and omits mine" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=st1%2Cst2" or conn.query_string =~ "id=st1,st2"
        refute conn.query_string =~ "mine="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, _} = LiveStreams.list_streams(%{id: ["st1", "st2"]}, token: "tok")
    end

    test "list_broadcasts with broadcast_status and broadcast_type atom parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "broadcastStatus=active"
        assert conn.query_string =~ "broadcastType=event"
        assert conn.query_string =~ "maxResults=50"
        assert conn.query_string =~ "pageToken=cursor_next_token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      params = %{
        broadcast_status: :active,
        broadcast_type: :event,
        max_results: 50,
        page_token: "cursor_next_token"
      }

      assert {:ok, _} = LiveBroadcasts.list_broadcasts(params, token: "tok")
    end

    test "list_broadcasts with onBehalfOfContentOwner in params" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner_account_123"
        assert conn.query_string =~ "onBehalfOfContentOwnerChannel=channel_456"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      params = %{
        on_behalf_of_content_owner: "owner_account_123",
        on_behalf_of_content_owner_channel: "channel_456"
      }

      assert {:ok, _} = LiveBroadcasts.list_broadcasts(params, token: "tok")
    end

    test "create_broadcast with unicode, special characters, and emojis in title & description" do
      special_title = "🔴 Lux Agent Live Stream 🚀 | 日本語 & Français !@#$%^&*()_+"
      special_desc = "Testing unicode:\n\tLine 1: 漢字\n\tLine 2: <script>alert(1)</script>"

      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["title"] == special_title
        assert decoded["snippet"]["description"] == special_desc

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_unicode_1",
            "snippet" => %{
              "title" => special_title,
              "description" => special_desc
            }
          })
        )
      end)

      assert {:ok, bcast} =
               LiveBroadcasts.create_broadcast(
                 %{title: special_title, description: special_desc},
                 token: "tok"
               )

      assert bcast["snippet"]["title"] == special_title
    end

    test "update_broadcast and update_stream with missing ID argument returns {:error, :missing_*_id}" do
      for invalid_params <- [%{}, %{title: "New Title"}, [title: "New Title"], nil] do
        assert {:error, :missing_broadcast_id} = LiveBroadcasts.update_broadcast(invalid_params, token: "tok")
        assert {:error, :missing_stream_id} = LiveStreams.update_stream(invalid_params, token: "tok")
      end
    end

    test "delete_broadcast and delete_stream with missing ID argument returns {:error, :missing_*_id}" do
      for invalid_id <- [nil, "", 0, :atom_id, %{id: "123"}] do
        assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast(invalid_id, token: "tok")
        assert {:error, :missing_stream_id} = LiveStreams.delete_stream(invalid_id, token: "tok")
      end
    end

    test "delete_broadcast and delete_stream succeed on 204 or 200 responses" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_del_10"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{id: "bcast_del_10", deleted: true}} =
               LiveBroadcasts.delete_broadcast("bcast_del_10", token: "tok")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=stream_del_10"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{id: "stream_del_10", deleted: true}} =
               LiveStreams.delete_stream("stream_del_10", token: "tok")
    end
  end

  # ============================================================================
  # 7. Comprehensive HTTP Error Matrix for Live Broadcasts & Streams
  # ============================================================================
  describe "API Error Matrix (400, 401, 403, 404, 409, 429, 500)" do
    test "401 unauthorized triggers token auto-refresh and retries" do
      # 1st call fails 401
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))
      end)

      # OAuth refresh succeeds
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "refreshed_m2_token"}))
      end)

      # 2nd call succeeds
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer refreshed_m2_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [%{"id" => "bcast_refreshed_1"}]
          })
        )
      end)

      opts = [
        token: "expired_tok",
        refresh_token: "rtok",
        client_id: "cid",
        client_secret: "csec"
      ]

      assert {:ok, %{"items" => [%{"id" => "bcast_refreshed_1"}]}} =
               LiveBroadcasts.list_broadcasts(%{}, opts)
    end

    test "403 quotaExceeded returns structured quota error" do
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
                  "reason" => "quotaExceeded",
                  "message" => "The request cannot be completed because you have exceeded your quota."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveBroadcasts.create_broadcast(%{title: "Stream Out of Quota"}, token: "tok")

      assert details.reason == "quotaExceeded"
    end

    test "429 rateLimitExceeded with Retry-After header returns structured rate limit error" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "15")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{
              "code" => 429,
              "message" => "Too Many Requests",
              "status" => "RESOURCE_EXHAUSTED"
            }
          })
        )
      end)

      assert {:error, {:rate_limited, details}} =
               LiveStreams.create_stream(%{title: "Throttled Stream"}, token: "tok")

      assert details.status == 429
      assert details.retry_after == 15
    end

    test "500 Internal Server Error returns raw status and error message" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{
            "error" => %{
              "code" => 500,
              "message" => "Internal error encountered on backend."
            }
          })
        )
      end)

      assert {:error, {500, msg}} =
               LiveBroadcasts.get_broadcast("bcast_500", token: "tok")

      assert msg =~ "Internal error"
    end
  end

  # ============================================================================
  # 8. Empirical Vulnerability & Edge Case Demonstrations
  # ============================================================================
  describe "Empirical Vulnerabilities & Payload Parsing Nuances" do
    test "get_boolean correctly preserves explicit `false` values" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["contentDetails"]["enableDvr"] == false
        assert decoded["contentDetails"]["enableAutoStart"] == false
        assert decoded["contentDetails"]["enableAutoStop"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "bcast_false_demo"}))
      end)

      params = %{
        title: "False Boolean Stress Test",
        enable_dvr: false,
        enable_auto_start: false,
        enable_auto_stop: true
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "tok")
    end

    test "DEMONSTRATION: update_broadcast with string keys drops snippet and status updates" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Because build_snippet_for_update checks `params[:title]` instead of string key,
        # snippet is omitted entirely from update payload!
        assert decoded["id"] == "bcast_str_keys"
        refute Map.has_key?(decoded, "snippet")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "bcast_str_keys"}))
      end)

      # Invoking with string-keyed map
      params = %{"id" => "bcast_str_keys", "title" => "New String Title"}
      assert {:ok, _} = LiveBroadcasts.update_broadcast(params, token: "tok")
    end
  end
end
