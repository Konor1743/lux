# Milestone 3 Investigation & Design Report: YouTube Live Chat Reading & Poller

## 1. Observation

### 1.1 Existing Codebase Infrastructure
Direct observations from existing YouTube integration modules:
- **`Lux.Integrations.YouTube.Client`** (`lib/lux/integrations/youtube/client.ex:1-260`):
  - Base endpoint is `https://www.googleapis.com/youtube/v3` (line 17).
  - Handles authentication (`Authorization: Bearer <token>` or `key=<api_key>`).
  - Supports automatic token refresh on HTTP 401 via `attempt_token_refresh/1` and retry (lines 93-110).
  - Integrates with `Req.Test` via `:plug` option and Application env (lines 86-87).
  - Passes error responses through `Lux.Integrations.YouTube.Errors.parse/3` (lines 105-115).
- **`Lux.Integrations.YouTube.Errors`** (`lib/lux/integrations/youtube/errors.ex:1-435`):
  - Classifies quota errors: `{:error, {:quota_exceeded, %{reason: reason, message: msg, status: status, details: details}}}` (lines 81-93).
  - Classifies rate limits: `{:error, {:rate_limited, %{reason: reason, retry_after: retry_after, ...}}}` (lines 95-109).
  - Provides `retryable?/1`, `backoff_delay/2` with full jitter, and `with_retry/2` (lines 370-434).
- **`Lux.Integrations.YouTube.LiveBroadcasts`** (`lib/lux/integrations/youtube/live_broadcasts.ex:1-957`):
  - Provides `live_chat_id(broadcast)` helper (lines 479-487) extracting `snippet.liveChatId` from broadcast maps.
  - Exposes `get_broadcast(id, opts)` (lines 237-279) returning broadcast maps containing `liveChatId`.
- **`Lux.Integrations.YouTube`** (`lib/lux/integrations/youtube.ex:1-100`):
  - Top-level integration hub holding default headers, base URL, and auth injector `add_auth_header/1`.
- **Test Infrastructure (`UnitAPICase`)** (`test/test_helper.exs:1-47`):
  - Configures `Req.Test` mock plug for `Lux.Integrations.YouTube.Client` using `YouTubeClientMock`.
  - Supports `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)` and verification via `Req.Test.verify_on_exit!()`.

---

### 1.2 YouTube Data API v3 Live Chat Specifications

#### A. `liveChatMessages.list` (`GET /liveChat/messages`)
- **Endpoint**: `GET https://www.googleapis.com/youtube/v3/liveChat/messages`
- **Request Parameters**:
  - `liveChatId` (string, required): The ID of the live chat.
  - `part` (string, required): Properties to return (`id`, `snippet`, `authorDetails`). Default: `"id,snippet,authorDetails"`.
  - `hl` (string, optional): Language code for text localization.
  - `maxResults` (integer, optional): Maximum items to return (`1..2000`, API default 500).
  - `pageToken` (string, optional): Pagination cursor from previous `nextPageToken`.
  - `profileImageSize` (integer, optional): Profile avatar size in px (`16..720`, default 88).
- **Response Structure**:
  ```json
  {
    "kind": "youtube#liveChatMessageListResponse",
    "etag": "\"etag_string\"",
    "nextPageToken": "CAUQAA",
    "pollingIntervalMillis": 4500,
    "offlineAt": "2026-08-17T21:30:00.000Z",
    "pageInfo": {
      "totalResults": 15,
      "resultsPerPage": 15
    },
    "items": [
      {
        "kind": "youtube#liveChatMessage",
        "etag": "\"item_etag\"",
        "id": "LCC.message_id_12345",
        "snippet": {
          "type": "textMessageEvent",
          "liveChatId": "chat_id_abc123",
          "authorChannelId": "UC_author_channel_id",
          "publishedAt": "2026-08-17T20:15:30.123Z",
          "hasDisplayContent": true,
          "displayMessage": "Hello stream and agents!",
          "textMessageDetails": {
            "messageText": "Hello stream and agents!"
          }
        },
        "authorDetails": {
          "channelId": "UC_author_channel_id",
          "channelUrl": "https://www.youtube.com/channel/UC_author_channel_id",
          "displayName": "Alice Developer",
          "profileImageUrl": "https://yt3.ggpht.com/avatar.jpg",
          "isVerified": false,
          "isChatOwner": false,
          "isChatSponsor": true,
          "isChatModerator": false
        }
      }
    ]
  }
  ```
