defmodule Lux.Integrations.YouTube.AdversarialSuiteChallengerTest do
  use UnitAPICase, async: false
  require Logger

  alias Lux.Integrations.YouTube.{Client, Errors, LiveChat}
  alias Lux.Integrations.YouTube.LiveChat.Poller

  setup do
    Req.Test.set_req_test_to_shared(YouTubeClientMock)
    Req.Test.set_req_test_to_shared(YouTubeOAuthMock)
    Req.Test.verify_on_exit!()
    :ok
  end

  # Fixture helpers
  defp message_fixture(id, text, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "id" => id,
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "chat_adv_123",
          "authorChannelId" => "UC_author_adv",
          "publishedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "displayMessage" => text,
          "textMessageDetails" => %{
            "messageText" => text
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_author_adv",
          "displayName" => "AdvChatter",
          "profileImageUrl" => "https://yt3.ggpht.com/adv.jpg",
          "isVerified" => false,
          "isChatOwner" => false,
          "isChatSponsor" => false,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  defp list_response(items, next_token, polling_ms, offline_at) do
    %{
      "kind" => "youtube#liveChatMessageListResponse",
      "nextPageToken" => next_token,
      "pollingIntervalMillis" => polling_ms,
      "offlineAt" => offline_at,
      "items" => items
    }
  end

  defp list_response(items, next_token, polling_ms) do
    list_response(items, next_token, polling_ms, nil)
  end

  # ============================================================================
  # Category 1: Poller Concurrency, Mock Isolation, and Crash Resilience
  # ============================================================================
  describe "Category 1: Poller Concurrency, Mock Isolation, and Crash Resilience" do
    test "concurrent pollers with isolated chat IDs and message queues" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        chat_id =
          URI.decode_query(conn.query_string)["liveChatId"] || "unknown"

        items = [message_fixture("msg_#{chat_id}", "Hello from #{chat_id}")]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response(items, "tok_#{chat_id}", 3000)))
      end)

      poller_count = 20

      pollers =
        for i <- 1..poller_count do
          chat_id = "concurrent_chat_#{i}"
          {:ok, pid} =
            Poller.start_link(
              live_chat_id: chat_id,
              token: "tok_#{i}",
              auto_start: false
            )
          {chat_id, pid}
        end

      # Execute poll_once across all pollers concurrently via Tasks
      tasks =
        Enum.map(pollers, fn {chat_id, poller} ->
          Task.async(fn ->
            {:ok, msgs} = Poller.poll_once(poller)
            assert length(msgs) == 1
            [msg] = msgs
            assert msg.id == "msg_#{chat_id}"
            assert msg.display_message == "Hello from #{chat_id}"
            status = Poller.get_status(poller)
            assert status.message_count == 1
            assert status.poll_count == 1
            assert status.page_token == "tok_#{chat_id}"
            :ok
          end)
        end)

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))

      for {_chat_id, poller} <- pollers, do: Poller.stop(poller)
    end

    test "subscriber crash resilience under massive abrupt termination" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([message_fixture("m1", "t1")], "tok2", 5000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "subscriber_resilience_chat",
          token: "tok",
          auto_start: false
        )

      test_pid = self()

      # Spawn 50 subscriber processes that forward received messages to test_pid
      subscribers =
        for _ <- 1..50 do
          spawn_link(fn ->
            receive do
              {:live_chat_messages, _id, _msgs} = msg ->
                send(test_pid, {:forwarded, self(), msg})
              :stop -> :ok
            end
          end)
        end

      # Subscribe all
      Enum.each(subscribers, fn sub ->
        :ok = Poller.subscribe(poller, sub)
      end)

      status_before = Poller.get_status(poller)
      assert status_before.subscribers_count == 50

      # Brutally kill 45 subscribers
      {killed, remaining} = Enum.split(subscribers, 45)
      Enum.each(killed, fn pid ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end)

      # Allow DOWN messages to be processed by poller
      Process.sleep(50)

      status_after = Poller.get_status(poller)
      assert status_after.subscribers_count == 5
      assert Process.alive?(poller)

      # Poller still works and delivers to remaining 5 subscribers
      {:ok, [msg]} = Poller.poll_once(poller)
      assert msg.id == "m1"

      Enum.each(remaining, fn pid ->
        assert_receive {:forwarded, ^pid, {:live_chat_messages, "subscriber_resilience_chat", [delivered]}}, 1000
        assert delivered.id == "m1"
      end)

      Poller.stop(poller)
    end

    test "handler_fn exception isolation with variety of failure modes" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([message_fixture("m_err", "crash")], "tok2", 5000)))
      end)

      # 1. 1-arity function raising RuntimeError
      {:ok, p1} =
        Poller.start_link(
          live_chat_id: "crash_1",
          token: "tok",
          auto_start: false,
          handler_fn: fn _msgs -> raise "Arity 1 crash!" end
        )
      assert {:ok, [_]} = Poller.poll_once(p1)
      assert Process.alive?(p1)
      Poller.stop(p1)

      # 2. 2-arity function raising Erlang error
      {:ok, p2} =
        Poller.start_link(
          live_chat_id: "crash_2",
          token: "tok",
          auto_start: false,
          handler_fn: fn _chat_id, _msgs -> :erlang.error(:badarith) end
        )
      assert {:ok, [_]} = Poller.poll_once(p2)
      assert Process.alive?(p2)
      Poller.stop(p2)

      # 3. Bad MFA tuple targeting non-existent module
      {:ok, p3} =
        Poller.start_link(
          live_chat_id: "crash_3",
          token: "tok",
          auto_start: false,
          handler_fn: {DefinitelyNonExistentModule, :non_existent_func, ["extra"]}
        )
      assert {:ok, [_]} = Poller.poll_once(p3)
      assert Process.alive?(p3)
      Poller.stop(p3)

      # 4. Invalid handler_fn type (e.g. integer or string)
      {:ok, p4} =
        Poller.start_link(
          live_chat_id: "crash_4",
          token: "tok",
          auto_start: false,
          handler_fn: :not_a_function
        )
      assert {:ok, [_]} = Poller.poll_once(p4)
      assert Process.alive?(p4)
      Poller.stop(p4)
    end
  end

  # ============================================================================
  # Category 2: Dynamic Polling Interval & Rate Limit Backoff
  # ============================================================================
  describe "Category 2: Dynamic Polling Interval & Rate Limit Backoff" do
    test "clamping pollingIntervalMillis to configured min and max interval boundaries" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        interval =
          case URI.decode_query(conn.query_string)["pageToken"] do
            "tok_too_low" -> 200 # Below min of 1000
            "tok_too_high" -> 999_999 # Above max of 10_000
            "tok_normal" -> 4500 # Inside bounds
            _ -> 5000
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([], "tok_next", interval)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "clamp_chat",
          token: "tok",
          auto_start: false,
          min_interval_ms: 1000,
          max_interval_ms: 10_000,
          default_interval_ms: 5000
        )

      # 1. Suggested interval below min_interval_ms
      Poller.set_interval(poller, 5000)
      # Manually set page_token to tok_too_low by mocking
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([], "tok_next1", 200)))
      end)
      {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).interval_ms == 1000

      # 2. Suggested interval above max_interval_ms
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([], "tok_next2", 999_999)))
      end)
      {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).interval_ms == 10_000

      # 3. Suggested interval within bounds
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([], "tok_next3", 4500)))
      end)
      {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).interval_ms == 4500

      Poller.stop(poller)
    end

    test "stream termination (offlineAt / 404) triggers :ended state and broadcasts termination" do
      test_pid = self()

      # Test offlineAt termination
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response([], "tok_ended", 5000, "2026-08-18T23:59:59Z"))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "ended_chat_1",
          token: "tok",
          auto_start: false,
          subscriber: test_pid
        )

      {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      assert status.status == :ended
      assert status.offline_at == "2026-08-18T23:59:59Z"
      assert_receive {:live_chat_ended, "ended_chat_1", %{offline_at: "2026-08-18T23:59:59Z"}}, 1000
      Poller.stop(poller)

      # Test 404 Not Found termination
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "liveChatEnded", "message" => "The live chat is ended."}]}})
        )
      end)

      {:ok, poller2} =
        Poller.start_link(
          live_chat_id: "ended_chat_2",
          token: "tok",
          auto_start: false,
          subscriber: test_pid
        )

      {:error, {404, _}} = Poller.poll_once(poller2)
      status2 = Poller.get_status(poller2)
      assert status2.status == :ended
      assert_receive {:live_chat_ended, "ended_chat_2", {404, _}}, 1000
      Poller.stop(poller2)
    end

    test "error backoff cycle: consecutive errors increase backoff, recover on success" do
      test_pid = self()

      # First 3 polls fail with 503
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => %{"message" => "Backend timeout 1"}}))
      end)
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => %{"message" => "Backend timeout 2"}}))
      end)
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => %{"message" => "Backend timeout 3"}}))
      end)
      # 4th poll succeeds
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response([message_fixture("m_rec", "Recovered!")], "tok_rec", 4000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "backoff_chat",
          token: "tok",
          auto_start: false,
          subscriber: test_pid
        )

      # 1st error
      assert {:error, {503, _}} = Poller.poll_once(poller)
      s1 = Poller.get_status(poller)
      assert s1.consecutive_errors == 1
      assert s1.last_error == {503, "Backend timeout 1"}
      assert_receive {:live_chat_error, "backoff_chat", {503, "Backend timeout 1"}}, 1000

      # 2nd error
      assert {:error, {503, _}} = Poller.poll_once(poller)
      s2 = Poller.get_status(poller)
      assert s2.consecutive_errors == 2
      assert s2.last_error == {503, "Backend timeout 2"}

      # 3rd error
      assert {:error, {503, _}} = Poller.poll_once(poller)
      s3 = Poller.get_status(poller)
      assert s3.consecutive_errors == 3

      # 4th poll: Recovery
      assert {:ok, [msg]} = Poller.poll_once(poller)
      assert msg.id == "m_rec"
      s4 = Poller.get_status(poller)
      assert s4.consecutive_errors == 0
      assert s4.last_error == nil
      assert s4.message_count == 1
      assert s4.interval_ms == 4000

      Poller.stop(poller)
    end
  end

  # ============================================================================
  # Category 3: 401 Token Refresh Boundaries & Multi-Process Mock Sharing
  # ============================================================================
  describe "Category 3: 401 Token Refresh Boundaries & Multi-Process Mock Sharing" do
    test "concurrent 401 token refreshes across multiple processes" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        if auth == ["Bearer valid_refreshed_token"] do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "ok"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired"}}))
        end
      end)

      Req.Test.stub(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "valid_refreshed_token"}))
      end)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            opts = %{
              token: "expired_token_#{i}",
              refresh_token: "rt_#{i}",
              client_id: "cid",
              client_secret: "sec",
              auto_refresh: true
            }
            assert {:ok, %{"status" => "ok"}} = Client.get("/test_endpoint", opts)
            :ok
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
    test "401 token refresh succeeds on first retry with updated token" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expired_token"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "valid_rt"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "new_refreshed_token", "expires_in" => 3600}))
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer new_refreshed_token"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => ["success"]}))
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "valid_rt",
        client_id: "cid",
        client_secret: "sec",
        auto_refresh: true
      }

      assert {:ok, %{"items" => ["success"]}} = Client.get("/liveChat/messages", opts)
    end

    test "401 refresh loop boundary: terminates on second 401 without infinite recursion" do
      # Initial request gets 401
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bad_tok1"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid token 1"}}))
      end)

      # OAuth refresh succeeds and returns a second token
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"access_token" => "bad_tok2"}))
      end)

      # Second request also gets 401 - must NOT trigger another refresh
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer bad_tok2"]
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid token 2"}}))
      end)

      opts = %{
        token: "bad_tok1",
        refresh_token: "valid_rt",
        client_id: "cid",
        client_secret: "sec",
        auto_refresh: true
      }

      # Should immediately return {:error, :invalid_token} without calling OAuth again
      assert {:error, :invalid_token} = Client.get("/liveChat/messages", opts)
    end

    test "401 with failing OAuth refresh gracefully returns :invalid_token" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant", "error_description" => "Token revoked"}))
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "revoked_rt",
        client_id: "cid",
        client_secret: "sec",
        auto_refresh: true
      }

      assert {:error, :invalid_token} = Client.get("/liveChat/messages", opts)
    end

    test "auto_refresh: false bypasses token refresh entirely" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))
      end)

      opts = %{
        token: "expired_token",
        refresh_token: "valid_rt",
        client_id: "cid",
        client_secret: "sec",
        auto_refresh: false
      }

      assert {:error, :invalid_token} = Client.get("/liveChat/messages", opts)
    end
  end

  # ============================================================================
  # Category 4: Malformed Payloads, Corrupt Error Bodies & Edge Cases
  # ============================================================================
  describe "Category 4: Malformed Payloads, Corrupt Error Bodies & Edge Cases" do
    test "Errors.parse handles HTML 502/503 error bodies from gateways" do
      html_502 = """
      <!DOCTYPE html>
      <html>
        <head><title>502 Bad Gateway</title></head>
        <body><center><h1>502 Bad Gateway</h1></center><hr><center>cloudflare</center></body>
      </html>
      """

      assert {:error, {502, msg}} = Errors.parse(502, html_502, [])
      assert msg =~ "502 Bad Gateway"
      assert Errors.retryable?({:error, {502, msg}})
    end

    test "Errors.parse handles non-JSON, empty, and nil bodies across HTTP statuses" do
      # 500 with nil body
      assert {:error, {500, "Internal Server Error"}} = Errors.parse(500, nil, [])

      # 400 with empty string body
      assert {:error, {400, "Bad Request"}} = Errors.parse(400, "", [])

      # 403 with raw unparseable string
      assert {:error, {403, "Access Denied by WAF"}} = Errors.parse(403, "Access Denied by WAF", [])

      # 429 with corrupted JSON
      assert {:error, {:rate_limited, info}} = Errors.parse(429, "{broken json", [])
      assert info.status == 429
      assert info.reason == "rateLimitExceeded"
    end

    test "Errors.extract_retry_after parses diverse header styles" do
      # Integer string
      assert Errors.extract_retry_after([{"retry-after", "30"}]) == 30
      assert Errors.extract_retry_after(%{"Retry-After" => "120"}) == 120
      assert Errors.extract_retry_after(%{retry_after: 45}) == 45

      # Multi-value or list headers
      assert Errors.extract_retry_after([{"retry-after", ["60", "120"]}]) == 60

      # Invalid / non-integer values
      assert Errors.extract_retry_after([{"retry-after", "invalid"}]) == nil
      assert Errors.extract_retry_after([{"retry-after", "-10"}]) == nil
      assert Errors.extract_retry_after(%{"Retry-After" => "3.14"}) == nil
      assert Errors.extract_retry_after(nil) == nil
      assert Errors.extract_retry_after([]) == nil
    end

    test "LiveChat.normalize_message handles sparse, malformed, and weird message maps" do
      # Completely empty map
      normalized = LiveChat.normalize_message(%{})
      assert normalized.id == nil
      assert normalized.type == "textMessageEvent"
      assert normalized.is_verified == false
      assert normalized.is_chat_owner == false
      assert normalized.is_chat_sponsor == false
      assert normalized.is_chat_moderator == false
      assert normalized.message_text == nil
      assert normalized.super_chat_details == nil

      # Super chat with string micros and float amount
      raw_sc = %{
        "id" => "sc_sparse",
        "snippet" => %{
          "type" => "superChatEvent",
          "liveChatId" => "c1",
          "superChatDetails" => %{
            "amountMicros" => "25000000",
            "currency" => "EUR",
            "amountDisplayString" => "€25.00",
            "userComment" => "Bravo!"
          }
        }
      }
      sc_norm = LiveChat.normalize_message(raw_sc)
      assert sc_norm.id == "sc_sparse"
      assert sc_norm.super_chat_details.amount_micros == 25_000_000
      assert sc_norm.super_chat_details.currency == "EUR"
      assert sc_norm.message_text == "Bravo!"
      assert LiveChat.super_chat?(sc_norm)
      assert LiveChat.super_chat_amount(sc_norm) == "€25.00"

      # Non-map input
      assert LiveChat.normalize_message("not a map") == %{}
      assert LiveChat.normalize_message(nil) == %{}
    end

    test "LiveChat validation guards reject invalid inputs cleanly" do
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages("", token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(nil, token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "Hello", token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_1", "", token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_1", nil, token: "tok")
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id("", token: "tok")
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(nil, token: "tok")
    end
  end
end
