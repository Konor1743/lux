# Milestone 4 Handoff Report: Resiliency, Quota/Rate Limits & High-Level Lenses/Prisms

## 1. Observation

### 1.1 Existing Resiliency and Error Architecture in `lib/lux/integrations/youtube/errors.ex`
- **Error Classification & Parsing**:
  - `Lux.Integrations.YouTube.Errors.parse/3` (lines 58–129) accurately extracts and normalizes Google Data API v3 and OAuth error structures.
  - Quota errors (`quotaExceeded`, `dailyLimitExceeded`, `QUOTA_EXCEEDED`, `RESOURCE_EXHAUSTED_QUOTA`, `RESOURCE_EXHAUSTED`) on HTTP 403/429 map to `{:error, {:quota_exceeded, %{reason: ..., message: ..., status: ..., domain: ..., details: ...}}}` (lines 81–93).
  - Rate limit errors (`rateLimitExceeded`, `userRateLimitExceeded`, `concurrentLimitExceeded`, `servingLimitExceeded`) or general HTTP 429 map to `{:error, {:rate_limited, %{reason: ..., message: ..., status: ..., domain: ..., retry_after: ..., details: ...}}}` (lines 95–109).
  - HTTP 401 maps to `{:error, :invalid_token}` (lines 77–79).
  - Other non-2xx responses map to `{:error, {status, message}}` (lines 111–128).
- **Header Parsing**:
  - `extract_retry_after/1` (lines 298–331) parses `Retry-After` headers in seconds from keyword lists or maps.
- **Predicates**:
  - `quota_exceeded?/1` (lines 354–358), `rate_limited?/1` (lines 362–367), and `retryable?/1` (lines 372–377). Note: Quota errors (`{:quota_exceeded, _}`) and 400/401/404 are strictly non-retryable; rate limits, 429, and 5xx (500, 502, 503, 504) are retryable.
- **Exponential Backoff Engine**:
  - `backoff_delay(attempt, opts)` (lines 384–394) implements full-jitter exponential backoff: `delay = max(min_delay, trunc(:rand.uniform() * min(max_backoff, base_backoff * 2^(attempt - 1))))`.
  - `with_retry(fun, opts)` (lines 401–433) retries 0-arity closures upon receiving `{:rate_limited, %{retry_after: s}}` or retryable errors up to `max_retries` (default 3), sleeping via customizable `:sleep_fun`.

### 1.2 Existing Client Resiliency in `lib/lux/integrations/youtube/client.ex`
- **Request Engine**: `Lux.Integrations.YouTube.Client.request/3` (lines 64–120) runs HTTP requests via `Req.new/1`.
- **Auto-Refresh on 401**:
  - Catches HTTP 401; if `auto_refresh: true` and `retry_count < 1`, invokes `OAuth.refresh_token/2` and transparently retries with the refreshed token (lines 93–109).
- **Plug Injection for Testing**:
  - Supports `:plug` passed in options or via `Application.get_env(:lux, Lux.Integrations.YouTube.Client, [])` for mock interception using `Req.Test` (lines 86–87).

### 1.3 Lens and Prism Architecture in Lux
- **`Lux.Lens` (`lib/lux/lens.ex`)**:
  - Lenses are data-fetching macros defining `view/0`, `focus/2`, `before_focus/1`, and `after_focus/1`.
  - Execution path: `focus(input, opts)` -> merges input -> calls `authenticate/1` -> calls `before_focus/1` -> executes `Req.request` with `[url: url, headers: headers, max_retries: 2]` -> on 200 calls `after_focus.(body)`, on non-200 returns `{:error, response.body}`.
  - Test harness: `UnitAPICase` configures `Application.put_env(:lux, :req_options, plug: {Req.Test, Lux.Lens})`. Tests use `Req.Test.expect(Lux.Lens, fn conn -> ... end)`.
