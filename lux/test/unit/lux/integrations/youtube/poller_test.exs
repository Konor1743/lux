defmodule Lux.Integrations.YouTube.LiveChat.PollerTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.LiveChat.Poller

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp message_fixture(id, text, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "id" => id,
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "chat_poller_123",
          "authorChannelId" => "UC_user_1",
          "publishedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "displayMessage" => text,
          "textMessageDetails" => %{
            "messageText" => text
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_user_1",
          "displayName" => "Chatter",
          "profileImageUrl" => "https://yt3.ggpht.com/avatar.jpg",
          "isVerified" => false,
          "isChatOwner" => false,
          "isChatSponsor" => false,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  defp list_response(items, next_token \\ "tok_next", polling_ms \\ 5000, offline_at \\ nil) do
    %{
      "kind" => "youtube#liveChatMessageListResponse",
      "nextPageToken" => next_token,
      "pollingIntervalMillis" => polling_ms,
      "offlineAt" => offline_at,
      "items" => items
    }
  end

  # Helper module for MFA testing
  defmodule TestHandler do
    def handle_messages(messages, caller_pid, tag) do
      send(caller_pid, {:mfa_called, tag, messages})
    end
  end

  describe "Poller lifecycle & validation" do
    test "fails to start without live_chat_id" do
      assert {:error, :missing_live_chat_id} = Poller.start_link([])
      assert {:error, :missing_live_chat_id} = Poller.start_link(live_chat_id: "")
      assert {:error, :missing_live_chat_id} = Poller.start(live_chat_id: nil)
    end

    test "starts successfully and returns status summary", %{} do
      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_status_123",
          token: "tok",
          auto_start: false,
          default_interval_ms: 4000,
          min_interval_ms: 1000,
          max_interval_ms: 30_000
        )

      status = Poller.get_status(poller)
      assert status.status == :paused
      assert status.live_chat_id == "chat_status_123"
      assert status.interval_ms == 4000
      assert status.message_count == 0
      assert status.poll_count == 0
      assert status.consecutive_errors == 0
      assert status.last_error == nil

      Poller.stop(poller)
    end

    test "starts with registered name" do
      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_named_1",
          token: "tok",
          auto_start: false,
          name: :named_poller_test
        )

      assert Process.whereis(:named_poller_test) == poller
      assert Poller.get_status(:named_poller_test).live_chat_id == "chat_named_1"
      Poller.stop(:named_poller_test)
    end
  end

  describe "poll_once/1 synchronous polling" do
    test "executes single poll, updates page_token and metrics" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "liveChatId=chat_step_1"
        refute conn.query_string =~ "pageToken="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([message_fixture("m1", "First message")], "tok_2", 3000))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_step_1",
          token: "tok",
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, [msg1]} = Poller.poll_once(poller)
      assert msg1.id == "m1"
      assert msg1.message_text == "First message"

      status = Poller.get_status(poller)
      assert status.message_count == 1
      assert status.poll_count == 1
      assert status.page_token == "tok_2"
      assert status.interval_ms == 3000

      # Second poll should use tok_2
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=tok_2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([message_fixture("m2", "Second message")], "tok_3", 3000))
        )
      end)

      assert {:ok, [msg2]} = Poller.poll_once(poller)
      assert msg2.id == "m2"

      status2 = Poller.get_status(poller)
      assert status2.message_count == 2
      assert status2.poll_count == 2
      assert status2.page_token == "tok_3"

      Poller.stop(poller)
    end
  end

  describe "Multi-page pagination & deduplication simulation" do
    test "simulates sequential multi-page poll stream without duplicating messages" do
      test_pid = self()

      # Setup sequential page expectations
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "liveChatId=chat_multi_1"
        refute conn.query_string =~ "pageToken="

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            list_response(
              [
                message_fixture("m_p1_1", "Page 1 - Msg 1"),
                message_fixture("m_p1_2", "Page 1 - Msg 2")
              ],
              "tok_page2"
            )
          )
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=tok_page2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            list_response(
              [
                message_fixture("m_p2_1", "Page 2 - Msg 1"),
                message_fixture("m_p2_2", "Page 2 - Msg 2"),
                message_fixture("m_p2_3", "Page 2 - Msg 3")
              ],
              "tok_page3"
            )
          )
        )
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=tok_page3"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([], "tok_page3"))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_multi_1",
          token: "tok",
          subscribers: [test_pid],
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      # Cycle 1
      assert {:ok, batch1} = Poller.poll_once(poller)
      assert length(batch1) == 2
      assert_receive {:live_chat_messages, "chat_multi_1", rec_msgs1}, 1000
      assert Enum.map(rec_msgs1, & &1.id) == ["m_p1_1", "m_p1_2"]

      # Cycle 2
      assert {:ok, batch2} = Poller.poll_once(poller)
      assert length(batch2) == 3
      assert_receive {:live_chat_messages, "chat_multi_1", rec_msgs2}, 1000
      assert Enum.map(rec_msgs2, & &1.id) == ["m_p2_1", "m_p2_2", "m_p2_3"]

      # Cycle 3 (empty batch)
      assert {:ok, batch3} = Poller.poll_once(poller)
      assert batch3 == []
      refute_receive {:live_chat_messages, _, _}, 100

      status = Poller.get_status(poller)
      assert status.message_count == 5
      assert status.poll_count == 3
      assert status.page_token == "tok_page3"

      Poller.stop(poller)
    end
  end

  describe "Subscriber notification and dynamic subscription" do
    test "dispatches to multiple subscriber PIDs and handles subscribe/unsubscribe" do
      test_pid = self()
      other_subscriber =
        spawn(fn ->
          loop = fn loop_fn ->
            receive do
              {:live_chat_messages, "chat_subs_1", msgs} ->
                send(test_pid, {:other_received, length(msgs)})
                loop_fn.(loop_fn)

              :stop ->
                :ok
            end
          end

          loop.(loop)
        end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([message_fixture("m_sub_1", "Broadcast test")]))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_subs_1",
          token: "tok",
          subscriber: test_pid,
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      # Dynamically add other_subscriber
      :ok = Poller.subscribe(poller, other_subscriber)
      assert Poller.get_status(poller).subscribers_count == 2

      {:ok, _} = Poller.poll_once(poller)

      assert_receive {:live_chat_messages, "chat_subs_1", [msg]}
      assert msg.id == "m_sub_1"
      assert_receive {:other_received, 1}

      # Unsubscribe test_pid
      :ok = Poller.unsubscribe(poller, test_pid)
      assert Poller.get_status(poller).subscribers_count == 1

      send(other_subscriber, :stop)
      Poller.stop(poller)
    end

    test "handles subscriber process death via monitor cleanup" do
      dead_process = spawn(fn -> :ok end)
      # Wait for dead_process to exit
      Process.sleep(20)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_down_1",
          token: "tok",
          subscribers: [dead_process, self()],
          auto_start: false
        )

      # Give GenServer a moment to handle DOWN
      Process.sleep(20)
      status = Poller.get_status(poller)
      assert status.subscribers_count == 1

      Poller.stop(poller)
    end
  end

  describe "handler_fn callbacks" do
    test "executes 1-arity and 2-arity function callbacks" do
      test_pid = self()

      handler_1 = fn msgs ->
        send(test_pid, {:handler_1_invoked, length(msgs)})
      end

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([message_fixture("h1", "Test")]))
        )
      end)

      {:ok, poller1} =
        Poller.start_link(
          live_chat_id: "chat_h1",
          token: "tok",
          handler_fn: handler_1,
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller1)
      {:ok, _} = Poller.poll_once(poller1)
      assert_receive {:handler_1_invoked, 1}
      Poller.stop(poller1)

      # 2-arity handler
      handler_2 = fn chat_id, msgs ->
        send(test_pid, {:handler_2_invoked, chat_id, length(msgs)})
      end

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([message_fixture("h2", "Test 2")]))
        )
      end)

      {:ok, poller2} =
        Poller.start_link(
          live_chat_id: "chat_h2",
          token: "tok",
          handler_fn: handler_2,
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller2)
      {:ok, _} = Poller.poll_once(poller2)
      assert_receive {:handler_2_invoked, "chat_h2", 1}
      Poller.stop(poller2)
    end

    test "executes MFA handler and rescues exceptions safely" do
      test_pid = self()

      # MFA handler
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([message_fixture("mfa_1", "MFA message")]))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_mfa",
          token: "tok",
          handler_fn: {TestHandler, :handle_messages, [test_pid, :mfa_tag]},
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      {:ok, _} = Poller.poll_once(poller)
      assert_receive {:mfa_called, :mfa_tag, [msg]}
      assert msg.id == "mfa_1"
      Poller.stop(poller)

      # Crashing handler should not crash GenServer
      crashing_handler = fn _msgs -> raise "Handler crash!" end

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([message_fixture("crash_1", "Boom")]))
        )
      end)

      {:ok, crash_poller} =
        Poller.start_link(
          live_chat_id: "chat_crash",
          token: "tok",
          handler_fn: crashing_handler,
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), crash_poller)
      assert {:ok, [_]} = Poller.poll_once(crash_poller)
      assert Process.alive?(crash_poller)
      Poller.stop(crash_poller)
    end
  end

  describe "Dynamic interval adjustment and clamping" do
    test "adapts interval to API suggestion within min/max bounds" do
      # Test interval clamping to max
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([], "t1", 90_000))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_clamp_1",
          token: "tok",
          default_interval_ms: 5000,
          min_interval_ms: 2000,
          max_interval_ms: 30_000,
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      {:ok, _} = Poller.poll_once(poller)
      assert Poller.get_status(poller).interval_ms == 30_000

      # Test interval clamping to min
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([], "t2", 500))
        )
      end)

      {:ok, _} = Poller.poll_once(poller)
      assert Poller.get_status(poller).interval_ms == 2000

      # Set interval manually
      :ok = Poller.set_interval(poller, 7500)
      assert Poller.get_status(poller).interval_ms == 7500

      Poller.stop(poller)
    end
  end

  describe "Pause & Resume" do
    test "pauses polling and resumes cleanly" do
      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_pause_1",
          token: "tok",
          auto_start: false
        )

      assert Poller.get_status(poller).status == :paused

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([])))
      end)

      Req.Test.allow(YouTubeClientMock, self(), poller)

      :ok = Poller.resume(poller)
      assert Poller.get_status(poller).status == :running

      # Wait for the poll scheduled at delay 0
      Process.sleep(50)
      assert Poller.get_status(poller).poll_count >= 1

      :ok = Poller.pause(poller)
      assert Poller.get_status(poller).status == :paused

      Poller.stop(poller)
    end
  end

  describe "Stream completion / offline detection" do
    test "notifies subscriber on offlineAt field in response and marks status ended" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([], "tok_end", 5000, "2026-08-17T23:30:00.000Z"))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_offline_1",
          token: "tok",
          subscriber: self(),
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      {:ok, _} = Poller.poll_once(poller)

      assert_receive {:live_chat_ended, "chat_offline_1", %{offline_at: "2026-08-17T23:30:00.000Z"}}
      status = Poller.get_status(poller)
      assert status.status == :ended
      assert status.offline_at == "2026-08-17T23:30:00.000Z"

      Poller.stop(poller)
    end

    test "handles 404 liveChatNotFound as live_chat_ended" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{
            "error" => %{"code" => 404, "message" => "Live chat not found"}
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_404",
          token: "tok",
          subscriber: self(),
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      assert {:error, {404, "Live chat not found"}} = Poller.poll_once(poller)

      assert_receive {:live_chat_error, "chat_404", {404, "Live chat not found"}}
      assert_receive {:live_chat_ended, "chat_404", {404, "Live chat not found"}}

      assert Poller.get_status(poller).status == :ended
      Poller.stop(poller)
    end
  end

  describe "Resilient Error Handling & Exponential Backoff" do
    test "broadcasts error to subscribers and tracks consecutive error count" do
      # 1st poll fails with 429
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{"code" => 429, "message" => "Too Many Requests"}
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_err_1",
          token: "tok",
          subscriber: self(),
          auto_start: false
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)

      assert_receive {:live_chat_error, "chat_err_1", {:rate_limited, _}}
      status = Poller.get_status(poller)
      assert status.consecutive_errors == 1
      assert match?({:rate_limited, _}, status.last_error)

      # 2nd poll fails with 403 quotaExceeded
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

      assert {:error, {:quota_exceeded, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_err_1", {:quota_exceeded, _}}
      status2 = Poller.get_status(poller)
      assert status2.consecutive_errors == 2

      # 3rd poll succeeds -> clears errors
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([message_fixture("recov_1", "Back online")])))
      end)

      assert {:ok, [_]} = Poller.poll_once(poller)
      status3 = Poller.get_status(poller)
      assert status3.consecutive_errors == 0
      assert status3.last_error == nil
      assert status3.message_count == 1

      Poller.stop(poller)
    end
  end
end
