# YouTube Integration E2E Test Suite Design: Tier 3 & Tier 4 Specification

**Author**: Explorer 2 (Milestone 5)  
**Target File**: `test/e2e/youtube_integration_e2e_test.exs`  
**Date**: 2026-08-17  
**Scope**: Tier 3 (Cross-Feature Pairwise Combinations) & Tier 4 (Real-World Application Scenarios)  

---

## 1. Executive Summary & Test Strategy

Milestone 5 establishes an end-to-end (E2E), offline-isolated test suite verifying the complete YouTube API and Live Streaming integration for the Lux framework. This report specifies the exact test architecture, interaction matrices, mock state transitions, and step-by-step test cases for:

1. **Tier 3 (Cross-Feature Interactions & Pairwise Combinations)**: 10 pairwise test cases covering all 6 feature domains ($F_1$ through $F_6$) plus Lux Lenses, Prisms, and Beams.
2. **Tier 4 (Real-World Application Scenarios)**: 5 complex, multi-phase production workflows simulating realistic streaming agent operations, live moderation, token lifecycle recovery, traffic degradation, and autonomous Lux agent loops.
3. **Mock State Machine & Plug Architecture**: Deterministic, offline HTTP simulation using `Req.Test`, GenServer process sharing, and stateful request routing.

### Feature Domain Reference
| ID | Feature Domain | Key Modules |
|:---|:---|:---|
| **$F_1$** | OAuth 2.0 & Token Refresh | `Lux.Integrations.YouTube.OAuth` |
| **$F_2$** | HTTP Client & Error Handling | `Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube.Errors` |
| **$F_3$** | Live Broadcast Lifecycle | `Lux.Integrations.YouTube.LiveBroadcasts` |
| **$F_4$** | Live Stream Ingestion & Binding | `Lux.Integrations.YouTube.LiveStreams` |
| **$F_5$** | Live Chat Reading & Poller | `Lux.Integrations.YouTube.LiveChat`, `Lux.Integrations.YouTube.LiveChat.Poller` |
| **$F_6$** | Resiliency & Quota / Rate Limiting | `Lux.Integrations.YouTube.Errors` (`with_retry/2`, `backoff_delay/2`) |
| **$L/P$** | Lux Lenses, Prisms & Agents | `Lux.Lens`, `Lux.Prism`, `Lux.Agent`, `Lux.Beam` |

---

## 2. Feature Interaction Matrix (Pairwise Coverage)

| Interaction | Primary Features | Secondary Features | Core Verification Goal | Test Case ID |
|:---|:---:|:---:|:---|:---|
| **F1 + F2** | OAuth 2.0 | API Client | Code exchange followed by API request with transparent 401 auto-refresh | `T3-PAIR-01` |
| **F3 + F4** | Live Broadcasts | Live Streams | Create broadcast, create ingestion stream, bind, verify RTMP/RTMPS URLs | `T3-PAIR-02` |
| **F3 + F5** | Live Broadcasts | Live Chat / Poller | Transition broadcast to live, extract `liveChatId`, attach Poller | `T3-PAIR-03` |
| **F5 + F6** | Live Chat / Poller | Resiliency / Errors | Poller encounters 429 rate limit & 403 quota exhaustion, backs off, recovers | `T3-PAIR-04` |
| **F2 + L/P** | API Client | Lenses & Prisms | Lens queries live broadcasts; output feeds into Prism inserting chat message | `T3-PAIR-05` |
| **F1 + F3** | OAuth 2.0 | Live Broadcasts | Token expires mid-lifecycle transition; client refreshes and completes transition | `T3-PAIR-06` |
| **F4 + F6** | Live Streams | Resiliency / Errors | Stream creation retry under transient 503 / 429 using exponential backoff | `T3-PAIR-07` |
| **F3 + F5 + F4** | Live Broadcasts | Chat & Streams | Broadcast transition to complete propagates `offlineAt` to Poller; resource teardown | `T3-PAIR-08` |
| **F1 + F5** | OAuth 2.0 | Live Chat | Chat message insertion (`insert_message/3`) transparently refreshes expired token | `T3-PAIR-09` |
| **F2 + F3 + F4** | API Client | Broadcasts & Streams | Concurrent batch querying of broadcasts and streams via `Task.async_stream` | `T3-PAIR-10` |