- **Key Polling Semantics**:
  - `pollingIntervalMillis`: Mandatory minimum delay (in ms) before the client makes the next `list` call. Quota penalty or throttling occurs if called faster.
  - `offlineAt`: Timestamp indicating the stream/chat has ended. If present, polling should terminate.
  - `nextPageToken`: Cursor passed to subsequent requests to retrieve new incoming messages.

#### B. `liveChatMessages.insert` (`POST /liveChat/messages`)
- **Endpoint**: `POST https://www.googleapis.com/youtube/v3/liveChat/messages`
- **Query Parameter**: `part=snippet` (or `part=id,snippet,authorDetails`)
- **Request Body**:
  ```json
  {
    "snippet": {
      "liveChatId": "chat_id_abc123",
      "type": "textMessageEvent",
      "textMessageDetails": {
        "messageText": "Hello from autonomous Lux agent!"
      }
    }
  }
  ```
- **Response**: HTTP 200 with the created `liveChatMessage` resource.
- **Quota Cost**: 50 quota units per insertion (compared to 1 unit per list).

#### C. `liveChatMessages.delete` (`DELETE /liveChat/messages`)
- **Endpoint**: `DELETE https://www.googleapis.com/youtube/v3/liveChat/messages`
- **Query Parameter**: `id=<messageId>`
- **Response**: HTTP 204 No Content.

#### D. Event Types Supported in YouTube Live Chat:
- `"textMessageEvent"`: Standard user message.
- `"superChatEvent"`: Super Chat with `superChatDetails` (`amountMicros`, `currency`, `amountDisplayString`, `userComment`, `tier`).
- `"superStickerEvent"`: Super Sticker with `superStickerDetails`.
- `"memberMilestoneChatEvent"`: Milestone chat with `memberMilestoneChatDetails` (`memberMonth`, `memberLevelName`, `userComment`).
- `"newSponsorEvent"`: Sponsor joined with `newSponsorDetails` (`memberLevelName`, `isUpgrade`).
- `"fanFundingEvent"`: Tip/fan funding.
- `"messageDeletedEvent"`: Moderation event (`deletedMessageId`).
- `"userBannedEvent"`: Moderation event with `userBannedDetails`.
- `"chatEndedEvent"`: Chat ended event.

---

## 2. Logic Chain

1. **Client Delegation**:
   - `Lux.Integrations.YouTube.LiveChat` should delegate HTTP operations to `Lux.Integrations.YouTube.Client` (`Client.get`, `Client.post`, `Client.delete`).
   - This reuses existing OAuth token management, automatic refresh on 401, error parsing, and Req.Test plug injection.

2. **Interface Parity & Ergonomics**:
   - Per `PROJECT.md:56-60`, `Lux.Integrations.YouTube.LiveChat` must implement:
     - `list_messages(live_chat_id, opts \\ %{})`: Fetches messages and returns `{:ok, %{messages: [...], next_page_token: ..., polling_interval_ms: ..., offline_at: ..., raw: ...}} | {:error, term()}`.
     - `insert_message(live_chat_id, message_text, opts \\ %{})`: Posts a message and returns `{:ok, message_map} | {:error, term()}`.
     - `get_live_chat_id(broadcast_id_or_map, opts \\ %{})`: Helper extracting `liveChatId` directly or fetching the broadcast via `LiveBroadcasts.get_broadcast/2`.
     - `delete_message(message_id, opts \\ %{})`: Deletes a chat message (HTTP 204).
     - `start_poller(opts)`: Spawns a supervised or standalone `Poller` GenServer.

3. **Message Normalization & Parsing Helpers**:
   - Consumers (agents, lenses, LiveViews) require both raw API responses and clean, idiomatic Elixir maps.
   - `LiveChat` should provide:
     - `parse_message/1`: Converts a raw JSON item into a structured `%Lux.Integrations.YouTube.LiveChat.Message{}` or normalized map containing:
       - `:id`, `:type`, `:published_at`, `:display_message`, `:message_text`, `:author`, `:live_chat_id`, `:super_chat`, `:raw`.
     - `parse_response/1`: Transforms the raw API response into `%{messages: list(), next_page_token: binary(), polling_interval_ms: integer(), offline_at: binary() | nil, page_info: map(), raw: map()}`.
     - Accessors: `author_name/1`, `author_channel_id/1`, `owner?/1`, `moderator?/1`, `sponsor?/1`, `verified?/1`, `super_chat?/1`, `super_chat_details/1`.

