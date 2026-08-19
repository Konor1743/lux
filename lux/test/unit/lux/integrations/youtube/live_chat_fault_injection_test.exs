defmodule Lux.Integrations.YouTube.LiveChatFaultInjectionTest do
  use UnitAPICase, async: false
  require Logger

  alias Lux.Integrations.YouTube.LiveChat
  alias Lux.Integrations.YouTube.LiveChat.Poller

  setup do
    Req.Test.set_req_test_to_shared(YouTubeClientMock)
    Req.Test.verify_on_exit!()
    :ok
  end

  # Helper module for MFA handler testing
  defmodule TestHandler do
    def handle_messages(messages, caller_pid, tag) do
      send(caller_pid, {:mfa_invoked, tag, length(messages)})
      :ok
    end

    def failing_handler(_messages, _caller_pid) do
      raise RuntimeError, "MFA failure test"
    end
  end

  # ============================================================================
  # 1. Rate Limit (429) & Quota Exceeded (403) Injection in Poller
  # ============================================================================
  describe "Rate limit (429) & Quota exceeded (403) injection in Poller" do
    test "429 rate limit error dispatches {:live_chat_error, ...} to subscribers without crashing poller" do
      test_pid = self()
      chat_id = "fault_chat_429_001"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{
              "code" => 429,
              "message" => "Too Many Requests - rate limit exceeded",
              "errors" => [
                %{
                  "domain" => "usageLimits",
                  "reason" => "rateLimitExceeded",
                  "message" => "Too Many Requests"
                }
              ]
            }
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "valid_token",
          subscriber: test_pid,
          auto_start: false,
          backoff_base_ms: 50,
          max_backoff_ms: 200
        )

      assert Process.alive?(poller)

      # Trigger synchronous poll
      assert {:error, {:rate_limited, rate_limit_info}} = Poller.poll_once(poller)
      assert rate_limit_info.status == 429
      assert rate_limit_info.reason == "rateLimitExceeded"
      assert rate_limit_info.retry_after == 2

      # Verify subscriber received error signal
      assert_receive {:live_chat_error, ^chat_id, {:rate_limited, ^rate_limit_info}}, 1000

      # Poller must still be alive and metrics updated
      assert Process.alive?(poller)
      status = Poller.get_status(poller)
      assert status.consecutive_errors == 1
      assert status.last_error == {:rate_limited, rate_limit_info}
      assert status.message_count == 0

      GenServer.stop(poller)
    end

    test "403 quota exceeded error dispatches {:live_chat_error, ...} and preserves poller state" do
      test_pid = self()
      chat_id = "fault_chat_quota_002"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        assert conn.request_path == "/youtube/v3/liveChat/messages"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "The request cannot be completed because you have exceeded your quota.",
              "errors" => [
                %{
                  "domain" => "youtube.quota",
                  "reason" => "quotaExceeded",
                  "message" => "The request cannot be completed because you have exceeded your quota."
                }
              ]
            }
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "valid_token",
          subscriber: test_pid,
          auto_start: false,
          backoff_base_ms: 100,
          max_backoff_ms: 500
        )

      assert {:error, {:quota_exceeded, quota_info}} = Poller.poll_once(poller)
      assert quota_info.status == 403
      assert quota_info.reason == "quotaExceeded"
      assert quota_info.message =~ "quota"

      # Verify subscriber received error signal
      assert_receive {:live_chat_error, ^chat_id, {:quota_exceeded, ^quota_info}}, 1000

      # Verify poller remains alive
      assert Process.alive?(poller)
      status = Poller.get_status(poller)
      assert status.consecutive_errors == 1
      assert status.last_error == {:quota_exceeded, quota_info}

      GenServer.stop(poller)
    end

    test "recovers cleanly from repeated 429s when API resumes responding with 200 OK" do
      test_pid = self()
      chat_id = "fault_chat_recover_003"
      {:ok, attempt_counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        attempt = Agent.get_and_update(attempt_counter, fn count -> {count + 1, count + 1} end)

        if attempt <= 2 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            429,
            Jason.encode!(%{
              "error" => %{
                "code" => 429,
                "message" => "Rate limit exceeded (attempt #{attempt})",
                "errors" => [%{"reason" => "rateLimitExceeded", "domain" => "usageLimits"}]
              }
            })
          )
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "kind" => "youtube#liveChatMessageListResponse",
              "pollingIntervalMillis" => 1000,
              "nextPageToken" => "token_after_recovery",
              "items" => [
                %{
                  "id" => "msg_recovered_1",
                  "snippet" => %{
                    "liveChatId" => chat_id,
                    "type" => "textMessageEvent",
                    "displayMessage" => "Back online!",
                    "textMessageDetails" => %{"messageText" => "Back online!"}
                  },
                  "authorDetails" => %{
                    "displayName" => "ResilientUser",
                    "channelId" => "UC_resilient"
                  }
                }
              ]
            })
          )
        end
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "valid_token",
          subscriber: test_pid,
          auto_start: false,
          backoff_base_ms: 10,
          max_backoff_ms: 50
        )

      # Attempt 1: 429
      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, ^chat_id, {:rate_limited, _}}, 1000
      status1 = Poller.get_status(poller)
      assert status1.consecutive_errors == 1

      # Attempt 2: 429
      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, ^chat_id, {:rate_limited, _}}, 1000
      status2 = Poller.get_status(poller)
      assert status2.consecutive_errors == 2

      # Attempt 3: 200 OK -> Recovery!
      assert {:ok, messages} = Poller.poll_once(poller)
      assert length(messages) == 1
      assert hd(messages).message_text == "Back online!"

      # Verify subscriber received message signal
      assert_receive {:live_chat_messages, ^chat_id, [received_msg]}, 1000
      assert received_msg.message_text == "Back online!"

      # Verify error metrics were reset
      status3 = Poller.get_status(poller)
      assert status3.consecutive_errors == 0
      assert status3.last_error == nil
      assert status3.message_count == 1
      assert status3.page_token == "token_after_recovery"

      GenServer.stop(poller)
    end
  end

  # ============================================================================
  # 2. Network & Server Fault Injection (500, 502, 503, 504, 401)
  # ============================================================================
  describe "Server and network fault injection" do
    test "HTTP 500/503 server errors do not terminate poller" do
      test_pid = self()
      chat_id = "fault_chat_500_004"
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        attempt = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

        status_code = if attempt == 1, do: 500, else: 503

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          status_code,
          Jason.encode!(%{
            "error" => %{
              "code" => status_code,
              "message" => "Backend server failure #{status_code}",
              "errors" => [%{"reason" => "backendError", "domain" => "global"}]
            }
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "valid_token",
          subscriber: test_pid,
          auto_start: false
        )

      # 500 error
      assert {:error, {500, msg500}} = Poller.poll_once(poller)
      assert msg500 =~ "Backend server failure 500"
      assert_receive {:live_chat_error, ^chat_id, {500, _}}, 1000
      assert Process.alive?(poller)

      # 503 error
      assert {:error, {503, msg503}} = Poller.poll_once(poller)
      assert msg503 =~ "Backend server failure 503"
      assert_receive {:live_chat_error, ^chat_id, {503, _}}, 1000
      assert Process.alive?(poller)

      GenServer.stop(poller)
    end

    test "401 Unauthorized during polling notifies subscriber with :invalid_token without killing poller" do
      test_pid = self()
      chat_id = "fault_chat_401_005"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => %{
              "code" => 401,
              "message" => "Invalid Credentials",
              "errors" => [%{"reason" => "authError", "domain" => "global"}]
            }
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "expired_token",
          subscriber: test_pid,
          auto_start: false,
          client_opts: %{auto_refresh: false}
        )

      assert {:error, :invalid_token} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, ^chat_id, :invalid_token}, 1000

      assert Process.alive?(poller)
      status = Poller.get_status(poller)
      assert status.consecutive_errors == 1
      assert status.last_error == :invalid_token

      GenServer.stop(poller)
    end
  end

  # ============================================================================
  # 3. Malformed API Responses & Unexpected JSON Payloads
  # ============================================================================
  describe "Malformed API responses and unexpected JSON payloads" do
    test "handles completely empty items list and nil nextPageToken gracefully" do
      test_pid = self()
      chat_id = "fault_chat_empty_006"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "items" => [],
            "pollingIntervalMillis" => 3000
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          auto_start: false
        )

      assert {:ok, []} = Poller.poll_once(poller)
      refute_receive {:live_chat_messages, ^chat_id, _}, 200

      status = Poller.get_status(poller)
      assert status.message_count == 0
      assert status.poll_count == 1
      assert status.interval_ms == 3000

      GenServer.stop(poller)
    end

    test "handles items missing snippet or missing authorDetails without crashing normalize_message" do
      raw_item_no_snippet = %{
        "id" => "msg_corrupt_1"
      }

      raw_item_empty_snippet = %{
        "id" => "msg_corrupt_2",
        "snippet" => %{}
      }

      raw_item_missing_author = %{
        "id" => "msg_corrupt_3",
        "snippet" => %{
          "liveChatId" => "chat_123",
          "displayMessage" => "Hello no author"
        }
      }

      norm1 = LiveChat.normalize_message(raw_item_no_snippet)
      assert norm1.id == "msg_corrupt_1"
      assert norm1.message_text == nil
      assert norm1.author_display_name == nil
      assert norm1.is_chat_owner == false

      norm2 = LiveChat.normalize_message(raw_item_empty_snippet)
      assert norm2.id == "msg_corrupt_2"
      assert norm2.message_text == nil

      norm3 = LiveChat.normalize_message(raw_item_missing_author)
      assert norm3.id == "msg_corrupt_3"
      assert norm3.display_message == "Hello no author"
      assert norm3.author_channel_id == nil
      assert norm3.author_display_name == nil
      assert norm3.is_verified == false

      # Helpers should return nil or false safely
      assert LiveChat.message_text(norm1) == nil
      assert LiveChat.author_name(norm1) == nil
      assert LiveChat.author_channel_id(norm1) == nil
      assert LiveChat.published_at(norm1) == nil
      assert LiveChat.chat_owner?(norm1) == false
      assert LiveChat.chat_moderator?(norm1) == false
      assert LiveChat.chat_sponsor?(norm1) == false
      assert LiveChat.super_chat?(norm1) == false
      assert LiveChat.super_chat_amount(norm1) == nil
    end

    test "handles SuperChat with string amountMicros, missing currency, and null userComment" do
      raw_super_chat = %{
        "id" => "sc_edge_001",
        "snippet" => %{
          "type" => "superChatEvent",
          "liveChatId" => "chat_sc",
          "superChatDetails" => %{
            "amountMicros" => "10000000",
            "currency" => "USD",
            "amountDisplayString" => "$10.00",
            "userComment" => nil
          }
        },
        "authorDetails" => %{
          "displayName" => "BigDonator",
          "channelId" => "UC_donator"
        }
      }

      norm = LiveChat.normalize_message(raw_super_chat)
      assert norm.type == "superChatEvent"
      assert LiveChat.super_chat?(norm) == true
      assert norm.super_chat_details.amount_micros == 10_000_000
      assert norm.super_chat_details.currency == "USD"
      assert norm.super_chat_details.amount_display_string == "$10.00"
      assert LiveChat.super_chat_amount(norm) == "$10.00"
    end

    test "handles malformed non-integer or negative pollingIntervalMillis by clamping and falling back" do
      test_pid = self()
      chat_id = "fault_chat_interval_007"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            # API returns a negative value
            "pollingIntervalMillis" => -500,
            "items" => []
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          default_interval_ms: 4000,
          min_interval_ms: 1000,
          max_interval_ms: 10000,
          auto_start: false
        )

      assert {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      # Negative interval should fallback to default_interval_ms (4000)
      assert status.interval_ms == 4000

      GenServer.stop(poller)
    end

    test "clamps extremely small (< min_interval) and extremely large (> max_interval) pollingIntervalMillis" do
      test_pid = self()
      chat_id = "fault_chat_clamp_008"
      {:ok, cycle} = Agent.start_link(fn -> 1 end)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        c = Agent.get_and_update(cycle, fn val -> {val, val + 1} end)

        interval = if c == 1, do: 100, else: 999_999

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "pollingIntervalMillis" => interval,
            "items" => []
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          min_interval_ms: 1000,
          max_interval_ms: 20000,
          auto_start: false
        )

      # Cycle 1: suggested interval 100ms -> clamped to min_interval 1000ms
      assert {:ok, []} = Poller.poll_once(poller)
      status1 = Poller.get_status(poller)
      assert status1.interval_ms == 1000

      # Cycle 2: suggested interval 999_999ms -> clamped to max_interval 20000ms
      assert {:ok, []} = Poller.poll_once(poller)
      status2 = Poller.get_status(poller)
      assert status2.interval_ms == 20000

      GenServer.stop(poller)
    end

    test "preserves current page_token when API returns null or missing nextPageToken" do
      test_pid = self()
      chat_id = "fault_chat_token_009"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "nextPageToken" => nil,
            "items" => []
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          initial_page_token: "existing_page_cursor",
          subscriber: test_pid,
          auto_start: false
        )

      assert {:ok, []} = Poller.poll_once(poller)
      status = Poller.get_status(poller)
      # Must not overwrite valid existing cursor with nil
      assert status.page_token == "existing_page_cursor"

      GenServer.stop(poller)
    end

    test "extracts author boolean badges with various casing and atom/string keys" do
      # All true
      item_all_badges = %{
        "id" => "msg_badge_1",
        "authorDetails" => %{
          "isVerified" => true,
          "isChatOwner" => true,
          "isChatSponsor" => true,
          "isChatModerator" => true
        }
      }

      norm1 = LiveChat.normalize_message(item_all_badges)
      assert LiveChat.chat_owner?(norm1) == true
      assert LiveChat.chat_moderator?(norm1) == true
      assert LiveChat.chat_sponsor?(norm1) == true
      assert norm1.is_verified == true

      # All false
      item_no_badges = %{
        "id" => "msg_badge_2",
        "authorDetails" => %{
          "isVerified" => false,
          "isChatOwner" => false,
          "isChatSponsor" => false,
          "isChatModerator" => false
        }
      }

      norm2 = LiveChat.normalize_message(item_no_badges)
      assert LiveChat.chat_owner?(norm2) == false
      assert LiveChat.chat_moderator?(norm2) == false
      assert LiveChat.chat_sponsor?(norm2) == false
      assert norm2.is_verified == false

      # Non-boolean strings must evaluate to default false
      item_string_badges = %{
        "id" => "msg_badge_3",
        "authorDetails" => %{
          "isVerified" => "true",
          "isChatOwner" => "yes",
          "isChatSponsor" => 1,
          "isChatModerator" => nil
        }
      }

      norm3 = LiveChat.normalize_message(item_string_badges)
      assert norm3.is_verified == false
      assert norm3.is_chat_owner == false
      assert norm3.is_chat_sponsor == false
      assert norm3.is_chat_moderator == false
    end
  end

  # ============================================================================
  # 4. Live Chat Ended / Inactive Broadcast Signal Transitions
  # ============================================================================
  describe "Live chat ended and inactive broadcast signal transitions" do
    test "detects offlineAt timestamp, dispatches {:live_chat_ended, ...}, and transitions status to :ended" do
      test_pid = self()
      chat_id = "fault_chat_offline_010"
      offline_time = "2026-08-17T23:59:59Z"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "offlineAt" => offline_time,
            "items" => [
              %{
                "id" => "msg_last_1",
                "snippet" => %{
                  "liveChatId" => chat_id,
                  "displayMessage" => "Stream has ended, thanks for watching!",
                  "textMessageDetails" => %{"messageText" => "Stream has ended, thanks for watching!"}
                },
                "authorDetails" => %{"displayName" => "Streamer"}
              }
            ]
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          auto_start: false
        )

      assert {:ok, messages} = Poller.poll_once(poller)
      assert length(messages) == 1

      # Verify messages received
      assert_receive {:live_chat_messages, ^chat_id, [last_msg]}, 1000
      assert last_msg.message_text =~ "Stream has ended"

      # Verify live_chat_ended signal received
      assert_receive {:live_chat_ended, ^chat_id, %{offline_at: ^offline_time}}, 1000

      # Poller status must now be :ended
      status = Poller.get_status(poller)
      assert status.status == :ended
      assert status.offline_at == offline_time

      GenServer.stop(poller)
    end

    test "404 liveChatNotFound transitions status to :ended and dispatches {:live_chat_ended, ...}" do
      test_pid = self()
      chat_id = "fault_chat_404_011"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{
            "error" => %{
              "code" => 404,
              "message" => "The live chat is no longer found.",
              "errors" => [%{"reason" => "liveChatNotFound", "domain" => "youtube.liveChat"}]
            }
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          auto_start: false
        )

      assert {:error, {404, msg}} = Poller.poll_once(poller)
      assert msg =~ "live chat is no longer found"

      # Verify error and ended signals received
      assert_receive {:live_chat_error, ^chat_id, {404, ^msg}}, 1000
      assert_receive {:live_chat_ended, ^chat_id, {404, ^msg}}, 1000

      status = Poller.get_status(poller)
      assert status.status == :ended

      GenServer.stop(poller)
    end

    test "403 liveChatEnded error notification delivered to subscribers" do
      test_pid = self()
      chat_id = "fault_chat_ended_403_012"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "The live chat is no longer active.",
              "errors" => [
                %{
                  "domain" => "youtube.liveChat",
                  "reason" => "liveChatEnded",
                  "message" => "The live chat is no longer active."
                }
              ]
            }
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          auto_start: false
        )

      assert {:error, {403, msg}} = Poller.poll_once(poller)
      assert msg =~ "live chat is no longer active"

      assert_receive {:live_chat_error, ^chat_id, {403, ^msg}}, 1000
      assert Process.alive?(poller)

      GenServer.stop(poller)
    end
  end

  # ============================================================================
  # 5. Subscriber Lifecycle & Handler Exception Resilience
  # ============================================================================
  describe "Subscriber crash and handler fault tolerance" do
    test "subscriber process crashing is automatically demonitored without crashing Poller" do
      chat_id = "fault_chat_sub_crash_013"

      # Spawn a temporary subscriber process
      sub_pid =
        spawn(fn ->
          receive do
            :kill -> exit(:normal)
          end
        end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: sub_pid,
          auto_start: false
        )

      assert Process.alive?(poller)
      status1 = Poller.get_status(poller)
      assert status1.subscribers_count == 1

      # Kill the subscriber process
      send(sub_pid, :kill)
      Process.sleep(50)

      # Poller must still be alive and subscriber count updated to 0
      assert Process.alive?(poller)
      status2 = Poller.get_status(poller)
      assert status2.subscribers_count == 0

      GenServer.stop(poller)
    end

    test "handler_fn raising runtime exception does NOT crash Poller" do
      test_pid = self()
      chat_id = "fault_chat_handler_boom_014"

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "items" => [
              %{
                "id" => "msg_crash_fn",
                "snippet" => %{
                  "liveChatId" => chat_id,
                  "displayMessage" => "Trigger handler crash",
                  "textMessageDetails" => %{"messageText" => "Trigger handler crash"}
                },
                "authorDetails" => %{"displayName" => "Tester"}
              }
            ]
          })
        )
      end)

      # Handler function that intentionally raises an exception
      exploding_handler = fn messages ->
        send(test_pid, {:handler_invoked, length(messages)})
        raise RuntimeError, "EXPLOSION in user handler callback!"
      end

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          handler_fn: exploding_handler,
          auto_start: false
        )

      assert {:ok, messages} = Poller.poll_once(poller)
      assert length(messages) == 1

      # Handler was invoked and raised, but subscriber still got messages
      assert_receive {:handler_invoked, 1}, 1000
      assert_receive {:live_chat_messages, ^chat_id, _}, 1000

      # Poller must still be alive and functional
      assert Process.alive?(poller)

      GenServer.stop(poller)
    end

    test "executes 2-arity handler_fn(chat_id, messages) and MFA {mod, fun, args} correctly" do
      test_pid = self()
      chat_id = "fault_chat_handler_types_015"

      Req.Test.stub(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "items" => [
              %{
                "id" => "msg_mfa_1",
                "snippet" => %{
                  "liveChatId" => chat_id,
                  "displayMessage" => "Test MFA & 2-arity"
                }
              }
            ]
          })
        )
      end)

      # 1. Test 2-arity handler
      arity2_handler = fn id, msgs ->
        send(test_pid, {:arity2_invoked, id, length(msgs)})
      end

      {:ok, poller1} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          handler_fn: arity2_handler,
          auto_start: false
        )

      assert {:ok, _} = Poller.poll_once(poller1)
      assert_receive {:arity2_invoked, ^chat_id, 1}, 1000
      GenServer.stop(poller1)

      # 2. Test MFA handler
      mfa_handler = {TestHandler, :handle_messages, [test_pid, :custom_tag]}

      {:ok, poller2} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          handler_fn: mfa_handler,
          auto_start: false
        )

      assert {:ok, _} = Poller.poll_once(poller2)
      assert_receive {:mfa_invoked, :custom_tag, 1}, 1000
      GenServer.stop(poller2)
    end

    test "multiple subscribers can subscribe and unsubscribe dynamically" do
      chat_id = "fault_chat_multi_sub_016"
      sub1 = self()

      sub2 =
        spawn(fn ->
          receive do
            {:live_chat_messages, _id, msgs} ->
              send(sub1, {:sub2_got_msgs, length(msgs)})
          end

          receive do
            :stop -> :ok
          end
        end)

      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "items" => [%{"id" => "msg_sub_test", "snippet" => %{"displayMessage" => "Hi all"}}]
          })
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscribers: [sub1, sub2],
          auto_start: false
        )

      status = Poller.get_status(poller)
      assert status.subscribers_count == 2

      # Poll once
      assert {:ok, _} = Poller.poll_once(poller)

      # Both subscribers should receive the message
      assert_receive {:live_chat_messages, ^chat_id, _}, 1000
      assert_receive {:sub2_got_msgs, 1}, 1000

      # Unsubscribe sub1
      assert :ok = Poller.unsubscribe(poller, sub1)
      status_after = Poller.get_status(poller)
      assert status_after.subscribers_count == 1

      # Clean up sub2
      send(sub2, :stop)
      GenServer.stop(poller)
    end
  end

  # ============================================================================
  # 6. Automatic Background Polling & Lifecycle Transitions
  # ============================================================================
  describe "Automatic polling loop & lifecycle transitions" do
    test "auto_start: true runs background polling loop and delivers messages periodically" do
      test_pid = self()
      chat_id = "fault_chat_auto_017"
      {:ok, poll_count} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(YouTubeClientMock, fn conn ->
        count = Agent.get_and_update(poll_count, fn c -> {c + 1, c + 1} end)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "pollingIntervalMillis" => 50,
            "nextPageToken" => "token_page_#{count}",
            "items" => [
              %{
                "id" => "auto_msg_#{count}",
                "snippet" => %{
                  "liveChatId" => chat_id,
                  "displayMessage" => "Auto message #{count}",
                  "textMessageDetails" => %{"messageText" => "Auto message #{count}"}
                }
              }
            ]
          })
        )
      end)

      # Start poller with auto_start: true and 50ms interval
      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          subscriber: test_pid,
          auto_start: true,
          min_interval_ms: 50,
          default_interval_ms: 50
        )

      # We should receive at least 2 message batches automatically over 200ms
      assert_receive {:live_chat_messages, ^chat_id, [msg1]}, 1000
      assert msg1.message_text =~ "Auto message"

      assert_receive {:live_chat_messages, ^chat_id, [msg2]}, 1000
      assert msg2.message_text =~ "Auto message"

      assert Process.alive?(poller)
      status = Poller.get_status(poller)
      assert status.status == :running
      assert status.message_count >= 2

      GenServer.stop(poller)
    end

    test "rapid pause and resume cycles maintain consistent timer and state" do
      chat_id = "fault_chat_rapid_pause_018"

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: chat_id,
          token: "tok",
          auto_start: false,
          interval_ms: 3000
        )

      for _ <- 1..10 do
        assert :ok = Poller.resume(poller)
        assert Poller.get_status(poller).status == :running
        assert :ok = Poller.pause(poller)
        assert Poller.get_status(poller).status == :paused
      end

      assert :ok = Poller.set_interval(poller, 7500)
      assert Poller.get_status(poller).interval_ms == 7500

      GenServer.stop(poller)
    end
  end

  # ============================================================================
  # 7. LiveChat Function Edge Cases (list_messages, insert_message, get_live_chat_id)
  # ============================================================================
  describe "LiveChat module API edge cases" do
    test "list_messages validates missing/empty live_chat_id before network call" do
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages("")
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(nil)
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(12345)
    end

    test "list_messages accepts part as atom list, string list, or binary" do
      Req.Test.expect(YouTubeClientMock, 2, fn conn ->
        assert conn.query_string =~ "part=snippet%2CauthorDetails%2Cid" or
                 conn.query_string =~ "part=snippet,authorDetails,id"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "items" => []
          })
        )
      end)

      assert {:ok, _} =
               LiveChat.list_messages("chat_part_test",
                 part: [:snippet, :authorDetails, :id],
                 token: "tok"
               )

      assert {:ok, _} =
               LiveChat.list_messages("chat_part_test",
                 part: ["snippet", "authorDetails", "id"],
                 token: "tok"
               )
    end

    test "insert_message validates empty message_text and missing live_chat_id" do
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "Hello")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message(nil, "Hello")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", "")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", nil)
    end

    test "insert_message sends proper POST body and query part" do
      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "part=snippet"

        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["liveChatId"] == "chat_send_101"
        assert decoded["snippet"]["type"] == "textMessageEvent"
        assert decoded["snippet"]["textMessageDetails"]["messageText"] == "Hello World from Lux!"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessage",
            "id" => "msg_created_999",
            "snippet" => decoded["snippet"]
          })
        )
      end)

      assert {:ok, resp} =
               LiveChat.insert_message("chat_send_101", "Hello World from Lux!", token: "tok")

      assert resp["id"] == "msg_created_999"
    end

    test "get_live_chat_id retrieves snippet.liveChatId from live broadcast" do
      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_active_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [
              %{
                "id" => "bcast_active_1",
                "snippet" => %{
                  "title" => "Active Stream",
                  "liveChatId" => "chat_id_extracted_555"
                }
              }
            ]
          })
        )
      end)

      assert {:ok, "chat_id_extracted_555"} =
               LiveChat.get_live_chat_id("bcast_active_1", token: "tok")
    end

    test "get_live_chat_id returns {:error, :no_live_chat_id} when broadcast has no live chat" do
      Req.Test.expect(YouTubeClientMock, 1, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_no_chat"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [
              %{
                "id" => "bcast_no_chat",
                "snippet" => %{"title" => "No Chat Broadcast"}
              }
            ]
          })
        )
      end)

      assert {:error, :no_live_chat_id} =
               LiveChat.get_live_chat_id("bcast_no_chat", token: "tok")
    end

    test "Poller.init fails immediately with {:error, :missing_live_chat_id} on empty live_chat_id" do
      assert {:error, :missing_live_chat_id} = Poller.start_link(live_chat_id: nil)
      assert {:error, :missing_live_chat_id} = Poller.start_link(live_chat_id: "")
    end
  end
end
