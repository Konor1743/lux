defmodule Lux.Integrations.YouTube.LiveStreamsTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.LiveStreams

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp stream_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveStream",
        "etag" => "\"etag_stream_123\"",
        "id" => "str_test_123",
        "snippet" => %{
          "publishedAt" => "2026-08-17T18:00:00Z",
          "channelId" => "UC_channel_123",
          "title" => "Primary OBS Stream",
          "description" => "Automated broadcast ingestion stream",
          "isDefaultStream" => false
        },
        "cdn" => %{
          "ingestionType" => "rtmp",
          "ingestionInfo" => %{
            "streamName" => "key-abcd-1234",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmp.youtube.com/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmp.youtube.com/live2?backup=1"
          },
          "resolution" => "1080p",
          "frameRate" => "60fps"
        },
        "status" => %{
          "streamStatus" => "ready",
          "healthStatus" => %{
            "status" => "good",
            "configurationIssues" => []
          }
        },
        "contentDetails" => %{
          "isReusable" => true
        }
      },
      overrides
    )
  end

  describe "create_stream/2" do
    test "creates a stream with flat parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "part=snippet%2Ccdn%2Cstatus%2CcontentDetails" or conn.query_string =~ "part="
        assert decoded["snippet"]["title"] == "Primary OBS Stream"
        assert decoded["snippet"]["description"] == "Automated broadcast ingestion stream"
        assert decoded["cdn"]["ingestionType"] == "rtmp"
        assert decoded["cdn"]["resolution"] == "1080p"
        assert decoded["cdn"]["frameRate"] == "60fps"
        assert decoded["contentDetails"]["isReusable"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture(%{"id" => "str_created_1"})))
      end)

      params = %{
        title: "Primary OBS Stream",
        description: "Automated broadcast ingestion stream",
        ingestion_type: "rtmp",
        resolution: "1080p",
        frame_rate: "60fps",
        is_reusable: true
      }

      assert {:ok, stream} = LiveStreams.create_stream(params, token: "test_token")
      assert stream["id"] == "str_created_1"
      assert LiveStreams.stream_key(stream) == "key-abcd-1234"
      assert LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"
      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key-abcd-1234"
    end

    test "creates a stream with structured nested payload and default fallback" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["cdn"]["ingestionType"] == "rtmp"
        assert decoded["cdn"]["resolution"] == "variable"
        assert decoded["cdn"]["frameRate"] == "variable"
        assert decoded["contentDetails"]["isReusable"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture(%{"id" => "str_default"})))
      end)

      params = %{
        snippet: %{title: "Default Fallback Stream"}
      }

      assert {:ok, stream} = LiveStreams.create_stream(params, token: "test_token")
      assert stream["id"] == "str_default"
    end

    test "supports onBehalfOfContentOwner and custom part parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "part=snippet%2Ccdn"
        assert conn.query_string =~ "onBehalfOfContentOwner=owner_xyz"
        assert conn.query_string =~ "onBehalfOfContentOwnerChannel=chan_xyz"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture()))
      end)

      params = %{
        title: "CMS Stream",
        on_behalf_of_content_owner: "owner_xyz",
        on_behalf_of_content_owner_channel: "chan_xyz",
        part: "snippet,cdn"
      }

      assert {:ok, _} = LiveStreams.create_stream(params, token: "test_token")
    end

    test "handles quotaExceeded error from Client" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "errors" => [%{"reason" => "quotaExceeded", "message" => "Quota exceeded"}]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveStreams.create_stream(%{title: "Fails"}, token: "test_token")

      assert details.reason == "quotaExceeded"
    end
  end

  describe "list_streams/2" do
    test "lists streams with mine=true default and pagination" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "mine=true"
        assert conn.query_string =~ "maxResults=10"
        assert conn.query_string =~ "pageToken=tok_next"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStreamListResponse",
            "items" => [
              stream_fixture(%{"id" => "str_1", "status" => %{"streamStatus" => "active"}}),
              stream_fixture(%{"id" => "str_2", "status" => %{"streamStatus" => "ready"}})
            ],
            "nextPageToken" => "tok_page_2"
          })
        )
      end)

      params = %{max_results: 10, page_token: "tok_next"}
      assert {:ok, resp} = LiveStreams.list_streams(params, token: "test_token")
      assert length(resp["items"]) == 2
      assert resp["nextPageToken"] == "tok_page_2"
    end

    test "lists streams filtered by multiple IDs list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "id=id1%2Cid2"
        refute conn.query_string =~ "mine=true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [stream_fixture(%{"id" => "id1"})]}))
      end)

      assert {:ok, resp} = LiveStreams.list_streams(%{id: ["id1", "id2"]}, token: "test_token")
      assert length(resp["items"]) == 1
    end

    test "accepts keyword list parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "mine=true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:ok, resp} = LiveStreams.list_streams([mine: true], token: "test_token")
      assert resp["items"] == []
    end
  end

  describe "get_stream/2" do
    test "fetches single stream and unwraps items list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.query_string =~ "id=str_target"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStreamListResponse",
            "items" => [
              stream_fixture(%{
                "id" => "str_target",
                "snippet" => %{"title" => "Target Stream"},
                "status" => %{"streamStatus" => "active", "healthStatus" => %{"status" => "good"}}
              })
            ]
          })
        )
      end)

      assert {:ok, stream} = LiveStreams.get_stream("str_target", token: "test_token")
      assert stream["id"] == "str_target"
      assert LiveStreams.active?(stream) == true
      assert LiveStreams.health_status(stream) == "good"
    end

    test "returns {:error, :not_found} when stream list is empty" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:error, :not_found} = LiveStreams.get_stream("nonexistent", token: "test_token")
    end

    test "returns error on missing ID" do
      assert {:error, :missing_stream_id} = LiveStreams.get_stream("", token: "test_token")
      assert {:error, :missing_stream_id} = LiveStreams.get_stream(nil, token: "test_token")
    end
  end

  describe "update_stream/2" do
    test "updates stream metadata with PUT request" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "PUT"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert decoded["id"] == "stream_to_update"
        assert decoded["snippet"]["title"] == "Updated Title"
        assert decoded["cdn"]["resolution"] == "720p"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            stream_fixture(%{
              "id" => "stream_to_update",
              "snippet" => %{"title" => "Updated Title"},
              "cdn" => %{"resolution" => "720p"}
            })
          )
        )
      end)

      params = %{
        id: "stream_to_update",
        title: "Updated Title",
        resolution: "720p"
      }

      assert {:ok, updated} = LiveStreams.update_stream(params, token: "test_token")
      assert updated["snippet"]["title"] == "Updated Title"
    end

    test "returns error when ID is missing in update" do
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{title: "New"}, token: "test_token")
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{id: ""}, token: "test_token")
    end
  end

  describe "delete_stream/2" do
    test "deletes stream and returns confirmation map" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "id=str_to_delete"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{id: "str_to_delete", deleted: true}} =
               LiveStreams.delete_stream("str_to_delete", token: "test_token")
    end

    test "returns error when ID is missing in delete" do
      assert {:error, :missing_stream_id} = LiveStreams.delete_stream("", token: "test_token")
      assert {:error, :missing_stream_id} = LiveStreams.delete_stream(nil, token: "test_token")
    end
  end

  describe "helpers & extractors" do
    setup do
      stream = stream_fixture(%{
        "id" => "str_h",
        "cdn" => %{
          "ingestionType" => "rtmp",
          "ingestionInfo" => %{
            "streamName" => "key-test-123",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmp.youtube.com/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmp.youtube.com/live2?backup=1"
          }
        },
        "status" => %{
          "streamStatus" => "active",
          "healthStatus" => %{
            "status" => "good",
            "configurationIssues" => []
          }
        }
      })

      {:ok, stream: stream}
    end

    test "extracts stream key and ingestion addresses", %{stream: stream} do
      assert LiveStreams.stream_key(stream) == "key-test-123"
      assert LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"
      assert LiveStreams.backup_ingestion_address(stream) == "rtmp://b.rtmp.youtube.com/live2?backup=1"
      assert LiveStreams.rtmps_ingestion_address(stream) == "rtmps://a.rtmp.youtube.com/live2"
      assert LiveStreams.rtmps_backup_ingestion_address(stream) == "rtmps://b.rtmp.youtube.com/live2?backup=1"
    end

    test "extracts from atom-keyed maps" do
      atom_map = %{
        cdn: %{
          ingestion_info: %{
            stream_name: "atom_key",
            ingestion_address: "rtmp://atom.com",
            backup_ingestion_address: "rtmp://atom-backup.com",
            rtmps_ingestion_address: "rtmps://atom.com",
            rtmps_backup_ingestion_address: "rtmps://atom-backup.com"
          }
        },
        status: %{
          stream_status: "ready",
          health_status: %{status: "ok"}
        }
      }

      assert LiveStreams.stream_key(atom_map) == "atom_key"
      assert LiveStreams.ingestion_address(atom_map) == "rtmp://atom.com"
      assert LiveStreams.backup_ingestion_address(atom_map) == "rtmp://atom-backup.com"
      assert LiveStreams.rtmps_ingestion_address(atom_map) == "rtmps://atom.com"
      assert LiveStreams.rtmps_backup_ingestion_address(atom_map) == "rtmps://atom-backup.com"
      assert LiveStreams.stream_status(atom_map) == "ready"
      assert LiveStreams.health_status(atom_map) == "ok"
    end

    test "constructs full stream URLs correctly", %{stream: stream} do
      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key-test-123"
      assert LiveStreams.stream_url(stream, protocol: :rtmps) == "rtmps://a.rtmp.youtube.com/live2/key-test-123"
      assert LiveStreams.stream_url(stream, backup: true) == "rtmp://b.rtmp.youtube.com/live2/key-test-123?backup=1"
      assert LiveStreams.stream_url(stream, protocol: :rtmps, backup: true) == "rtmps://b.rtmp.youtube.com/live2/key-test-123?backup=1"
    end

    test "evaluates health and readiness predicates", %{stream: stream} do
      assert LiveStreams.stream_status(stream) == "active"
      assert LiveStreams.health_status(stream) == "good"
      assert LiveStreams.active?(stream) == true
      assert LiveStreams.ready?(stream) == true
      assert LiveStreams.error?(stream) == false

      error_stream = %{
        "status" => %{
          "streamStatus" => "error",
          "healthStatus" => %{"status" => "bad"}
        }
      }

      assert LiveStreams.active?(error_stream) == false
      assert LiveStreams.ready?(error_stream) == false
      assert LiveStreams.error?(error_stream) == true
    end

    test "handles nil inputs safely" do
      assert LiveStreams.stream_key(nil) == nil
      assert LiveStreams.ingestion_address(nil) == nil
      assert LiveStreams.backup_ingestion_address(nil) == nil
      assert LiveStreams.rtmps_ingestion_address(nil) == nil
      assert LiveStreams.rtmps_backup_ingestion_address(nil) == nil
      assert LiveStreams.stream_url(nil) == nil
      assert LiveStreams.stream_status(nil) == nil
      assert LiveStreams.health_status(nil) == nil
      assert LiveStreams.active?(nil) == false
      assert LiveStreams.ready?(nil) == false
      assert LiveStreams.error?(nil) == false
    end

    test "default_part returns expected string" do
      assert LiveStreams.default_part() == "snippet,cdn,status,contentDetails"
    end

    test "create_stream with DASH ingestion and isReusable content detail" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["cdn"]["ingestionType"] == "dash"
        assert decoded["contentDetails"]["isReusable"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture()))
      end)

      params = %{
        title: "DASH Stream",
        ingestion_type: :dash,
        is_reusable: true
      }

      assert {:ok, _} = LiveStreams.create_stream(params, token: "test_token")
    end

    test "update_stream with content_details is_reusable and full cdn options" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["id"] == "str_up_full"
        assert decoded["cdn"]["frameRate"] == "60fps"
        assert decoded["cdn"]["resolution"] == "1080p"
        assert decoded["contentDetails"]["isReusable"] == false

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture(%{"id" => "str_up_full"})))
      end)

      params = %{
        id: "str_up_full",
        frame_rate: "60fps",
        resolution: "1080p",
        is_reusable: false
      }

      assert {:ok, _} = LiveStreams.update_stream(params, token: "test_token")
    end

    test "stream_url handles missing stream key or address" do
      assert LiveStreams.stream_url(%{"cdn" => %{"ingestionInfo" => %{}}}) == nil
      assert LiveStreams.stream_url(%{"cdn" => %{"ingestionInfo" => %{"streamName" => "key"}}}) == nil
      assert LiveStreams.stream_url(%{"cdn" => %{"ingestionInfo" => %{"ingestionAddress" => "rtmp://host"}}}) == nil
    end

    test "list_streams with multiple IDs and content owner options" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "id=s1%2Cs2"
        assert conn.query_string =~ "onBehalfOfContentOwner=owner1"
        assert conn.query_string =~ "onBehalfOfContentOwnerChannel=chan1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      params = %{
        id: ["s1", "s2"],
        on_behalf_of_content_owner: "owner1",
        on_behalf_of_content_owner_channel: "chan1"
      }

      assert {:ok, _} = LiveStreams.list_streams(params, token: "tok")
    end

    test "create, get, update, and delete stream with on_behalf_of_content_owner" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner1"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture()))
      end)

      assert {:ok, _} =
               LiveStreams.create_stream(%{title: "CDN test", ingestion_type: :rtmp, resolution: :variable, frame_rate: :variable},
                 token: "tok",
                 on_behalf_of_content_owner: "owner1"
               )

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner1"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [stream_fixture()]}))
      end)

      assert {:ok, _} = LiveStreams.get_stream("s1", token: "tok", on_behalf_of_content_owner: "owner1")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner1"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture()))
      end)

      assert {:ok, _} = LiveStreams.update_stream(%{id: "s1", title: "New"}, token: "tok", on_behalf_of_content_owner: "owner1")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "onBehalfOfContentOwner=owner1"
        conn |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, _} = LiveStreams.delete_stream("s1", token: "tok", on_behalf_of_content_owner: "owner1")
    end

    test "get_stream handles single item resource and API error responses" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"kind" => "youtube#liveStream", "id" => "str_direct"}))
      end)

      assert {:ok, stream} = LiveStreams.get_stream("str_direct", token: "tok")
      assert stream["id"] == "str_direct"

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "Server Error"}}))
      end)

      assert {:error, {500, "Server Error"}} = LiveStreams.get_stream("err_str", token: "tok")
    end

    test "delete_stream error propagation" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => %{"message" => "Forbidden"}}))
      end)

      assert {:error, {403, "Forbidden"}} = LiveStreams.delete_stream("str_err", token: "tok")
    end

    test "extractor helper variants with direct ingestionInfo and camelCase maps" do
      direct_ingestion = %{
        "ingestionInfo" => %{
          "streamName" => "direct_name",
          "ingestionAddress" => "rtmp://direct.com",
          "backupIngestionAddress" => "rtmp://backup.com",
          "rtmpsIngestionAddress" => "rtmps://direct.com",
          "rtmpsBackupIngestionAddress" => "rtmps://backup.com"
        }
      }

      assert LiveStreams.stream_key(direct_ingestion) == "direct_name"
      assert LiveStreams.ingestion_address(direct_ingestion) == "rtmp://direct.com"
      assert LiveStreams.backup_ingestion_address(direct_ingestion) == "rtmp://backup.com"
      assert LiveStreams.rtmps_ingestion_address(direct_ingestion) == "rtmps://direct.com"
      assert LiveStreams.rtmps_backup_ingestion_address(direct_ingestion) == "rtmps://backup.com"

      camel_atom = %{
        cdn: %{
          ingestionInfo: %{
            streamName: "camel_key",
            ingestionAddress: "rtmp://camel.com",
            backupIngestionAddress: "rtmp://camel-b.com",
            rtmpsIngestionAddress: "rtmps://camel.com",
            rtmpsBackupIngestionAddress: "rtmps://camel-b.com"
          }
        },
        status: %{
          streamStatus: "active",
          healthStatus: %{status: "good"}
        }
      }

      assert LiveStreams.stream_key(camel_atom) == "camel_key"
      assert LiveStreams.ingestion_address(camel_atom) == "rtmp://camel.com"
      assert LiveStreams.backup_ingestion_address(camel_atom) == "rtmp://camel-b.com"
      assert LiveStreams.rtmps_ingestion_address(camel_atom) == "rtmps://camel.com"
      assert LiveStreams.rtmps_backup_ingestion_address(camel_atom) == "rtmps://camel-b.com"
      assert LiveStreams.stream_status(camel_atom) == "active"
      assert LiveStreams.health_status(camel_atom) == "good"

      atom_direct = %{
        ingestionInfo: %{
          streamName: "atom_direct_key",
          ingestionAddress: "rtmp://atom-direct.com",
          backupIngestionAddress: "rtmp://atom-backup.com",
          rtmpsIngestionAddress: "rtmps://atom-direct.com",
          rtmpsBackupIngestionAddress: "rtmps://atom-backup.com"
        }
      }

      assert LiveStreams.stream_key(atom_direct) == "atom_direct_key"
      assert LiveStreams.ingestion_address(atom_direct) == "rtmp://atom-direct.com"
      assert LiveStreams.backup_ingestion_address(atom_direct) == "rtmp://atom-backup.com"
      assert LiveStreams.rtmps_ingestion_address(atom_direct) == "rtmps://atom-direct.com"
      assert LiveStreams.rtmps_backup_ingestion_address(atom_direct) == "rtmps://atom-backup.com"

      snake_nested = %{
        status: %{
          stream_status: "ready",
          health_status: %{status: "ok"}
        },
        cdn: %{
          ingestion_info: %{
            stream_name: "snake_key",
            ingestion_address: "rtmp://snake.com",
            backup_ingestion_address: "rtmp://snake-b.com",
            rtmps_ingestion_address: "rtmps://snake.com",
            rtmps_backup_ingestion_address: "rtmps://snake-b.com"
          }
        }
      }

      assert LiveStreams.stream_key(snake_nested) == "snake_key"
      assert LiveStreams.ingestion_address(snake_nested) == "rtmp://snake.com"
      assert LiveStreams.backup_ingestion_address(snake_nested) == "rtmp://snake-b.com"
      assert LiveStreams.rtmps_ingestion_address(snake_nested) == "rtmps://snake.com"
      assert LiveStreams.rtmps_backup_ingestion_address(snake_nested) == "rtmps://snake-b.com"
      assert LiveStreams.stream_status(snake_nested) == "ready"
      assert LiveStreams.health_status(snake_nested) == "ok"

      direct_string_map = %{
        "ingestionInfo" => %{
          "streamName" => "str_name_dir",
          "ingestionAddress" => "rtmp://dir.com",
          "backupIngestionAddress" => "rtmp://dir-b.com",
          "rtmpsIngestionAddress" => "rtmps://dir.com",
          "rtmpsBackupIngestionAddress" => "rtmps://dir-b.com"
        },
        "status" => %{
          "streamStatus" => "active",
          "healthStatus" => %{"status" => "good"}
        }
      }

      assert LiveStreams.stream_key(direct_string_map) == "str_name_dir"
      assert LiveStreams.ingestion_address(direct_string_map) == "rtmp://dir.com"
      assert LiveStreams.backup_ingestion_address(direct_string_map) == "rtmp://dir-b.com"
      assert LiveStreams.rtmps_ingestion_address(direct_string_map) == "rtmps://dir.com"
      assert LiveStreams.rtmps_backup_ingestion_address(direct_string_map) == "rtmps://dir-b.com"
      assert LiveStreams.stream_status(direct_string_map) == "active"
      assert LiveStreams.health_status(direct_string_map) == "good"
    end

    test "update_stream with nested cdn maps and description update" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["description"] == "Stream Desc Update"
        assert decoded["cdn"]["ingestionType"] == "rtmp"
        assert decoded["cdn"]["resolution"] == "720p"
        assert decoded["cdn"]["frameRate"] == "30fps"
        assert decoded["contentDetails"]["isReusable"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(stream_fixture()))
      end)

      params = %{
        id: "s1",
        description: "Stream Desc Update",
        cdn: %{
          "ingestionType" => "rtmp",
          "resolution" => "720p",
          "frameRate" => "30fps"
        },
        content_details: %{
          "isReusable" => true
        }
      }

      assert {:ok, _} = LiveStreams.update_stream(params, token: "tok")
    end

    test "list_streams with mine=false and string key params" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "mine=false"
        assert conn.query_string =~ "pageToken=pg_1"
        assert conn.query_string =~ "maxResults=5"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      params = %{
        "mine" => false,
        "pageToken" => "pg_1",
        "maxResults" => 5
      }

      assert {:ok, _} = LiveStreams.list_streams(params, token: "tok")
    end
  end
end