---

## 3. Tier 3: Detailed Pairwise Test Specifications

### T3-PAIR-01: F1 (OAuth) + F2 (Client) — Code Exchange & Auto 401 Refresh
- **Objective**: Verify that authorization code exchange seamlessly sets up client credentials, and an expired access token encountering HTTP 401 is automatically refreshed via `OAuth.refresh_token/2` and retried transparently.
- **Preconditions**:
  - `YouTubeOAuthMock` and `YouTubeClientMock` registered with `Req.Test`.
  - Client configured with `client_id: "client_123"`, `client_secret: "secret_456"`.
- **Execution Flow**:
  1. `OAuth.exchange_code("auth_code_init", client_id: "client_123", client_secret: "secret_456")`.
  2. OAuth Mock responds 200: `%{"access_token" => "tok_v1", "refresh_token" => "ref_v1", "expires_in" => 3600}`.
  3. Caller invokes `Client.get("/liveBroadcasts", token: "tok_v1", refresh_token: "ref_v1", client_id: "client_123", client_secret: "secret_456")`.
  4. YouTube Client Mock receives request with `Authorization: Bearer tok_v1` -> returns 401 Unauthorized: `%{"error" => %{"code" => 401, "message" => "Token expired"}}`.
  5. Client automatically invokes OAuth Mock `POST /token` with form `grant_type=refresh_token&refresh_token=ref_v1` -> OAuth Mock returns 200: `%{"access_token" => "tok_v2", "expires_in" => 3600}`.
  6. Client re-executes GET `/liveBroadcasts` with `Authorization: Bearer tok_v2` -> returns 200: `%{"items" => [%{"id" => "bcast_101"}]}`.
- **Assertions**:
  - `{:ok, %{"items" => [%{"id" => "bcast_101"}]}}` returned to caller.
  - Header progression strictly verified: `Bearer tok_v1` on attempt 1, `Bearer tok_v2` on attempt 2.
  - Retries strictly bounded to 1 attempt.

### T3-PAIR-02: F3 (LiveBroadcasts) + F4 (LiveStreams) — Broadcast & Stream Lifecycle Binding
- **Objective**: Verify the provisioning of a Live Stream ingestion point, creation of a Live Broadcast, and their bi-directional binding.
- **Preconditions**: Valid OAuth token `"tok_valid"`.
- **Execution Flow**:
  1. `LiveBroadcasts.create_broadcast(%{title: "Main Stage", scheduled_start_time: "2026-08-17T20:00:00Z", privacy_status: :unlisted, latency_preference: "low"}, token: "tok_valid")`.
     - Client Mock POST `/liveBroadcasts` returns 200: `%{"id" => "bcast_201", "status" => %{"lifeCycleStatus" => "created"}, "snippet" => %{"liveChatId" => "chat_201"}, "contentDetails" => %{"boundStreamId" => nil}}`.
  2. `LiveStreams.create_stream(%{title: "1080p Stream", ingestion_type: "rtmp", resolution: "1080p", frame_rate: "60fps"}, token: "tok_valid")`.
     - Client Mock POST `/liveStreams` returns 200: `%{"id" => "stream_201", "cdn" => %{"ingestionType" => "rtmp", "ingestionInfo" => %{"streamName" => "key_xyz", "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2", "rtmpsIngestionAddress" => "rtmps://a.rtmp.youtube.com/live2"}}}`.
  3. `LiveBroadcasts.bind_broadcast("bcast_201", "stream_201", token: "tok_valid")`.
     - Client Mock POST `/liveBroadcasts/bind?id=bcast_201&streamId=stream_201` returns 200: `%{"id" => "bcast_201", "contentDetails" => %{"boundStreamId" => "stream_201"}, "status" => %{"lifeCycleStatus" => "ready"}}`.
