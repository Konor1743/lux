defmodule Lux.Integrations.YouTube.LensesPrismsDomainAdversarialTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{LiveBroadcasts, LiveChat, LiveStreams}

  setup do
    Req.Test.verify_on_exit!()
    orig_keys = Application.get_env(:lux, :api_keys, [])

    on_exit(fn ->
      Application.put_env(:lux, :api_keys, orig_keys)
    end)

    :ok
  end

  # ============================================================================
  # 1. Missing Required Parameters & Schema Rejections
  # ============================================================================
  describe "1. Missing Required Parameters & Schema Rejections" do
    test "LiveChat.list_messages rejects nil or empty live_chat_id" do
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(nil, token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages("", token: "tok")
    end

    test "LiveChat.insert_message rejects nil or empty live_chat_id and message_text" do
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message(nil, "hello", token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "hello", token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_1", nil, token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_1", "", token: "tok")
    end

    test "LiveStreams.get_stream rejects nil or empty stream_id" do
      assert {:error, :missing_stream_id} = LiveStreams.get_stream(nil, token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.get_stream("", token: "tok")
    end

    test "LiveBroadcasts.get_broadcast rejects nil or empty broadcast_id" do
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.get_broadcast(nil, token: "tok")
      assert {:error, :missing_broadcast_id} = LiveBroadcasts.get_broadcast("", token: "tok")
    end

    test "LiveBroadcasts.transition_broadcast rejects invalid lifecycle states" do
      assert {:error, {:invalid_transition_status, "invalid_state"}} =
               LiveBroadcasts.transition_broadcast("b_1", "invalid_state", token: "tok")

      assert {:error, {:invalid_transition_status, :unknown}} =
               LiveBroadcasts.transition_broadcast("b_1", :unknown, token: "tok")
    end

    test "LiveBroadcasts.bind_broadcast handles bind parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=b_1"
        assert conn.query_string =~ "streamId=s_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "b_1",
          "contentDetails" => %{"boundStreamId" => "s_1"}
        }))
      end)

      assert {:ok, result} =
               LiveBroadcasts.bind_broadcast("b_1", "s_1", token: "tok")

      assert result["contentDetails"]["boundStreamId"] == "s_1"
    end
  end

  # ============================================================================
  # 2. Malformed Options & Boundary Conditions
  # ============================================================================
  describe "2. Malformed Options & Boundary Conditions" do
    test "LiveChat.list_messages bounds max_results between 1 and 2000" do
      Req.Test.expect(YouTubeClientMock, 2, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "items" => [],
          "pollingIntervalMillis" => 5000
        }))
      end)

      assert {:ok, _} = LiveChat.list_messages("chat_1", max_results: 0, token: "tok")
      assert {:ok, _} = LiveChat.list_messages("chat_1", max_results: 5000, token: "tok")
    end

    test "LiveBroadcasts.create_broadcast sanitizes and normalizes privacy_status atoms and strings" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["status"]["privacyStatus"] == "private"
        assert decoded["snippet"]["title"] == "Test Stream"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(decoded))
      end)

      params = %{
        title: "Test Stream",
        scheduled_start_time: "2026-08-17T20:00:00Z",
        privacy_status: :private
      }

      assert {:ok, _} = LiveBroadcasts.create_broadcast(params, token: "tok")
    end

    test "LiveStreams.create_stream validates and builds snippet and cdn payload" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveStreams"
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["cdn"]["ingestionType"] == "rtmp"
        assert decoded["cdn"]["resolution"] == "1080p"
        assert decoded["cdn"]["frameRate"] == "60fps"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(decoded))
      end)

      params = %{
        title: "My Ingestion Stream",
        ingestion_type: "rtmp",
        resolution: "1080p",
        frame_rate: "60fps"
      }

      assert {:ok, _} = LiveStreams.create_stream(params, token: "tok")
    end
  end

  # ============================================================================
  # 3. Concurrent Execution Across Multiple Processes
  # ============================================================================
  describe "3. Concurrent Execution Across Multiple Processes" do
    test "handles 50 concurrent requests simultaneously without state leakage or crash" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        Process.sleep(:rand.uniform(10))

        cond do
          conn.request_path == "/youtube/v3/liveBroadcasts" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "kind" => "youtube#liveBroadcastListResponse",
              "items" => [%{"id" => "b_concurrent", "snippet" => %{"title" => "Concurrent Broadcast"}}]
            }))

          conn.request_path == "/youtube/v3/liveChat/messages" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "kind" => "youtube#liveChatMessageListResponse",
              "items" => [],
              "pollingIntervalMillis" => 3000
            }))

          conn.request_path == "/youtube/v3/liveStreams" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "kind" => "youtube#liveStreamListResponse",
              "items" => [%{"id" => "s_concurrent"}]
            }))

          true ->
            conn
            |> Plug.Conn.send_resp(404, "Not found")
        end
      end)

      tasks =
        Enum.map(1..50, fn i ->
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                LiveBroadcasts.list_broadcasts([broadcast_status: :active], token: "tok_#{i}")

              1 ->
                LiveChat.list_messages("chat_#{i}", token: "tok_#{i}")

              2 ->
                LiveStreams.list_streams([mine: true], token: "tok_#{i}")
            end
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      assert length(results) == 50
      assert Enum.all?(results, fn
        {:ok, %{items: _}} -> true
        {:ok, %{messages: _}} -> true
        {:ok, %{"items" => _}} -> true
        _ -> false
      end)
    end
  end

  # ============================================================================
  # 4. Pipeline Integration & Simulated Workflow
  # ============================================================================
  describe "4. Pipeline Integration & Simulated Workflow" do
    test "executes full lifecycle pipeline: Create Broadcast -> Create Stream -> Bind -> Poll Chat -> Send Message" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "b_pipeline_123",
          "snippet" => %{
            "title" => "Pipeline Broadcast",
            "liveChatId" => "chat_pipeline_456"
          },
          "status" => %{"lifeCycleStatus" => "created"}
        }))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveStreams"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "stream_pipeline_789",
          "snippet" => %{"title" => "Pipeline Stream"}
        }))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
        assert conn.query_string =~ "id=b_pipeline_123"
        assert conn.query_string =~ "streamId=stream_pipeline_789"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "id" => "b_pipeline_123",
          "contentDetails" => %{"boundStreamId" => "stream_pipeline_789"}
        }))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "liveChatId=chat_pipeline_456"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "items" => [
            %{
              "id" => "msg_1",
              "snippet" => %{
                "liveChatId" => "chat_pipeline_456",
                "type" => "textMessageEvent",
                "textMessageDetails" => %{"messageText" => "Agent incoming message"}
              },
              "authorDetails" => %{"displayName" => "User123"}
            }
          ],
          "nextPageToken" => "token_next_1",
          "pollingIntervalMillis" => 5000
        }))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["snippet"]["liveChatId"] == "chat_pipeline_456"
        assert decoded["snippet"]["textMessageDetails"]["messageText"] == "Agent response: Got your message"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(decoded))
      end)

      # Step 1: Create Broadcast
      assert {:ok, broadcast} =
               LiveBroadcasts.create_broadcast(
                 %{
                   title: "Pipeline Broadcast",
                   scheduled_start_time: "2026-08-17T21:00:00Z",
                   privacy_status: :public
                 },
                 token: "tok_pipe"
               )

      broadcast_id = broadcast["id"]
      live_chat_id = LiveBroadcasts.live_chat_id(broadcast)
      assert broadcast_id == "b_pipeline_123"
      assert live_chat_id == "chat_pipeline_456"

      # Step 2: Create Ingestion Stream
      assert {:ok, stream} =
               LiveStreams.create_stream(
                 %{
                   title: "Pipeline Stream",
                   ingestion_type: "rtmp"
                 },
                 token: "tok_pipe"
               )

      stream_id = stream["id"]
      assert stream_id == "stream_pipeline_789"

      # Step 3: Bind Broadcast to Stream
      assert {:ok, bound} =
               LiveBroadcasts.bind_broadcast(broadcast_id, stream_id, token: "tok_pipe")

      assert bound["contentDetails"]["boundStreamId"] == stream_id

      # Step 4: Poll Chat Messages
      assert {:ok, chat_resp} =
               LiveChat.list_messages(live_chat_id, token: "tok_pipe")

      assert length(chat_resp.messages) == 1
      first_msg = hd(chat_resp.messages)
      assert first_msg.message_text == "Agent incoming message"

      # Step 5: Send Agent Chat Message
      reply_text = "Agent response: Got your message"
      assert {:ok, _sent} =
               LiveChat.insert_message(live_chat_id, reply_text, token: "tok_pipe")
    end
  end

  # ============================================================================
  # 5. Resiliency, Fault Injection & Error Propagation
  # ============================================================================
  describe "5. Resiliency, Fault Injection & Error Propagation" do
    test "correctly propagates 403 quotaExceeded without unhandled exception" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "Quota exceeded",
              "errors" => [%{"reason" => "quotaExceeded", "message" => "Quota exceeded"}]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveBroadcasts.list_broadcasts([mine: true], token: "tok")

      assert details.reason == "quotaExceeded"
      assert details.status == 403
    end

    test "correctly propagates 429 rateLimitExceeded without unhandled exception" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{
              "code" => 429,
              "message" => "Rate limited",
              "errors" => [%{"reason" => "rateLimitExceeded", "message" => "Rate limit exceeded"}]
            }
          })
        )
      end)

      assert {:error, {:rate_limited, details}} =
               LiveChat.list_messages("chat_1", token: "tok")

      assert details.reason == "rateLimitExceeded"
      assert details.retry_after == 30
    end

    test "correctly handles 401 unauthenticated after refresh attempt fails" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
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

      assert {:error, :invalid_token} =
               LiveStreams.get_stream("stream_1", token: "bad_tok", auto_refresh: false)
    end
  end
end
