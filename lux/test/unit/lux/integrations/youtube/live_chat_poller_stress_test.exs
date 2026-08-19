defmodule Lux.Integrations.YouTube.LiveChatPollerStressTest do
  use UnitAPICase, async: false
  require Logger

  alias Lux.Integrations.YouTube.LiveChat
  alias Lux.Integrations.YouTube.LiveChat.Poller

  setup do
    Req.Test.set_req_test_to_shared(YouTubeClientMock)
    Req.Test.verify_on_exit!()
    :ok
  end

  # ============================================================================
  # Helper Fixture Generators
  # ============================================================================

  defp build_message_item(id, chat_id, text, author_id, author_name, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "etag" => "\"etag_#{id}\"",
        "id" => id,
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => chat_id,
          "authorChannelId" => author_id,
          "publishedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "hasDisplayContent" => true,
          "displayMessage" => text,
          "textMessageDetails" => %{
            "messageText" => text
          }
        },
        "authorDetails" => %{
          "channelId" => author_id,
          "channelUrl" => "http://www.youtube.com/channel/#{author_id}",
          "displayName" => author_name,
          "profileImageUrl" => "https://yt3.ggpht.com/avatar_#{author_id}.jpg",
          "isVerified" => false,
          "isChatOwner" => false,
          "isChatSponsor" => false,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  defp build_page_response(items, next_page_token, polling_interval_ms, overrides) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessageListResponse",
        "etag" => "\"etag_list_#{next_page_token}\"",
        "nextPageToken" => next_page_token,
        "pollingIntervalMillis" => polling_interval_ms,
        "pageInfo" => %{
          "totalResults" => length(items),
          "resultsPerPage" => length(items)
        },
        "items" => items
      },
      overrides
    )
  end

  defp build_page_response(items, next_page_token, polling_interval_ms) do
    build_page_response(items, next_page_token, polling_interval_ms, %{})
  end

  # ============================================================================
  # 1. Rapid Pause / Resume / Status Thrashing Concurrency Harness
  # ============================================================================
  describe "1. Rapid Pause / Resume / Status Thrashing Concurrency Harness" do
    test "survives 300 rapid interleaved pause/resume/get_status calls across concurrent tasks without deadlock or crash" do
      chat_id = "stress_thrash_chat_001"

      # Stateful stub returning empty responses
      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response([], "tok_stable", 5000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "stress_tok",
          default_interval_ms: 1000,
          min_interval_ms: 100,
          auto_start: true
        )

      assert Process.alive?(poller)

      # Spawn 10 worker tasks hitting pause, resume, get_status, set_interval concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            for j <- 1..30 do
              case rem(i + j, 4) do
                0 -> Poller.pause(poller)
                1 -> Poller.resume(poller)
                2 ->
                  status = Poller.get_status(poller)
                  assert status.live_chat_id == chat_id
                  assert status.status in [:running, :paused]
                3 -> Poller.set_interval(poller, 500 + rem(j, 500))
              end
            end
            :ok
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))
      assert Process.alive?(poller)

      # Verify Poller is still functional after concurrency stress
      Poller.resume(poller)
      status = Poller.get_status(poller)
      assert status.status == :running
      assert {:ok, []} = Poller.poll_once(poller)

      Poller.stop(poller)
      refute Process.alive?(poller)
    end

    test "rapid tight-loop pause and resume 100 times consecutively maintains consistent timer and status state" do
      chat_id = "stress_tight_loop_chat_002"

      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response([], "tok_loop", 5000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          default_interval_ms: 5000,
          auto_start: true
        )

      for _ <- 1..100 do
        assert :ok = Poller.pause(poller)
        status = Poller.get_status(poller)
        assert status.status == :paused

        assert :ok = Poller.resume(poller)
        status = Poller.get_status(poller)
        assert status.status == :running
      end

      assert Process.alive?(poller)
      Poller.stop(poller)
    end
  end

  # ============================================================================
  # 2. High-Frequency Paginated Message Stream Simulation
  # ============================================================================
  describe "2. High-Frequency Paginated Message Stream Simulation" do
    test "streams 5,000 messages across 50 consecutive pages with strict FIFO order, zero duplicates, and exact count" do
      chat_id = "stress_stream_chat_5000"
      test_pid = self()

      # Total pages: 50, 100 messages per page = 5,000 messages
      total_pages = 50
      msgs_per_page = 100
      total_expected_messages = total_pages * msgs_per_page

      {:ok, page_agent} = Agent.start_link(fn -> 1 end)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        current_page = Agent.get_and_update(page_agent, fn p -> {p, p + 1} end)

        if current_page <= total_pages do
          start_idx = (current_page - 1) * msgs_per_page + 1
          end_idx = current_page * msgs_per_page

          items =
            Enum.map(start_idx..end_idx, fn idx ->
              build_message_item(
                "msg_stream_#{idx}",
                chat_id,
                "Stress message ##{idx}",
                "user_#{rem(idx, 20)}",
                "User #{rem(idx, 20)}"
              )
            end)

          next_token = "tok_page_#{current_page + 1}"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response(items, next_token, 50)))
        else
          # Finished stream, return empty
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response([], "tok_page_done", 5000)))
        end
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok_stream",
          subscriber: test_pid,
          default_interval_ms: 10,
          min_interval_ms: 5,
          auto_start: true
        )

      # Collect messages until all 5,000 are received
      all_received = collect_messages(total_expected_messages, 15_000)

      assert length(all_received) == total_expected_messages

      # Verify strict FIFO order
      expected_ids = Enum.map(1..total_expected_messages, &"msg_stream_#{&1}")
      actual_ids = Enum.map(all_received, & &1.id)
      assert actual_ids == expected_ids

      # Verify zero duplicates
      unique_ids = Enum.uniq(actual_ids)
      assert length(unique_ids) == total_expected_messages

      # Verify Poller internal status counter
      status = Poller.get_status(poller)
      assert status.message_count >= total_expected_messages
      assert status.poll_count >= total_pages

      Poller.stop(poller)
      Agent.stop(page_agent)
    end

    defp collect_messages(target_count, timeout_ms) do
      start_time = System.monotonic_time(:millisecond)
      do_collect([], target_count, start_time, timeout_ms)
    end

    defp do_collect(acc, target_count, start_time, timeout_ms) do
      if length(acc) >= target_count do
        acc
      else
        elapsed = System.monotonic_time(:millisecond) - start_time
        remaining = max(timeout_ms - elapsed, 0)

        if remaining == 0 do
          acc
        else
          receive do
            {:live_chat_messages, _chat_id, batch} ->
              do_collect(acc ++ batch, target_count, start_time, timeout_ms)
          after
            remaining ->
              acc
          end
        end
      end
    end
  end

  # ============================================================================
  # 3. Concurrent Subscriber Churn & Process Death Chaos Harness
  # ============================================================================
  describe "3. Concurrent Subscriber Churn & Process Death Chaos Harness" do
    test "handles 40 concurrent subscribers dynamically subscribing, unsubscribing, dying, and receiving batches without crashing poller" do
      chat_id = "stress_subscriber_churn_003"
      master_collector = self()

      Req.Test.stub(YouTubeClientMock, fn conn ->
        items = [
          build_message_item(
            "msg_churn_#{System.unique_integer([:positive])}",
            chat_id,
            "Churn broadcast text",
            "author_churn",
            "ChurnAuthor"
          )
        ]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response(items, "tok_churn_next", 20)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: master_collector,
          default_interval_ms: 20,
          min_interval_ms: 10,
          auto_start: true
        )

      assert Process.alive?(poller)

      # Spawn 40 unlinked subscribers with mixed behaviors
      _pids =
        for i <- 1..40 do
          spawn(fn ->
            # Subscribe dynamically
            Poller.subscribe(poller, self())

            _ = receive_some_messages(10, 200)

            case rem(i, 3) do
              0 ->
                # Unsubscribe normally
                Poller.unsubscribe(poller, self())

              1 ->
                # Hard crash / exit
                Process.exit(self(), :kill)

              2 ->
                # Stay subscribed
                :ok
            end
          end)
        end

      # Allow subscribers to run and die
      Process.sleep(400)

      # Verify Poller is completely alive and healthy
      assert Process.alive?(poller)
      status = Poller.get_status(poller)
      assert status.status == :running
      assert status.message_count > 0

      # Master collector still received messages throughout
      assert_receive {:live_chat_messages, ^chat_id, _batch}, 2000

      Poller.stop(poller)
    end

    defp receive_some_messages(0, _timeout), do: 0
    defp receive_some_messages(limit, timeout) do
      receive do
        {:live_chat_messages, _, _} ->
          1 + receive_some_messages(limit - 1, timeout)
      after
        timeout ->
          0
      end
    end
  end

  # ============================================================================
  # 4. Dynamic Interval & Boundary Clamping Stress Harness
  # ============================================================================
  describe "4. Dynamic Interval & Boundary Clamping Stress Harness" do
    test "correctly clamps API-suggested intervals to [min_interval_ms, max_interval_ms] under boundary values" do
      chat_id = "stress_interval_clamp_004"

      {:ok, interval_agent} = Agent.start_link(fn -> 5000 end)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        interval = Agent.get(interval_agent, & &1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(build_page_response([], "tok_clamp", interval))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          default_interval_ms: 4000,
          min_interval_ms: 1000,
          max_interval_ms: 10_000,
          auto_start: false
        )

      # 1. Suggested interval 50ms (less than min 1000ms) -> clamped to 1000ms
      Agent.update(interval_agent, fn _ -> 50 end)
      assert {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      assert status.interval_ms == 1000

      # 2. Suggested interval 50,000ms (greater than max 10,000ms) -> clamped to 10,000ms
      Agent.update(interval_agent, fn _ -> 50_000 end)
      assert {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      assert status.interval_ms == 10_000

      # 3. Suggested interval negative (-500) -> falls back to default 4000ms
      Agent.update(interval_agent, fn _ -> -500 end)
      assert {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      assert status.interval_ms == 4000

      # 4. Suggested interval 0 -> falls back to default 4000ms
      Agent.update(interval_agent, fn _ -> 0 end)
      assert {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      assert status.interval_ms == 4000

      # 5. Suggested interval valid 6000ms -> exactly 6000ms
      Agent.update(interval_agent, fn _ -> 6000 end)
      assert {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      assert status.interval_ms == 6000

      Poller.stop(poller)
      Agent.stop(interval_agent)
    end
  end

  # ============================================================================
  # 5. Adversarial Handler Callback Isolation Harness
  # ============================================================================
  describe "5. Adversarial Handler Callback Isolation Harness" do
    test "handler raising RuntimeError does not crash poller, and subscribers still receive messages" do
      chat_id = "stress_handler_crash_005"
      test_pid = self()

      Req.Test.stub(YouTubeClientMock, fn conn ->
        items = [build_message_item("msg_h_1", chat_id, "Handler crash test", "u1", "User1")]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response(items, "tok_h_next", 5000)))
      end)

      crashing_handler = fn _msgs ->
        raise RuntimeError, "Hostile handler crash!"
      end

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          handler_fn: crashing_handler,
          auto_start: false
        )

      assert Process.alive?(poller)
      assert {:ok, [msg]} = Poller.poll_once(poller)
      assert msg.id == "msg_h_1"

      # Verify subscriber received the broadcast despite handler crash
      assert_receive {:live_chat_messages, ^chat_id, [received_msg]}, 1000
      assert received_msg.id == "msg_h_1"

      # Poller remains completely alive and functional
      assert Process.alive?(poller)
      Poller.stop(poller)
    end

    test "2-arity handler raising ArgumentError does not crash poller" do
      chat_id = "stress_handler_arity2_006"

      Req.Test.stub(YouTubeClientMock, fn conn ->
        items = [build_message_item("msg_h_2", chat_id, "Arity 2 crash test", "u2", "User2")]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response(items, "tok_h2", 5000)))
      end)

      arity2_handler = fn _chat_id, _msgs ->
        raise ArgumentError, "Arity 2 error!"
      end

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          handler_fn: arity2_handler,
          auto_start: false
        )

      assert {:ok, [_]} = Poller.poll_once(poller)
      assert Process.alive?(poller)
      Poller.stop(poller)
    end

    test "handler MFA with non-existent module does not crash poller" do
      chat_id = "stress_handler_mfa_007"

      Req.Test.stub(YouTubeClientMock, fn conn ->
        items = [build_message_item("msg_h_3", chat_id, "MFA crash test", "u3", "User3")]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response(items, "tok_h3", 5000)))
      end)

      bad_mfa = {NonExistentModuleUnderTest, :never_defined, ["extra"]}

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          handler_fn: bad_mfa,
          auto_start: false
        )

      assert {:ok, [_]} = Poller.poll_once(poller)
      assert Process.alive?(poller)
      Poller.stop(poller)
    end
  end

  # ============================================================================
  # 6. Stream End & Inactive Detection (offlineAt & 404)
  # ============================================================================
  describe "6. Stream End & Inactive Detection (offlineAt & 404)" do
    test "offlineAt signal dispatches {:live_chat_ended, ...}, transitions status to :ended, and halts polling loop" do
      chat_id = "stress_ended_offline_008"
      test_pid = self()
      offline_ts = "2026-08-17T23:59:59.000Z"

      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(build_page_response([], "tok_ended", 100, %{"offlineAt" => offline_ts}))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          default_interval_ms: 50,
          min_interval_ms: 10,
          auto_start: true
        )

      # Receive ended notification
      assert_receive {:live_chat_ended, ^chat_id, %{offline_at: ^offline_ts}}, 2000

      status = Poller.get_status(poller)
      assert status.status == :ended
      assert status.offline_at == offline_ts

      # Wait a while and verify no additional polls occur while ended
      poll_count_before = status.poll_count
      Process.sleep(200)
      status_after = Poller.get_status(poller)
      assert status_after.poll_count == poll_count_before

      Poller.stop(poller)
    end

    test "404 Not Found error dispatches {:live_chat_ended, ...} and marks status as :ended" do
      chat_id = "stress_ended_404_009"
      test_pid = self()

      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{
            "error" => %{
              "code" => 404,
              "message" => "The live chat is no longer active or does not exist."
            }
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          default_interval_ms: 50,
          auto_start: true
        )

      assert_receive {:live_chat_ended, ^chat_id, {404, _}}, 2000

      status = Poller.get_status(poller)
      assert status.status == :ended

      Poller.stop(poller)
    end
  end

  # ============================================================================
  # 7. Massive Concurrent Pollers & Zero Process Leaks
  # ============================================================================
  describe "7. Massive Concurrent Pollers & Zero Process Leaks" do
    test "spawns 50 concurrent pollers, performs polling, stops them all, and guarantees zero process leaks" do
      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_page_response([], "tok_leak_test", 5000)))
      end)

      pollers =
        Enum.map(1..50, fn i ->
          {:ok, pid} =
            Poller.start_link(
              live_chat_id: "chat_leak_#{i}",
              token: "tok_leak",
              auto_start: false
            )

          pid
        end)

      assert length(pollers) == 50
      assert Enum.all?(pollers, &Process.alive?/1)

      # Concurrently poll once on all 50
      results =
        pollers
        |> Enum.map(fn p -> Task.async(fn -> Poller.poll_once(p) end) end)
        |> Task.await_many(5000)

      assert Enum.all?(results, &match?({:ok, []}, &1))

      # Stop all 50 pollers
      Enum.each(pollers, fn p ->
        assert :ok = Poller.stop(p)
      end)

      # Verify all 50 are dead
      Process.sleep(50)
      assert Enum.all?(pollers, fn p -> not Process.alive?(p) end)
    end

    test "start_link with missing or blank live_chat_id terminates cleanly without leaking process" do
      assert {:error, :missing_live_chat_id} = Poller.start_link([])
      assert {:error, :missing_live_chat_id} = Poller.start_link(live_chat_id: "")
      assert {:error, :missing_live_chat_id} = Poller.start_link(live_chat_id: nil)
    end
  end

  # ============================================================================
  # 8. Message Normalization & Helper Extractor Adversarial Fuzzing
  # ============================================================================
  describe "8. Message Normalization & Helper Extractor Adversarial Fuzzing" do
    test "normalizes extreme and malformed live chat payloads without throwing exceptions" do
      # 1. Empty map
      assert %{is_verified: false, is_chat_owner: false, type: "textMessageEvent"} =
               LiveChat.normalize_message(%{})

      # 2. Nil and non-map inputs
      assert %{} = LiveChat.normalize_message(nil)
      assert %{} = LiveChat.normalize_message("invalid_payload")
      assert %{} = LiveChat.normalize_message([1, 2, 3])

      # 3. Super chat with string amountMicros
      sc_item = %{
        "id" => "msg_sc_str",
        "snippet" => %{
          "type" => "superChatEvent",
          "liveChatId" => "chat_sc",
          "superChatDetails" => %{
            "amountMicros" => "25000000",
            "currency" => "EUR",
            "amountDisplayString" => "€25.00",
            "userComment" => "Super donation string micros"
          }
        }
      }

      norm_sc = LiveChat.normalize_message(sc_item)
      assert norm_sc.super_chat_details.amount_micros == 25_000_000
      assert norm_sc.super_chat_details.currency == "EUR"
      assert norm_sc.super_chat_details.amount_display_string == "€25.00"
      assert norm_sc.message_text == "Super donation string micros"
      assert LiveChat.super_chat?(norm_sc) == true
      assert LiveChat.super_chat_amount(norm_sc) == "€25.00"

      # 4. Super chat with unparseable amountMicros
      sc_unparseable = %{
        "id" => "msg_sc_bad",
        "snippet" => %{
          "type" => "superChatEvent",
          "superChatDetails" => %{
            "amountMicros" => "invalid_non_int",
            "amountDisplayString" => "$???"
          }
        }
      }
      norm_bad = LiveChat.normalize_message(sc_unparseable)
      assert norm_bad.super_chat_details.amount_micros == nil
      assert LiveChat.super_chat_amount(norm_bad) == "$???"

      # 5. Giant unicode message with RTL, emojis, and special chars (5,000 chars)
      giant_text = String.duplicate("🚀 Lux AI 🤖 مرحبا بالعالم 🌍 日本語 ", 150)
      unicode_item = %{
        "id" => "msg_unicode",
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "chat_unicode",
          "displayMessage" => giant_text
        },
        "authorDetails" => %{
          "displayName" => "UnicodeUser 🌟",
          "isChatOwner" => true,
          "isChatModerator" => true
        }
      }
      norm_unicode = LiveChat.normalize_message(unicode_item)
      assert norm_unicode.display_message == giant_text
      assert norm_unicode.message_text == giant_text
      assert norm_unicode.is_chat_owner == true
      assert norm_unicode.is_chat_moderator == true
      assert LiveChat.author_name(norm_unicode) == "UnicodeUser 🌟"
      assert LiveChat.chat_owner?(norm_unicode) == true
      assert LiveChat.chat_moderator?(norm_unicode) == true
    end

    test "all helper extractors safely handle nil, empty maps, and atoms" do
      assert LiveChat.message_text(nil) == nil
      assert LiveChat.message_text(%{}) == nil
      assert LiveChat.author_name(nil) == nil
      assert LiveChat.author_name(%{}) == nil
      assert LiveChat.author_channel_id(nil) == nil
      assert LiveChat.author_channel_id(%{}) == nil
      assert LiveChat.published_at(nil) == nil
      assert LiveChat.published_at(%{}) == nil
      assert LiveChat.chat_owner?(nil) == false
      assert LiveChat.chat_owner?(%{}) == false
      assert LiveChat.chat_moderator?(nil) == false
      assert LiveChat.chat_moderator?(%{}) == false
      assert LiveChat.chat_sponsor?(nil) == false
      assert LiveChat.chat_sponsor?(%{}) == false
      assert LiveChat.super_chat?(nil) == false
      assert LiveChat.super_chat?(%{}) == false
      assert LiveChat.super_chat_amount(nil) == nil
      assert LiveChat.super_chat_amount(%{}) == nil
    end
  end
end