- **Assertions**:
  - `LiveStreams.stream_url(stream_201)` equals `"rtmp://a.rtmp.youtube.com/live2/key_xyz"`.
  - `LiveStreams.stream_url(stream_201, protocol: :rtmps)` equals `"rtmps://a.rtmp.youtube.com/live2/key_xyz"`.
  - `LiveBroadcasts.bound_stream_id(bound_bcast)` equals `"stream_201"`.
  - `LiveBroadcasts.ready?(bound_bcast)` returns `true`.

### T3-PAIR-03: F3 (LiveBroadcasts) + F5 (LiveChat) — Transition to Live & Poller Attachment
- **Objective**: Transition a bound broadcast to `live`, extract its active `liveChatId`, attach a `LiveChat.Poller`, and receive chat streams.
- **Preconditions**: Broadcast `bcast_301` in `ready` state with `liveChatId: "chat_301"`.
- **Execution Flow**:
  1. `LiveBroadcasts.transition_broadcast("bcast_301", :testing, token: "tok_valid")` -> 200 OK (`lifeCycleStatus: "testing"`).
  2. `LiveBroadcasts.transition_broadcast("bcast_301", :live, token: "tok_valid")` -> 200 OK (`lifeCycleStatus: "live"`, `snippet.liveChatId: "chat_301"`).
  3. `LiveChat.get_live_chat_id_for_broadcast("bcast_301", token: "tok_valid")` returns `{:ok, "chat_301"}`.
  4. Start `LiveChat.Poller` on `"chat_301"` with `subscriber: self()`, `auto_start: false`, `token: "tok_valid"`.
  5. Mock GET `/liveChat/messages?liveChatId=chat_301` returns 200 with 2 messages and `nextPageToken: "tok_page2"`.
  6. `Poller.poll_once(poller)` -> returns `{:ok, [msg1, msg2]}`.
- **Assertions**:
  - Subscriber process receives `{:live_chat_messages, "chat_301", messages}`.
  - Normalized messages contain `:id`, `:message_text`, `:author_display_name`.
  - Poller status reflects `page_token: "tok_page2"`, `message_count: 2`, `poll_count: 1`.

### T3-PAIR-04: F5 (LiveChat) + F6 (Resiliency) — Poller 429 Throttle & 403 Quota Recovery
- **Objective**: Verify Poller behavior under intermittent rate limiting (429) and quota exhaustion (403), ensuring backoff scheduling and subscriber error notifications without process crash.
- **Preconditions**: Poller initialized on `chat_401` with `subscriber: self()`, `auto_start: false`.
- **Execution Flow**:
  1. Poll 1: Mock returns HTTP 429 Too Many Requests (`reason: "rateLimitExceeded"`, `Retry-After: 2`).
     - Poller updates `consecutive_errors: 1`, `last_error: {:rate_limited, ...}`.
     - Subscriber receives `{:live_chat_error, "chat_401", {:rate_limited, %{retry_after: 2}}}`.
  2. Poll 2: Mock returns HTTP 403 Forbidden (`reason: "quotaExceeded"`).
     - Poller updates `consecutive_errors: 2`, `last_error: {:quota_exceeded, ...}`.
     - Subscriber receives `{:live_chat_error, "chat_401", {:quota_exceeded, %{reason: "quotaExceeded"}}}`.
  3. Poll 3: Mock returns HTTP 200 OK with `messages: [msg]`, `nextPageToken: "tok_page_3"`, `pollingIntervalMillis: 3000`.
     - Poller resets `consecutive_errors: 0`, `last_error: nil`, `message_count: 1`.
     - Subscriber receives `{:live_chat_messages, "chat_401", [msg]}`.
- **Assertions**:
  - Error transitions do not terminate the GenServer.
  - Error metrics accurately tracked and cleared upon recovery.