- **`Lux.Prism` (`lib/lux/prism.ex`)**:
  - Prisms are actionable agent building blocks defining `name`, `description`, `input_schema`, `output_schema`, and `handler(input, context)`.
  - Prisms call domain integration modules (`LiveBroadcasts`, `LiveStreams`, `LiveChat`, `Client`).
  - Test harness: Prisms execute domain functions using `YouTubeClientMock`. Tests use `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)`.

---

## 2. Logic Chain

### 2.1 Resiliency Needs for High-Level Lenses and Prisms
1. **Lens Parameter Translation & Schema Cleanliness**:
   - Agent workflows use idiomatic Elixir snake_case keys (e.g. `:broadcast_status`, `:max_results`, `:live_chat_id`), whereas the YouTube API expects camelCase query params (`broadcastStatus`, `maxResults`, `liveChatId`).
   - Lenses must transform snake_case inputs into Google API query params in `before_focus/1`, and transform raw Google JSON items into normalized, typed Elixir maps in `after_focus/1`.
2. **Lens Error Transparency**:
   - If a Lens request fails (e.g. 403 `quotaExceeded` or 429 `rateLimitExceeded`), `Lux.Lens.focus/2` returns `{:error, body}`.
   - `after_focus/1` and error handlers should handle `%{"error" => error_map}` structures gracefully, converting them into structured error tuples via `Errors.parse/1`.
3. **Prism Auto-Retry & Resiliency Execution**:
   - Prisms perform stateful actions (creating broadcasts, streams, binding, and sending live chat messages).
   - In autonomous agent environments, transient rate limits (`429` / `403 rateLimitExceeded`) or temporary network hiccups shouldn't immediately crash an agent task.
   - Prisms must wrap their API invocations in `Errors.with_retry/2`, supporting configurable `:max_retries`, `:sleep_fun` (for deterministic zero-wait test execution), and fail-fast termination on non-retryable errors (`{:quota_exceeded, _}`, `400`, `401`).
4. **Agent Actionable Quota Feedback**:
   - Agents need clear distinction between rate-limits (which can be waited out) and daily quota depletion (which halts YouTube actions until midnight PT). An agent-facing error formatting utility `Errors.format_error_for_agent/1` provides clean explanations for LLM context injection.

---

## 3. Detailed Component Designs

### 3.1 YouTube Lenses (`lib/lux/lenses/youtube/`)

#### A. `Lux.Lenses.YouTube.ListBroadcasts` (`lib/lux/lenses/youtube/list_broadcasts.ex`)
- **Purpose**: Lens for listing YouTube Live Broadcasts with status filtering and pagination.
- **Contract**:
  - URL: `"https://www.googleapis.com/youtube/v3/liveBroadcasts"`
  - Method: `:get`
  - Headers: `Lux.Integrations.YouTube.headers()`
  - Auth: `Lux.Integrations.YouTube.auth()`
  - Schema:
    - `:broadcast_status` (`string`, enum: `["all", "active", "completed", "upcoming"]`, default: `"all"`)
    - `:broadcast_type` (`string`, enum: `["all", "event", "persistent"]`, default: `"event"`)
    - `:id` (`string`, optional broadcast ID filter)
    - `:mine` (`boolean`, default: `true` if `:id` is absent)
    - `:max_results` (`integer`, 1..50, default: 25)
    - `:page_token` (`string`, optional)
    - `:part` (`string`, default: `"snippet,status,contentDetails"`)
  - `before_focus/1`: Converts snake_case keys to camelCase query params (`broadcastStatus`, `broadcastType`, `maxResults`, `pageToken`), ensures `mine: true` when `:id` is omitted.
  - `after_focus/1`:
    - Normalizes list items into list of `%Broadcast{id, title, description, published_at, scheduled_start_time, scheduled_end_time, status, privacy_status, live_chat_id, bound_stream_id, watch_url}`.
    - Preserves `next_page_token`, `prev_page_token`, `total_results`.