4. **GenServer Poller (`Lux.Integrations.YouTube.LiveChat.Poller`) Architecture**:
   - **Continuous Polling Loop**:
     - GenServer initializes with either `live_chat_id` or `broadcast_id`.
     - Maintains internal state: `live_chat_id`, `page_token`, `polling_interval_ms`, `seen_message_ids` (bounded deduplication set), `status` (`:running`, `:paused`, `:ended`, `:error`), `subscribers` (PIDs), `handlers` (callbacks), `consecutive_errors`.
     - When `:poll_tick` arrives:
       1. Calls `LiveChat.list_messages(state.live_chat_id, client_opts_with_page_token)`.
       2. On `{:ok, response}`:
          - Extracts `items`, `next_page_token`, `polling_interval_ms`, `offline_at`.
          - Filters out previously seen message IDs using `seen_message_ids`.
          - Dispatches new messages to all subscribers (`{:youtube_live_chat, messages}` or `{:youtube_live_chat_message, msg}`) and executes callback handlers.
          - Updates `seen_message_ids` (maintaining a bounded size, e.g. last 2,000 IDs to avoid memory leaks during multi-hour livestreams).
          - Sets `page_token = next_page_token`.
          - Updates `polling_interval_ms = clamp(polling_interval_millis, min_interval, max_interval)`.
          - If `offline_at` is set, notifies subscribers (`{:youtube_live_chat_ended, %{offline_at: ...}}`) and stops or transitions to `:ended`.
          - Else, schedules next `:poll_tick` after `polling_interval_ms`.
       3. On Quota Exceeded `{:error, {:quota_exceeded, details}}`:
          - Notifies subscribers (`{:youtube_live_chat_error, {:quota_exceeded, details}}`) and halts polling (`status: :error`).
       4. On Rate Limit / Network Errors:
          - Increments `consecutive_errors`.
          - Applies backoff delay via `Errors.backoff_delay(consecutive_errors)` or `retry_after`.
          - Schedules next `:poll_tick` after backoff.
   - **Poller Controls**:
     - `start_link(opts)`
     - `subscribe(poller, pid \\ self())` / `unsubscribe(poller, pid \\ self())`
     - `pause(poller)` / `resume(poller)`
     - `poll_now(poller)` (immediate trigger)
     - `insert_message(poller, text, opts \\ %{})` (convenience proxy)
     - `get_state(poller)` (diagnostics / testing inspection)
     - `stop(poller)`

---

## 3. Recommended Module Designs & Specifications

### 3.1 `Lux.Integrations.YouTube.LiveChat` Interface Spec