### T3-PAIR-05: F2 (Client) + L/P (Lenses & Prisms) — Lens Querying to Prism Chat Action
- **Objective**: Test integration of YouTube client inside `Lux.Lens` and `Lux.Prism` workflows where Lens fetches active broadcasts and feeds broadcast ID into a Prism that posts an announcement.
- **Preconditions**: Defined `ListBroadcastsLens` (`use Lux.Lens`) and `SendMessagePrism` (`use Lux.Prism`).
- **Execution Flow**:
  1. `ListBroadcastsLens.focus(%{broadcast_status: :active})`.
     - Mock GET `/liveBroadcasts?broadcastStatus=active&mine=true` returns `%{"items" => [%{"id" => "bcast_501", "snippet" => %{"liveChatId" => "chat_501", "title" => "Live Q&A"}}]}`.
     - Lens `after_focus/1` parses item list into `[%{id: "bcast_501", live_chat_id: "chat_501", title: "Live Q&A"}]`.
  2. Pass extracted `live_chat_id` to `SendMessagePrism.run(%{live_chat_id: "chat_501", message: "Agent active"})`.
     - Mock POST `/liveChat/messages` receives JSON payload `%{"snippet" => %{"liveChatId" => "chat_501", "textMessageDetails" => %{"messageText" => "Agent active"}}}` -> returns 200 OK.
- **Assertions**:
  - `{:ok, %{id: "msg_501", status: :sent}}` returned from Prism.
  - Schema contracts validated on both ends.

### T3-PAIR-06: F1 (OAuth) + F3 (LiveBroadcasts) — Mid-Lifecycle Token Expiration during Transition
- **Objective**: Validate that a multi-step broadcast lifecycle pipeline recovers transparently when access token expires between transition steps.
- **Execution Flow**:
  1. `LiveBroadcasts.transition_broadcast("bcast_601", :testing, token: "tok_old", refresh_token: "ref_tok")` -> Mock returns 200 OK.
  2. `LiveBroadcasts.transition_broadcast("bcast_601", :live, token: "tok_old", refresh_token: "ref_tok")` -> Mock returns 401 Unauthorized.
  3. Client invokes OAuth Mock `POST /token` -> returns `access_token: "tok_new"`.
  4. Client replays transition to `:live` with `tok_new` -> Mock returns 200 OK.
- **Assertions**:
  - Final return is `{:ok, %{"status" => %{"lifeCycleStatus" => "live"}}}`.
  - Exactly 1 OAuth refresh triggered.

### T3-PAIR-07: F4 (LiveStreams) + F6 (Resiliency) — Stream Creation with Transient 503 Retry
- **Objective**: Create live stream ingestion resource wrapped in `Errors.with_retry/2` against transient 503 errors.
- **Execution Flow**:
  1. Invoke `Errors.with_retry(fn -> LiveStreams.create_stream(%{title: "Resilient Stream"}, token: "tok") end, max_retries: 2, sleep_fun: fn _ -> :ok end)`.
  2. Attempt 1: Mock returns 503 Service Unavailable `%{"error" => %{"code" => 503, "message" => "Backend timeout"}}`.
  3. `with_retry` checks `Errors.retryable?(503)` -> true, executes backoff delay.
  4. Attempt 2: Mock returns 200 OK `%{"id" => "stream_701", "cdn" => %{"ingestionInfo" => %{"streamName" => "key_701", "ingestionAddress" => "rtmp://..."}}}`.
- **Assertions**:
  - `{:ok, stream}` returned successfully.
  - Ingestion keys extracted without error.