#### B. `Lux.Lenses.YouTube.GetChatMessages` (`lib/lux/lenses/youtube/get_chat_messages.ex`)
- **Purpose**: Lens for fetching messages from a YouTube Live Chat room (`liveChatId`).
- **Contract**:
  - URL: `"https://www.googleapis.com/youtube/v3/liveChat/messages"`
  - Method: `:get`
  - Headers: `Lux.Integrations.YouTube.headers()`
  - Auth: `Lux.Integrations.YouTube.auth()`
  - Schema:
    - `:live_chat_id` (`string`, required)
    - `:page_token` (`string`, optional)
    - `:max_results` (`integer`, 1..2000, default: 200)
    - `:part` (`string`, default: `"snippet,authorDetails"`)
  - `before_focus/1`: Maps `live_chat_id` -> `liveChatId`, `page_token` -> `pageToken`, `max_results` -> `maxResults`.
  - `after_focus/1`:
    - Normalizes messages into list of maps with `:id`, `:live_chat_id`, `:author_display_name`, `:author_channel_id`, `:author_profile_image_url`, `:is_owner`, `:is_moderator`, `:is_sponsor`, `:is_verified`, `:published_at`, `:message_text`, `:type`, `:super_chat`.
    - Returns `%{messages: [...], next_page_token: string | nil, polling_interval_ms: integer}`.

#### C. `Lux.Lenses.YouTube.GetStream` (`lib/lux/lenses/youtube/get_stream.ex`)
- **Purpose**: Lens for fetching live stream ingestion parameters (RTMP stream key, endpoint URL, health status) by stream ID.
- **Contract**:
  - URL: `"https://www.googleapis.com/youtube/v3/liveStreams"`
  - Method: `:get`
  - Headers: `Lux.Integrations.YouTube.headers()`
  - Auth: `Lux.Integrations.YouTube.auth()`
  - Schema:
    - `:id` (`string`, required)
    - `:part` (`string`, default: `"snippet,cdn,status,contentDetails"`)
  - `before_focus/1`: Passes `:id` and `:part`.
  - `after_focus/1`:
    - Returns `{:ok, %{id: stream_id, title: ..., stream_name: stream_key, ingestion_address: ..., backup_ingestion_address: ..., status: ..., health_status: ..., resolution: ..., frame_rate: ..., is_reusable: ...}}`.
    - Returns `{:error, :not_found}` if `items` list is empty.

---

### 3.2 YouTube Prisms (`lib/lux/prisms/youtube/`)

#### A. `Lux.Prisms.YouTube.CreateBroadcast` (`lib/lux/prisms/youtube/create_broadcast.ex`)
- **Purpose**: High-level Agent Prism to create a live broadcast, optionally creating and binding an RTMP stream ingestion point in one unified flow.
- **Contract**:
  - Input Schema:
    - `:title` (string, required)
    - `:description` (string, optional)
    - `:scheduled_start_time` (string ISO 8601, optional)
    - `:privacy_status` (string enum: `["public", "private", "unlisted"]`, default `"public"`)
    - `:create_and_bind_stream` (boolean, default `false`)
    - `:stream_title` (string, optional)
    - `:bind_stream_id` (string, optional)
    - `:enable_auto_start` (boolean, default `true`)
    - `:enable_auto_stop` (boolean, default `true`)
    - `:enable_dvr` (boolean, default `true`)
    - `:latency_preference` (string enum: `["normal", "low", "ultra_low", "ultraLow"]`, default `"low"`)
    - `:token` (string, optional token override)
    - `:plug` (plug, optional test override)
  - Output Schema:
    - `:broadcast_id` (string, required)
    - `:title` (string)
    - `:watch_url` (string, required)
    - `:live_chat_id` (string | nil)
    - `:bound_stream_id` (string | nil)
    - `:stream_key` (string | nil)
    - `:ingestion_address` (string | nil)
    - `:status` (string)
  - Execution Flow:
    1. Wraps API calls in `Errors.with_retry/2`.
    2. Calls `LiveBroadcasts.create_broadcast(params, opts)`.
    3. If `create_and_bind_stream: true`:
       - Calls `LiveStreams.create_stream(%{title: stream_title}, opts)`.
       - Calls `LiveBroadcasts.bind_broadcast(broadcast_id, stream_id, opts)`.
       - Extracts `streamName` and `ingestionAddress`.
    4. If `bind_stream_id` provided:
       - Calls `LiveBroadcasts.bind_broadcast(broadcast_id, bind_stream_id, opts)`.
    5. Returns `{:ok, %{broadcast_id: ..., watch_url: ..., live_chat_id: ..., bound_stream_id: ..., ...}}`.

