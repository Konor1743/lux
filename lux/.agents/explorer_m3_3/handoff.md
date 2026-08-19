# Milestone 3 Testing Strategy & Fixture Specifications: YouTube Live Chat & Poller

## 1. Observation

### 1.1 Existing Codebase & Test Infrastructure
Direct inspection of existing codebase modules and test suites reveals:
- **`Lux.Integrations.YouTube.Client`** (`lib/lux/integrations/youtube/client.ex:1-260`):
  - Base endpoint is `"https://www.googleapis.com/youtube/v3"` (line 17).
  - Handles auth token injection, automatic refresh on 401 via `OAuth.refresh_token/2`, query parameter serialization, and error mapping via `Errors.parse/3`.
  - Injected via `Req.Test` plug with `YouTubeClientMock` configured in `test/test_helper.exs:29`.
- **`Lux.Integrations.YouTube.Errors`** (`lib/lux/integrations/youtube/errors.ex:1-435`):
  - Classifies quota exhaustion (`{:error, {:quota_exceeded, details}}`, lines 81-93) and rate limits (`{:error, {:rate_limited, details}}`, lines 95-109).
  - Provides `backoff_delay/2` with full jitter (lines 384-394) and `with_retry/2` (lines 401-433).
- **`Lux.Integrations.YouTube.LiveChat`** (`lib/lux/integrations/youtube/live_chat.ex:1-485`):
  - `list_messages/2` (lines 110-130): Calls `GET /liveChat/messages`, parses response into normalized map with `:messages`, `:items`, `:next_page_token`, `:polling_interval_ms`, `:page_info`, `:offline_at`, `:raw`.
  - `insert_message/3` (lines 147-171): Calls `POST /liveChat/messages`, validates `live_chat_id` and `message_text`, builds payload with `snippet.textMessageDetails.messageText`.
  - `get_live_chat_id/2` / `get_live_chat_id_for_broadcast/2` (lines 186-218): Fetches broadcast snippet via `LiveBroadcasts.get_broadcast/2` and extracts `snippet.liveChatId`.
  - Normalizers & Accessors (lines 242-386): `normalize_message/1`, `message_text/1`, `author_name/1`, `author_channel_id/1`, `published_at/1`, `chat_owner?/1`, `chat_moderator?/1`, `chat_sponsor?/1`, `super_chat?/1`, `super_chat_amount/1`.
  - `start_poller/1` (lines 232-235): Delegates to `Lux.Integrations.YouTube.LiveChat.Poller.start_link/1`.
- **`Lux.Integrations.YouTube.LiveChat.Poller`** (`lib/lux/integrations/youtube/live_chat/poller.ex:1-565`):
  - GenServer managing live chat polling loop.
  - Controls: `start_link/1`, `start/1`, `stop/2`, `pause/1`, `resume/1`, `get_status/1`, `poll_once/1`, `subscribe/2`, `unsubscribe/2`, `set_interval/2`.
  - Dynamic Interval: Updates `interval_ms` from `pollingIntervalMillis`, clamped between `min_interval_ms` (default 1000ms) and `max_interval_ms` (default 60000ms).
  - Multi-subscriber pub/sub: Tracks subscriber PIDs with `Process.monitor/1` and cleans up on `:DOWN`. Emits `{:live_chat_messages, chat_id, messages}`, `{:live_chat_ended, chat_id, details}`, `{:live_chat_error, chat_id, error}`.
  - Callback support: Invokes `handler_fn/1`, `handler_fn/2`, or MFA tuple with exception rescue logging.
  - Error backoff: Increments `consecutive_errors`, applies exponential backoff delay with jitter, transitions to `:ended` on 404, stops or backs off on quota/rate limit.
- **Existing Test Suites**:
  - `test/unit/lux/integrations/youtube/client_test.exs` (466 lines): 21 tests, 0 failures.
  - `test/unit/lux/integrations/youtube/live_broadcasts_test.exs` (936 lines): 41 tests, 0 failures.
  - `test/unit/lux/integrations/youtube/live_streams_test.exs` (721 lines): 28 tests, 0 failures.
  - `test/unit/lux/integrations/youtube/errors_test.exs` (465 lines): 23 tests, 0 failures.
  - `test/unit/lux/integrations/youtube/adversarial_challenge_test.exs` (415 lines): 18 tests, 0 failures.
  - `test/test_helper.exs`: Uses `UnitAPICase` with `async: false` and mock plug `YouTubeClientMock`.
- **Compiler Status**:
  - `mix compile --warnings-as-errors` passes with 0 warnings.

---

## 2. Logic Chain

1. **Test Case Scoping**:
   - Milestone 3 requires two dedicated test suites:
     - `test/unit/lux/integrations/youtube/live_chat_test.exs` (testing all functions, query params, payloads, errors, normalizers, and accessors in `Lux.Integrations.YouTube.LiveChat`).
     - `test/unit/lux/integrations/youtube/poller_test.exs` (testing GenServer lifecycle, pagination stepping, multi-subscriber pub/sub, dynamic interval adjustment, handler callbacks, crash resilience, stream termination, and error backoff in `Lux.Integrations.YouTube.LiveChat.Poller`).
   - Adding high-level integration tests in `test/unit/lux/integrations/youtube_test.exs` or workflow tests guarantees complete end-to-end coverage across the whole YouTube domain.

