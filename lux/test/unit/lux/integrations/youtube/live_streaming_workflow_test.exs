defmodule Lux.Integrations.YouTube.LiveStreamingWorkflowTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{LiveBroadcasts, LiveStreams}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "end-to-end live streaming workflow" do
    test "executes full lifecycle: create broadcast -> create stream -> bind -> transition -> delete" do
      # 1. Mock create_broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "part=snippet%2Cstatus%2CcontentDetails" or conn.query_string =~ "part="

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["snippet"]["title"] == "Autonomous Agent Stream"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_e2e_1",
            "snippet" => %{
              "title" => "Autonomous Agent Stream",
              "liveChatId" => "chat_e2e_999"
            },
            "status" => %{"lifeCycleStatus" => "created", "privacyStatus" => "public"},
            "contentDetails" => %{"boundStreamId" => nil}
          })
        )
      end)

      # 2. Mock create_stream
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveStreams"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["cdn"]["ingestionType"] == "rtmp"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStream",
            "id" => "stream_e2e_2",
            "cdn" => %{
              "ingestionType" => "rtmp",
              "ingestionInfo" => %{
                "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
                "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
                "streamName" => "key_secret_live"
              },
              "resolution" => "1080p",
              "frameRate" => "60fps"
            },
            "status" => %{"streamStatus" => "ready", "healthStatus" => %{"status" => "good"}}
          })
        )
      end)

      # 3. Mock bind_broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_e2e_1"
        assert conn.query_string =~ "streamId=stream_e2e_2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_e2e_1",
            "contentDetails" => %{"boundStreamId" => "stream_e2e_2"},
            "status" => %{"lifeCycleStatus" => "ready"}
          })
        )
      end)

      # 4a. Mock transition to testing
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=testing"
        assert conn.query_string =~ "id=bcast_e2e_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_e2e_1",
            "status" => %{"lifeCycleStatus" => "testing"}
          })
        )
      end)

      # 4b. Mock transition to live
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"
        assert conn.query_string =~ "id=bcast_e2e_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_e2e_1",
            "status" => %{"lifeCycleStatus" => "live"}
          })
        )
      end)

      # 4c. Mock transition to complete
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"
        assert conn.query_string =~ "id=bcast_e2e_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_e2e_1",
            "status" => %{"lifeCycleStatus" => "complete"}
          })
        )
      end)

      # 5a. Mock delete broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_e2e_1"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      # 5b. Mock delete stream
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=stream_e2e_2"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      opts = [token: "test_oauth_token"]

      # Step 1: Create broadcast
      assert {:ok, broadcast} =
               LiveBroadcasts.create_broadcast(
                 %{
                   title: "Autonomous Agent Stream",
                   scheduled_start_time: "2026-08-17T20:00:00Z",
                   privacy_status: :public
                 },
                 opts
               )

      assert broadcast["id"] == "bcast_e2e_1"
      assert LiveBroadcasts.live_chat_id(broadcast) == "chat_e2e_999"

      # Step 2: Create stream
      assert {:ok, stream} =
               LiveStreams.create_stream(
                 %{
                   title: "Agent Stream Ingestion",
                   resolution: "1080p",
                   frame_rate: "60fps",
                   ingestion_type: "rtmp"
                 },
                 opts
               )

      assert stream["id"] == "stream_e2e_2"
      assert LiveStreams.stream_key(stream) == "key_secret_live"
      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key_secret_live"

      # Step 3: Bind
      assert {:ok, bound} = LiveBroadcasts.bind_broadcast(broadcast["id"], stream["id"], opts)
      assert LiveBroadcasts.bound_stream_id(bound) == "stream_e2e_2"

      # Step 4: Transitions
      assert {:ok, testing_bcast} = LiveBroadcasts.transition_broadcast(broadcast["id"], :testing, opts)
      assert LiveBroadcasts.testing?(testing_bcast) == true

      assert {:ok, live_bcast} = LiveBroadcasts.transition_broadcast(broadcast["id"], :live, opts)
      assert LiveBroadcasts.active?(live_bcast) == true

      assert {:ok, completed_bcast} = LiveBroadcasts.transition_broadcast(broadcast["id"], :complete, opts)
      assert LiveBroadcasts.complete?(completed_bcast) == true

      # Step 5: Clean up deletion
      assert {:ok, %{deleted: true}} = LiveBroadcasts.delete_broadcast(broadcast["id"], opts)
      assert {:ok, %{deleted: true}} = LiveStreams.delete_stream(stream["id"], opts)
    end

    test "handles token expiration and auto-refresh during stream binding" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expired_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401, "message" => "Token expired"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "refreshed_access_token"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer refreshed_access_token"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcast",
            "id" => "bcast_1",
            "contentDetails" => %{"boundStreamId" => "str_1"}
          })
        )
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "valid_refresh_token",
        client_id: "cid",
        client_secret: "csec",
        auto_refresh: true
      }

      assert {:ok, bound} = LiveBroadcasts.bind_broadcast("bcast_1", "str_1", opts)
      assert LiveBroadcasts.bound_stream_id(bound) == "str_1"
    end
  end
end