#### B. `Lux.Prisms.YouTube.SendChatMessage` (`lib/lux/prisms/youtube/send_chat_message.ex`)
- **Purpose**: High-level Agent Prism to post a message into a YouTube live chat stream.
- **Contract**:
  - Input Schema:
    - `:live_chat_id` (string, required)
    - `:message` (string, 1..200 chars, required)
    - `:token` (string, optional)
    - `:plug` (plug, optional)
  - Output Schema:
    - `:sent` (boolean, required)
    - `:message_id` (string, required)
    - `:live_chat_id` (string, required)
    - `:message` (string, required)
    - `:published_at` (string)
  - Execution Flow:
    1. Validates presence of `live_chat_id` and non-empty `message`.
    2. Wraps in `Errors.with_retry/2` with backoff on rate-limits.
    3. Calls `LiveChat.insert_message(live_chat_id, message, opts)`.
    4. Returns `{:ok, %{sent: true, message_id: id, live_chat_id: live_chat_id, message: message, published_at: published_at}}`.

---

### 3.3 Resiliency & Agent Feedback Helpers in `Errors`
- **`Errors.format_error_for_agent/1`**:
  - Translates `{:error, {:quota_exceeded, details}}` into an intelligible agent string: `"YouTube API quota limit exceeded. Request failed because daily quota (10,000 units) is depleted. Try again after midnight Pacific Time."`
  - Translates `{:error, {:rate_limited, %{retry_after: s}}}` into: `"YouTube API rate limit reached. Backing off for #{s} seconds."`
  - Translates `{:error, :invalid_token}` into: `"YouTube OAuth credentials invalid or expired. Re-authentication required."`

---

## 4. Test Suite Design for Milestone 4

