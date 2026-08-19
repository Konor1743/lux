defmodule Lux.Integrations.YouTube.LiveStreamsStressOracleTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{LiveBroadcasts, LiveStreams}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  # ============================================================================
  # 1. LiveStreams CDN Configurations & Parameter Normalization
  # ============================================================================
  describe "LiveStreams CDN Configurations & Ingestion Types" do
    test "create_stream with all ingestion types (rtmp, dash, hls)" do
      for ingestion <- ["rtmp", "dash", "hls", :rtmp, :dash, :hls] do
        ingestion_str = to_string(ingestion)

        Req.Test.expect(YouTubeClientMock, fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/youtube/v3/liveStreams"
          assert conn.query_string =~ "part=snippet%2Ccdn%2Cstatus%2CcontentDetails"

          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)

          assert decoded["cdn"]["ingestionType"] == ingestion_str
          assert decoded["cdn"]["resolution"] == "variable"
          assert decoded["cdn"]["frameRate"] == "variable"
          assert decoded["snippet"]["title"] == "Stream #{ingestion_str}"
          assert decoded["contentDetails"]["isReusable"] == true

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "kind" => "youtube#liveStream",
              "id" => "stream_#{ingestion_str}_1",
              "cdn" => %{
                "ingestionType" => ingestion_str,
                "ingestionInfo" => %{
                  "streamName" => "key_#{ingestion_str}",
                  "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2"
                }
              },
              "status" => %{"streamStatus" => "ready"}
            })
          )
        end)

        assert {:ok, stream} =
                 LiveStreams.create_stream(
                   %{
                     title: "Stream #{ingestion_str}",
                     ingestion_type: ingestion
                   },
                   token: "tok"
                 )

        assert stream["id"] == "stream_#{ingestion_str}_1"
        assert LiveStreams.stream_key(stream) == "key_#{ingestion_str}"
        assert LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"
        assert LiveStreams.ready?(stream) == true
      end
    end

    test "create_stream with resolution and frame_rate variations (1080p, 720p, 60fps, 30fps, variable)" do
      matrix = [
        {"1080p", "60fps"},
        {"720p", "30fps"},
        {"480p", "variable"},
        {"360p", "30fps"},
        {"240p", "variable"},
        {"variable", "variable"}
      ]

      for {res, fps} <- matrix do
        Req.Test.expect(YouTubeClientMock, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)

          assert decoded["cdn"]["resolution"] == res
          assert decoded["cdn"]["frameRate"] == fps

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "id" => "stream_#{res}_#{fps}",
              "cdn" => %{"resolution" => res, "frameRate" => fps}
            })
          )
        end)

        assert {:ok, stream} =
                 LiveStreams.create_stream(
                   %{
                     title: "Test #{res} #{fps}",
                     resolution: res,
                     frame_rate: fps
                   },
                   token: "tok"
                 )

        assert stream["id"] == "stream_#{res}_#{fps}"
      end
    end

    test "create_stream with is_reusable and is_default_stream variations" do
      for {reusable, is_default} <- [{true, false}, {false, true}, {false, false}, {true, true}] do
        Req.Test.expect(YouTubeClientMock, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)

          assert decoded["contentDetails"]["isReusable"] == reusable
          assert decoded["snippet"]["isDefaultStream"] == is_default

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "stream_flags"}))
        end)

        assert {:ok, _} =
                 LiveStreams.create_stream(
                   %{
                     title: "Flags Stream",
                     is_reusable: reusable,
                     is_default_stream: is_default
                   },
                   token: "tok"
                 )
      end
    end

    test "create_stream with nested snippet, cdn, contentDetails structures" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["title"] == "Nested Title"
        assert decoded["snippet"]["description"] == "Nested Desc"
        assert decoded["snippet"]["isDefaultStream"] == true
        assert decoded["cdn"]["ingestionType"] == "dash"
        assert decoded["cdn"]["resolution"] == "1080p"
        assert decoded["cdn"]["frameRate"] == "60fps"
        assert decoded["contentDetails"]["isReusable"] == false

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "stream_nested"}))
      end)

      params = %{
        snippet: %{
          title: "Nested Title",
          description: "Nested Desc",
          is_default_stream: true
        },
        cdn: %{
          ingestion_type: "dash",
          resolution: "1080p",
          frame_rate: "60fps"
        },
        content_details: %{
          is_reusable: false
        }
      }

      assert {:ok, _} = LiveStreams.create_stream(params, token: "tok")
    end

    test "update_stream requires id and selectively builds update payload" do
      # Missing ID
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{title: "No ID"}, token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{id: ""}, token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{"id" => nil}, token: "tok")

      # Successful partial update (snippet only)
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/youtube/v3/liveStreams"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["id"] == "stream_up_1"
        assert decoded["snippet"]["title"] == "Updated Title"
        assert decoded["snippet"]["description"] == "Updated Desc"
        refute Map.has_key?(decoded, "cdn")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(decoded))
      end)

      assert {:ok, _} =
               LiveStreams.update_stream(
                 %{
                   id: "stream_up_1",
                   title: "Updated Title",
                   description: "Updated Desc"
                 },
                 token: "tok"
               )

      # Successful partial update (cdn only)
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["id"] == "stream_up_2"
        assert decoded["cdn"]["resolution"] == "720p"
        assert decoded["cdn"]["frameRate"] == "30fps"
        refute Map.has_key?(decoded, "snippet")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(decoded))
      end)

      assert {:ok, _} =
               LiveStreams.update_stream(
                 %{
                   id: "stream_up_2",
                   resolution: "720p",
                   frame_rate: "30fps"
                 },
                 token: "tok"
               )
    end
  end

  # ============================================================================
  # 2. LiveStreams Stream URL Construction & Ingestion Info Extractors
  # ============================================================================
  describe "LiveStreams Ingestion Info Extractors & stream_url construction" do
    test "stream_key extractor across all representation variations" do
      # Nested string keys
      assert LiveStreams.stream_key(%{"cdn" => %{"ingestionInfo" => %{"streamName" => "key1"}}}) == "key1"
      # Nested atom keys (camelCase)
      assert LiveStreams.stream_key(%{cdn: %{ingestionInfo: %{streamName: "key2"}}}) == "key2"
      # Nested atom keys (snake_case)
      assert LiveStreams.stream_key(%{cdn: %{ingestion_info: %{stream_name: "key3"}}}) == "key3"
      # Direct ingestionInfo map (string)
      assert LiveStreams.stream_key(%{"ingestionInfo" => %{"streamName" => "key4"}}) == "key4"
      # Direct ingestionInfo map (atom camelCase)
      assert LiveStreams.stream_key(%{ingestionInfo: %{streamName: "key5"}}) == "key5"
      # Direct ingestionInfo map (atom snake_case)
      assert LiveStreams.stream_key(%{ingestion_info: %{stream_name: "key6"}}) == "key6"
      # Nil or empty or unexpected
      assert LiveStreams.stream_key(nil) == nil
      assert LiveStreams.stream_key(%{}) == nil
      assert LiveStreams.stream_key("invalid") == nil
    end

    test "ingestion_address and backup extractors (RTMP and RTMPS)" do
      sample_stream = %{
        "cdn" => %{
          "ingestionInfo" => %{
            "streamName" => "secret_key_999",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmps.youtube.com/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmps.youtube.com/live2?backup=1"
          }
        }
      }

      assert LiveStreams.ingestion_address(sample_stream) == "rtmp://a.rtmp.youtube.com/live2"
      assert LiveStreams.backup_ingestion_address(sample_stream) == "rtmp://b.rtmp.youtube.com/live2?backup=1"
      assert LiveStreams.rtmps_ingestion_address(sample_stream) == "rtmps://a.rtmps.youtube.com/live2"
      assert LiveStreams.rtmps_backup_ingestion_address(sample_stream) == "rtmps://b.rtmps.youtube.com/live2?backup=1"

      # Atom keyed variation
      atom_stream = %{
        cdn: %{
          ingestion_info: %{
            stream_name: "secret_key_999",
            ingestion_address: "rtmp://a.rtmp.youtube.com/live2",
            backup_ingestion_address: "rtmp://b.rtmp.youtube.com/live2?backup=1",
            rtmps_ingestion_address: "rtmps://a.rtmps.youtube.com/live2",
            rtmps_backup_ingestion_address: "rtmps://b.rtmps.youtube.com/live2?backup=1"
          }
        }
      }

      assert LiveStreams.ingestion_address(atom_stream) == "rtmp://a.rtmp.youtube.com/live2"
      assert LiveStreams.backup_ingestion_address(atom_stream) == "rtmp://b.rtmp.youtube.com/live2?backup=1"
      assert LiveStreams.rtmps_ingestion_address(atom_stream) == "rtmps://a.rtmps.youtube.com/live2"
      assert LiveStreams.rtmps_backup_ingestion_address(atom_stream) == "rtmps://b.rtmps.youtube.com/live2?backup=1"
    end

    test "stream_url constructs correct URLs for rtmp/rtmps primary/backup with query string handling" do
      sample_stream = %{
        "cdn" => %{
          "ingestionInfo" => %{
            "streamName" => "key_abc_123",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmps.youtube.com/live2/",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmps.youtube.com/live2?backup=1"
          }
        }
      }

      # Primary RTMP
      assert LiveStreams.stream_url(sample_stream) == "rtmp://a.rtmp.youtube.com/live2/key_abc_123"
      assert LiveStreams.stream_url(sample_stream, protocol: :rtmp, backup: false) ==
               "rtmp://a.rtmp.youtube.com/live2/key_abc_123"

      # Backup RTMP (with query param)
      assert LiveStreams.stream_url(sample_stream, backup: true) ==
               "rtmp://b.rtmp.youtube.com/live2/key_abc_123?backup=1"

      # Primary RTMPS (handling trailing slash)
      assert LiveStreams.stream_url(sample_stream, protocol: :rtmps) ==
               "rtmps://a.rtmps.youtube.com/live2/key_abc_123"

      # Backup RTMPS (with query param)
      assert LiveStreams.stream_url(sample_stream, protocol: :rtmps, backup: true) ==
               "rtmps://b.rtmps.youtube.com/live2/key_abc_123?backup=1"

      # Edge cases: nil stream, empty key, missing cdn
      assert LiveStreams.stream_url(nil) == nil
      assert LiveStreams.stream_url(%{}) == nil
      assert LiveStreams.stream_url(%{"cdn" => %{"ingestionInfo" => %{"streamName" => ""}}}) == nil
      assert LiveStreams.stream_url(%{"cdn" => %{"ingestionInfo" => %{"ingestionAddress" => ""}}}) == nil
    end
  end

  # ============================================================================
  # 3. Health Status & Stream Status Predicates
  # ============================================================================
  describe "LiveStreams Health Status & Predicates" do
    test "stream_status and health_status extractors" do
      # String map
      str_map = %{
        "status" => %{
          "streamStatus" => "active",
          "healthStatus" => %{
            "status" => "good"
          }
        }
      }

      assert LiveStreams.stream_status(str_map) == "active"
      assert LiveStreams.health_status(str_map) == "good"

      # Atom map camelCase
      atom_map_camel = %{
        status: %{
          streamStatus: "ready",
          healthStatus: %{
            status: "ok"
          }
        }
      }

      assert LiveStreams.stream_status(atom_map_camel) == "ready"
      assert LiveStreams.health_status(atom_map_camel) == "ok"

      # Atom map snake_case
      atom_map_snake = %{
        status: %{
          stream_status: "error",
          health_status: %{
            status: "bad"
          }
        }
      }

      assert LiveStreams.stream_status(atom_map_snake) == "error"
      assert LiveStreams.health_status(atom_map_snake) == "bad"

      # Nil / empty
      assert LiveStreams.stream_status(nil) == nil
      assert LiveStreams.health_status(nil) == nil
      assert LiveStreams.stream_status(%{}) == nil
      assert LiveStreams.health_status(%{}) == nil
    end

    test "active?, ready?, and error? status predicates" do
      # Active
      active_stream = %{"status" => %{"streamStatus" => "active", "healthStatus" => %{"status" => "good"}}}
      assert LiveStreams.active?(active_stream) == true
      assert LiveStreams.ready?(active_stream) == true
      assert LiveStreams.error?(active_stream) == false

      # Ready
      ready_stream = %{"status" => %{"streamStatus" => "ready", "healthStatus" => %{"status" => "noData"}}}
      assert LiveStreams.active?(ready_stream) == false
      assert LiveStreams.ready?(ready_stream) == true
      assert LiveStreams.error?(ready_stream) == false

      # Created (neither active nor ready)
      created_stream = %{"status" => %{"streamStatus" => "created"}}
      assert LiveStreams.active?(created_stream) == false
      assert LiveStreams.ready?(created_stream) == false
      assert LiveStreams.error?(created_stream) == false

      # Inactive
      inactive_stream = %{"status" => %{"streamStatus" => "inactive"}}
      assert LiveStreams.active?(inactive_stream) == false
      assert LiveStreams.ready?(inactive_stream) == false
      assert LiveStreams.error?(inactive_stream) == false

      # Error by streamStatus == "error"
      err_stream = %{"status" => %{"streamStatus" => "error", "healthStatus" => %{"status" => "noData"}}}
      assert LiveStreams.active?(err_stream) == false
      assert LiveStreams.ready?(err_stream) == false
      assert LiveStreams.error?(err_stream) == true

      # Error by healthStatus == "bad" even if streamStatus == "active"
      bad_health_stream = %{"status" => %{"streamStatus" => "active", "healthStatus" => %{"status" => "bad"}}}
      assert LiveStreams.active?(bad_health_stream) == true
      assert LiveStreams.ready?(bad_health_stream) == true
      assert LiveStreams.error?(bad_health_stream) == true
    end
  end

  # ============================================================================
  # 4. Stream Deletion & Get Stream
  # ============================================================================
  describe "LiveStreams Deletion & Retrieval" do
    test "delete_stream with valid stream ID returns {:ok, %{id: id, deleted: true}}" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=stream_del_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, result} = LiveStreams.delete_stream("stream_del_123", token: "tok")
      assert result == %{id: "stream_del_123", deleted: true}
    end

    test "delete_stream with invalid or blank ID rejects before HTTP call" do
      for invalid <- [nil, "", 12345, :atom_id, %{id: "123"}] do
        assert {:error, :missing_stream_id} = LiveStreams.delete_stream(invalid, token: "tok")
      end
    end

    test "delete_stream API errors (404, 403, 401)" do
      # 404 Not Found
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => %{"message" => "LiveStream not found"}}))
      end)

      assert {:error, {404, "LiveStream not found"}} =
               LiveStreams.delete_stream("stream_missing", token: "tok")

      # 403 Quota Exceeded
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{"errors" => [%{"reason" => "quotaExceeded", "message" => "Quota exceeded"}]}
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveStreams.delete_stream("stream_quota", token: "tok")
      assert details.reason == "quotaExceeded"
    end

    test "get_stream returns single unwrapped stream or {:error, :not_found}" do
      # Found
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=stream_find_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [%{"id" => "stream_find_1", "status" => %{"streamStatus" => "active"}}]
          })
        )
      end)

      assert {:ok, stream} = LiveStreams.get_stream("stream_find_1", token: "tok")
      assert stream["id"] == "stream_find_1"
      assert LiveStreams.active?(stream) == true

      # Not found (empty items list)
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:error, :not_found} = LiveStreams.get_stream("stream_nonexistent", token: "tok")

      # Invalid ID
      assert {:error, :missing_stream_id} = LiveStreams.get_stream("", token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.get_stream(nil, token: "tok")
    end
  end

  # ============================================================================
  # 5. LiveBroadcasts Lifecycle & Helper Adversarial Tests
  # ============================================================================
  describe "LiveBroadcasts Adversarial Stress & Helper Checks" do
    test "create_broadcast handles DateTime, NaiveDateTime, and ISO8601 strings" do
      utc_dt = ~U[2026-09-01 18:00:00Z]
      naive_dt = ~N[2026-09-01 18:00:00]
      iso_str = "2026-09-01T18:00:00Z"

      for start_time <- [utc_dt, naive_dt, iso_str] do
        Req.Test.expect(YouTubeClientMock, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)

          assert decoded["snippet"]["scheduledStartTime"] == "2026-09-01T18:00:00Z"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "bcast_dt_ok"}))
        end)

        assert {:ok, _} =
                 LiveBroadcasts.create_broadcast(
                   %{
                     title: "DateTime Stream",
                     scheduled_start_time: start_time
                   },
                   token: "tok"
                 )
      end
    end

    test "create_broadcast preserves explicit false booleans in contentDetails" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        cd = decoded["contentDetails"]
        assert cd["enableAutoStart"] == false
        assert cd["enableAutoStop"] == false
        assert cd["enableDvr"] == false
        assert cd["enableContentEncryption"] == false
        assert cd["enableEmbed"] == false
        assert cd["recordFromStart"] == false
        assert cd["enableClosedCaptions"] == false
        assert cd["enableLowLatency"] == false
        assert cd["latencyPreference"] == "ultraLow"
        assert cd["monitorStream"]["enableMonitorStream"] == false
        assert cd["monitorStream"]["broadcastStreamDelayMs"] == 5000

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "bcast_booleans_false"}))
      end)

      params = %{
        title: "False Flags Broadcast",
        enable_auto_start: false,
        enable_auto_stop: false,
        enable_dvr: false,
        enable_content_encryption: false,
        enable_embed: false,
        record_from_start: false,
        enable_closed_captions: false,
        enable_low_latency: false,
        latency_preference: :ultra_low,
        monitor_stream: %{
          enable_monitor_stream: false,
          broadcast_stream_delay_ms: 5000
        }
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "tok")
    end

    test "bind_broadcast binding to stream ID and unbinding (nil/empty)" do
      # Bind to stream
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_bind_1"
        assert conn.query_string =~ "streamId=stream_target_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "bcast_bind_1",
            "contentDetails" => %{"boundStreamId" => "stream_target_1"}
          })
        )
      end)

      assert {:ok, bcast} =
               LiveBroadcasts.bind_broadcast("bcast_bind_1", "stream_target_1", token: "tok")
      assert LiveBroadcasts.bound_stream_id(bcast) == "stream_target_1"

      # Unbind with nil
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=bcast_bind_1"
        refute conn.query_string =~ "streamId="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "bcast_bind_1", "contentDetails" => %{}}))
      end)

      assert {:ok, unbound} =
               LiveBroadcasts.bind_broadcast("bcast_bind_1", nil, token: "tok")
      assert LiveBroadcasts.bound_stream_id(unbound) == nil

      # Missing broadcast ID
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.bind_broadcast("", "stream_1", token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.bind_broadcast(nil, "stream_1", token: "tok")
    end

    test "broadcast helper extractors and url generator" do
      sample_bcast = %{
        "id" => "bcast_sample_99",
        "snippet" => %{
          "title" => "Sample Stream",
          "liveChatId" => "chat_xyz_789"
        },
        "status" => %{
          "lifeCycleStatus" => "live"
        },
        "contentDetails" => %{
          "boundStreamId" => "stream_xyz_456"
        }
      }

      assert LiveBroadcasts.bound_stream_id(sample_bcast) == "stream_xyz_456"
      assert LiveBroadcasts.live_chat_id(sample_bcast) == "chat_xyz_789"
      assert LiveBroadcasts.status(sample_bcast) == "live"
      assert LiveBroadcasts.life_cycle_status(sample_bcast) == "live"
      assert LiveBroadcasts.active?(sample_bcast) == true
      assert LiveBroadcasts.testing?(sample_bcast) == false
      assert LiveBroadcasts.complete?(sample_bcast) == false
      assert LiveBroadcasts.upcoming?(sample_bcast) == false
      assert LiveBroadcasts.broadcast_url(sample_bcast) == "https://www.youtube.com/watch?v=bcast_sample_99"
      assert LiveBroadcasts.broadcast_url("direct_id_123") == "https://www.youtube.com/watch?v=direct_id_123"
      assert LiveBroadcasts.broadcast_url(nil) == nil
      assert LiveBroadcasts.broadcast_url("") == nil
    end

    test "delete_broadcast with valid ID and error handling" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_del_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, result} = LiveBroadcasts.delete_broadcast("bcast_del_1", token: "tok")
      assert result == %{id: "bcast_del_1", deleted: true}

      assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast("", token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.delete_broadcast(nil, token: "tok")
    end
  end

  # ============================================================================
  # 6. Fault Injection & Network Transport Mocks
  # ============================================================================
  describe "Mock Fault Injection & Network Errors" do
    test "Req.Test transport_error simulation across LiveBroadcasts & LiveStreams" do
      # Broadcast create timeout
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               LiveBroadcasts.create_broadcast(%{title: "Timeout Stream"}, token: "tok")

      # Stream create econnrefused
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               LiveStreams.create_stream(%{title: "Dead Stream"}, token: "tok")

      # Broadcast bind closed connection
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      assert {:error, %Req.TransportError{reason: :closed}} =
               LiveBroadcasts.bind_broadcast("bcast_100", "stream_200", token: "tok")

      # Broadcast transition timeout
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               LiveBroadcasts.transition_broadcast("bcast_live_timeout", :live, token: "tok")
    end
  end
end
