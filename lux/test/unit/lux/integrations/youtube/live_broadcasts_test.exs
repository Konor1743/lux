defmodule Lux.Integrations.YouTube.LiveBroadcastsTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.LiveBroadcasts

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp broadcast_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveBroadcast",
        "etag" => "\"etag_broadcast_123\"",
        "id" => "bcast_test_123",
        "snippet" => %{
          "publishedAt" => "2026-08-17T18:00:00Z",
          "channelId" => "UC_channel_123",
          "title" => "Lux Live Event",
          "description" => "Autonomous agent live stream",
          "scheduledStartTime" => "2026-08-17T20:00:00Z",
          "scheduledEndTime" => "2026-08-17T22:00:00Z",
          "isDefaultBroadcast" => false,
          "liveChatId" => "chat_id_abc123"
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
            "embedHtml" => "<iframe src=\"https://youtube.com/embed/bcast_test_123\"></iframe>"
          },
          "enableEmbed" => true,
          "enableDvr" => true,
          "enableContentEncryption" => false,
          "startWithSlate" => false,
          "recordFromStart" => true,
          "enableClosedCaptions" => false,
          "latencyPreference" => "low",
          "enableAutoStart" => true,
          "enableAutoStop" => true
        }
      },
      overrides
    )
  end

  describe "create_broadcast/2" do
    test "creates a broadcast with flat friendly parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "part=snippet%2Cstatus%2CcontentDetails" or conn.query_string =~ "part="
        assert decoded["snippet"]["title"] == "Autonomous Agent Livestream"
        assert decoded["snippet"]["description"] == "Live demo of Lux agents"
        assert decoded["snippet"]["scheduledStartTime"] == "2026-08-17T20:00:00Z"
        assert decoded["snippet"]["scheduledEndTime"] == "2026-08-17T22:00:00Z"
        assert decoded["status"]["privacyStatus"] == "unlisted"
        assert decoded["status"]["selfDeclaredMadeForKids"] == false
        assert decoded["contentDetails"]["enableAutoStart"] == true
        assert decoded["contentDetails"]["enableAutoStop"] == true
        assert decoded["contentDetails"]["enableDvr"] == true
        assert decoded["contentDetails"]["latencyPreference"] == "low"
        assert decoded["contentDetails"]["monitorStream"]["enableMonitorStream"] == true
        assert decoded["contentDetails"]["monitorStream"]["broadcastStreamDelayMs"] == 0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture(%{"id" => "bcast_created_1"})))
      end)

      params = %{
        title: "Autonomous Agent Livestream",
        description: "Live demo of Lux agents",
        scheduled_start_time: "2026-08-17T20:00:00Z",
        scheduled_end_time: "2026-08-17T22:00:00Z",
        privacy_status: :unlisted,
        enable_auto_start: true,
        enable_auto_stop: true,
        enable_dvr: true,
        latency_preference: :low,
        monitor_stream: %{
          enable_monitor_stream: true,
          broadcast_stream_delay_ms: 0
        }
      }

      assert {:ok, broadcast} = LiveBroadcasts.create_broadcast(params, token: "test_token")
      assert broadcast["id"] == "bcast_created_1"
      assert LiveBroadcasts.live_chat_id(broadcast) == "chat_id_abc123"
    end

    test "creates a broadcast with DateTime structs and atom latency" do
      dt_start = ~U[2026-08-17 21:00:00Z]
      dt_end = ~U[2026-08-17 23:00:00Z]

      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["scheduledStartTime"] == "2026-08-17T21:00:00Z"
        assert decoded["snippet"]["scheduledEndTime"] == "2026-08-17T23:00:00Z"
        assert decoded["contentDetails"]["latencyPreference"] == "ultraLow"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      params = %{
        title: "Ultra Low Latency Stream",
        scheduled_start_time: dt_start,
        scheduled_end_time: dt_end,
        latency_preference: :ultra_low
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "test_token")
    end

    test "creates a broadcast with NaiveDateTime struct" do
      ndt = ~N[2026-08-17 21:00:00]

      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["scheduledStartTime"] == "2026-08-17T21:00:00Z"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      params = %{
        title: "Naive DateTime Stream",
        scheduled_start_time: ndt
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "test_token")
    end

    test "creates a broadcast with pre-structured nested YouTube map" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["title"] == "Nested Map Stream"
        assert decoded["status"]["privacyStatus"] == "private"
        assert decoded["contentDetails"]["enableEmbed"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      params = %{
        snippet: %{title: "Nested Map Stream"},
        status: %{privacyStatus: "private"},
        contentDetails: %{enableEmbed: true}
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "test_token")
    end

    test "supports onBehalfOfContentOwner and custom part parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "part=snippet"
        assert conn.query_string =~ "onBehalfOfContentOwner=owner_xyz"
        assert conn.query_string =~ "onBehalfOfContentOwnerChannel=chan_xyz"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      params = %{
        title: "CMS Stream",
        on_behalf_of_content_owner: "owner_xyz",
        on_behalf_of_content_owner_channel: "chan_xyz",
        part: "snippet"
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "test_token")
    end

    test "propagates API errors properly" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "errors" => [%{"reason" => "quotaExceeded", "message" => "Daily quota exceeded"}]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveBroadcasts.create_broadcast(%{title: "Fails"}, token: "test_token")

      assert details.reason == "quotaExceeded"
    end
  end

  describe "list_broadcasts/2" do
    test "lists broadcasts with default mine=true" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "mine=true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [broadcast_fixture()],
            "nextPageToken" => "token_next_page"
          })
        )
      end)

      assert {:ok, resp} = LiveBroadcasts.list_broadcasts(%{}, token: "test_token")
      assert length(resp["items"]) == 1
      assert resp["nextPageToken"] == "token_next_page"
    end

    test "filters by broadcast_status and pagination" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "broadcastStatus=active"
        assert conn.query_string =~ "broadcastType=event"
        assert conn.query_string =~ "maxResults=10"
        assert conn.query_string =~ "pageToken=cursor_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [broadcast_fixture()]}))
      end)

      params = %{
        broadcast_status: :active,
        broadcast_type: :event,
        max_results: 10,
        page_token: "cursor_123"
      }

      assert {:ok, resp} = LiveBroadcasts.list_broadcasts(params, token: "test_token")
      assert length(resp["items"]) == 1
    end

    test "filters by multiple broadcast IDs" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "id=b1%2Cb2"
        refute conn.query_string =~ "mine=true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [broadcast_fixture()]}))
      end)

      assert {:ok, _} = LiveBroadcasts.list_broadcasts(%{id: ["b1", "b2"]}, token: "test_token")
    end

    test "accepts keyword list parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "broadcastStatus=upcoming"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, resp} = LiveBroadcasts.list_broadcasts([broadcast_status: :upcoming], token: "test_token")
      assert resp["items"] == []
    end
  end

  describe "get_broadcast/2" do
    test "retrieves single broadcast by ID" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.query_string =~ "id=bcast_target_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [broadcast_fixture(%{"id" => "bcast_target_1"})]
          })
        )
      end)

      assert {:ok, broadcast} = LiveBroadcasts.get_broadcast("bcast_target_1", token: "test_token")
      assert broadcast["id"] == "bcast_target_1"
      assert LiveBroadcasts.status(broadcast) == "created"
      assert LiveBroadcasts.upcoming?(broadcast) == true
      assert LiveBroadcasts.active?(broadcast) == false
    end

    test "returns {:error, :not_found} when items is empty" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:error, :not_found} = LiveBroadcasts.get_broadcast("nonexistent", token: "test_token")
    end

    test "returns {:error, :missing_broadcast_id} for invalid ID" do
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.get_broadcast("", token: "test_token")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.get_broadcast(nil, token: "test_token")
    end

    test "supports list of parts in options" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "part=snippet%2Cstatus"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [broadcast_fixture()]}))
      end)

      assert {:ok, _} = LiveBroadcasts.get_broadcast("bcast_1", part: [:snippet, :status], token: "test_token")
    end
  end

  describe "update_broadcast/2" do
    test "updates broadcast snippet and status fields" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "PUT"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert decoded["id"] == "bcast_to_update"
        assert decoded["snippet"]["title"] == "Updated Title"
        assert decoded["status"]["privacyStatus"] == "private"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"id" => "bcast_to_update"}))
        )
      end)

      params = %{
        id: "bcast_to_update",
        title: "Updated Title",
        privacy_status: :private
      }

      assert {:ok, updated} = LiveBroadcasts.update_broadcast(params, token: "test_token")
      assert updated["id"] == "bcast_to_update"
    end

    test "returns {:error, :missing_broadcast_id} when id is missing" do
      assert {:error, :missing_broadcast_id} =
               LiveBroadcasts.update_broadcast(%{title: "No ID"}, token: "test_token")

      assert {:error, :missing_broadcast_id} =
               LiveBroadcasts.update_broadcast(%{id: ""}, token: "test_token")
    end
  end

  describe "transition_broadcast/3" do
    test "transitions to :testing status" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=testing"
        assert conn.query_string =~ "id=bcast_trans"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_trans",
              "status" => %{"lifeCycleStatus" => "testing"}
            })
          )
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.transition_broadcast("bcast_trans", :testing, token: "test_token")
      assert LiveBroadcasts.status(bcast) == "testing"
      assert LiveBroadcasts.testing?(bcast) == true
      assert LiveBroadcasts.active?(bcast) == false
    end

    test "transitions to :live status" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "broadcastStatus=live"
        assert conn.query_string =~ "id=bcast_trans"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_trans",
              "status" => %{"lifeCycleStatus" => "live"}
            })
          )
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.transition_broadcast("bcast_trans", :live, token: "test_token")
      assert LiveBroadcasts.active?(bcast) == true
      assert LiveBroadcasts.complete?(bcast) == false
    end

    test "transitions to :complete status" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "broadcastStatus=complete"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_trans",
              "status" => %{"lifeCycleStatus" => "complete"}
            })
          )
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.transition_broadcast("bcast_trans", "complete", token: "test_token")
      assert LiveBroadcasts.complete?(bcast) == true
      assert LiveBroadcasts.active?(bcast) == false
    end

    test "rejects invalid transition status" do
      assert {:error, {:invalid_transition_status, :created}} =
               LiveBroadcasts.transition_broadcast("bcast_1", :created, token: "test_token")

      assert {:error, {:invalid_transition_status, "invalid"}} =
               LiveBroadcasts.transition_broadcast("bcast_1", "invalid", token: "test_token")
    end

    test "returns {:error, :missing_broadcast_id} when id is invalid" do
      assert {:error, :missing_broadcast_id} =
               LiveBroadcasts.transition_broadcast("", :live, token: "test_token")

      assert {:error, :missing_broadcast_id} =
               LiveBroadcasts.transition_broadcast(nil, :live, token: "test_token")
    end

    test "propagates API 400 invalidTransition error" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "The broadcast cannot transition to the testing status."
            }
          })
        )
      end)

      assert {:error, {400, "The broadcast cannot transition to the testing status."}} =
               LiveBroadcasts.transition_broadcast("bcast_1", :testing, token: "test_token")
    end
  end

  describe "bind_broadcast/3" do
    test "binds broadcast to stream ID" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_bind_1"
        assert conn.query_string =~ "streamId=stream_target_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_bind_1",
              "contentDetails" => %{"boundStreamId" => "stream_target_1"}
            })
          )
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.bind_broadcast("bcast_bind_1", "stream_target_1", token: "test_token")
      assert LiveBroadcasts.bound_stream_id(bcast) == "stream_target_1"
    end

    test "unbinds broadcast when stream_id is nil" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "id=bcast_bind_1"
        refute conn.query_string =~ "streamId="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            broadcast_fixture(%{
              "id" => "bcast_bind_1",
              "contentDetails" => %{"boundStreamId" => nil}
            })
          )
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.bind_broadcast("bcast_bind_1", nil, token: "test_token")
      assert LiveBroadcasts.bound_stream_id(bcast) == nil
    end

    test "returns error on missing broadcast ID in bind" do
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.bind_broadcast("", "stream_1", token: "test_token")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.bind_broadcast(nil, "stream_1", token: "test_token")
    end
  end

  describe "delete_broadcast/2" do
    test "deletes broadcast by ID (HTTP 204)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_del"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{id: "bcast_del", deleted: true}} =
               LiveBroadcasts.delete_broadcast("bcast_del", token: "test_token")
    end

    test "returns error on missing broadcast ID in delete" do
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast("", token: "test_token")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast(nil, token: "test_token")
    end
  end

  describe "helper accessors" do
    setup do
      broadcast = broadcast_fixture(%{
        "id" => "bcast_helper_123",
        "snippet" => %{
          "liveChatId" => "chat_xyz",
          "title" => "Helper Test"
        },
        "status" => %{
          "lifeCycleStatus" => "live"
        },
        "contentDetails" => %{
          "boundStreamId" => "str_helper_456"
        }
      })

      {:ok, broadcast: broadcast}
    end

    test "extracts fields properly from map", %{broadcast: broadcast} do
      assert LiveBroadcasts.bound_stream_id(broadcast) == "str_helper_456"
      assert LiveBroadcasts.live_chat_id(broadcast) == "chat_xyz"
      assert LiveBroadcasts.status(broadcast) == "live"
      assert LiveBroadcasts.life_cycle_status(broadcast) == "live"
      assert LiveBroadcasts.active?(broadcast) == true
      assert LiveBroadcasts.complete?(broadcast) == false
      assert LiveBroadcasts.testing?(broadcast) == false
      assert LiveBroadcasts.upcoming?(broadcast) == false
      assert LiveBroadcasts.broadcast_url(broadcast) == "https://www.youtube.com/watch?v=bcast_helper_123"
      assert LiveBroadcasts.broadcast_url("bcast_direct") == "https://www.youtube.com/watch?v=bcast_direct"
    end

    test "handles atom keys in helper accessors" do
      atom_map = %{
        id: "bcast_atom",
        snippet: %{live_chat_id: "chat_atom"},
        status: %{life_cycle_status: "testing"},
        content_details: %{bound_stream_id: "str_atom"}
      }

      assert LiveBroadcasts.bound_stream_id(atom_map) == "str_atom"
      assert LiveBroadcasts.live_chat_id(atom_map) == "chat_atom"
      assert LiveBroadcasts.status(atom_map) == "testing"
      assert LiveBroadcasts.testing?(atom_map) == true
      assert LiveBroadcasts.broadcast_url(atom_map) == "https://www.youtube.com/watch?v=bcast_atom"
    end

    test "handles nil inputs safely" do
      assert LiveBroadcasts.bound_stream_id(nil) == nil
      assert LiveBroadcasts.live_chat_id(nil) == nil
      assert LiveBroadcasts.status(nil) == nil
      assert LiveBroadcasts.life_cycle_status(nil) == nil
      assert LiveBroadcasts.active?(nil) == false
      assert LiveBroadcasts.testing?(nil) == false
      assert LiveBroadcasts.complete?(nil) == false
      assert LiveBroadcasts.upcoming?(nil) == false
      assert LiveBroadcasts.broadcast_url(nil) == nil
    end

    test "default_parts returns expected string" do
      assert LiveBroadcasts.default_parts() == "snippet,status,contentDetails"
    end
  end

  describe "advanced create & update parameter permutations" do
    test "create_broadcast with additional optional content details and default broadcast flag" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["isDefaultBroadcast"] == true
        assert decoded["contentDetails"]["startWithSlate"] == true
        assert decoded["contentDetails"]["recordFromStart"] == true
        assert decoded["contentDetails"]["enableClosedCaptions"] == true
        assert decoded["contentDetails"]["closedCaptionsType"] == "closedCaptionsHttpPost"
        assert decoded["contentDetails"]["enableLowLatency"] == true
        assert decoded["contentDetails"]["enableContentEncryption"] == true
        assert decoded["contentDetails"]["enableEmbed"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      params = %{
        title: "Full Options Stream",
        is_default_broadcast: true,
        start_with_slate: true,
        record_from_start: true,
        enable_closed_captions: true,
        closed_captions_type: "closedCaptionsHttpPost",
        enable_low_latency: true,
        enable_content_encryption: true,
        enable_embed: true
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "test_token")
    end

    test "update_broadcast with comprehensive content details and status fields" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["id"] == "bcast_full_update"
        assert decoded["snippet"]["description"] == "Updated Description"
        assert decoded["status"]["selfDeclaredMadeForKids"] == true
        assert decoded["contentDetails"]["enableAutoStart"] == true
        assert decoded["contentDetails"]["enableAutoStop"] == true
        assert decoded["contentDetails"]["enableDvr"] == true
        assert decoded["contentDetails"]["latencyPreference"] == "normal"
        assert decoded["contentDetails"]["monitorStream"]["enableMonitorStream"] == false

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture(%{"id" => "bcast_full_update"})))
      end)

      params = %{
        id: "bcast_full_update",
        description: "Updated Description",
        self_declared_made_for_kids: true,
        enable_auto_start: true,
        enable_auto_stop: true,
        enable_dvr: true,
        latency_preference: :normal,
        monitor_stream: %{
          enable_monitor_stream: false,
          broadcast_stream_delay_ms: 1000
        }
      }

      assert {:ok, bcast} = LiveBroadcasts.update_broadcast(params, token: "test_token")
      assert bcast["id"] == "bcast_full_update"
    end

    test "update_broadcast with string keys" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["id"] == "bcast_str_key"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture(%{"id" => "bcast_str_key"})))
      end)

      params = %{"id" => "bcast_str_key", "title" => "New String Title"}
      assert {:ok, _} = LiveBroadcasts.update_broadcast(params, token: "test_token")
    end

    test "list_broadcasts with persistent broadcastType and content owner options" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "broadcastType=persistent"
        assert conn.query_string =~ "broadcastStatus=all"
        assert conn.query_string =~ "onBehalfOfContentOwner=owner123"
        assert conn.query_string =~ "onBehalfOfContentOwnerChannel=chan456"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, _} =
               LiveBroadcasts.list_broadcasts(
                 %{
                   broadcast_type: :persistent,
                   broadcast_status: :all,
                   on_behalf_of_content_owner: "owner123",
                   on_behalf_of_content_owner_channel: "chan456"
                 },
                 token: "test_token"
               )
    end

    test "create_broadcast and update_broadcast with DateTime, NaiveDateTime and latency options" do
      dt = ~U[2026-08-20 18:00:00Z]
      ndt = ~N[2026-08-20 20:00:00]

      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["scheduledStartTime"] == "2026-08-20T18:00:00Z"
        assert decoded["snippet"]["scheduledEndTime"] == "2026-08-20T20:00:00Z"
        assert decoded["contentDetails"]["latencyPreference"] == "ultraLow"
        assert decoded["status"]["privacyStatus"] == "unlisted"
        assert conn.query_string =~ "onBehalfOfContentOwner=owner123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      params = %{
        title: "Date test",
        scheduled_start_time: dt,
        scheduled_end_time: ndt,
        latency_preference: :ultra_low,
        privacy_status: :unlisted
      }

      assert {:ok, _} =
               LiveBroadcasts.create_broadcast(params,
                 token: "test_token",
                 on_behalf_of_content_owner: "owner123",
                 on_behalf_of_content_owner_channel: "chan456"
               )

      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["scheduledStartTime"] == "2026-08-20T18:00:00Z"
        assert decoded["snippet"]["scheduledEndTime"] == "2026-08-20T20:00:00Z"
        assert conn.query_string =~ "part=snippet%2Cstatus"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture(%{"id" => "b1"})))
      end)

      update_params = %{
        id: "b1",
        scheduled_start_time: dt,
        scheduled_end_time: ndt
      }

      assert {:ok, _} =
               LiveBroadcasts.update_broadcast(update_params,
                 part: [:snippet, :status],
                 token: "test_token",
                 on_behalf_of_content_owner: "owner123"
               )
    end

    test "transition, bind, and delete broadcast pass on_behalf_of_content_owner" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner123"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      assert {:ok, _} =
               LiveBroadcasts.transition_broadcast("b1", :testing,
                 token: "tok",
                 on_behalf_of_content_owner: "owner123"
               )

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner123"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      assert {:ok, _} =
               LiveBroadcasts.bind_broadcast("b1", "s1",
                 token: "tok",
                 on_behalf_of_content_owner: "owner123"
               )

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner123"
        conn |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, _} =
               LiveBroadcasts.delete_broadcast("b1",
                 token: "tok",
                 on_behalf_of_content_owner: "owner123"
               )
    end

    test "get_broadcast handles single broadcast response and API errors" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"kind" => "youtube#liveBroadcast", "id" => "single_bcast"}))
      end)

      assert {:ok, bcast} = LiveBroadcasts.get_broadcast("single_bcast", token: "tok")
      assert bcast["id"] == "single_bcast"

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "Failed"}}))
      end)

      assert {:error, {500, "Failed"}} = LiveBroadcasts.get_broadcast("err_bcast", token: "tok")
    end

    test "delete_broadcast, transition_broadcast, and bind_broadcast error handling" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => %{"message" => "Denied"}}))
      end)

      assert {:error, {403, "Denied"}} = LiveBroadcasts.delete_broadcast("del_err", token: "tok")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "Server Error"}}))
      end)

      assert {:error, {500, "Server Error"}} = LiveBroadcasts.bind_broadcast("bind_err", "s1", token: "tok")
    end

    test "builders handle nested camelCase maps and keyword list params" do
      params = [
        snippet: %{
          "title" => "KW Title",
          "description" => "KW Desc",
          "scheduledStartTime" => "2026-08-20T10:00:00Z",
          "scheduledEndTime" => "2026-08-20T12:00:00Z",
          "isDefaultBroadcast" => true
        },
        status: %{
          "privacyStatus" => "private",
          "selfDeclaredMadeForKids" => true
        },
        content_details: %{
          "enableAutoStart" => true,
          "enableAutoStop" => true,
          "enableDvr" => true,
          "enableContentEncryption" => true,
          "enableEmbed" => true,
          "recordFromStart" => true,
          "startWithSlate" => true,
          "enableClosedCaptions" => true,
          "closedCaptionsType" => "closedCaptionsHttpPost",
          "enableLowLatency" => true,
          "latencyPreference" => "ultraLow",
          "monitorStream" => %{
            "enableMonitorStream" => true,
            "broadcastStreamDelayMs" => 5000
          }
        }
      ]

      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["snippet"]["title"] == "KW Title"
        assert decoded["contentDetails"]["enableAutoStart"] == true
        assert decoded["contentDetails"]["monitorStream"]["broadcastStreamDelayMs"] == 5000

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(broadcast_fixture()))
      end)

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "tok")
    end

    test "helper accessors with camelCase atom keys" do
      broadcast = %{
        contentDetails: %{boundStreamId: "stream_camel"},
        snippet: %{liveChatId: "chat_camel"},
        status: %{lifeCycleStatus: "created"}
      }

      assert LiveBroadcasts.bound_stream_id(broadcast) == "stream_camel"
      assert LiveBroadcasts.live_chat_id(broadcast) == "chat_camel"
      assert LiveBroadcasts.status(broadcast) == "created"
      assert LiveBroadcasts.upcoming?(broadcast) == true
      assert LiveBroadcasts.broadcast_url(%{}) == nil
      assert LiveBroadcasts.broadcast_url("") == nil
    end
  end
end