### T3-PAIR-08: F3 + F5 + F4 — Full Teardown & Broadcast Termination Signal Propagation
- **Objective**: Verify that transitioning broadcast to `:complete` causes Poller to detect `offlineAt`, notify subscribers, transition to `:ended`, and allow safe deletion of broadcast and stream.
- **Execution Flow**:
  1. Broadcast `bcast_801` and stream `stream_801` active with Poller on `chat_801`.
  2. `LiveBroadcasts.transition_broadcast("bcast_801", :complete, token: "tok")` -> 200 OK (`lifeCycleStatus: "complete"`).
  3. Poller polls `chat_801` -> Mock returns 200 with `%{"items" => [], "offlineAt" => "2026-08-17T21:00:00Z"}`.
  4. Subscriber receives `{:live_chat_ended, "chat_801", %{offline_at: "2026-08-17T21:00:00Z"}}`.
  5. Poller status is `:ended`.
  6. `LiveStreams.delete_stream("stream_801", token: "tok")` -> 204 No Content.
  7. `LiveBroadcasts.delete_broadcast("bcast_801", token: "tok")` -> 204 No Content.
  8. `Poller.stop(poller)` returns `:ok`.
- **Assertions**:
  - Clean lifecycle termination with zero dangling processes.

### T3-PAIR-09: F1 (OAuth) + F5 (LiveChat) — Live Chat Message Insertion with Expired Token
- **Objective**: Verify `LiveChat.insert_message/3` executes token refresh transparently when token has expired.
- **Execution Flow**:
  1. `LiveChat.insert_message("chat_901", "Message 1", token: "exp_tok", refresh_token: "ref_tok")`.
  2. POST `/liveChat/messages` returns 401 Unauthorized.
  3. Client refreshes token via OAuth Mock -> receives `new_tok`.
  4. Replayed POST `/liveChat/messages` with `new_tok` returns 200 OK `%{"id" => "msg_901", "snippet" => %{"displayMessage" => "Message 1"}}`.
- **Assertions**:
  - `{:ok, %{"snippet" => %{"displayMessage" => "Message 1"}}}` returned to caller.

### T3-PAIR-010: F2 + F3 + F4 — Concurrent Batch Fetching of Broadcasts and Streams
- **Objective**: Concurrently query `/liveBroadcasts` and `/liveStreams` using Elixir async tasks to ensure client thread safety and absence of shared state corruption.
- **Execution Flow**:
  1. Spawn 4 parallel tasks querying `LiveBroadcasts.list_broadcasts/2` and `LiveStreams.list_streams/2`.
  2. Mock handles all requests concurrently.
  3. `Task.await_many/1` collects all results.
- **Assertions**:
  - All 4 tasks return `{:ok, ...}`.
  - No connection leaks or cross-task interference.

---

## 4. Tier 4: Detailed Real-World Scenario Specifications

### Scenario 1: Complete Live Stream Production Workflow (9-Phase Production Lifecycle)
- **Goal**: Full emulation of a complete live event production pipeline.
- **Phase Breakdown**:
  ```
  [1. Auth Exchange] ──> [2. Create Stream] ──> [3. Create Broadcast]
                                                        │
  [6. Go Live] <── [5. Testing State] <── [4. Bind Stream]
        │
  [7. Poller & Chat Ingestion] ──> [8. Complete Broadcast] ──> [9. Resource Teardown]
  ```