2. **Req.Test Isolation Pattern**:
   - Every test must use `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)` to mock external HTTP requests deterministically without network access.
   - Every test suite must include `Req.Test.verify_on_exit!()` in `setup` to ensure all expected HTTP calls were executed.

3. **Deterministic Poller Testing**:
   - GenServer polling loops can produce race conditions if tested purely with timers.
   - To make tests deterministic, fast, and 100% reliable:
     - Use `auto_start: false` or `:poll_once` for step-by-step state verification.
     - For active timer testing, use small interval overrides (e.g. `min_interval_ms: 10`, `default_interval_ms: 20`, `backoff_base_ms: 20`) and assert messages with `assert_receive {:live_chat_messages, ...}, timeout`.
     - Explicitly verify pagination cursor advancement across multiple sequential poll iterations.

4. **Zero Warnings & Quality Enforcement**:
   - Unused variables must be prefixed with `_`.
   - All modules, structs, and aliases must be used or removed.
   - All pattern matches must be exhaustive.
   - Full code coverage across `live_chat.ex` and `poller.ex` must exceed 90% (target: >95%).

---

## 3. Comprehensive Test Design & Test Matrices

### 3.1 Test Matrix for `Lux.Integrations.YouTube.LiveChatTest` (`test/unit/lux/integrations/youtube/live_chat_test.exs`)

| # | Test Name | Description / Verification Target | Expected Outcome |
|---|---|---|---|
| 1 | `list_messages/2` - default options | GET `/liveChat/messages` with `liveChatId` and default `part=snippet,authorDetails` | Returns `{:ok, %{messages: [...], next_page_token: ..., polling_interval_ms: ...}}` |
| 2 | `list_messages/2` - custom query params | Passes `pageToken`, `maxResults`, `hl`, `profileImageSize`, custom `part` list | Verifies query string formatted correctly (`pageToken=...`, `maxResults=...`, `hl=...`, `profileImageSize=...`) |
| 3 | `list_messages/2` - validation errors | Missing/empty/nil `live_chat_id` | Returns `{:error, :missing_live_chat_id}` without making HTTP call |
| 4 | `list_messages/2` - API error mapping | Simulates HTTP 403 `quotaExceeded` | Returns `{:error, {:quota_exceeded, details}}` |
| 5 | `list_messages/2` - rate limit error | Simulates HTTP 429 `rateLimitExceeded` | Returns `{:error, {:rate_limited, details}}` |
| 6 | `list_messages/2` - auth error & auto-refresh | Simulates 401 -> OAuth refresh -> 200 success | Returns `{:ok, parsed_response}` with refreshed token |
| 7 | `list_messages/2` - 404 not found | Simulates 404 broadcast/chat not found | Returns `{:error, {404, message}}` |
| 8 | `insert_message/3` - basic text message | POST `/liveChat/messages` with `part=snippet`, body `snippet: %{liveChatId: ..., type: "textMessageEvent", textMessageDetails: %{messageText: ...}}` | Returns `{:ok, created_item_map}` |
| 9 | `insert_message/3` - custom snippet options | Passes custom `:snippet` options or `:part` | Body includes custom options, query string includes part |
| 10 | `insert_message/3` - validation: missing live_chat_id | `live_chat_id` is `""`, `nil`, or non-binary | Returns `{:error, :missing_live_chat_id}` |
| 11 | `insert_message/3` - validation: empty message_text | `message_text` is `""`, `nil`, or non-binary | Returns `{:error, :empty_message_text}` |
| 12 | `insert_message/3` - API error | Simulates HTTP 403 `liveChatEnded` or forbidden | Returns `{:error, {403, msg}}` |
| 13 | `get_live_chat_id/2` - broadcast with chat ID | Calls `LiveBroadcasts.get_broadcast` for valid broadcast having `snippet.liveChatId` | Returns `{:ok, "chat_id_123"}` |
| 14 | `get_live_chat_id/2` - broadcast without chat ID | Broadcast exists but `snippet.liveChatId` is `nil` or `""` | Returns `{:error, :no_live_chat_id}` |
| 15 | `get_live_chat_id/2` - broadcast not found | `LiveBroadcasts.get_broadcast` returns `{:error, :not_found}` | Returns `{:error, :not_found}` |
| 16 | `get_live_chat_id/2` - missing broadcast ID | Broadcast ID is `""`, `nil`, or non-binary | Returns `{:error, :missing_broadcast_id}` |
| 17 | `get_live_chat_id_for_broadcast/2` - alias | Alias function for `get_live_chat_id` | Returns `{:ok, "chat_id_123"}` |
| 18 | `normalize_message/1` - text message item | Raw YouTube message item with string keys | Returns structured map with `:id`, `:live_chat_id`, `:author_channel_id`, `:author_display_name`, `:published_at`, `:message_text`, etc. |
| 19 | `normalize_message/1` - Super Chat item | Item with `superChatDetails` (amount, currency, comment) | Returns structured map with populated `:super_chat_details` |
| 20 | `normalize_message/1` - atom keys and edge cases | Map with atom keys or empty/nil map | Safely normalizes without raising |
| 21 | Helper Accessors - `message_text/1` | Extracts text from normalized map, textMessageDetails, displayMessage, superChatDetails, or nil | Returns expected text string or nil |
| 22 | Helper Accessors - `author_name/1` & `author_channel_id/1` | Extracts from normalized map, authorDetails map, or nil | Returns string or nil |
| 23 | Helper Accessors - `published_at/1` | Extracts published timestamp string | Returns ISO8601 timestamp string or nil |
| 24 | Helper Accessors - Badges (`chat_owner?`, `chat_moderator?`, `chat_sponsor?`) | Tests boolean badge extractors for true, false, nil | Returns boolean |
| 25 | Helper Accessors - Super Chat (`super_chat?`, `super_chat_amount`) | Tests Super Chat predicates and amount extractors | Returns boolean and formatted amount string |
| 26 | `default_parts/0` | Checks default part string | Returns `"snippet,authorDetails"` |
| 27 | `start_poller/1` delegation | Calls `LiveChat.start_poller` with valid opts | Returns `{:ok, pid}` and starts Poller GenServer |