```elixir
defmodule Lux.Integrations.YouTube.LiveChat do
  @moduledoc """
  YouTube Live Chat integration module for reading, posting, deleting,
  and polling live chat messages (`liveChatMessages` resource).
  """

  alias Lux.Integrations.YouTube.Client
  alias Lux.Integrations.YouTube.LiveBroadcasts
  alias Lux.Integrations.YouTube.LiveChat.Poller

  @default_parts "id,snippet,authorDetails"
  @default_insert_parts "snippet"

  @type live_chat_id :: String.t()
  @type message_id :: String.t()
  @type broadcast_id :: String.t()

  @type message :: %{
          id: String.t(),
          type: String.t() | atom(),
          live_chat_id: String.t(),
          published_at: String.t() | DateTime.t(),
          display_message: String.t(),
          message_text: String.t(),
          author: %{
            channel_id: String.t(),
            channel_url: String.t(),
            display_name: String.t(),
            profile_image_url: String.t(),
            is_owner: boolean(),
            is_moderator: boolean(),
            is_sponsor: boolean(),
            is_verified: boolean()
          },
          super_chat: map() | nil,
          super_sticker: map() | nil,
          member_milestone: map() | nil,
          new_sponsor: map() | nil,
          deleted_message_id: String.t() | nil,
          user_banned: map() | nil,
          raw: map()
        }

  @type list_response :: %{
          messages: [message()],
          next_page_token: String.t() | nil,
          polling_interval_ms: non_neg_integer(),
          offline_at: String.t() | nil,
          page_info: %{total_results: integer(), results_per_page: integer()} | nil,
          raw: map()
        }

  # --- Core API ---

  @doc """
  Lists live chat messages for a given `liveChatId`.
  Supports options: `:part`, `:page_token`, `:max_results`, `:hl`, `:profile_image_size`, `:token`, `:plug`, `:raw_response`.
  """
  @spec list_messages(live_chat_id(), map() | keyword()) ::
          {:ok, list_response()} | {:ok, map()} | {:error, term()}
  def list_messages(live_chat_id, opts \\ %{})

  @doc """
  Inserts/posts a new text message to the live chat.
  Supports options: `:part`, `:token`, `:plug`.
  """
  @spec insert_message(live_chat_id(), String.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def insert_message(live_chat_id, message_text, opts \\ %{})

  @doc """
  Deletes a live chat message by message ID.
  """
  @spec delete_message(message_id(), map() | keyword()) ::
          {:ok, %{id: message_id(), deleted: true}} | {:error, term()}
  def delete_message(message_id, opts \\ %{})

  @doc """
  Retrieves the `liveChatId` from a broadcast struct, broadcast map, or by broadcast ID.
  """
  @spec get_live_chat_id(broadcast_id() | map(), map() | keyword()) ::
          {:ok, live_chat_id()} | {:error, term()}
  def get_live_chat_id(broadcast_or_id, opts \\ %{})

  @doc """
  Starts a live chat poller process.
  """
  @spec start_poller(map() | keyword()) :: {:ok, pid()} | {:error, term()}
  def start_poller(opts)

  # --- Parsers and Accessors ---

  @spec parse_response(map()) :: list_response()
  def parse_response(response_map)

  @spec parse_message(map()) :: message()
  def parse_message(item_map)

  @spec author_name(message() | map()) :: String.t() | nil
  def author_name(message_or_item)

  @spec author_channel_id(message() | map()) :: String.t() | nil
  def author_channel_id(message_or_item)

  @spec message_text(message() | map()) :: String.t() | nil
  def message_text(message_or_item)

  @spec owner?(message() | map()) :: boolean()
  def owner?(message_or_item)

  @spec moderator?(message() | map()) :: boolean()
  def moderator?(message_or_item)

  @spec sponsor?(message() | map()) :: boolean()
  def sponsor?(message_or_item)

  @spec super_chat?(message() | map()) :: boolean()
  def super_chat?(message_or_item)

  @spec super_chat_details(message() | map()) :: map() | nil
  def super_chat_details(message_or_item)
end
```

---

### 3.2 `Lux.Integrations.YouTube.LiveChat.Poller` GenServer Spec

```elixir
defmodule Lux.Integrations.YouTube.LiveChat.Poller do
  @moduledoc """
  GenServer poller for continuous, rate-limit-aware live chat streaming.
  """
  use GenServer

  alias Lux.Integrations.YouTube.Errors
  alias Lux.Integrations.YouTube.LiveChat

  defstruct [
    :live_chat_id,
    :broadcast_id,
    :page_token,
    :timer_ref,
    client_opts: %{},
    polling_interval_ms: 5000,
    min_polling_interval_ms: 1000,
    max_polling_interval_ms: 30000,
    backoff_on_error_ms: 5000,
    consecutive_errors: 0,
    subscribers: MapSet.new(),
    handlers: [],
    seen_message_ids: MapSet.new(),
    max_history_size: 2000,
    emit_format: :parsed,
    first_poll_done: false,
    include_initial_messages: true,
    status: :running
  ]

  # --- Client API ---
  def start_link(opts)
  def subscribe(poller, pid \\ self())
  def unsubscribe(poller, pid \\ self())
  def pause(poller)
  def resume(poller)
  def poll_now(poller)
  def insert_message(poller, text, opts \\ %{})
  def get_state(poller)
  def stop(poller)

  # --- Server Callbacks ---
  # init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2
end
```

---

## 4. Caveats & Edge Cases

1. **Strict `pollingIntervalMillis` Enforcement**:
   - YouTube throttles and penalizes clients that poll faster than `pollingIntervalMillis`.
   - The Poller must dynamically update its poll interval from every API response, clamping between `min_polling_interval_ms` (e.g. 1000ms) and `max_polling_interval_ms` (e.g. 30000ms).