- **Step-by-Step Details**:
  1. **Auth Initial**: `OAuth.exchange_code("code_prod_101")` -> tokens `access_token: "prod_tok_1"`, `refresh_token: "prod_ref_1"`.
  2. **Stream Provisioning**: `LiveStreams.create_stream(%{title: "4K Keynote", ingestion_type: "rtmp", resolution: "1080p", frame_rate: "60fps"})` -> returns stream `prod_stream_1` with RTMP address `rtmp://a.rtmp.youtube.com/live2/key_prod_1`.
  3. **Broadcast Scheduling**: `LiveBroadcasts.create_broadcast(%{title: "Lux 2026 Keynote", scheduled_start_time: "2026-08-17T20:00:00Z", privacy_status: :unlisted, enable_auto_start: false, latency_preference: "low"})` -> returns broadcast `prod_bcast_1`, `liveChatId: "prod_chat_1"`, `status: "created"`.
  4. **Stream Binding**: `LiveBroadcasts.bind_broadcast("prod_bcast_1", "prod_stream_1")` -> returns status `"ready"`, `boundStreamId: "prod_stream_1"`.
  5. **Pre-Flight Testing**: `LiveBroadcasts.transition_broadcast("prod_bcast_1", :testing)` -> returns status `"testing"`. Verify `LiveBroadcasts.testing?(bcast) == true`.
  6. **Going Live**: `LiveBroadcasts.transition_broadcast("prod_bcast_1", :live)` -> returns status `"live"`. Verify `LiveBroadcasts.active?(bcast) == true`.
  7. **Chat Ingestion**:
     - Start `LiveChat.Poller` on `"prod_chat_1"` with `subscriber: self()`.
     - Poller receives batch of 2 viewer welcome messages.
     - Post broadcast announcement: `LiveChat.insert_message("prod_chat_1", "Welcome to the Keynote!")` -> 200 OK.
  8. **Broadcast Completion**: `LiveBroadcasts.transition_broadcast("prod_bcast_1", :complete)` -> returns status `"complete"`.
  9. **Teardown & Verification**:
     - Poller receives `offlineAt: "2026-08-17T21:30:00Z"`, notifies subscriber `{:live_chat_ended, "prod_chat_1", ...}`, enters `:ended`.
     - Delete stream `LiveStreams.delete_stream("prod_stream_1")` -> 204.
     - Delete broadcast `LiveBroadcasts.delete_broadcast("prod_bcast_1")` -> 204.
     - Stop poller `Poller.stop(poller)`.

---

### Scenario 2: Automated Chat Bot & Live Moderation Workflow
- **Goal**: Multi-agent live chat monitoring, command parsing, spam filtering, Super Chat tracking, and moderation responses.
- **Workflow State & Logic**:
  ```
  Incoming Chat Batch (Poller)
         │
         ├── Message A: "!help" ───────────────> Trigger SendMessagePrism ("Commands: !help, !schedule")
         ├── Message B: "SPAM LINK http://..." ─> Trigger Moderation Alert / Flag Message
         ├── Message C: Super Chat ($10.00) ───> Trigger Thank You Message ("Thanks @User for $10!")
         └── Message D: "Regular message" ─────> Stored in Agent Context Memory
  ```
- **Step-by-Step Details**:
  1. Start Poller on `chat_mod_202` with `auto_start: false`.
  2. Seed mock response for GET `/liveChat/messages`:
     - Msg 1: `%{id: "m_cmd", message_text: "!help", author_display_name: "Alice"}`
     - Msg 2: `%{id: "m_spam", message_text: "BUY CHEAP COINS http://scam.net", author_display_name: "SpamBot"}`
     - Msg 3: `%{id: "m_super", super_chat_details: %{amount_micros: 10_000_000, currency: "USD", user_comment: "Great stream!"}, author_display_name: "Bob"}`
     - Msg 4: `%{id: "m_chat", message_text: "Hello everyone!", author_display_name: "Charlie"}`
  3. `Poller.poll_once(poller)` returns the 4 normalized messages.
  4. Moderation Handler iterates through messages:
     - Detects `!help` -> calls `LiveChat.insert_message("chat_mod_202", "@Alice Bot Commands: !help, !schedule, !about")` -> 200 OK.
     - Detects URL / Spam in `m_spam` -> records violation flag `%{target_id: "m_spam", reason: :unauthorized_link}` and posts warning message.
     - Detects SuperChat in `m_super` -> calls `LiveChat.insert_message("chat_mod_202", "Thank you Bob for the $10.00 Super Chat!")` -> 200 OK.
  5. Subsequent poll verifies `nextPageToken` cursor advancement and empty delta.
  6. Poller cleanly stopped.

---