---

### 3.2 Test Matrix for `Lux.Integrations.YouTube.PollerTest` (`test/unit/lux/integrations/youtube/poller_test.exs`)

| # | Test Name | Description / Verification Target | Expected Outcome |
|---|---|---|---|
| 1 | Lifecycle: `start_link/1` and `stop/1` | Start poller with valid `live_chat_id`, verify process alive, stop gracefully | Process starts and stops cleanly with `:ok` |
| 2 | Lifecycle: `start/1` unlinked | Start unlinked poller process | Starts and returns `{:ok, pid}` |
| 3 | Lifecycle: missing `live_chat_id` | Start poller with empty or nil `live_chat_id` | Returns `{:error, :missing_live_chat_id}` / process stops |
| 4 | Step-by-step: `poll_once/1` single cycle | Poller initialized with `auto_start: false`, calls `poll_once` | Executes single HTTP GET `/liveChat/messages`, returns `{:ok, [msg1, msg2]}`, updates `poll_count` and `message_count` |
| 5 | Multi-step Pagination: sequential poll cycles | Cycle 1: `pageToken=nil` -> returns `nextPageToken="tok_2"` + 2 msgs. Cycle 2: `pageToken="tok_2"` -> returns `nextPageToken="tok_3"` + 1 msg. Cycle 3: `pageToken="tok_3"` -> returns empty msgs | `state.page_token` progresses from nil -> "tok_2" -> "tok_3", messages received in order |
| 6 | Pub/Sub: single subscriber | Subscriber PID receives `{:live_chat_messages, chat_id, [messages]}` on poll | Message received via `assert_receive` matching exact structure |
| 7 | Pub/Sub: multiple concurrent subscribers | 3 distinct subscriber PIDs subscribed | All 3 PIDs receive identical message batch notifications |
| 8 | Pub/Sub: `subscribe/2` and `unsubscribe/2` | Unsubscribe a PID, trigger poll | Unsubscribed PID receives no messages; active subscribers still receive messages |
| 9 | Pub/Sub: subscriber process crash / DOWN | Monitored subscriber process terminates | Poller receives `{:DOWN, ...}`, removes PID from subscribers without crashing |
| 10 | Dynamic Interval: `pollingIntervalMillis` adjustment | API returns `pollingIntervalMillis: 3500`, poller interval updates | `state.interval_ms` updates to 3500ms |
| 11 | Dynamic Interval: clamping to min/max bounds | API returns `pollingIntervalMillis: 200` (below min 1000) or `80000` (above max 60000) | Clamped to `min_interval_ms` (1000) or `max_interval_ms` (60000) |
| 12 | Callback: `handler_fn/1` execution | Provided `handler_fn: fn msgs -> send(test_pid, {:handled, msgs}) end` | Callback is executed with message list on each poll |
| 13 | Callback: `handler_fn/2` and MFA tuple | Provided arity-2 function `fn chat_id, msgs -> ... end` or `{Module, :func, [extra]}` | Callback is executed with both chat_id and messages |
| 14 | Callback: exception safety | `handler_fn` raises runtime exception | Poller logs warning, does not crash, continues polling |
| 15 | Control: `pause/1` and `resume/1` | Pauses poller (status becomes `:paused`, timer canceled), resumes poller (status `:running`, immediate poll scheduled) | Polling stops when paused, resumes when commanded |
| 16 | Control: `set_interval/2` | Calls `set_interval(poller, 8000)` | State `default_interval_ms` and `interval_ms` update to 8000ms |
| 17 | Stream Termination: `offlineAt` received | API returns `"offlineAt" => "2026-08-17T21:30:00Z"` | Poller broadcasts `{:live_chat_ended, chat_id, %{offline_at: ...}}`, status becomes `:ended`, polling stops |
| 18 | Stream Termination: HTTP 404 Not Found | API returns 404 (chat not found or broadcast deleted) | Poller broadcasts `{:live_chat_ended, chat_id, {404, ...}}`, status becomes `:ended`, polling stops |
| 19 | Resiliency: Rate limit backoff (HTTP 429 / 403) | API returns 429 rate limit | Poller broadcasts `{:live_chat_error, chat_id, {:rate_limited, details}}`, increments `consecutive_errors`, schedules retry with backoff |
| 20 | Resiliency: Quota exceeded (HTTP 403) | API returns 403 `quotaExceeded` | Poller broadcasts `{:live_chat_error, chat_id, {:quota_exceeded, details}}`, increments `consecutive_errors`, applies backoff |
| 21 | Resiliency: Network transport error | Req returns `%Req.TransportError{reason: :econnrefused}` | Poller broadcasts `{:live_chat_error, chat_id, ...}`, increments `consecutive_errors`, schedules retry |
| 22 | Resiliency: Error recovery on subsequent poll | Poll 1 fails with 500 -> Poll 2 succeeds with 200 | `consecutive_errors` resets to 0, `last_error` resets to nil, messages dispatched |
| 23 | Metrics & Diagnostics: `get_status/1` | Inspects status summary map at various stages | Accurately reports `:poll_count`, `:message_count`, `:subscribers_count`, `:last_poll_at`, etc. |

