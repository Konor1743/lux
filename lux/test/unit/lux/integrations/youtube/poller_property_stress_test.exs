defmodule Lux.Integrations.YouTube.PollerPropertyStressTest do
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
  # Fixtures & Generators
  # ============================================================================

  defp make_msg(id, chat_id, text, author_id, author_name) do
    %{
      "kind" => "youtube#liveChatMessage",
      "id" => id,
      "snippet" => %{
        "type" => "textMessageEvent",
        "liveChatId" => chat_id,
        "authorChannelId" => author_id,
        "publishedAt" => "2026-08-17T23:30:00.000Z",
        "displayMessage" => text,
        "textMessageDetails" => %{"messageText" => text}
      },
      "authorDetails" => %{
        "channelId" => author_id,
        "displayName" => author_name,
        "profileImageUrl" => "https://yt3.ggpht.com/avatar.jpg",
        "isVerified" => false,
        "isChatOwner" => false,
        "isChatSponsor" => false,
        "isChatModerator" => false
      }
    }
  end

  defp make_response(items, next_page_token, polling_interval_ms, offline_at) do
    resp = %{
      "kind" => "youtube#liveChatMessageListResponse",
      "nextPageToken" => next_page_token,
      "pollingIntervalMillis" => polling_interval_ms,
      "pageInfo" => %{
        "totalResults" => length(items),
        "resultsPerPage" => length(items)
      },
      "items" => items
    }

    if offline_at do
      Map.put(resp, "offlineAt", offline_at)
    else
      resp
    end
  end

  defp make_response(items, next_page_token, polling_interval_ms) do
    make_response(items, next_page_token, polling_interval_ms, nil)
  end

  # ============================================================================
  # 1. Alternating Empty and Active Pages Stress Harness
  # ============================================================================
  describe "1. Alternating Empty and Active Pages Stress Harness" do
    test "correctly handles alternating empty pages and bursty message pages across 30 cycles" do
      chat_id = "stress_alt_chat_001"
      test_pid = self()
      _total_cycles = 30
      {:ok, cycle_agent} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(YouTubeClientMock, fn _conn ->
        cycle = Agent.get_and_update(cycle_agent, fn c -> {c, c + 1} end)

        {items, interval} =
          if rem(cycle, 2) == 0 do
            # Active page with 10 messages
            msgs =
              Enum.map(1..10, fn m ->
                make_msg("msg_c#{cycle}_m#{m}", chat_id, "Burst text #{m}", "u_#{m}", "User #{m}")
              end)

            {msgs, 10}
          else
            # Empty page
            {[], 10}
          end

        conn =
          Plug.Test.conn(:get, "/youtube/v3/liveChat/messages")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(make_response(items, "token_cycle_#{cycle + 1}", interval))
          )

        conn
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          default_interval_ms: 10,
          min_interval_ms: 5,
          auto_start: true
        )

      # 15 active cycles * 10 msgs = 150 messages total
      expected_total = 15 * 10
      collected = collect_messages_exact(expected_total, 10_000)

      assert length(collected) == expected_total

      # Verify all 150 unique messages received
      unique_ids = Enum.map(collected, & &1.id) |> Enum.uniq()
      assert length(unique_ids) == expected_total

      Poller.stop(poller)
      Agent.stop(cycle_agent)
    end

    defp collect_messages_exact(target, timeout) do
      start = System.monotonic_time(:millisecond)
      do_collect_exact([], target, start, timeout)
    end

    defp do_collect_exact(acc, target, start, timeout) do
      if length(acc) >= target do
        acc
      else
        remaining = max(timeout - (System.monotonic_time(:millisecond) - start), 0)

        if remaining == 0 do
          acc
        else
          receive do
            {:live_chat_messages, _, batch} ->
              do_collect_exact(acc ++ batch, target, start, timeout)
          after
            remaining ->
              acc
          end
        end
      end
    end
  end

  # ============================================================================
  # 2. Resilient Error Storm & Recovery Simulation
  # ============================================================================
  describe "2. Resilient Error Storm & Recovery Simulation" do
    test "withstands a storm of 10 consecutive 500/429/403 errors and then recovers cleanly without restarting process" do
      chat_id = "stress_error_storm_002"
      test_pid = self()

      {:ok, error_phase_agent} = Agent.start_link(fn -> :error_phase end)

      Req.Test.stub(YouTubeClientMock, fn _conn ->
        phase = Agent.get(error_phase_agent, & &1)

        case phase do
          :error_phase ->
            Plug.Test.conn(:get, "/youtube/v3/liveChat/messages")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              500,
              Jason.encode!(%{"error" => %{"code" => 500, "message" => "Internal Server Error"}})
            )

          :recovered ->
            items = [make_msg("msg_recov_1", chat_id, "Recovered text", "u_rec", "UserRec")]

            Plug.Test.conn(:get, "/youtube/v3/liveChat/messages")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(make_response(items, "tok_recov", 5000)))
        end
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          default_interval_ms: 20,
          backoff_base_ms: 10,
          max_backoff_ms: 50,
          auto_start: false
        )

      assert Process.alive?(poller)

      # Trigger 5 error polls
      for _ <- 1..5 do
        assert {:error, {500, _}} = Poller.poll_once(poller)
      end

      status = Poller.get_status(poller)
      assert status.consecutive_errors == 5
      assert match?({500, _}, status.last_error)

      # Verify error events arrived at subscriber
      assert_receive {:live_chat_error, ^chat_id, {500, _}}, 1000

      # Transition to recovered phase
      Agent.update(error_phase_agent, fn _ -> :recovered end)

      assert {:ok, [msg]} = Poller.poll_once(poller)
      assert msg.id == "msg_recov_1"

      # Verify consecutive errors reset to 0 and last_error reset to nil
      status_after = Poller.get_status(poller)
      assert status_after.consecutive_errors == 0
      assert status_after.last_error == nil
      assert status_after.message_count == 1

      Poller.stop(poller)
      Agent.stop(error_phase_agent)
    end
  end

  # ============================================================================
  # 3. Super Chat, Badges, and Unicode Property Verification
  # ============================================================================
  describe "3. Super Chat, Badges, and Unicode Property Verification" do
    test "accurately parses multi-tier superchats, badges, moderator flags, and UTF-8 payloads" do
      chat_id = "stress_props_003"

      messages_raw = [
        # Owner & Moderator message
        %{
          "kind" => "youtube#liveChatMessage",
          "id" => "msg_owner",
          "snippet" => %{
            "type" => "textMessageEvent",
            "liveChatId" => chat_id,
            "authorChannelId" => "UC_OWNER",
            "publishedAt" => "2026-08-17T23:00:00Z",
            "displayMessage" => "Welcome everyone! 🎉",
            "textMessageDetails" => %{"messageText" => "Welcome everyone! 🎉"}
          },
          "authorDetails" => %{
            "channelId" => "UC_OWNER",
            "displayName" => "StreamOwner",
            "isChatOwner" => true,
            "isChatModerator" => true,
            "isChatSponsor" => true,
            "isVerified" => true
          }
        },
        # Super Chat with €50
        %{
          "kind" => "youtube#liveChatMessage",
          "id" => "msg_sc_50",
          "snippet" => %{
            "type" => "superChatEvent",
            "liveChatId" => chat_id,
            "authorChannelId" => "UC_DONOR",
            "publishedAt" => "2026-08-17T23:01:00Z",
            "displayMessage" => "Amazing stream!",
            "superChatDetails" => %{
              "amountMicros" => 50_000_000,
              "currency" => "EUR",
              "amountDisplayString" => "€50.00",
              "userComment" => "Amazing stream!",
              "tier" => 5
            }
          },
          "authorDetails" => %{
            "channelId" => "UC_DONOR",
            "displayName" => "GenerousFan",
            "isChatOwner" => false,
            "isChatModerator" => false,
            "isChatSponsor" => true,
            "isVerified" => false
          }
        }
      ]

      Req.Test.stub(YouTubeClientMock, fn _conn ->
        Plug.Test.conn(:get, "/youtube/v3/liveChat/messages")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(make_response(messages_raw, "tok_props_done", 5000))
        )
      end)

      {:ok, resp} = LiveChat.list_messages(chat_id, token: "tok")
      assert length(resp.messages) == 2

      [m1, m2] = resp.messages

      # Verify m1 (Owner/Mod)
      assert m1.id == "msg_owner"
      assert m1.is_chat_owner == true
      assert m1.is_chat_moderator == true
      assert m1.is_chat_sponsor == true
      assert m1.is_verified == true
      assert LiveChat.chat_owner?(m1) == true
      assert LiveChat.chat_moderator?(m1) == true
      assert LiveChat.chat_sponsor?(m1) == true
      assert LiveChat.super_chat?(m1) == false
      assert LiveChat.message_text(m1) == "Welcome everyone! 🎉"
      assert LiveChat.author_name(m1) == "StreamOwner"
      assert LiveChat.author_channel_id(m1) == "UC_OWNER"

      # Verify m2 (Super Chat)
      assert m2.id == "msg_sc_50"
      assert m2.is_chat_owner == false
      assert m2.is_chat_sponsor == true
      assert LiveChat.super_chat?(m2) == true
      assert LiveChat.super_chat_amount(m2) == "€50.00"
      assert m2.super_chat_details.amount_micros == 50_000_000
      assert m2.super_chat_details.currency == "EUR"
      assert m2.super_chat_details.amount_display_string == "€50.00"
      assert m2.super_chat_details.user_comment == "Amazing stream!"
      assert LiveChat.message_text(m2) == "Amazing stream!"
    end
  end
end