2. **Deduplication & PageToken Boundaries**:
   - During live chat polling, repeated calls with `pageToken` may include previously returned messages (or empty lists).
   - The Poller must track seen message IDs using a bounded `MapSet` / ring buffer to avoid duplicate deliveries while preventing memory exhaustion on 10+ hour livestreams.

3. **Stream Completion / `offlineAt`**:
   - When a broadcast ends, YouTube sets `"offlineAt"` in the list response.
   - The Poller should emit a terminal event `{:youtube_live_chat_ended, %{offline_at: timestamp, live_chat_id: id}}` and transition `status` to `:ended`.

4. **Quota Costs**:
   - `list_messages` = 1 quota unit.
   - `insert_message` = 50 quota units.
   - If quota is exceeded (HTTP 403 `quotaExceeded`), the Poller must halt polling and emit `{:youtube_live_chat_error, {:quota_exceeded, details}}` rather than spamming the API.

5. **Token Expiration During Long Streams**:
   - Livestreams often exceed 1 hour (the lifetime of Google OAuth access tokens).
   - Because `LiveChat` calls `Client.request/3`, expired tokens will be refreshed automatically via `Client`'s auto-refresh mechanism without breaking the poller.

---

## 5. Conclusion & Implementation Plan

### Implementation Deliverables:
1. **`lib/lux/integrations/youtube/live_chat.ex`**:
   - `list_messages/2`, `insert_message/3`, `delete_message/2`, `get_live_chat_id/2`, `start_poller/1`.
   - Normalizers: `parse_response/1`, `parse_message/1`.
   - Accessors: `author_name/1`, `author_channel_id/1`, `message_text/1`, `owner?/1`, `moderator?/1`, `sponsor?/1`, `super_chat?/1`, `super_chat_details/1`.
2. **`lib/lux/integrations/youtube/live_chat/poller.ex`**:
   - GenServer implementing dynamic polling, deduplication, subscriber distribution, backoff, and lifecycle controls.
3. **`lib/lux/integrations/youtube.ex`**:
   - Add delegation/helper functions for `list_chat_messages/2`, `insert_chat_message/3`, `get_live_chat_id/2`, `start_chat_poller/1`.
4. **Unit & Integration Tests**:
   - `test/unit/lux/integrations/youtube/live_chat_test.exs`: Comprehensive tests for `list_messages`, `insert_message`, `delete_message`, `get_live_chat_id`, parsing, error handling.
   - `test/unit/lux/integrations/youtube/poller_test.exs`: GenServer lifecycle, subscriber notification, dynamic polling interval, deduplication, pause/resume, quota error handling, stream ending.

---

## 6. Verification Method

### 6.1 Test Execution Commands
```bash
# Run unit tests for LiveChat and Poller
mix test test/unit/lux/integrations/youtube/live_chat_test.exs test/unit/lux/integrations/youtube/poller_test.exs

# Run full YouTube test suite
mix test test/unit/lux/integrations/youtube/

# Check compiler warnings
mix compile --warnings-as-errors
```

### 6.2 Example Test Fixture with `Req.Test`
```elixir
Req.Test.expect(YouTubeClientMock, fn conn ->
  assert conn.method == "GET"
  assert conn.request_path == "/youtube/v3/liveChat/messages"
  assert conn.query_string =~ "liveChatId=chat_123"
  assert conn.query_string =~ "part=id%2Csnippet%2CauthorDetails"

  resp_body = %{
    "kind" => "youtube#liveChatMessageListResponse",
    "nextPageToken" => "token_next_123",
    "pollingIntervalMillis" => 4000,
    "items" => [
      %{
        "id" => "msg_1",
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "chat_123",
          "publishedAt" => "2026-08-17T20:00:00Z",
          "displayMessage" => "Hello world",
          "textMessageDetails" => %{"messageText" => "Hello world"}
        },
        "authorDetails" => %{
          "displayName" => "Tester",
          "channelId" => "UC_123",
          "isChatOwner" => true,
          "isChatModerator" => false,
          "isChatSponsor" => false
        }
      }
    ]
  }

  conn
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(200, Jason.encode!(resp_body))
end)
```