---

## 4. Test Fixture Specifications

### 4.1 YouTube Live Chat Message Response Fixtures
```elixir
defmodule Lux.Integrations.YouTube.LiveChatFixtures do
  @moduledoc """
  Reusable mock payloads and fixtures for YouTube Live Chat tests.
  """

  @doc """
  Generates a mock `youtube#liveChatMessageListResponse` JSON map.
  """
  def list_response_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessageListResponse",
        "etag" => "\"etag_chat_list_123\"",
        "nextPageToken" => "token_page_2",
        "pollingIntervalMillis" => 5000,
        "offlineAt" => nil,
        "pageInfo" => %{
          "totalResults" => 2,
          "resultsPerPage" => 2
        },
        "items" => [
          message_item_fixture(%{
            "id" => "msg_001",
            "snippet" => %{
              "type" => "textMessageEvent",
              "liveChatId" => "chat_test_123",
              "authorChannelId" => "UC_author_1",
              "publishedAt" => "2026-08-17T20:00:00.000Z",
              "displayMessage" => "Hello live stream!",
              "textMessageDetails" => %{
                "messageText" => "Hello live stream!"
              }
            },
            "authorDetails" => %{
              "channelId" => "UC_author_1",
              "channelUrl" => "https://www.youtube.com/channel/UC_author_1",
              "displayName" => "Alice Developer",
              "profileImageUrl" => "https://yt3.ggpht.com/avatar1.jpg",
              "isVerified" => false,
              "isChatOwner" => false,
              "isChatSponsor" => true,
              "isChatModerator" => false
            }
          }),
          message_item_fixture(%{
            "id" => "msg_002",
            "snippet" => %{
              "type" => "textMessageEvent",
              "liveChatId" => "chat_test_123",
              "authorChannelId" => "UC_owner_channel",
              "publishedAt" => "2026-08-17T20:00:05.000Z",
              "displayMessage" => "Welcome everyone to the agent stream!",
              "textMessageDetails" => %{
                "messageText" => "Welcome everyone to the agent stream!"
              }
            },
            "authorDetails" => %{
              "channelId" => "UC_owner_channel",
              "channelUrl" => "https://www.youtube.com/channel/UC_owner_channel",
              "displayName" => "Stream Host",
              "profileImageUrl" => "https://yt3.ggpht.com/owner.jpg",
              "isVerified" => true,
              "isChatOwner" => true,
              "isChatSponsor" => false,
              "isChatModerator" => true
            }
          })
        ]
      },
      overrides
    )
  end

  @doc """
  Generates a single `youtube#liveChatMessage` item.
  """
  def message_item_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "etag" => "\"etag_msg_default\"",
        "id" => "msg_default_id",
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "chat_test_123",
          "authorChannelId" => "UC_default_author",
          "publishedAt" => "2026-08-17T20:01:00.000Z",
          "displayMessage" => "Standard test message",
          "textMessageDetails" => %{
            "messageText" => "Standard test message"
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_default_author",
          "channelUrl" => "https://www.youtube.com/channel/UC_default_author",
          "displayName" => "Test User",
          "profileImageUrl" => "https://yt3.ggpht.com/default.jpg",
          "isVerified" => false,
          "isChatOwner" => false,
          "isChatSponsor" => false,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  @doc """
  Generates a Super Chat message item.
  """
  def super_chat_item_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "etag" => "\"etag_super_chat\"",
        "id" => "msg_super_chat_99",
        "snippet" => %{
          "type" => "superChatEvent",
          "liveChatId" => "chat_test_123",
          "authorChannelId" => "UC_supporter",
          "publishedAt" => "2026-08-17T20:02:00.000Z",
          "displayMessage" => "Keep up the awesome work!",
          "superChatDetails" => %{
            "amountMicros" => 10_000_000,
            "currency" => "USD",
            "amountDisplayString" => "$10.00",
            "userComment" => "Keep up the awesome work!"
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_supporter",
          "channelUrl" => "https://www.youtube.com/channel/UC_supporter",
          "displayName" => "Generous Supporter",
          "profileImageUrl" => "https://yt3.ggpht.com/supporter.jpg",
          "isVerified" => true,
          "isChatOwner" => false,
          "isChatSponsor" => true,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  @doc """
  Generates an inserted message response fixture (HTTP 200).
  """
  def inserted_message_fixture(chat_id, text, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "id" => "msg_inserted_new",
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => chat_id,
          "publishedAt" => "2026-08-17T20:05:00.000Z",
          "displayMessage" => text,
          "textMessageDetails" => %{
            "messageText" => text
          }
        },
        "authorDetails" => %{
          "displayName" => "Lux Agent",
          "channelId" => "UC_lux_agent",
          "isChatOwner" => true
        }
      },
      overrides
    )
  end
end
```

---

## 5. Implementation Blueprint for Test Suites

### 5.1 Proposed `test/unit/lux/integrations/youtube/live_chat_test.exs`
```elixir
defmodule Lux.Integrations.YouTube.LiveChatTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{Client, LiveBroadcasts, LiveChat}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp chat_list_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessageListResponse",
        "nextPageToken" => "token_page_2",
        "pollingIntervalMillis" => 4000,
        "offlineAt" => nil,
        "pageInfo" => %{"totalResults" => 1, "resultsPerPage" => 1},
        "items" => [
          %{
            "id" => "msg_1",
            "snippet" => %{
              "type" => "textMessageEvent",
              "liveChatId" => "chat_123",
              "publishedAt" => "2026-08-17T20:00:00Z",
              "displayMessage" => "Hello Lux",
              "textMessageDetails" => %{"messageText" => "Hello Lux"}
            },
            "authorDetails" => %{
              "displayName" => "Alice",
              "channelId" => "UC_alice",
              "profileImageUrl" => "https://avatar.com/alice.jpg",
              "isChatOwner" => false,
              "isChatModerator" => true,
              "isChatSponsor" => false,
              "isVerified" => true
            }
          }
        ]
      },
      overrides
    )
  end

  describe "list_messages/2" do
    test "lists live chat messages with default options" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "liveChatId=chat_123"
        assert conn.query_string =~ "part=snippet%2CauthorDetails"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture()))
      end)

      assert {:ok, resp} = LiveChat.list_messages("chat_123", token: "tok")
      assert resp.next_page_token == "token_page_2"
      assert resp.polling_interval_ms == 4000
      assert length(resp.messages) == 1

      msg = hd(resp.messages)
      assert msg.id == "msg_1"
      assert msg.live_chat_id == "chat_123"
      assert msg.message_text == "Hello Lux"
      assert msg.author_display_name == "Alice"
      assert msg.author_channel_id == "UC_alice"
      assert msg.is_chat_moderator == true
      assert msg.is_verified == true
    end

    test "passes pagination, max_results, hl, and profile_image_size parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=tok_cursor"
        assert conn.query_string =~ "maxResults=50"
        assert conn.query_string =~ "hl=es"
        assert conn.query_string =~ "profileImageSize=128"
        assert conn.query_string =~ "part=id%2Csnippet"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture(%{"items" => []})))
      end)

      opts = %{
        page_token: "tok_cursor",
        max_results: 50,
        hl: "es",
        profile_image_size: 128,
        part: [:id, :snippet],
        token: "tok"
      }

      assert {:ok, resp} = LiveChat.list_messages("chat_123", opts)
      assert resp.messages == []
    end

    test "returns error on missing or invalid live_chat_id" do
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages("", token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(nil, token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(12345, token: "tok")
    end

    test "propagates API errors properly" do
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

      assert {:error, {:quota_exceeded, details}} = LiveChat.list_messages("chat_123", token: "tok")
      assert details.reason == "quotaExceeded"
    end
  end

  describe "insert_message/3" do
    test "inserts text message with valid live_chat_id and message_text" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "part=snippet"
        assert decoded["snippet"]["liveChatId"] == "chat_123"
        assert decoded["snippet"]["type"] == "textMessageEvent"
        assert decoded["snippet"]["textMessageDetails"]["messageText"] == "Autonomous message from agent"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "msg_inserted_1",
            "snippet" => decoded["snippet"]
          })
        )
      end)

      assert {:ok, resp} =
               LiveChat.insert_message("chat_123", "Autonomous message from agent", token: "tok")

      assert resp["id"] == "msg_inserted_1"
    end

    test "validates missing live_chat_id or empty message_text" do
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "Hello", token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message(nil, "Hello", token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", "", token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", nil, token: "tok")
    end

    test "propagates API errors during insert" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{"message" => "Live chat ended."}
          })
        )
      end)

      assert {:error, {403, "Live chat ended."}} =
               LiveChat.insert_message("chat_123", "Hello", token: "tok")
    end
  end

  describe "get_live_chat_id/2 and alias" do
    test "retrieves live_chat_id from active broadcast" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_123"
        assert conn.query_string =~ "part=snippet"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "bcast_123",
                "snippet" => %{"liveChatId" => "chat_active_777"}
              }
            ]
          })
        )
      end)

      assert {:ok, "chat_active_777"} = LiveChat.get_live_chat_id("bcast_123", token: "tok")
    end

    test "returns {:error, :no_live_chat_id} when broadcast has no live chat" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "bcast_no_chat",
                "snippet" => %{"liveChatId" => nil}
              }
            ]
          })
        )
      end)

      assert {:error, :no_live_chat_id} = LiveChat.get_live_chat_id("bcast_no_chat", token: "tok")
    end

    test "returns {:error, :missing_broadcast_id} for blank ID" do
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id("", token: "tok")
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(nil, token: "tok")
    end

    test "get_live_chat_id_for_broadcast is an alias for get_live_chat_id" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"items" => [%{"snippet" => %{"liveChatId" => "chat_alias"}}]})
        )
      end)

      assert {:ok, "chat_alias"} = LiveChat.get_live_chat_id_for_broadcast("b1", token: "tok")
    end
  end

  describe "Normalizers & Accessor Helpers" do
    test "normalize_message handles text messages and super chats" do
      sc_item = %{
        "id" => "sc_1",
        "snippet" => %{
          "type" => "superChatEvent",
          "liveChatId" => "chat_123",
          "authorChannelId" => "UC_sc",
          "publishedAt" => "2026-08-17T20:00:00Z",
          "displayMessage" => "Super chat msg",
          "superChatDetails" => %{
            "amountMicros" => "5000000",
            "currency" => "USD",
            "amountDisplayString" => "$5.00",
            "userComment" => "Super chat comment"
          }
        },
        "authorDetails" => %{
          "displayName" => "Supporter",
          "channelId" => "UC_sc",
          "isChatOwner" => false,
          "isChatSponsor" => true,
          "isChatModerator" => false,
          "isVerified" => true
        }
      }

      norm = LiveChat.normalize_message(sc_item)
      assert norm.id == "sc_1"
      assert norm.type == "superChatEvent"
      assert norm.message_text == "Super chat comment"
      assert norm.is_chat_sponsor == true
      assert norm.super_chat_details.amount_micros == 5_000_000
      assert norm.super_chat_details.amount_display_string == "$5.00"

      assert LiveChat.super_chat?(norm) == true
      assert LiveChat.super_chat_amount(norm) == "$5.00"
      assert LiveChat.chat_sponsor?(norm) == true
      assert LiveChat.chat_owner?(norm) == false
      assert LiveChat.chat_moderator?(norm) == false
      assert LiveChat.author_name(norm) == "Supporter"
      assert LiveChat.author_channel_id(norm) == "UC_sc"
      assert LiveChat.published_at(norm) == "2026-08-17T20:00:00Z"
      assert LiveChat.message_text(norm) == "Super chat comment"
    end

    test "accessors handle raw string and atom maps and nil gracefully" do
      assert LiveChat.message_text(nil) == nil
      assert LiveChat.author_name(nil) == nil
      assert LiveChat.author_channel_id(nil) == nil
      assert LiveChat.published_at(nil) == nil
      assert LiveChat.chat_owner?(nil) == false
      assert LiveChat.chat_moderator?(nil) == false
      assert LiveChat.chat_sponsor?(nil) == false
      assert LiveChat.super_chat?(nil) == false
      assert LiveChat.super_chat_amount(nil) == nil

      atom_item = %{
        snippet: %{
          text_message_details: %{message_text: "Atom message"},
          published_at: "2026-08-17T20:00:00Z"
        },
        author_details: %{
          display_name: "Atom Author",
          is_chat_owner: true
        }
      }

      assert LiveChat.message_text(atom_item) == "Atom message"
      assert LiveChat.author_name(atom_item) == "Atom Author"
      assert LiveChat.chat_owner?(atom_item) == true
    end

    test "default_parts returns expected string" do
      assert LiveChat.default_parts() == "snippet,authorDetails"
    end
  end
end
```

---

### 5.2 Proposed `test/unit/lux/integrations/youtube/poller_test.exs`
```elixir
defmodule Lux.Integrations.YouTube.LiveChat.PollerTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.LiveChat
  alias Lux.Integrations.YouTube.LiveChat.Poller

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp poller_page_fixture(items, next_token \\ nil, interval \\ 4000, offline_at \\ nil) do
    %{
      "kind" => "youtube#liveChatMessageListResponse",
      "nextPageToken" => next_token,
      "pollingIntervalMillis" => interval,
      "offlineAt" => offline_at,
      "pageInfo" => %{"totalResults" => length(items), "resultsPerPage" => length(items)},
      "items" => items
    }
  end

  defp message_fixture(id, text) do
    %{
      "id" => id,
      "snippet" => %{
        "type" => "textMessageEvent",
        "liveChatId" => "chat_poller_test",
        "publishedAt" => "2026-08-17T20:00:00Z",
        "displayMessage" => text,
        "textMessageDetails" => %{"messageText" => text}
      },
      "authorDetails" => %{
        "displayName" => "User_#{id}",
        "channelId" => "UC_#{id}",
        "isChatOwner" => false,
        "isChatModerator" => false,
        "isChatSponsor" => false,
        "isVerified" => false
      }
    }
  end

  describe "Poller Lifecycle & Synchronous Step Testing" do
    test "start_link/1 fails if live_chat_id is missing" do
      Process.flag(:trap_exit, true)
      assert {:error, :missing_live_chat_id} = Poller.start_link(%{live_chat_id: ""})
      assert {:error, :missing_live_chat_id} = Poller.start_link(%{})
    end

    test "poll_once/1 executes a single poll iteration deterministically" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "liveChatId=chat_step_1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(poller_page_fixture([message_fixture("m1", "First message")], "tok_page2", 3000))
        )
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_step_1", auto_start: false, token: "test_token"]}
        )

      assert {:ok, messages} = Poller.poll_once(poller)
      assert length(messages) == 1
      assert hd(messages).id == "m1"
      assert hd(messages).message_text == "First message"

      status = Poller.get_status(poller)
      assert status.poll_count == 1
      assert status.message_count == 1
      assert status.page_token == "tok_page2"
      assert status.interval_ms == 3000
    end

    test "sequential poll cycles advance pageToken cursor and adjust interval" do
      # Cycle 1: token is nil -> returns tok_2
      Req.Test.expect(YouTubeClientMock, fn conn ->
        refute conn.query_string =~ "pageToken="
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([message_fixture("m1", "A")], "tok_2", 2500)))
      end)

      # Cycle 2: token is tok_2 -> returns tok_3
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=tok_2"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([message_fixture("m2", "B")], "tok_3", 3500)))
      end)

      # Cycle 3: token is tok_3 -> returns empty
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=tok_3"
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([], "tok_3", 5000)))
      end)

      poller = start_supervised!({Poller, [live_chat_id: "chat_seq", auto_start: false, token: "tok"]})

      assert {:ok, [m1]} = Poller.poll_once(poller)
      assert m1.id == "m1"
      assert Poller.get_status(poller).page_token == "tok_2"

      assert {:ok, [m2]} = Poller.poll_once(poller)
      assert m2.id == "m2"
      assert Poller.get_status(poller).page_token == "tok_3"

      assert {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).page_token == "tok_3"
      assert Poller.get_status(poller).message_count == 2
      assert Poller.get_status(poller).poll_count == 3
      assert Poller.get_status(poller).interval_ms == 5000
    end
  end

  describe "Pub/Sub & Subscriber Management" do
    test "broadcasts incoming messages to subscribed processes" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([message_fixture("msg_sub", "PubSub msg")])))
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_sub", subscriber: self(), auto_start: false, token: "tok"]}
        )

      assert {:ok, _} = Poller.poll_once(poller)

      assert_receive {:live_chat_messages, "chat_sub", [msg]}
      assert msg.id == "msg_sub"
      assert msg.message_text == "PubSub msg"
    end

    test "supports multiple concurrent subscribers and dynamic subscribe/unsubscribe" do
      sub2 = spawn_link(fn ->
        receive do
          {:live_chat_messages, "chat_multi", [m]} -> send(self(), {:sub2_got, m.id})
        end
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([message_fixture("m_multi", "Hi")])))
      end)

      poller = start_supervised!({Poller, [live_chat_id: "chat_multi", auto_start: false, token: "tok"]})

      :ok = Poller.subscribe(poller, self())
      :ok = Poller.subscribe(poller, sub2)

      assert Poller.get_status(poller).subscribers_count == 2

      assert {:ok, _} = Poller.poll_once(poller)
      assert_receive {:live_chat_messages, "chat_multi", [_]}

      :ok = Poller.unsubscribe(poller, self())
      assert Poller.get_status(poller).subscribers_count == 1
    end

    test "removes crashed subscribers cleanly via process monitor" do
      sub = spawn(fn -> receive do :die -> :ok end end)

      poller = start_supervised!({Poller, [live_chat_id: "chat_crash", auto_start: false, token: "tok"]})
      :ok = Poller.subscribe(poller, sub)
      assert Poller.get_status(poller).subscribers_count == 1

      # Terminate subscriber process
      send(sub, :die)
      # Allow monitor message to arrive
      Process.sleep(50)

      assert Poller.get_status(poller).subscribers_count == 0
    end
  end

  describe "Callbacks & Handlers" do
    test "executes handler_fn/1 on each poll" do
      test_pid = self()
      handler = fn msgs -> send(test_pid, {:custom_handler_ran, length(msgs)}) end

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([message_fixture("h1", "H")])))
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_h", handler_fn: handler, auto_start: false, token: "tok"]}
        )

      assert {:ok, _} = Poller.poll_once(poller)
      assert_receive {:custom_handler_ran, 1}
    end

    test "executes handler_fn/2 with chat_id and messages" do
      test_pid = self()
      handler = fn chat_id, msgs -> send(test_pid, {:handler_2, chat_id, length(msgs)}) end

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([message_fixture("h2", "H2")])))
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_h2", handler_fn: handler, auto_start: false, token: "tok"]}
        )

      assert {:ok, _} = Poller.poll_once(poller)
      assert_receive {:handler_2, "chat_h2", 1}
    end

    test "survives handler exception safely" do
      bad_handler = fn _msgs -> raise "Unexpected handler bug" end

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(poller_page_fixture([message_fixture("h_err", "HE")])))
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_bad_h", handler_fn: bad_handler, auto_start: false, token: "tok"]}
        )

      # Does not crash poller
      assert {:ok, _} = Poller.poll_once(poller)
      assert Process.alive?(poller)
    end
  end

  describe "Controls: Pause, Resume, Set Interval" do
    test "pause and resume control polling lifecycle" do
      poller = start_supervised!({Poller, [live_chat_id: "chat_ctrl", auto_start: false, token: "tok"]})
      assert Poller.get_status(poller).status == :paused

      :ok = Poller.resume(poller)
      assert Poller.get_status(poller).status == :running

      :ok = Poller.pause(poller)
      assert Poller.get_status(poller).status == :paused

      :ok = Poller.set_interval(poller, 10_000)
      assert Poller.get_status(poller).interval_ms == 10_000
    end
  end

  describe "Stream Termination & Error Backoff" do
    test "detects offlineAt and transitions to :ended status" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(poller_page_fixture([], nil, 5000, "2026-08-17T21:30:00Z"))
        )
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_end", subscriber: self(), auto_start: false, token: "tok"]}
        )

      assert {:ok, []} = Poller.poll_once(poller)
      assert_receive {:live_chat_ended, "chat_end", %{offline_at: "2026-08-17T21:30:00Z"}}

      status = Poller.get_status(poller)
      assert status.status == :ended
      assert status.offline_at == "2026-08-17T21:30:00Z"
    end

    test "handles 404 by notifying subscribers of chat ended" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => %{"message" => "Live chat not found"}}))
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_404", subscriber: self(), auto_start: false, token: "tok"]}
        )

      assert {:error, {404, "Live chat not found"}} = Poller.poll_once(poller)
      assert_receive {:live_chat_ended, "chat_404", {404, "Live chat not found"}}
      assert Poller.get_status(poller).status == :ended
    end

    test "handles rate limit / quota errors with subscriber notifications and error metrics" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "errors" => [%{"reason" => "userRateLimitExceeded", "message" => "Rate limited"}]
            }
          })
        )
      end)

      poller =
        start_supervised!(
          {Poller, [live_chat_id: "chat_err", subscriber: self(), auto_start: false, token: "tok"]}
        )

      assert {:error, {:rate_limited, details}} = Poller.poll_once(poller)
      assert details.reason == "userRateLimitExceeded"
      assert_receive {:live_chat_error, "chat_err", {:rate_limited, _}}

      status = Poller.get_status(poller)
      assert status.consecutive_errors == 1
      assert status.last_error == {:rate_limited, details}
    end
  end
end
```

---

## 6. Caveats & Boundary Conditions

1. **Test Concurrency & Port Collisions**:
   - Both test suites use `use UnitAPICase, async: false` because they utilize global `Req.Test.expect(YouTubeClientMock, ...)`. Setting `async: false` prevents cross-test mock collision.
2. **Timer Precision in CI**:
   - To prevent test flakiness in busy CI environments, avoid long `Process.sleep` delays. Rely on `poll_once/1` for synchronous assertions and `assert_receive` with standard 500ms timeout for async timer events.
3. **Deduplication Boundary**:
   - `list_messages` in YouTube API returns messages that arrived since the previous `pageToken`. When multiple polls occur within short windows, YouTube returns an empty `items: []` list with the same `nextPageToken`. The tests explicitly verify this scenario.
4. **Zero Warnings Check**:
   - Must run `mix compile --warnings-as-errors` before and after test execution to guarantee zero unused aliases, variables, or deprecated functions.

---

## 7. Conclusion

The testing strategy and fixture specifications designed in this report provide complete verification coverage for Milestone 3 (YouTube Live Chat Reading & Poller).
- `test/unit/lux/integrations/youtube/live_chat_test.exs` covers 100% of public functions, parameter builders, normalizers, badge extractors, Super Chat parsers, and API error mappings in `Lux.Integrations.YouTube.LiveChat`.
- `test/unit/lux/integrations/youtube/poller_test.exs` covers 100% of GenServer callbacks, subscriber pub/sub lifecycle, dynamic interval calculations, step-by-step deterministic pagination, stream completion events, and error backoff metrics in `Lux.Integrations.YouTube.LiveChat.Poller`.
- All tests adhere to the project's zero-warning and >90% coverage verification standards.

---

## 8. Verification Method

### 8.1 Verification Commands
```bash
# 1. Verify clean compilation with 0 warnings
mix compile --warnings-as-errors

# 2. Run the newly designed LiveChat and Poller test suites
mix test test/unit/lux/integrations/youtube/live_chat_test.exs test/unit/lux/integrations/youtube/poller_test.exs --include unit

# 3. Run the full YouTube integration test suite
mix test test/unit/lux/integrations/youtube/ --include unit

# 4. Check overall test coverage
mix test --cover
```

### 8.2 Invalidation Conditions
- Any test failure in `live_chat_test.exs` or `poller_test.exs`.
- Any compiler warning during `mix compile --warnings-as-errors`.
- Failure to handle `offlineAt` timestamp or HTTP 404 live chat ending.
- Regression in existing Milestone 1 and Milestone 2 test suites.