### 4.1 Lens Test Suite (`test/unit/lux/lenses/youtube_lenses_test.exs`)
- **Module**: `Lux.Lenses.YouTubeLensesTest`
- **Framework**: `use UnitAPICase, async: true`
- **Mock Interception Target**: `Req.Test.expect(Lux.Lens, fn conn -> ... end)`
- **Test Matrix**:
  1. **`ListBroadcasts` Lens**:
     - `test "lists broadcasts with default parameters"`:
       - Intercepts `GET /youtube/v3/liveBroadcasts`.
       - Asserts query params contain `broadcastStatus=all`, `broadcastType=event`, `mine=true`, `part=snippet%2Cstatus%2CcontentDetails`.
       - Asserts auth header `Bearer ...`.
       - Returns 2 broadcasts JSON.
       - Asserts `{:ok, %{broadcasts: [b1, b2], next_page_token: ..., total_results: 2}}`.
       - Verifies `b1.watch_url == "https://www.youtube.com/watch?v=..."` and `b1.live_chat_id == "..."`.
     - `test "lists broadcasts with custom status filter and pagination"`:
       - Inputs: `broadcast_status: "upcoming"`, `max_results: 10`, `page_token: "page_1"`.
       - Verifies camelCase translation: `broadcastStatus=upcoming&maxResults=10&pageToken=page_1`.
     - `test "filters broadcast by specific ID without mine parameter"`:
       - Inputs: `id: "bcast_xyz"`.
       - Verifies `id=bcast_xyz` is passed.
     - `test "handles empty broadcast list"`:
       - Returns `items: []`.
       - Asserts `{:ok, %{broadcasts: []}}`.
     - `test "handles API quota and rate limit errors"`:
       - Returns HTTP 403 `quotaExceeded` / HTTP 429.
       - Asserts returned error matches expected format.
     - `test "schema properties and defaults validation"`:
       - Asserts schema structure of `ListBroadcasts.view().schema`.
  2. **`GetChatMessages` Lens**:
     - `test "fetches live chat messages with normalized author and snippet details"`:
       - Intercepts `GET /youtube/v3/liveChat/messages`.
       - Asserts query params `liveChatId=chat_123&part=snippet%2CauthorDetails`.
       - Returns text message and super chat message fixtures.
       - Asserts normalized response with `messages`, `author_display_name`, `is_sponsor`, `polling_interval_ms: 6000`, `next_page_token: "page_2"`.
     - `test "fetches chat messages with pagination"`:
       - Inputs: `live_chat_id: "chat_123"`, `page_token: "tok_2"`, `max_results: 50`.
       - Verifies `pageToken=tok_2&maxResults=50`.
     - `test "extracts Super Chat contribution details"`:
       - Verifies `super_chat` map containing `amount_micros: 10000000`, `currency: "USD"`, `amount_display_string: "$10.00"`, `user_comment: "..."`.
     - `test "handles empty chat message list"`:
       - Returns `items: []`.
       - Asserts `{:ok, %{messages: []}}`.
     - `test "schema validation requires live_chat_id"`:
       - Asserts `GetChatMessages.view().schema.required == ["live_chat_id"]`.
  3. **`GetStream` Lens**:
     - `test "fetches stream details and extracts RTMP ingestion info"`:
       - Intercepts `GET /youtube/v3/liveStreams`.
       - Asserts query param `id=stream_123`.
       - Returns stream item with `cdn.ingestionInfo`.
       - Asserts returned stream map contains `stream_name`, `ingestion_address`, `backup_ingestion_address`, `status: "active"`, `health_status: "good"`.
     - `test "handles stream not found"`:
       - Returns `items: []`.
       - Asserts `{:error, :not_found}`.
     - `test "schema validation requires id"`:
       - Asserts `GetStream.view().schema.required == ["id"]`.