### Scenario 3: Token Expiration and Resilient Recovery During Active Broadcast
- **Goal**: Emulate long-duration streaming where access token expires mid-broadcast, verifying that both background Poller and foreground API calls recover transparently via OAuth token refresh without message drops or crashes.
- **Workflow Steps**:
  1. System starts with `access_token: "tok_expired"`, `refresh_token: "ref_valid"`.
  2. Background Poller triggers GET `/liveChat/messages` -> YouTube API returns 401 Unauthorized (`invalid_token`).
  3. Client intercepts 401, calls OAuth Mock `POST /token` -> returns `access_token: "tok_refreshed_303"`.
  4. Client replays GET `/liveChat/messages` with `tok_refreshed_303` -> returns 200 OK with message batch.
  5. Simultaneously, foreground operator process calls `LiveBroadcasts.get_broadcast("bcast_303")` -> succeeds with `tok_refreshed_303`.
  6. Next 3 consecutive poller cycles execute without any further 401s or refresh calls.
  7. Metrics verification: Poller `consecutive_errors == 0`, `message_count` matches delivered total, exactly 1 OAuth refresh request logged.

---

### Scenario 4: Quota Degradation & Rate Limit Backoff Handling during Peak Chat Traffic
- **Goal**: Simulate chat surges triggering HTTP 429 rate limiting followed by 403 quota exhaustion, testing exponential backoff, subscriber notifications, and full state recovery.
- **Workflow Phases**:
  1. **Initial Burst**: Poller running with 1000ms polling rate.
  2. **Stage 1 (429 Rate Limit)**:
     - YouTube returns 429 Too Many Requests (`reason: "rateLimitExceeded"`, `Retry-After: 2`).
     - Poller catches error, increments `consecutive_errors: 1`, broadcasts `{:live_chat_error, chat_id, {:rate_limited, %{retry_after: 2}}}`.
     - Poller delay set to 2000ms.
  3. **Stage 2 (403 Quota Exhaustion)**:
     - Next poll returns 403 Forbidden (`reason: "quotaExceeded"`).
     - Poller catches quota error, increments `consecutive_errors: 2`, calculates exponential backoff (`base: 1000ms`, `attempt: 2` -> ~2000-4000ms with jitter).
     - Broadcasts `{:live_chat_error, chat_id, {:quota_exceeded, ...}}`.
  4. **Stage 3 (Recovery & Backlog Processing)**:
     - Quota window resets. Next poll returns 200 OK with accumulated 10 messages and `pollingIntervalMillis: 5000`.
     - Poller delivers batch to subscribers, resets `consecutive_errors: 0`, updates polling interval to 5000ms.
  5. **Verification**: Verify subscriber received all 10 messages, error notifications were properly structured, and GenServer remained healthy throughout.

---

### Scenario 5: Full Lux Agent Workflow using Lenses and Prisms inside Autonomous Agent Loop
- **Goal**: Complete end-to-end integration test of YouTube Lenses and Prisms within an autonomous `Lux.Agent` loop.
- **Agent Architecture**:
  ```
  Lux.Agent (YouTubeProductionAgent)
     ├── Lenses:
     │     ├── ListBroadcastsLens (GET /liveBroadcasts)
     │     └── GetChatMessagesLens (GET /liveChat/messages)
     └── Prisms:
           ├── CreateBroadcastPrism (POST /liveBroadcasts)
           ├── SendMessagePrism (POST /liveChat/messages)
           └── TransitionBroadcastPrism (POST /liveBroadcasts/transition)
  ```
