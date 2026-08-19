defmodule Lux.Integrations.YouTube.LiveStreamingE2EStressTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{Errors, LiveBroadcasts, LiveStreams}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  # ===========================================================================
  # Fixtures & Helpers
  # ===========================================================================

  defp make_broadcast(id, status, stream_id \\ nil, chat_id \\ "chat_123") do
    %{
      "kind" => "youtube#liveBroadcast",
      "etag" => "\"etag_#{id}\"",
      "id" => id,
      "snippet" => %{
        "publishedAt" => "2026-08-17T18:00:00Z",
        "channelId" => "UC_channel_test",
        "title" => "Broadcast #{id}",
        "description" => "Test stream for #{id}",
        "scheduledStartTime" => "2026-08-17T20:00:00Z",
        "scheduledEndTime" => "2026-08-17T22:00:00Z",
        "isDefaultBroadcast" => false,
        "liveChatId" => chat_id
      },
      "status" => %{
        "lifeCycleStatus" => status,
        "privacyStatus" => "public",
        "recordingStatus" => "notRecording",
        "madeForKids" => false,
        "selfDeclaredMadeForKids" => false
      },
      "contentDetails" => %{
        "boundStreamId" => stream_id,
        "monitorStream" => %{
          "enableMonitorStream" => true,
          "broadcastStreamDelayMs" => 0,
          "embedHtml" => "<iframe src=\"https://youtube.com/embed/#{id}\"></iframe>"
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
    }
  end

  defp make_stream(id, stream_status \\ "ready", health \\ "good") do
    %{
      "kind" => "youtube#liveStream",
      "etag" => "\"etag_#{id}\"",
      "id" => id,
      "snippet" => %{
        "publishedAt" => "2026-08-17T18:00:00Z",
        "channelId" => "UC_channel_test",
        "title" => "Stream #{id}",
        "description" => "Ingestion for #{id}",
        "isDefaultStream" => false
      },
      "cdn" => %{
        "ingestionType" => "rtmp",
        "ingestionInfo" => %{
          "streamName" => "key_#{id}",
          "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
          "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
          "rtmpsIngestionAddress" => "rtmps://a.rtmp.youtube.com/live2",
          "rtmpsBackupIngestionAddress" => "rtmps://secbackup.youtube.com:443/live2?param=val"
        },
        "resolution" => "1080p",
        "frameRate" => "60fps"
      },
      "status" => %{
        "streamStatus" => stream_status,
        "healthStatus" => %{
          "status" => health
        }
      },
      "contentDetails" => %{
        "isReusable" => true
      }
    }
  end

  defp quota_error_body(reason \\ "quotaExceeded") do
    Jason.encode!(%{
      "error" => %{
        "code" => 403,
        "message" => "The request cannot be completed because you have exceeded your quota.",
        "errors" => [
          %{
            "message" => "The request cannot be completed because you have exceeded your quota.",
            "domain" => "youtube.quota",
            "reason" => reason
          }
        ]
      }
    })
  end

  defp rate_limit_error_body do
    Jason.encode!(%{
      "error" => %{
        "code" => 429,
        "message" => "Rate limit exceeded. Please slow down.",
        "errors" => [
          %{
            "message" => "Rate limit exceeded",
            "domain" => "youtube.rateLimit",
            "reason" => "rateLimitExceeded"
          }
        ]
      }
    })
  end

  # ===========================================================================
  # 1. Step-by-Step Failure Injection Matrix Across E2E Lifecycle
  # ===========================================================================
  describe "E2E Lifecycle: Step 1 (Create Broadcast) Failure Injections" do
    test "Step 1 fails with 403 quotaExceeded" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, quota_error_body())
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveBroadcasts.create_broadcast(%{title: "New Stream"}, token: "tok")

      assert details.reason == "quotaExceeded"
      assert details.status == 403
    end

    test "Step 1 fails with 401 and recovers via automatic token refresh" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expired_tok"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "fresh_tok_step1"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh_tok_step1"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_101", "created")))
      end)

      opts = %{
        token: "expired_tok",
        refresh_token: "ref_tok",
        client_id: "cid",
        client_secret: "csec",
        auto_refresh: true
      }

      assert {:ok, bcast} = LiveBroadcasts.create_broadcast(%{title: "Stream 101"}, opts)
      assert bcast["id"] == "bcast_101"
    end

    test "Step 1 fails with 429 Rate Limited containing Retry-After header" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, rate_limit_error_body())
      end)

      assert {:error, {:rate_limited, details}} =
               LiveBroadcasts.create_broadcast(%{title: "Rate Limited Stream"}, token: "tok")

      assert details.retry_after == 30
      assert details.status == 429
    end

    test "Step 1 fails with Network Drop (TransportError timeout)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               LiveBroadcasts.create_broadcast(%{title: "Timeout Stream"}, token: "tok")
    end
  end

  describe "E2E Lifecycle: Step 2 (Create Stream) Failure Injections" do
    test "Step 2 fails with 403 quotaExceeded after Step 1 created broadcast" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_orphaned", "created")))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, quota_error_body("dailyLimitExceeded"))
      end)

      opts = [token: "tok"]
      assert {:ok, broadcast} = LiveBroadcasts.create_broadcast(%{title: "Test"}, opts)
      assert broadcast["id"] == "bcast_orphaned"

      assert {:error, {:quota_exceeded, details}} =
               LiveStreams.create_stream(%{title: "Ingestion"}, opts)

      assert details.reason == "dailyLimitExceeded"

      # Compensation/Cleanup: delete orphaned broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_orphaned"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, %{deleted: true}} = LiveBroadcasts.delete_broadcast(broadcast["id"], opts)
    end

    test "Step 2 fails with 401 Unauthorized and auto-refreshes token" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer stale_tok"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Unauthorized"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "fresh_tok_step2"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh_tok_step2"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_stream("stream_step2_fresh")))
      end)

      opts = %{
        token: "stale_tok",
        refresh_token: "ref_tok",
        client_id: "cid",
        client_secret: "csec",
        auto_refresh: true
      }

      assert {:ok, stream} = LiveStreams.create_stream(%{title: "Stream 2"}, opts)
      assert stream["id"] == "stream_step2_fresh"
    end

    test "Step 2 fails with Network Drop (TransportError econnrefused)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               LiveStreams.create_stream(%{title: "Dead Stream"}, token: "tok")
    end
  end

  describe "E2E Lifecycle: Step 3 (Bind Broadcast) Failure Injections" do
    test "Step 3 fails with 403 quotaExceeded" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, quota_error_body("RESOURCE_EXHAUSTED"))
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveBroadcasts.bind_broadcast("bcast_1", "str_1", token: "tok")

      assert details.reason == "RESOURCE_EXHAUSTED"
    end

    test "Step 3 fails with 400 streamNotFound (invalid stream ID)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "Stream not found",
              "errors" => [%{"reason" => "streamNotFound", "message" => "Stream does not exist"}]
            }
          })
        )
      end)

      assert {:error, {400, "Stream not found"}} =
               LiveBroadcasts.bind_broadcast("bcast_1", "invalid_stream_id", token: "tok")
    end

    test "Step 3 network drop on bind: probing with get_broadcast verifies idempotent bind status" do
      # Bind attempt encounters transport error (network drop after server processed it)
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        Req.Test.transport_error(conn, :closed)
      end)

      opts = [token: "tok"]

      assert {:error, %Req.TransportError{reason: :closed}} =
               LiveBroadcasts.bind_broadcast("bcast_100", "stream_200", opts)

      # Follow-up probe: fetch broadcast to verify if bind succeeded on server
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_100"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"items" => [make_broadcast("bcast_100", "ready", "stream_200")]})
        )
      end)

      assert {:ok, broadcast} = LiveBroadcasts.get_broadcast("bcast_100", opts)
      assert LiveBroadcasts.bound_stream_id(broadcast) == "stream_200"
      assert broadcast["status"]["lifeCycleStatus"] == "ready"
    end
  end

  describe "E2E Lifecycle: Step 4 (Transition to Testing) Failure Injections" do
    test "Step 4 fails with 403 quotaExceeded" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=testing"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, quota_error_body())
      end)

      assert {:error, {:quota_exceeded, _}} =
               LiveBroadcasts.transition_broadcast("bcast_1", :testing, token: "tok")
    end

    test "Step 4 fails with 400 invalidTransition (stream not ready or active)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "The stream is not ready for testing.",
              "errors" => [
                %{
                  "reason" => "invalidTransition",
                  "message" => "Cannot transition broadcast from ready to testing without ingestion."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {400, "The stream is not ready for testing."}} =
               LiveBroadcasts.transition_broadcast("bcast_1", :testing, token: "tok")
    end

    test "Step 4 fails with 401 and successfully auto-refreshes token" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expired_testing_tok"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "refreshed_testing_tok"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer refreshed_testing_tok"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_testing_ok", "testing")))
      end)

      opts = %{
        token: "expired_testing_tok",
        refresh_token: "ref_tok",
        client_id: "cid",
        client_secret: "csec"
      }

      assert {:ok, bcast} = LiveBroadcasts.transition_broadcast("bcast_testing_ok", :testing, opts)
      assert LiveBroadcasts.testing?(bcast) == true
    end

    test "Step 4 rejects invalid transition atom before making network call" do
      assert {:error, {:invalid_transition_status, :aborted}} =
               LiveBroadcasts.transition_broadcast("bcast_1", :aborted, token: "tok")

      assert {:error, {:invalid_transition_status, :paused}} =
               LiveBroadcasts.transition_broadcast("bcast_1", :paused, token: "tok")

      assert {:error, {:invalid_transition_status, nil}} =
               LiveBroadcasts.transition_broadcast("bcast_1", nil, token: "tok")
    end
  end

  describe "E2E Lifecycle: Step 5 (Transition to Live) Failure Injections" do
    test "Step 5 fails with 403 quotaExceeded" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, quota_error_body())
      end)

      assert {:error, {:quota_exceeded, _}} =
               LiveBroadcasts.transition_broadcast("bcast_live_fail", :live, token: "tok")
    end

    test "Step 5 fails with 429 Rate Limited and retries with Errors.with_retry" do
      attempts = :atomics.new(1, [])
      :atomics.put(attempts, 1, 0)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        curr = :atomics.add_get(attempts, 1, 1)

        if curr == 1 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, rate_limit_error_body())
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_live_ok", "live")))
        end
      end)

      opts = [token: "tok"]

      res =
        Errors.with_retry(
          fn ->
            LiveBroadcasts.transition_broadcast("bcast_live_ok", :live, opts)
          end,
          sleep_fun: fn _delay -> :ok end,
          max_retries: 3
        )

      assert {:ok, bcast} = res
      assert LiveBroadcasts.active?(bcast) == true
    end

    test "Step 5 network drop during transition: verify state with get_broadcast" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        Req.Test.transport_error(conn, :timeout)
      end)

      opts = [token: "tok"]

      assert {:error, %Req.TransportError{reason: :timeout}} =
               LiveBroadcasts.transition_broadcast("bcast_live_timeout", :live, opts)

      # Probe to check if the server transitioned anyway
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_live_timeout"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"items" => [make_broadcast("bcast_live_timeout", "live")]})
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.get_broadcast("bcast_live_timeout", opts)
      assert LiveBroadcasts.active?(bcast) == true
    end
  end

  describe "E2E Lifecycle: Step 6 (Transition to Complete) Failure Injections" do
    test "Step 6 fails with 403 quotaExceeded" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, quota_error_body())
      end)

      assert {:error, {:quota_exceeded, _}} =
               LiveBroadcasts.transition_broadcast("bcast_complete_quota", :complete, token: "tok")
    end

    test "Step 6 fails with 400 redundantTransition when already completed" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => %{
              "code" => 400,
              "message" => "The broadcast is already complete.",
              "errors" => [
                %{
                  "reason" => "redundantTransition",
                  "message" => "Broadcast bcast_done is already in status complete."
                }
              ]
            }
          })
        )
      end)

      assert {:error, {400, "The broadcast is already complete."}} =
               LiveBroadcasts.transition_broadcast("bcast_done", :complete, token: "tok")
    end

    test "Step 6 network drop on complete: recovery via get_broadcast confirms complete? is true" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        Req.Test.transport_error(conn, :closed)
      end)

      opts = [token: "tok"]

      assert {:error, %Req.TransportError{reason: :closed}} =
               LiveBroadcasts.transition_broadcast("bcast_net_done", :complete, opts)

      # Probe status
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_net_done"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"items" => [make_broadcast("bcast_net_done", "complete")]})
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.get_broadcast("bcast_net_done", opts)
      assert LiveBroadcasts.complete?(bcast) == true
      refute LiveBroadcasts.active?(bcast)
    end
  end

  # ===========================================================================
  # 2. Resilient Multi-Step Workflow Runner Simulation
  # ===========================================================================
  describe "Resilient End-to-End Workflow with Intermittent Failures" do
    test "executes full workflow with 401 on create_stream and 429 on bind_broadcast" do
      # Step 1: create_broadcast (200)
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("wf_bcast_1", "created")))
      end)

      # Step 2: create_stream -> 401 then refresh then 200
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer initial_tok"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "tok_v2"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_v2"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_stream("wf_stream_1")))
      end)

      # Step 3: bind_broadcast -> 429 rate limit then retry succeeds
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        conn
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, rate_limit_error_body())
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("wf_bcast_1", "ready", "wf_stream_1")))
      end)

      # Step 4: transition testing
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=testing"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("wf_bcast_1", "testing", "wf_stream_1")))
      end)

      # Step 5: transition live
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("wf_bcast_1", "live", "wf_stream_1")))
      end)

      # Step 6: transition complete
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("wf_bcast_1", "complete", "wf_stream_1")))
      end)

      opts = %{
        token: "initial_tok",
        refresh_token: "ref_tok",
        client_id: "cid",
        client_secret: "csec"
      }

      # 1. Create Broadcast
      assert {:ok, bcast} = LiveBroadcasts.create_broadcast(%{title: "Resilient WF"}, opts)
      assert bcast["id"] == "wf_bcast_1"

      # 2. Create Stream (auto-refreshes on 401)
      assert {:ok, stream} = LiveStreams.create_stream(%{title: "Resilient Ingestion"}, opts)
      assert stream["id"] == "wf_stream_1"

      # 3. Bind with retry on 429
      bind_res =
        Errors.with_retry(
          fn ->
            LiveBroadcasts.bind_broadcast(bcast["id"], stream["id"], opts)
          end,
          sleep_fun: fn _ -> :ok end,
          max_retries: 3
        )

      assert {:ok, bound_bcast} = bind_res
      assert LiveBroadcasts.bound_stream_id(bound_bcast) == "wf_stream_1"

      # 4. Transition Testing
      assert {:ok, test_bcast} = LiveBroadcasts.transition_broadcast(bcast["id"], :testing, opts)
      assert LiveBroadcasts.testing?(test_bcast)

      # 5. Transition Live
      assert {:ok, live_bcast} = LiveBroadcasts.transition_broadcast(bcast["id"], :live, opts)
      assert LiveBroadcasts.active?(live_bcast)

      # 6. Transition Complete
      assert {:ok, done_bcast} = LiveBroadcasts.transition_broadcast(bcast["id"], :complete, opts)
      assert LiveBroadcasts.complete?(done_bcast)
    end
  end

  # ===========================================================================
  # 3. Stream & Broadcast Edge Cases & Malformed Payloads
  # ===========================================================================
  describe "Stream Ingestion, URL builders & Status Extractors Edge Cases" do
    test "stream_url handles custom ports and complex query parameters" do
      stream = %{
        "cdn" => %{
          "ingestionInfo" => %{
            "streamName" => "key_abc123",
            "ingestionAddress" => "rtmp://ingest.youtube.com:1935/live2",
            "backupIngestionAddress" => "rtmp://backup.youtube.com:1935/live2?token=xyz&secure=1",
            "rtmpsIngestionAddress" => "rtmps://secure.youtube.com:443/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://secbackup.youtube.com:443/live2?param=val"
          }
        }
      }

      assert LiveStreams.stream_url(stream, protocol: :rtmp, backup: false) ==
               "rtmp://ingest.youtube.com:1935/live2/key_abc123"

      assert LiveStreams.stream_url(stream, protocol: :rtmp, backup: true) ==
               "rtmp://backup.youtube.com:1935/live2/key_abc123?token=xyz&secure=1"

      assert LiveStreams.stream_url(stream, protocol: :rtmps, backup: false) ==
               "rtmps://secure.youtube.com:443/live2/key_abc123"

      assert LiveStreams.stream_url(stream, protocol: :rtmps, backup: true) ==
               "rtmps://secbackup.youtube.com:443/live2/key_abc123?param=val"
    end

    test "stream_url returns nil gracefully when missing stream key or address" do
      assert LiveStreams.stream_url(nil) == nil
      assert LiveStreams.stream_url(%{}) == nil
      assert LiveStreams.stream_url(%{"cdn" => %{"ingestionInfo" => %{"streamName" => ""}}}) == nil
      assert LiveStreams.stream_url(%{"cdn" => %{"ingestionInfo" => %{"ingestionAddress" => ""}}}) == nil
    end

    test "stream status and health evaluation under diverse statuses" do
      assert LiveStreams.active?(make_stream("s1", "active", "good")) == true
      assert LiveStreams.ready?(make_stream("s2", "ready", "ok")) == true
      assert LiveStreams.ready?(make_stream("s3", "active", "good")) == true
      assert LiveStreams.ready?(make_stream("s4", "created", "noData")) == false
      assert LiveStreams.error?(make_stream("s5", "error", "good")) == true
      assert LiveStreams.error?(make_stream("s6", "active", "bad")) == true
      refute LiveStreams.error?(make_stream("s7", "active", "good"))
    end

    test "broadcast URL and life cycle helper predicates" do
      assert LiveBroadcasts.broadcast_url("bcast_123") == "https://www.youtube.com/watch?v=bcast_123"
      assert LiveBroadcasts.broadcast_url(%{"id" => "bcast_456"}) == "https://www.youtube.com/watch?v=bcast_456"
      assert LiveBroadcasts.broadcast_url(%{id: "bcast_789"}) == "https://www.youtube.com/watch?v=bcast_789"
      assert LiveBroadcasts.broadcast_url(nil) == nil
      assert LiveBroadcasts.broadcast_url("") == nil

      assert LiveBroadcasts.upcoming?(make_broadcast("b1", "created")) == true
      assert LiveBroadcasts.upcoming?(make_broadcast("b2", "ready")) == true
      refute LiveBroadcasts.upcoming?(make_broadcast("b3", "live"))
      assert LiveBroadcasts.testing?(make_broadcast("b4", "testing")) == true
      assert LiveBroadcasts.testing?(make_broadcast("b5", "testStarting")) == true
      assert LiveBroadcasts.active?(make_broadcast("b6", "live")) == true
      assert LiveBroadcasts.complete?(make_broadcast("b7", "complete")) == true
    end

    test "unbinding broadcast passes empty or nil streamId" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_unbind"
        refute conn.query_string =~ "streamId="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_unbind", "created", nil)))
      end)

      assert {:ok, bcast} = LiveBroadcasts.bind_broadcast("bcast_unbind", nil, token: "tok")
      assert LiveBroadcasts.bound_stream_id(bcast) == nil
    end
  end

  # ===========================================================================
  # 4. Concurrency Stress Test Under Failure Injections
  # ===========================================================================
  describe "Concurrent Live Broadcast Lifecycle Stress Test" do
    test "20 concurrent workflows running through create -> bind -> complete with random 401s" do
      concurrency = 20

      Req.Test.stub(YouTubeClientMock, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")

        cond do
          auth == ["Bearer expired_concurrent_tok"] ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))

          conn.request_path == "/youtube/v3/liveBroadcasts" and conn.method == "POST" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("b_conc", "created")))

          conn.request_path == "/youtube/v3/liveStreams" and conn.method == "POST" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(make_stream("s_conc")))

          conn.request_path == "/youtube/v3/liveBroadcasts/bind" and conn.method == "POST" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("b_conc", "ready", "s_conc")))

          conn.request_path == "/youtube/v3/liveBroadcasts/transition" and conn.method == "POST" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("b_conc", "complete", "s_conc")))

          true ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
        end
      end)

      Req.Test.stub(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "refreshed_conc_tok"}))
      end)

      opts = %{
        token: "expired_concurrent_tok",
        refresh_token: "valid_rt",
        client_id: "cid",
        client_secret: "csec"
      }

      tasks =
        for i <- 1..concurrency do
          Task.async(fn ->
            with {:ok, bcast} <- LiveBroadcasts.create_broadcast(%{title: "Conc #{i}"}, opts),
                 {:ok, stream} <- LiveStreams.create_stream(%{title: "Conc Stream #{i}"}, opts),
                 {:ok, _bound} <- LiveBroadcasts.bind_broadcast(bcast["id"], stream["id"], opts),
                 {:ok, done} <- LiveBroadcasts.transition_broadcast(bcast["id"], :complete, opts) do
              {:ok, bcast["id"], stream["id"], LiveBroadcasts.complete?(done)}
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert length(results) == concurrency
      assert Enum.all?(results, fn res -> match?({:ok, _b_id, _s_id, true}, res) end)
    end
  end

  # ===========================================================================
  # 5. Token Revocation & Multi-Refresh Failure Chains
  # ===========================================================================
  describe "Token Expiration & Revocation Multi-Step Chains" do
    test "token refresh fails with 400 invalid_grant when refresh token is revoked" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid credentials"}}))
      end)

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
        token: "bad_access_token",
        refresh_token: "revoked_refresh_token",
        client_id: "cid",
        client_secret: "csec",
        auto_refresh: true
      }

      assert {:error, :invalid_token} =
               LiveBroadcasts.create_broadcast(%{title: "Revoked Auth Stream"}, opts)
    end

    test "sequential token refreshes across multiple workflow steps" do
      # Step 1: create_broadcast -> 401 -> refresh (tok_2) -> 200
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_1"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired tok_1"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "tok_2"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_2"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("seq_bcast_1", "created")))
      end)

      # Step 2: create_stream with tok_2 -> 200
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_2"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_stream("seq_stream_1")))
      end)

      # Step 3: bind with tok_2 -> 401 (tok_2 expired!) -> refresh (tok_3) -> 200
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_2"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired tok_2"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "tok_3"}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_3"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("seq_bcast_1", "ready", "seq_stream_1")))
      end)

      base_opts = %{
        token: "tok_1",
        refresh_token: "rt_valid",
        client_id: "cid",
        client_secret: "csec"
      }

      assert {:ok, bcast} = LiveBroadcasts.create_broadcast(%{title: "Seq 1"}, base_opts)
      assert {:ok, stream} = LiveStreams.create_stream(%{title: "Seq Stream 1"}, Map.put(base_opts, :token, "tok_2"))
      assert {:ok, bound} = LiveBroadcasts.bind_broadcast(bcast["id"], stream["id"], Map.put(base_opts, :token, "tok_2"))
      assert LiveBroadcasts.bound_stream_id(bound) == "seq_stream_1"
    end
  end

  # ===========================================================================
  # 6. Server 500/502/503 Fault Injections & Automatic Resiliency Retries
  # ===========================================================================
  describe "Server 5xx Fault Injections and Retries" do
    test "Step 4 transition testing recovers from 503 Service Unavailable via Errors.with_retry" do
      attempt_counter = :atomics.new(1, [])
      :atomics.put(attempt_counter, 1, 0)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        count = :atomics.add_get(attempt_counter, 1, 1)

        if count < 3 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => %{"code" => 503, "message" => "Backend Unavailable"}}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_503_recovered", "testing")))
        end
      end)

      opts = [token: "tok"]

      res =
        Errors.with_retry(
          fn ->
            LiveBroadcasts.transition_broadcast("bcast_503_recovered", :testing, opts)
          end,
          sleep_fun: fn _ -> :ok end,
          max_retries: 3
        )

      assert {:ok, bcast} = res
      assert LiveBroadcasts.testing?(bcast)
    end

    test "handles 502 Bad Gateway with raw HTML error body" do
      html_502 = "<html><head><title>502 Bad Gateway</title></head><body>502 Bad Gateway</body></html>"

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(502, html_502)
      end)

      assert {:error, {502, ^html_502}} =
               LiveBroadcasts.transition_broadcast("bcast_html_err", :live, token: "tok")
    end
  end

  # ===========================================================================
  # 7. Missing Resource & Parameter Validation Edge Cases
  # ===========================================================================
  describe "Missing Resource & Parameter Validation Edge Cases" do
    test "get_broadcast returns {:error, :not_found} when API returns empty items list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=non_existent_bcast"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"kind" => "youtube#liveBroadcastListResponse", "items" => []}))
      end)

      assert {:error, :not_found} =
               LiveBroadcasts.get_broadcast("non_existent_bcast", token: "tok")
    end

    test "get_stream returns {:error, :not_found} when API returns empty items list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=non_existent_stream"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"kind" => "youtube#liveStreamListResponse", "items" => []}))
      end)

      assert {:error, :not_found} =
               LiveStreams.get_stream("non_existent_stream", token: "tok")
    end

    test "update_broadcast and update_stream enforce :missing_broadcast_id / :missing_stream_id" do
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.update_broadcast(%{title: "No ID"}, token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.update_broadcast(%{id: ""}, token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.update_broadcast(%{id: nil}, token: "tok")

      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{title: "No ID"}, token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{id: ""}, token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{id: nil}, token: "tok")
    end

    test "delete_broadcast and delete_stream enforce valid ID parameters" do
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast("", token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast(nil, token: "tok")

      assert {:error, :missing_stream_id} = LiveStreams.delete_stream("", token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.delete_stream(nil, token: "tok")
    end
  end

  # ===========================================================================
  # 8. Direct & Non-Standard Lifecycle Transitions
  # ===========================================================================
  describe "Direct & Non-Standard Lifecycle Transitions" do
    test "direct transition from created to live (monitor stream disabled)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=live"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_direct_live", "live", "s1")))
      end)

      assert {:ok, bcast} =
               LiveBroadcasts.transition_broadcast("bcast_direct_live", :live, token: "tok")

      assert LiveBroadcasts.active?(bcast) == true
      refute LiveBroadcasts.testing?(bcast)
    end

    test "direct cancellation from created to complete without going live" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(make_broadcast("bcast_cancelled", "complete")))
      end)

      assert {:ok, bcast} =
               LiveBroadcasts.transition_broadcast("bcast_cancelled", :complete, token: "tok")

      assert LiveBroadcasts.complete?(bcast) == true
      refute LiveBroadcasts.active?(bcast)
    end
  end
end