### 4.2 Prism Test Suite (`test/unit/lux/prisms/youtube_prisms_test.exs`)
- **Module**: `Lux.Prisms.YouTubePrismsTest`
- **Framework**: `use UnitAPICase, async: false`
- **Mock Interception Target**: `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)`
- **Test Matrix**:
  1. **`CreateBroadcast` Prism**:
     - `test "successfully creates a broadcast with friendly parameters"`:
       - Intercepts `POST /youtube/v3/liveBroadcasts`.
       - Verifies JSON body snippet (`title`, `description`, `scheduledStartTime`) and status (`privacyStatus`).
       - Asserts `CreateBroadcast.run(%{title: "New Stream", privacy_status: "unlisted"})` returns `{:ok, %{broadcast_id: "bcast_1", watch_url: "https://www.youtube.com/watch?v=bcast_1", live_chat_id: "chat_1", status: "created"}}`.
     - `test "creates broadcast and automatically creates & binds stream when create_and_bind_stream is true"`:
       - 3 sequential expectations on `YouTubeClientMock`:
         1. `POST /youtube/v3/liveBroadcasts` -> returns broadcast `bcast_1`.
         2. `POST /youtube/v3/liveStreams` -> returns stream `stream_1` with `ingestionInfo` (`streamName: "key_xyz"`, `ingestionAddress: "rtmp://..."`).
         3. `POST /youtube/v3/liveBroadcasts/bind` (query `id=bcast_1&streamId=stream_1`) -> returns bound broadcast.
       - Asserts returned map has `broadcast_id: "bcast_1"`, `bound_stream_id: "stream_1"`, `stream_key: "key_xyz"`, `ingestion_address: "rtmp://..."`.
     - `test "binds broadcast to existing stream when bind_stream_id is provided"`:
       - Expectation 1: `POST /liveBroadcasts`.
       - Expectation 2: `POST /liveBroadcasts/bind` with `streamId=existing_stream_99`.
       - Asserts returned map has `bound_stream_id: "existing_stream_99"`.
     - `test "auto-retries and recovers from transient rate limit (HTTP 429)"`:
       - Expectation 1: `POST /liveBroadcasts` returns HTTP 429 with `rateLimitExceeded`.
       - Expectation 2: `POST /liveBroadcasts` returns HTTP 200 with broadcast.
       - Asserts `CreateBroadcast.run(...)` succeeds on retry.
     - `test "fails fast on quotaExceeded without retrying"`:
       - Expectation: `POST /liveBroadcasts` returns HTTP 403 `quotaExceeded`.
       - Asserts `{:error, {:quota_exceeded, _}}` is returned immediately.
     - `test "input/output schema verification"`:
       - Verifies `input_schema` and `output_schema` conform to `Lux.Prism` expectations.
  2. **`SendChatMessage` Prism**:
     - `test "successfully inserts a chat message"`:
       - Intercepts `POST /youtube/v3/liveChat/messages`.
       - Verifies JSON body: `snippet.liveChatId == "chat_123"`, `snippet.textMessageDetails.messageText == "Hello Agent World!"`.
       - Asserts `SendChatMessage.run(%{live_chat_id: "chat_123", message: "Hello Agent World!"})` returns `{:ok, %{sent: true, message_id: "msg_999", live_chat_id: "chat_123", message: "Hello Agent World!"}}`.
     - `test "auto-retries on HTTP 403 userRateLimitExceeded with Retry-After"`:
       - Expectation 1: returns HTTP 403 with `userRateLimitExceeded` and header `retry-after: 0`.
       - Expectation 2: returns HTTP 200 with message.
       - Asserts `SendChatMessage.run(...)` succeeds after backoff.
     - `test "validates missing live_chat_id or empty message"`:
       - Calling with `%{live_chat_id: ""}` returns `{:error, ...}`.
       - Calling with `%{message: ""}` returns `{:error, ...}`.
     - `test "fails fast on daily quota exhaustion"`:
       - Returns HTTP 403 `dailyLimitExceeded`.
       - Asserts `{:error, {:quota_exceeded, _}}` immediately without retries.
     - `test "input/output schema verification"`:
       - Verifies `input_schema` requires `["live_chat_id", "message"]`.

---

## 5. Caveats
- **Async Execution in Tests**: `UnitAPICase` sets global plug env for `Lux.Lens` and `YouTubeClientMock`. Lens tests using `Req.Test.expect(Lux.Lens, ...)` can run `async: true`, while Prism tests interacting with `YouTubeClientMock` are best run `async: false` or with explicit `:plug` options to avoid test process race conditions when configuring shared mocks.
- **Quota Cost Awareness**: YouTube Data API v3 charges 1 unit for `GET`, 50 units for `POST liveBroadcasts/create`, and 50 units for `POST liveStreams/create`. Prisms combining broadcast and stream creation consume ~100 units per invocation.

---

## 6. Conclusion
The error classification and exponential backoff engine in `Lux.Integrations.YouTube.Errors` and `Client` are robust and well-tested. Milestone 4 completes the YouTube integration by adding:
1. **Lenses** (`ListBroadcasts`, `GetChatMessages`, `GetStream`) providing standardized data-loading contracts for agent workflows.
2. **Prisms** (`CreateBroadcast`, `SendChatMessage`) providing resilient agent action tools with automatic retry on burst throttling.
3. **Comprehensive offline unit test suites** in `test/unit/lux/lenses/youtube_lenses_test.exs` and `test/unit/lux/prisms/youtube_prisms_test.exs` using `Req.Test` stubs.

---

## 7. Verification Method
1. **Compilation Check**:
   ```bash
   mix compile --warnings-as-errors
   ```
2. **Execute Milestone 4 Test Suites**:
   ```bash
   mix test test/unit/lux/lenses/youtube_lenses_test.exs test/unit/lux/prisms/youtube_prisms_test.exs --include unit
   ```
3. **Full Integration & Stress Test Suite**:
   ```bash
   mix test test/unit/lux/integrations/youtube/ --include unit
   ```