- **Step-by-Step Execution**:
  1. Define test modules:
     - `ListBroadcastsLens`: `use Lux.Lens`, url: `"https://www.googleapis.com/youtube/v3/liveBroadcasts"`.
     - `GetChatMessagesLens`: `use Lux.Lens`, url: `"https://www.googleapis.com/youtube/v3/liveChat/messages"`.
     - `CreateBroadcastPrism`: `use Lux.Prism`, handler creates broadcast.
     - `SendMessagePrism`: `use Lux.Prism`, handler posts chat message.
     - `TransitionBroadcastPrism`: `use Lux.Prism`, handler transitions broadcast.
  2. Step 1: Agent creates scheduled broadcast -> `CreateBroadcastPrism.run(%{title: "Autonomous Agent Stream", privacy_status: :unlisted})` -> returns `{:ok, %{id: "bcast_agent_505", live_chat_id: "chat_agent_505"}}`.
  3. Step 2: Agent focuses `ListBroadcastsLens.focus(%{broadcast_status: :upcoming})` -> returns list containing `"bcast_agent_505"`.
  4. Step 3: Agent transitions broadcast to `:live` -> `TransitionBroadcastPrism.run(%{broadcast_id: "bcast_agent_505", status: :live})` -> returns `{:ok, %{status: "live"}}`.
  5. Step 4: Agent reads live chat -> `GetChatMessagesLens.focus(%{live_chat_id: "chat_agent_505"})` -> returns initial chat state.
  6. Step 5: Agent sends greeting to chat -> `SendMessagePrism.run(%{live_chat_id: "chat_agent_505", message: "Autonomous Agent has started streaming."})` -> returns `{:ok, %{message_id: "msg_ag_1"}}`.
- **Assertions**:
  - Full lens focus and prism execution cycles succeed.
  - JSON schemas and return types comply with Lux specifications.

---

## 5. Mock State Machine & Plug Architecture

### Mock Architecture Diagram
```
                          ┌────────────────────────┐
                          │    ExUnit Test Case    │
                          └───────────┬────────────┘
                                      │
               ┌──────────────────────┴──────────────────────┐
               ▼                                             ▼
  ┌─────────────────────────┐                   ┌─────────────────────────┐
  │   YouTubeClientMock     │                   │    YouTubeOAuthMock     │
  │ (Req.Test Plug Router)  │                   │ (Req.Test Plug Router)  │
  └────────────┬────────────┘                   └────────────┬────────────┘
               │                                             │
               ├── POST /liveBroadcasts                      ├── POST /token (auth_code)
               ├── GET  /liveBroadcasts                      └── POST /token (refresh)
               ├── PUT  /liveBroadcasts
               ├── POST /liveBroadcasts/bind
               ├── POST /liveBroadcasts/transition
               ├── DELETE /liveBroadcasts
               ├── POST /liveStreams
               ├── GET  /liveStreams
               ├── DELETE /liveStreams
               ├── GET  /liveChat/messages
               └── POST /liveChat/messages
```

### Multi-Process Authorization (`Req.Test.allow`)
Because `LiveChat.Poller` runs in its own GenServer process, tests starting a poller must explicitly grant mock access:
```elixir
{:ok, poller} = LiveChat.Poller.start_link(live_chat_id: chat_id, token: "tok", auto_start: false)
Req.Test.allow(YouTubeClientMock, self(), poller)
Req.Test.allow(YouTubeOAuthMock, self(), poller)
```

### Stateful Mock Helpers
To enable complex multi-step tests without brittle hardcoded expectation lists, implement reusable helper constructors:
1. `broadcast_fixture(id, status, stream_id, chat_id)`: Generates standard YouTube broadcast JSON maps.
2. `stream_fixture(id, status, stream_key)`: Generates standard YouTube stream JSON maps with ingestion endpoints.
3. `chat_message_fixture(id, text, author_name, overrides)`: Generates standard normalized live chat messages.
4. `chat_list_fixture(items, next_page_token, polling_interval_ms, offline_at)`: Generates live chat list responses.
5. `error_response_fixture(status, reason, message, retry_after)`: Generates Google API formatted error bodies.

---

## 6. Verification and Compliance Checklist

- [x] Full coverage of all 6 feature domains ($F_1$ through $F_6$).
- [x] 10 Pairwise combinations designed for Tier 3 (exceeding $\ge 8$ requirement).
- [x] 5 Complex real-world multi-phase scenarios designed for Tier 4 (exceeding $\ge 5$ requirement).
- [x] Plug handlers and state transition mechanisms fully specified with `Req.Test`.
- [x] Zero reliance on external network access (`CODE_ONLY` compliance).
- [x] Ready for implementation in `test/e2e/youtube_integration_e2e_test.exs`.
