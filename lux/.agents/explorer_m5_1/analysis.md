# Milestone 5: YouTube Core API & Live Streaming E2E Test Suite Analysis

## Executive Summary
This report presents the architectural analysis, test design, and offline mock specifications for **Milestone 5 (E2E Test Suite Tiers 1-4 & Adversarial Hardening)** of the YouTube integration in the Lux framework.

The YouTube integration comprises 6 primary functional areas:
1. **F1: OAuth 2.0 Flow & Token Refresh** (`Lux.Integrations.YouTube.OAuth`)
2. **F2: YouTube API Client & Error Handling** (`Lux.Integrations.YouTube.Client`)
3. **F3: Live Broadcast Lifecycle & Management** (`Lux.Integrations.YouTube.LiveBroadcasts`)
4. **F4: Live Stream Ingestion & Binding** (`Lux.Integrations.YouTube.LiveStreams`)
5. **F5: Live Chat Reading & Poller Pagination** (`Lux.Integrations.YouTube.LiveChat`, `Poller`)
6. **F6: Quota/Rate Limiting Handling & Lenses/Prisms Execution** (`Lux.Integrations.YouTube.Errors`, `Lux.Integrations.YouTube`, `Lux.Lens`, `Lux.Prism`)

This document defines:
- **30 Tier 1 Test Cases** (5 per feature) covering complete functional requirements under nominal conditions.
- **30 Tier 2 Test Cases** (5 per feature) covering boundary values, corner cases, error parsing, payload malformations, and resiliency.
- **`Req.Test` Offline Mock Architecture** and stateful plug router specifications to ensure zero external network calls, zero flakiness, and 100% deterministic test execution.

---

## 1. Codebase Inventory & Architectural Baseline

| Module | File Path | Responsibilities & Key Contracts |
|---|---|---|
| `Lux.Integrations.YouTube` | `lib/lux/integrations/youtube.ex` | Base URL (`https://www.googleapis.com/youtube/v3`), standard headers, request settings for lenses, custom auth injection function (`add_auth_header/1`) supporting `Lux.Lens` and `Plug.Conn`. |
| `Lux.Integrations.YouTube.OAuth` | `lib/lux/integrations/youtube/oauth.ex` | OAuth 2.0 URL generation (`authorize_url/1`), auth code exchange (`exchange_code/2`), token refresh (`refresh_token/2`), default scopes list (`default_scopes/0`). |
| `Lux.Integrations.YouTube.Client` | `lib/lux/integrations/youtube/client.ex` | Req-based HTTP client (`request/3`, `get/2`, `post/2`, `put/2`, `delete/2`), Bearer auth & API key injection, auto-refresh on 401 with retry limit, `Req.Test` plug routing. |
| `Lux.Integrations.YouTube.Errors` | `lib/lux/integrations/youtube/errors.ex` | Structured error parser (`parse/3`), quota (`quota_exceeded?/1`), rate limit (`rate_limited?/1`), retryability (`retryable?/1`), `Retry-After` header extraction, jittered backoff (`backoff_delay/2`), function retry executor (`with_retry/2`). |
| `Lux.Integrations.YouTube.LiveBroadcasts` | `lib/lux/integrations/youtube/live_broadcasts.ex` | Broadcast CRUD (`create_broadcast/2`, `get_broadcast/2`, `list_broadcasts/2`, `update_broadcast/2`, `delete_broadcast/2`), lifecycle state transitions (`transition_broadcast/3` for `testing`, `live`, `complete`), stream binding (`bind_broadcast/3`), status & URL accessors. |
| `Lux.Integrations.YouTube.LiveStreams` | `lib/lux/integrations/youtube/live_streams.ex` | Stream CRUD (`create_stream/2`, `get_stream/2`, `list_streams/2`, `update_stream/2`, `delete_stream/2`), RTMP/RTMPS ingestion URL builders (`stream_url/2`), stream key and health status extractors. |
| `Lux.Integrations.YouTube.LiveChat` | `lib/lux/integrations/youtube/live_chat.ex` | Message listing (`list_messages/2`), message insertion (`insert_message/3`), broadcast liveChatId lookup (`get_live_chat_id/2`), message normalization (`normalize_message/1`), Super Chat & badge extractors. |
| `Lux.Integrations.YouTube.LiveChat.Poller` | `lib/lux/integrations/youtube/live_chat/poller.ex` | GenServer for continuous chat polling, dynamic polling interval adaptation (`pollingIntervalMillis`), multi-subscriber broadcasting, `:handler_fn` execution, token cursor management, stream termination detection (`offlineAt`, 404). |

---

## 2. Req.Test Offline Mock Architecture & Plug Design

### 2.1 Isolation Strategy
All E2E tests run offline without communicating with Google/YouTube external endpoints. Isolation is enforced via `Req.Test` stubs and mock plugs.

```
+-------------------------------------------------------------------------+
|                              E2E Test Case                              |
+-------------------------------------------------------------------------+
                                     |
               +---------------------+---------------------+
               |                                           |
               v                                           v
+-----------------------------+             +-----------------------------+
| Lux.Integrations.YouTube    |             | Lux.Integrations.YouTube    |
| .Client (YouTubeClientMock) |             | .OAuth (YouTubeOAuthMock)   |
+-----------------------------+             +-----------------------------+
               |                                           |
               v                                           v
+-------------------------------------------------------------------------+
|                  Req.Test / In-Memory Mock Router                       |
|  - Validates HTTP method, path, query params, auth header, JSON body    |
|  - Injects simulated Google API responses (200, 204, 400, 401, 403, 429)|
|  - Tracks call sequence, payload integrity, and state transitions        |
+-------------------------------------------------------------------------+
```

### 2.2 Application Mock Configuration
In `UnitAPICase` or test setup:
```elixir
Application.put_env(:lux, Lux.Integrations.YouTube.Client, plug: {Req.Test, YouTubeClientMock})
Application.put_env(:lux, Lux.Integrations.YouTube.OAuth, plug: {Req.Test, YouTubeOAuthMock})
Application.put_env(:lux, :req_options, plug: {Req.Test, Lux.Lens})
```

### 2.3 Plug Interception Contracts

| Endpoint Path | Method | Expected Mock Behavior |
|---|---|---|
| `oauth2.googleapis.com/token` | `POST` | Validates form encoded `grant_type`, `client_id`, `client_secret`, and `code` or `refresh_token`. Returns JSON token payload or OAuth error. |
| `/youtube/v3/liveBroadcasts` | `POST` | Validates `part` query parameter, `snippet`, `status`, `contentDetails`. Returns created broadcast JSON with `id` and `liveChatId`. |
| `/youtube/v3/liveBroadcasts` | `GET` | Handles `id` filter or `mine=true` & `broadcastStatus`. Returns `items` list or empty list `[]`. |
| `/youtube/v3/liveBroadcasts` | `PUT` | Validates `id` in payload and `part`. Returns updated broadcast JSON. |
| `/youtube/v3/liveBroadcasts` | `DELETE` | Validates `id` query parameter. Returns 204 No Content (or 200). |
| `/youtube/v3/liveBroadcasts/transition` | `POST` | Validates `id`, `broadcastStatus` (`testing`, `live`, `complete`). Returns broadcast with updated `lifeCycleStatus`. |
| `/youtube/v3/liveBroadcasts/bind` | `POST` | Validates `id`, `streamId` (or unbind). Returns broadcast with updated `boundStreamId`. |
| `/youtube/v3/liveStreams` | `POST` | Validates `cdn.ingestionType`, `resolution`, `frameRate`. Returns stream JSON with `cdn.ingestionInfo`. |
| `/youtube/v3/liveStreams` | `GET` | Handles `id` or `mine=true`. Returns `items` stream list. |
| `/youtube/v3/liveStreams` | `PUT` | Validates stream `id` and updated CDN/snippet. Returns updated stream. |
| `/youtube/v3/liveStreams` | `DELETE` | Validates `id`. Returns 204 No Content. |
| `/youtube/v3/liveChat/messages` | `GET` | Validates `liveChatId`, `pageToken`, `part`. Returns `items`, `nextPageToken`, `pollingIntervalMillis`, `offlineAt`. |
| `/youtube/v3/liveChat/messages` | `POST` | Validates `liveChatId`, `type`, `textMessageDetails.messageText`. Returns inserted message JSON. |

---

## 3. Tier 1: Feature Coverage Test Cases (30 Cases)

### Feature 1: OAuth 2.0 Flow & Token Refresh (`Lux.Integrations.YouTube.OAuth`)

#### Case `T1-F1-01`: Standard Authorization URL Generation
- **Target**: `Lux.Integrations.YouTube.OAuth.authorize_url/1`
- **Input**: `%{client_id: "test-client-id", redirect_uri: "https://example.com/cb", state: "csrf_token_123"}`
- **Mock**: N/A (Pure URL construction)
- **Expected Outcome**:
  - URL starts with `https://accounts.google.com/o/oauth2/v2/auth?`
  - Decoded query contains `client_id=test-client-id`, `redirect_uri=https://example.com/cb`, `response_type=code`, `access_type=offline`, `prompt=consent`, `state=csrf_token_123`.
  - Default scopes present: `https://www.googleapis.com/auth/youtube`, `https://www.googleapis.com/auth/youtube.force-ssl`, `https://www.googleapis.com/auth/youtube.readonly`.

#### Case `T1-F1-02`: Authorization URL with Custom Scopes & Options
- **Target**: `Lux.Integrations.YouTube.OAuth.authorize_url/1`
- **Input**: `%{client_id: "cid", scope: ["https://www.googleapis.com/auth/youtube.readonly"], login_hint: "user@lux.io", include_granted_scopes: "true"}`
- **Mock**: N/A
- **Expected Outcome**:
  - `scope` parameter equals `"https://www.googleapis.com/auth/youtube.readonly"`.
  - `login_hint=user@lux.io` and `include_granted_scopes=true` present in query string.

#### Case `T1-F1-03`: Authorization Code Exchange
- **Target**: `Lux.Integrations.YouTube.OAuth.exchange_code/2`
- **Input**: `code = "auth_code_xyz"`, `opts = [client_id: "cid", client_secret: "sec", redirect_uri: "https://example.com/cb"]`
- **Mock Setup (`YouTubeOAuthMock`)**:
  - Expects `POST` to `https://oauth2.googleapis.com/token`.
  - Validates form body: `code=auth_code_xyz`, `grant_type=authorization_code`, `client_id=cid`, `client_secret=sec`, `redirect_uri=https://example.com/cb`.
  - Responds HTTP 200 with `%{"access_token" => "ya29.new_token", "refresh_token" => "1//refresh_xyz", "expires_in" => 3600, "token_type" => "Bearer"}`.
- **Expected Outcome**:
  - Returns `{:ok, %{"access_token" => "ya29.new_token", "refresh_token" => "1//refresh_xyz", "expires_in" => 3600, "token_type" => "Bearer"}}`.

#### Case `T1-F1-04`: Token Refresh Execution
- **Target**: `Lux.Integrations.YouTube.OAuth.refresh_token/2`
- **Input**: `refresh_token = "1//refresh_token_123"`, `opts = [client_id: "cid", client_secret: "sec"]`
- **Mock Setup (`YouTubeOAuthMock`)**:
  - Expects `POST` to `https://oauth2.googleapis.com/token`.
  - Validates form body: `grant_type=refresh_token`, `refresh_token=1//refresh_token_123`, `client_id=cid`, `client_secret=sec`.
  - Responds HTTP 200 with `%{"access_token" => "ya29.refreshed_token", "expires_in" => 3600, "token_type" => "Bearer"}`.
- **Expected Outcome**:
  - Returns `{:ok, %{"access_token" => "ya29.refreshed_token", "expires_in" => 3600, "token_type" => "Bearer"}}`.

#### Case `T1-F1-05`: Application Config Fallback for OAuth Credentials
- **Target**: `Lux.Integrations.YouTube.OAuth.exchange_code/2`
- **Setup**: `Application.put_env(:lux, :api_keys, youtube_client_id: "cfg_cid", youtube_client_secret: "cfg_sec", youtube_redirect_uri: "https://cfg.example.com/cb")`
- **Input**: `code = "auth_code_config"`, `opts = %{}`
- **Mock Setup (`YouTubeOAuthMock`)**:
  - Expects `POST` with `client_id=cfg_cid`, `client_secret=cfg_sec`, `redirect_uri=https://cfg.example.com/cb`.
  - Responds HTTP 200 with token map.
- **Expected Outcome**:
  - Resolves config credentials automatically and returns `{:ok, token_map}`.

---

### Feature 2: YouTube API Client & Error Handling (`Lux.Integrations.YouTube.Client`)

#### Case `T1-F2-01`: Client GET Request with Bearer Token Injection
- **Target**: `Lux.Integrations.YouTube.Client.get/2`
- **Input**: `path = "/liveBroadcasts"`, `opts = [token: "test_access_token", params: [part: "snippet", mine: true]]`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/liveBroadcasts`.
  - Validates header: `authorization: Bearer test_access_token`.
  - Validates query params: `part=snippet`, `mine=true`.
  - Responds HTTP 200 with `%{"kind" => "youtube#liveBroadcastListResponse", "items" => [%{"id" => "b1"}]}`.
- **Expected Outcome**:
  - Returns `{:ok, %{"kind" => "youtube#liveBroadcastListResponse", "items" => [%{"id" => "b1"}]}}`.

#### Case `T1-F2-02`: Client POST and PUT Requests with JSON Payload Encoding
- **Target**: `Lux.Integrations.YouTube.Client.post/2` and `Client.put/2`
- **Input**: `path = "/liveBroadcasts"`, `opts = [token: "tok", json: %{snippet: %{title: "New Stream"}}]`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `POST /youtube/v3/liveBroadcasts`.
  - Validates JSON body decoded: `%{"snippet" => %{"title" => "New Stream"}}`.
  - Responds HTTP 200 with `%{"id" => "b_created"}`.
- **Expected Outcome**:
  - Returns `{:ok, %{"id" => "b_created"}}`.

#### Case `T1-F2-03`: Client DELETE Request Execution
- **Target**: `Lux.Integrations.YouTube.Client.delete/2`
- **Input**: `path = "/liveBroadcasts"`, `opts = [token: "tok", params: [id: "b_del_1"]]`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `DELETE /youtube/v3/liveBroadcasts?id=b_del_1`.
  - Responds HTTP 204 with empty body.
- **Expected Outcome**:
  - Returns `{:ok, ""}` (or empty body) successfully.

#### Case `T1-F2-04`: API Key Query Parameter Fallback When Token is Absent
- **Target**: `Lux.Integrations.YouTube.Client.get/2`
- **Setup**: `Application.put_env(:lux, :api_keys, youtube_access_token: nil, youtube_api_key: "ai_api_key_999")`
- **Input**: `path = "/videos"`, `opts = [params: [part: "snippet", id: "vid123"]]`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/videos?part=snippet&id=vid123&key=ai_api_key_999`.
  - Validates header `authorization` is NOT present.
  - Responds HTTP 200 with video resource.
- **Expected Outcome**:
  - Injects `key=ai_api_key_999` parameter and returns `{:ok, body}`.

#### Case `T1-F2-05`: Automatic Token Refresh on HTTP 401 Unauthorized
- **Target**: `Lux.Integrations.YouTube.Client.get/2`
- **Setup**: `opts = [token: "expired_token", refresh_token: "valid_refresh", client_id: "cid", client_secret: "sec", auto_refresh: true]`
- **Mock Setup (`YouTubeClientMock` and `YouTubeOAuthMock`)**:
  1. `YouTubeClientMock`: First call to `GET /youtube/v3/liveBroadcasts` with `authorization: Bearer expired_token` responds HTTP 401.
  2. `YouTubeOAuthMock`: Call to `POST https://oauth2.googleapis.com/token` with `refresh_token` responds HTTP 200 with `%{"access_token" => "new_refreshed_token"}`.
  3. `YouTubeClientMock`: Second call to `GET /youtube/v3/liveBroadcasts` with `authorization: Bearer new_refreshed_token` responds HTTP 200 with `%{"items" => []}`.
- **Expected Outcome**:
  - Completes transparent retry and returns `{:ok, %{"items" => []}}`.

---

### Feature 3: Live Broadcast Lifecycle & Management (`Lux.Integrations.YouTube.LiveBroadcasts`)

#### Case `T1-F3-01`: Create Live Broadcast with Full Configuration
- **Target**: `Lux.Integrations.YouTube.LiveBroadcasts.create_broadcast/2`
- **Input**:
  ```elixir
  params = %{
    title: "AI Live Show",
    description: "Autonomous agent broadcast",
    scheduled_start_time: "2026-08-20T20:00:00Z",
    privacy_status: :public,
    enable_auto_start: true,
    enable_auto_stop: true,
    enable_dvr: true,
    latency_preference: :ultra_low
  }
  ```
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `POST /youtube/v3/liveBroadcasts?part=snippet%2Cstatus%2CcontentDetails`.
  - Validates JSON payload:
    - `snippet.title == "AI Live Show"`
    - `snippet.scheduledStartTime == "2026-08-20T20:00:00Z"`
    - `status.privacyStatus == "public"`
    - `contentDetails.enableAutoStart == true`
    - `contentDetails.latencyPreference == "ultraLow"`
  - Responds HTTP 200 with broadcast resource `%{"id" => "bcast_101", "snippet" => %{"title" => "AI Live Show", "liveChatId" => "chat_101"}, "status" => %{"lifeCycleStatus" => "created"}}`.
- **Expected Outcome**:
  - Returns `{:ok, broadcast}` with `id="bcast_101"`.

#### Case `T1-F3-02`: Retrieve Single Broadcast by ID
- **Target**: `Lux.Integrations.YouTube.LiveBroadcasts.get_broadcast/2`
- **Input**: `id = "bcast_101"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/liveBroadcasts?part=snippet%2Cstatus%2CcontentDetails&id=bcast_101`.
  - Responds HTTP 200 with `%{"kind" => "youtube#liveBroadcastListResponse", "items" => [%{"id" => "bcast_101", "snippet" => %{"title" => "AI Live Show"}}]}`.
- **Expected Outcome**:
  - Returns unwrapped broadcast item `{:ok, %{"id" => "bcast_101", "snippet" => %{"title" => "AI Live Show"}}}`.

#### Case `T1-F3-03`: List Live Broadcasts Filtered by Status
- **Target**: `Lux.Integrations.YouTube.LiveBroadcasts.list_broadcasts/2`
- **Input**: `params = [broadcast_status: :active, max_results: 10]`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/liveBroadcasts`.
  - Validates query params: `broadcastStatus=active`, `mine=true`, `maxResults=10`, `broadcastType=event`.
  - Responds HTTP 200 with list response containing 2 broadcast items.
- **Expected Outcome**:
  - Returns `{:ok, %{"items" => [_, _], "pageInfo" => %{"totalResults" => 2}}}`.

#### Case `T1-F3-04`: Update Live Broadcast Metadata
- **Target**: `Lux.Integrations.YouTube.LiveBroadcasts.update_broadcast/2`
- **Input**: `params = %{id: "bcast_101", title: "Updated Title", description: "Updated Desc"}`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `PUT /youtube/v3/liveBroadcasts?part=snippet%2Cstatus%2CcontentDetails`.
  - Validates JSON body: `%{"id" => "bcast_101", "snippet" => %{"title" => "Updated Title", "description" => "Updated Desc"}}`.
  - Responds HTTP 200 with updated broadcast resource.
- **Expected Outcome**:
  - Returns `{:ok, updated_broadcast}`.

#### Case `T1-F3-05`: Complete Broadcast Lifecycle Progression (Testing -> Live -> Complete) & Stream Binding
- **Target**: `LiveBroadcasts.bind_broadcast/3` and `LiveBroadcasts.transition_broadcast/3`
- **Input**: `broadcast_id = "bcast_101"`, `stream_id = "stream_202"`
- **Mock Setup (`YouTubeClientMock`)**:
  1. `POST /youtube/v3/liveBroadcasts/bind?id=bcast_101&streamId=stream_202&part=id%2Csnippet%2CcontentDetails%2Cstatus` -> Responds 200 with `contentDetails.boundStreamId = "stream_202"`.
  2. `POST /youtube/v3/liveBroadcasts/transition?broadcastStatus=testing&id=bcast_101&part=status%2Csnippet%2CcontentDetails` -> Responds 200 with `status.lifeCycleStatus = "testing"`.
  3. `POST /youtube/v3/liveBroadcasts/transition?broadcastStatus=live&id=bcast_101&part=status%2Csnippet%2CcontentDetails` -> Responds 200 with `status.lifeCycleStatus = "live"`.
  4. `POST /youtube/v3/liveBroadcasts/transition?broadcastStatus=complete&id=bcast_101&part=status%2Csnippet%2CcontentDetails` -> Responds 200 with `status.lifeCycleStatus = "complete"`.
- **Expected Outcome**:
  - All 4 API calls succeed in sequence.
  - `LiveBroadcasts.active?(live_bcast)` evaluates `true`.
  - `LiveBroadcasts.complete?(complete_bcast)` evaluates `true`.

---

### Feature 4: Live Stream Ingestion & Binding (`Lux.Integrations.YouTube.LiveStreams`)

#### Case `T1-F4-01`: Create RTMP Live Stream Ingestion Resource
- **Target**: `Lux.Integrations.YouTube.LiveStreams.create_stream/2`
- **Input**: `params = %{title: "Primary RTMP Ingest", ingestion_type: "rtmp", resolution: "1080p", frame_rate: "60fps", is_reusable: true}`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `POST /youtube/v3/liveStreams?part=snippet%2Ccdn%2Cstatus%2CcontentDetails`.
  - Validates JSON payload:
    - `snippet.title == "Primary RTMP Ingest"`
    - `cdn.ingestionType == "rtmp"`
    - `cdn.resolution == "1080p"`
    - `cdn.frameRate == "60fps"`
    - `contentDetails.isReusable == true`
  - Responds HTTP 200 with stream resource containing `cdn.ingestionInfo`:
    - `streamName = "live_key_secret_abc"`
    - `ingestionAddress = "rtmp://a.rtmp.youtube.com/live2"`
    - `backupIngestionAddress = "rtmp://b.rtmp.youtube.com/live2?backup=1"`
    - `rtmpsIngestionAddress = "rtmps://a.rtmps.youtube.com/live2"`
- **Expected Outcome**:
  - Returns `{:ok, stream}`.
  - `LiveStreams.stream_key(stream) == "live_key_secret_abc"`.
  - `LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"`.

#### Case `T1-F4-02`: Retrieve Live Stream by ID & Extract Stream URLs
- **Target**: `Lux.Integrations.YouTube.LiveStreams.get_stream/2` and `LiveStreams.stream_url/2`
- **Input**: `id = "stream_202"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/liveStreams?part=snippet%2Ccdn%2Cstatus%2CcontentDetails&id=stream_202`.
  - Responds HTTP 200 with `%{"items" => [stream_map]}`.
- **Expected Outcome**:
  - Returns unwrapped stream `{:ok, stream_map}`.
  - `LiveStreams.stream_url(stream_map, protocol: :rtmp)` returns `"rtmp://a.rtmp.youtube.com/live2/live_key_secret_abc"`.
  - `LiveStreams.stream_url(stream_map, protocol: :rtmps)` returns `"rtmps://a.rtmps.youtube.com/live2/live_key_secret_abc"`.
  - `LiveStreams.stream_url(stream_map, backup: true)` returns `"rtmp://b.rtmp.youtube.com/live2/live_key_secret_abc?backup=1"`.

#### Case `T1-F4-03`: List Live Streams for Authenticated Channel
- **Target**: `Lux.Integrations.YouTube.LiveStreams.list_streams/2`
- **Input**: `params = [mine: true, max_results: 5]`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/liveStreams?mine=true&maxResults=5&part=snippet%2Ccdn%2Cstatus%2CcontentDetails`.
  - Responds HTTP 200 with `%{"items" => [stream1, stream2], "nextPageToken" => "token_page_2"}`.
- **Expected Outcome**:
  - Returns `{:ok, response}` with list of 2 streams and pagination cursor.

#### Case `T1-F4-04`: Update Live Stream Settings
- **Target**: `Lux.Integrations.YouTube.LiveStreams.update_stream/2`
- **Input**: `params = %{id: "stream_202", title: "Updated Stream Title", resolution: "720p"}`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `PUT /youtube/v3/liveStreams?part=snippet%2Ccdn%2CcontentDetails`.
  - Validates JSON payload: `%{"id" => "stream_202", "snippet" => %{"title" => "Updated Stream Title"}, "cdn" => %{"resolution" => "720p"}}`.
  - Responds HTTP 200 with updated stream resource.
- **Expected Outcome**:
  - Returns `{:ok, updated_stream}`.

#### Case `T1-F4-05`: Delete Live Stream Resource
- **Target**: `Lux.Integrations.YouTube.LiveStreams.delete_stream/2`
- **Input**: `id = "stream_202"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `DELETE /youtube/v3/liveStreams?id=stream_202`.
  - Responds HTTP 204 No Content.
- **Expected Outcome**:
  - Returns `{:ok, %{id: "stream_202", deleted: true}}`.

---

### Feature 5: Live Chat Reading & Poller (`Lux.Integrations.YouTube.LiveChat`, `Poller`)

#### Case `T1-F5-01`: List Live Chat Messages with Normalization
- **Target**: `Lux.Integrations.YouTube.LiveChat.list_messages/2`
- **Input**: `live_chat_id = "chat_abc_123"`, `opts = [max_results: 50]`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/liveChat/messages?liveChatId=chat_abc_123&maxResults=50&part=snippet%2CauthorDetails`.
  - Responds HTTP 200 with raw YouTube JSON:
    - Items containing author details (`isChatOwner: true`, `isChatModerator: false`, `displayName: "AgentHost"`), snippet (`displayMessage: "Welcome to the stream!"`), `nextPageToken: "chat_page_2"`, `pollingIntervalMillis: 3000`.
- **Expected Outcome**:
  - Returns `{:ok, parsed}` where:
    - `length(parsed.messages) == 1`
    - `hd(parsed.messages).message_text == "Welcome to the stream!"`
    - `hd(parsed.messages).is_chat_owner == true`
    - `parsed.polling_interval_ms == 3000`
    - `parsed.next_page_token == "chat_page_2"`

#### Case `T1-F5-02`: Insert (Post) New Live Chat Message
- **Target**: `Lux.Integrations.YouTube.LiveChat.insert_message/3`
- **Input**: `live_chat_id = "chat_abc_123"`, `message_text = "Hello from Lux Agent!"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `POST /youtube/v3/liveChat/messages?part=snippet`.
  - Validates JSON payload:
    - `snippet.liveChatId == "chat_abc_123"`
    - `snippet.type == "textMessageEvent"`
    - `snippet.textMessageDetails.messageText == "Hello from Lux Agent!"`
  - Responds HTTP 200 with `%{"id" => "msg_new_999", "snippet" => %{"displayMessage" => "Hello from Lux Agent!"}}`.
- **Expected Outcome**:
  - Returns `{:ok, %{"id" => "msg_new_999", ...}}`.

#### Case `T1-F5-03`: Resolve `liveChatId` from Live Broadcast
- **Target**: `Lux.Integrations.YouTube.LiveChat.get_live_chat_id/2`
- **Input**: `broadcast_id = "bcast_101"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `GET /youtube/v3/liveBroadcasts?id=bcast_101&part=snippet`.
  - Responds HTTP 200 with `%{"items" => [%{"id" => "bcast_101", "snippet" => %{"liveChatId" => "chat_resolved_888"}}]}`.
- **Expected Outcome**:
  - Returns `{:ok, "chat_resolved_888"}`.

#### Case `T1-F5-04`: Poller GenServer Message Ingestion & Subscriber Notification
- **Target**: `Lux.Integrations.YouTube.LiveChat.Poller` (`start_link/1`, `poll_once/1`)
- **Setup**:
  - Start poller with `live_chat_id: "chat_poller_1"`, `auto_start: false`, `subscriber: self()`.
- **Mock Setup (`YouTubeClientMock`)**:
  - Call to `GET /youtube/v3/liveChat/messages?liveChatId=chat_poller_1...` responds HTTP 200 with 2 messages and `nextPageToken = "cursor_2"`.
- **Action**: `Poller.poll_once(poller_pid)`
- **Expected Outcome**:
  - Returns `{:ok, [msg1, msg2]}`.
  - Test process receives message `{:live_chat_messages, "chat_poller_1", [msg1, msg2]}`.
  - `Poller.get_status(poller_pid).page_token == "cursor_2"`.
  - `Poller.get_status(poller_pid).message_count == 2`.

#### Case `T1-F5-05`: Poller Dynamic Polling Interval Adjustment
- **Target**: `Lux.Integrations.YouTube.LiveChat.Poller`
- **Setup**: Start poller with `default_interval_ms: 5000`, `min_interval_ms: 1000`, `max_interval_ms: 30000`, `auto_start: false`.
- **Mock Setup (`YouTubeClientMock`)**:
  - Responds HTTP 200 with `pollingIntervalMillis: 8500`.
- **Action**: `Poller.poll_once(poller_pid)`
- **Expected Outcome**:
  - `Poller.get_status(poller_pid).interval_ms == 8500`.

---

### Feature 6: Quota/Rate Limiting & Lenses/Prisms Execution (`Lux.Integrations.YouTube.Errors`, `Lux.Integrations.YouTube`)

#### Case `T1-F6-01`: HTTP 403 `quotaExceeded` Parsing & Classification
- **Target**: `Lux.Integrations.YouTube.Errors.parse/3` and `Errors.quota_exceeded?/1`
- **Input**:
  - Status: 403
  - Body: `%{"error" => %{"code" => 403, "message" => "Quota Exceeded", "errors" => [%{"domain" => "youtube.quota", "reason" => "quotaExceeded", "message" => "Quota Exceeded"}]}}`
- **Expected Outcome**:
  - Returns `{:error, {:quota_exceeded, details}}` where `details.reason == "quotaExceeded"` and `details.status == 403`.
  - `Errors.quota_exceeded?({:error, {:quota_exceeded, details}}) == true`.
  - `Errors.retryable?({:error, {:quota_exceeded, details}}) == false`.

#### Case `T1-F6-02`: HTTP 429 / 403 `userRateLimitExceeded` with `Retry-After` Header
- **Target**: `Lux.Integrations.YouTube.Errors.parse/3` and `Errors.rate_limited?/1`
- **Input**:
  - Status: 403
  - Body: `%{"error" => %{"errors" => [%{"reason" => "userRateLimitExceeded"}]}}`
  - Headers: `[{"retry-after", "10"}]`
- **Expected Outcome**:
  - Returns `{:error, {:rate_limited, details}}` where `details.retry_after == 10`.
  - `Errors.rate_limited?({:error, {:rate_limited, details}}) == true`.
  - `Errors.retryable?({:error, {:rate_limited, details}}) == true`.

#### Case `T1-F6-03`: `with_retry/2` Backoff Execution on Transient Failures
- **Target**: `Lux.Integrations.YouTube.Errors.with_retry/2`
- **Setup**: Function fails twice with `{:error, {:rate_limited, %{retry_after: 0}}}` and succeeds on third attempt with `{:ok, :recovered}`. Custom `sleep_fun` records invoked delays.
- **Expected Outcome**:
  - Retries 2 times and returns `{:ok, :recovered}`.
  - Sleep function recorded 2 backoff delays.

#### Case `T1-F6-04`: `Lux.Integrations.YouTube.add_auth_header/1` Lens Integration
- **Target**: `Lux.Integrations.YouTube.add_auth_header/1`
- **Setup**: `Application.put_env(:lux, :api_keys, youtube_access_token: "lens_token_abc")`
- **Input**: `%Lux.Lens{name: "YouTubeLens", url: "https://www.googleapis.com/youtube/v3/videos", headers: [{"x-agent", "1"}]}`
- **Expected Outcome**:
  - Injects `{"Authorization", "Bearer lens_token_abc"}` into `lens.headers` while preserving `{"x-agent", "1"}`.

#### Case `T1-F6-05`: Custom Auth & Request Settings in Lens Workflow
- **Target**: `Lux.Integrations.YouTube.request_settings/0`
- **Expected Outcome**:
  - `settings.headers` contains `{"Content-Type", "application/json"}` and `{"Accept", "application/json"}`.
  - `settings.auth.type == :custom`.
  - `settings.auth.auth_function` is `&Lux.Integrations.YouTube.add_auth_header/1`.

---

## 4. Tier 2: Boundary & Corner Case Test Cases (30 Cases)

### Feature 1: OAuth 2.0 Boundary & Corner Cases

#### Case `T2-F1-01`: Missing Credentials in `exchange_code/2`
- **Target**: `Lux.Integrations.YouTube.OAuth.exchange_code/2`
- **Setup**: Clear application config for client_id and client_secret.
- **Input**: `code = "any_code"`, `opts = [client_id: "", client_secret: nil]`
- **Expected Outcome**:
  - Returns `{:error, :missing_credentials}` immediately without executing any HTTP request.

#### Case `T2-F1-02`: Missing Refresh Token or Credentials in `refresh_token/2`
- **Target**: `Lux.Integrations.YouTube.OAuth.refresh_token/2`
- **Setup**: Clear application config.
- **Input**: `refresh_token = "valid_refresh_token"`, `opts = [client_id: nil, client_secret: ""]`
- **Expected Outcome**:
  - Returns `{:error, :missing_credentials}` without network call.

#### Case `T2-F1-03`: OAuth Endpoint Returning HTTP 400 with `invalid_grant` Payload
- **Target**: `Lux.Integrations.YouTube.OAuth.exchange_code/2`
- **Mock Setup (`YouTubeOAuthMock`)**:
  - Responds HTTP 400 with `%{"error" => "invalid_grant", "error_description" => "Code was already redeemed or expired."}`.
- **Expected Outcome**:
  - Returns structured tuple `{:error, {:oauth_error, "invalid_grant", "Code was already redeemed or expired."}}`.

#### Case `T2-F1-04`: `authorize_url/1` with URI-Unsafe Special Characters in State & Scopes
- **Target**: `Lux.Integrations.YouTube.OAuth.authorize_url/1`
- **Input**: `opts = %{client_id: "cid", state: "csrf&secret=1+2 3/4?foo=bar", login_hint: "user+tag@domain.com"}`
- **Expected Outcome**:
  - Returns valid, properly percent-encoded URI where special characters in `state` and `login_hint` do not break query string parsing.
  - `URI.decode_query(URI.parse(url).query)["state"] == "csrf&secret=1+2 3/4?foo=bar"`.

#### Case `T2-F1-05`: OAuth Endpoint Returning Non-JSON HTML Error Page
- **Target**: `Lux.Integrations.YouTube.OAuth.refresh_token/2`
- **Mock Setup (`YouTubeOAuthMock`)**:
  - Responds HTTP 502 with HTML body `"<html><title>502 Bad Gateway</title><body>Gateway timeout</body></html>"` and content-type `"text/html"`.
- **Expected Outcome**:
  - Returns `{:error, {502, "<html><title>502 Bad Gateway</title><body>Gateway timeout</body></html>"}}` without crashing Jason decoder.

---

### Feature 2: Client Boundary & Corner Cases

#### Case `T2-F2-01`: 401 Auto-Refresh Infinite Loop Prevention
- **Target**: `Lux.Integrations.YouTube.Client.request/3`
- **Setup**: `opts = [token: "bad_token", refresh_token: "expired_refresh", auto_refresh: true]`
- **Mock Setup (`YouTubeClientMock` and `YouTubeOAuthMock`)**:
  - Call 1: `GET /youtube/v3/liveBroadcasts` responds HTTP 401.
  - Call 2: `OAuth.refresh_token` responds HTTP 400 `%{"error" => "invalid_grant"}`.
- **Expected Outcome**:
  - Refresh failure halts retry immediately.
  - Returns `{:error, :invalid_token}` without looping or infinite retries.

#### Case `T2-F2-02`: Client Handling Network Transport Error / Disconnection
- **Target**: `Lux.Integrations.YouTube.Client.get/2`
- **Mock Setup (`YouTubeClientMock`)**:
  - Raises/returns `{:error, %Req.TransportError{reason: :econnrefused}}`.
- **Expected Outcome**:
  - Returns `{:error, %Req.TransportError{reason: :econnrefused}}` gracefully.
  - `Errors.retryable?({:error, %Req.TransportError{reason: :econnrefused}}) == true`.

#### Case `T2-F2-03`: Client Path Normalization with Empty, Slash-less, and Absolute URLs
- **Target**: `Lux.Integrations.YouTube.Client.get/2`
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects correctly formed URL for paths `""`, `"liveBroadcasts"`, `"/liveBroadcasts"`, `"https://www.googleapis.com/youtube/v3/liveBroadcasts"`.
- **Expected Outcome**:
  - All 4 variations resolve to the exact expected absolute endpoint without double-slashes (`//`) or malformed paths.

#### Case `T2-F2-04`: Client Receiving HTTP 500 / 503 Internal Server Error with HTML Body
- **Target**: `Lux.Integrations.YouTube.Client.post/2`
- **Mock Setup (`YouTubeClientMock`)**:
  - Responds HTTP 503 with `"Backend server unavailable"`.
- **Expected Outcome**:
  - Returns `{:error, {503, "Service Unavailable"}}` (or string message) without raising JSON decode exception.
  - `Errors.retryable?({:error, {503, "Service Unavailable"}}) == true`.

#### Case `T2-F2-05`: Client Request with Deep Nested Map and Unicode Ingestion Data
- **Target**: `Lux.Integrations.YouTube.Client.post/2`
- **Input**: Payload with emojis, UTF-8 non-ASCII characters (`"Transmisión en vivo 🎥 日本語"`), and 5 levels of nesting.
- **Mock Setup (`YouTubeClientMock`)**:
  - Validates JSON payload preserved and decoded identically.
  - Responds HTTP 200 with echoed data.
- **Expected Outcome**:
  - Returns `{:ok, body}` without UTF-8 encoding distortion.

---

### Feature 3: Live Broadcasts Boundary & Corner Cases

#### Case `T2-F3-01`: Non-Existent Broadcast ID Returning `{:error, :not_found}`
- **Target**: `Lux.Integrations.YouTube.LiveBroadcasts.get_broadcast/2`
- **Input**: `id = "non_existent_bcast_id"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Responds HTTP 200 with `%{"kind" => "youtube#liveBroadcastListResponse", "items" => []}`.
- **Expected Outcome**:
  - Returns `{:error, :not_found}` instead of `{:ok, nil}` or raising exception.

#### Case `T2-F3-02`: Invalid Transition Target Status Validation
- **Target**: `Lux.Integrations.YouTube.LiveBroadcasts.transition_broadcast/3`
- **Input**: `broadcast_id = "bcast_1"`, `status = :invalid_status` (or `"paused"`, `""`, `nil`)
- **Mock Setup**: No HTTP expectations set (must NOT hit network).
- **Expected Outcome**:
  - Immediately returns `{:error, {:invalid_transition_status, :invalid_status}}`.

#### Case `T2-F3-03`: Missing or Blank Broadcast ID Across All LiveBroadcasts Functions
- **Target**: `LiveBroadcasts.get_broadcast/2`, `update_broadcast/2`, `delete_broadcast/2`, `transition_broadcast/3`, `bind_broadcast/3`
- **Input**: `broadcast_id = ""` or `nil` or `12345`
- **Expected Outcome**:
  - All 5 functions return `{:error, :missing_broadcast_id}` without executing HTTP requests.

#### Case `T2-F3-04`: Broadcast Unbinding with `stream_id: nil` or `""`
- **Target**: `Lux.Integrations.YouTube.LiveBroadcasts.bind_broadcast/3`
- **Input**: `broadcast_id = "bcast_101"`, `stream_id = nil` (or `""`)
- **Mock Setup (`YouTubeClientMock`)**:
  - Expects `POST /youtube/v3/liveBroadcasts/bind?id=bcast_101&part=id%2Csnippet%2CcontentDetails%2Cstatus`.
  - Validates `streamId` query parameter is NOT present.
  - Responds HTTP 200 with unbound broadcast (`boundStreamId: nil`).
- **Expected Outcome**:
  - Returns `{:ok, unbound_broadcast}`.
  - `LiveBroadcasts.bound_stream_id(unbound_broadcast) == nil`.

#### Case `T2-F3-05`: Live Broadcast Status Helper Resilience on Nil/Empty/Malformed Maps
- **Target**: `LiveBroadcasts.status/1`, `live_chat_id/1`, `bound_stream_id/1`, `active?/1`, `testing?/1`, `complete?/1`, `upcoming?/1`, `broadcast_url/1`
- **Input**: `nil`, `%{}` , `%{"status" => nil}`, `%{"contentDetails" => "malformed_string"}`
- **Expected Outcome**:
  - Accessors return `nil` or `false` safely without raising `KeyError` or `FunctionClauseError`.

---

### Feature 4: Live Streams Boundary & Corner Cases

#### Case `T2-F4-01`: Non-Existent Live Stream ID Returning `{:error, :not_found}`
- **Target**: `Lux.Integrations.YouTube.LiveStreams.get_stream/2`
- **Input**: `id = "missing_stream_id"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Responds HTTP 200 with `%{"kind" => "youtube#liveStreamListResponse", "items" => []}`.
- **Expected Outcome**:
  - Returns `{:error, :not_found}`.

#### Case `T2-F4-02`: Missing or Blank Stream ID Across LiveStreams Functions
- **Target**: `LiveStreams.get_stream/2`, `update_stream/2`, `delete_stream/2`
- **Input**: `id = ""` or `nil`
- **Expected Outcome**:
  - All 3 functions return `{:error, :missing_stream_id}` immediately.

#### Case `T2-F4-03`: `stream_url/2` Handling Ingestion Addresses with Query Parameters & Trailing Slashes
- **Target**: `Lux.Integrations.YouTube.LiveStreams.stream_url/2`
- **Input**:
  - Stream with `ingestionAddress: "rtmp://b.rtmp.youtube.com/live2?backup=1&param=2/"`, `streamName: "my_key"`
- **Expected Outcome**:
  - Correctly constructs `"rtmp://b.rtmp.youtube.com/live2/my_key?backup=1&param=2"`.
  - Places stream key before query parameters without double slash.

#### Case `T2-F4-04`: Stream Ingestion & Status Accessor Resilience on Malformed Data
- **Target**: `LiveStreams.stream_key/1`, `ingestion_address/1`, `stream_status/1`, `health_status/1`
- **Input**: `nil`, `%{}`, `%{"cdn" => nil}`, `%{"status" => %{"healthStatus" => nil}}`
- **Expected Outcome**:
  - Returns `nil` without raising exceptions.

#### Case `T2-F4-05`: Stream Creation Receiving HTTP 400 Bad Request Payload
- **Target**: `Lux.Integrations.YouTube.LiveStreams.create_stream/2`
- **Mock Setup (`YouTubeClientMock`)**:
  - Responds HTTP 400 with `%{"error" => %{"code" => 400, "message" => "Invalid ingestion type: webm", "errors" => [%{"reason" => "invalidIngestionType"}]}}`.
- **Expected Outcome**:
  - Returns `{:error, {400, "Invalid ingestion type: webm"}}`.

---

### Feature 5: Live Chat Boundary & Corner Cases

#### Case `T2-F5-01`: Missing or Blank `live_chat_id` in `list_messages/2`
- **Target**: `Lux.Integrations.YouTube.LiveChat.list_messages/2`
- **Input**: `live_chat_id = ""` (or `nil` or `:atom`)
- **Expected Outcome**:
  - Returns `{:error, :missing_live_chat_id}` without making network call.

#### Case `T2-F5-02`: Missing or Blank Message Text / Chat ID in `insert_message/3`
- **Target**: `Lux.Integrations.YouTube.LiveChat.insert_message/3`
- **Input 1**: `live_chat_id = "chat1"`, `message_text = ""`
- **Input 2**: `live_chat_id = ""`, `message_text = "Hello"`
- **Expected Outcome**:
  - Input 1 returns `{:error, :empty_message_text}`.
  - Input 2 returns `{:error, :missing_live_chat_id}`.
  - Zero network calls made.

#### Case `T2-F5-03`: `get_live_chat_id/2` When Chat is Disabled on Broadcast
- **Target**: `Lux.Integrations.YouTube.LiveChat.get_live_chat_id/2`
- **Input**: `broadcast_id = "bcast_no_chat"`
- **Mock Setup (`YouTubeClientMock`)**:
  - Responds HTTP 200 with broadcast item having `snippet.liveChatId = nil` (chat disabled or completed).
- **Expected Outcome**:
  - Returns `{:error, :no_live_chat_id}`.

#### Case `T2-F5-04`: Poller Handling Broadcast Termination Signal (`offlineAt` & HTTP 404)
- **Target**: `Lux.Integrations.YouTube.LiveChat.Poller`
- **Setup**: Start poller with subscriber `self()`, `auto_start: false`.
- **Mock Setup (`YouTubeClientMock`)**:
  - Call 1: Responds HTTP 200 with `offlineAt: "2026-08-20T22:00:00Z"`, `messages: []`.
- **Action**: `Poller.poll_once(poller_pid)`
- **Expected Outcome**:
  - Test process receives `{:live_chat_ended, "chat_id", %{offline_at: "2026-08-20T22:00:00Z"}}`.
  - `Poller.get_status(poller_pid).status == :ended`.
  - `Poller.get_status(poller_pid).offline_at == "2026-08-20T22:00:00Z"`.

#### Case `T2-F5-05`: Poller Dead Subscriber Cleanup via Process Monitor
- **Target**: `Lux.Integrations.YouTube.LiveChat.Poller`
- **Setup**:
  - Spawn temporary subscriber process, subscribe to poller, verify subscriber count is 1.
  - Terminate subscriber process (`Process.exit(temp_pid, :kill)`).
- **Expected Outcome**:
  - Poller handles `:DOWN` monitor message and removes PID from `subscribers` set.
  - `Poller.get_status(poller_pid).subscribers_count == 0`.
  - Poller continues running normally without crashing.

---

### Feature 6: Quota/Rate Limiting Boundary & Corner Cases

#### Case `T2-F6-01`: Quota Exhaustion Extraction from Varied Google Error Formats
- **Target**: `Lux.Integrations.YouTube.Errors.parse/3`
- **Input Variations**:
  - Top-level `error: "QUOTA_EXCEEDED"`
  - Nested `error.details: [%{"reason" => "dailyLimitExceeded"}]`
  - Raw JSON string body with `RESOURCE_EXHAUSTED`
- **Expected Outcome**:
  - All variations correctly extract reason and map to `{:error, {:quota_exceeded, details}}`.

#### Case `T2-F6-02`: Rate Limit Parsing with Malformed, Negative, or Absent `Retry-After` Header
- **Target**: `Lux.Integrations.YouTube.Errors.parse/3`
- **Input 1**: Headers `[{"retry-after", "-5"}]`
- **Input 2**: Headers `[{"retry-after", "invalid_seconds"}]`
- **Input 3**: Headers `[]`
- **Expected Outcome**:
  - In all 3 cases, `details.retry_after == nil`.
  - Still correctly classifies error as `{:error, {:rate_limited, details}}`.

#### Case `T2-F6-03`: `with_retry/2` Max Retries Exhaustion on Persistent 503
- **Target**: `Lux.Integrations.YouTube.Errors.with_retry/2`
- **Setup**: Function consistently returns `{:error, {503, "Service Unavailable"}}`, `max_retries: 3`.
- **Expected Outcome**:
  - Retries exactly 3 times (4 total invocations).
  - Returns final `{:error, {503, "Service Unavailable"}}`.

#### Case `T2-F6-04`: `with_retry/2` Immediate Non-Retry on Non-Retryable 400 & 403 Quota
- **Target**: `Lux.Integrations.YouTube.Errors.with_retry/2`
- **Setup**: Function returns `{:error, {:quota_exceeded, %{reason: "quotaExceeded"}}}`.
- **Expected Outcome**:
  - Invokes function exactly once (0 retries).
  - Returns `{:error, {:quota_exceeded, _}}` immediately.

#### Case `T2-F6-05`: `add_auth_header/1` Preservation of Pre-existing Lens Params and Headers
- **Target**: `Lux.Integrations.YouTube.add_auth_header/1`
- **Setup**: Clear token, set API key `"api_k_123"`.
- **Input**: `%Lux.Lens{params: %{part: "snippet", key: "existing_key"}, headers: [{"authorization", "CustomAuth"}]}`
- **Expected Outcome**:
  - Does NOT overwrite existing `key: "existing_key"` param or duplicate authorization headers.

---

## 5. Implementation Roadmap & Test File Structure

The proposed implementation file `test/e2e/youtube_integration_e2e_test.exs` should be structured as follows:

```elixir
defmodule Lux.E2E.YouTubeIntegrationE2ETest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube
  alias Lux.Integrations.YouTube.{Client, Errors, LiveBroadcasts, LiveChat, LiveStreams, OAuth}
  alias Lux.Integrations.YouTube.LiveChat.Poller

  setup do
    Req.Test.verify_on_exit!()
    orig_keys = Application.get_env(:lux, :api_keys, [])
    on_exit(fn ->
      Application.put_env(:lux, :api_keys, orig_keys)
    end)
    :ok
  end

  # ==========================================
  # TIER 1: FEATURE COVERAGE (T1-F1 to T1-F6)
  # ==========================================
  describe "Tier 1: Feature 1 - OAuth 2.0 Flow & Token Refresh" do ... end
  describe "Tier 1: Feature 2 - YouTube API Client & Error Handling" do ... end
  describe "Tier 1: Feature 3 - Live Broadcast Lifecycle & Management" do ... end
  describe "Tier 1: Feature 4 - Live Stream Ingestion & Binding" do ... end
  describe "Tier 1: Feature 5 - Live Chat Reading & Poller Pagination" do ... end
  describe "Tier 1: Feature 6 - Quota/Rate Limiting & Lenses/Prisms Execution" do ... end

  # ==========================================
  # TIER 2: BOUNDARY & CORNER CASES (T2-F1 to T2-F6)
  # ==========================================
  describe "Tier 2: Feature 1 - OAuth 2.0 Boundary Cases" do ... end
  describe "Tier 2: Feature 2 - Client Boundary & Error Resilience" do ... end
  describe "Tier 2: Feature 3 - Live Broadcast Boundary & Transition Errors" do ... end
  describe "Tier 2: Feature 4 - Live Stream Boundary & URL Formatting" do ... end
  describe "Tier 2: Feature 5 - Live Chat Boundary & Poller Resilience" do ... end
  describe "Tier 2: Feature 6 - Quota/Rate Limit Boundary & Non-Retry Logic" do ... end
end
```

---

## 6. Verification and Validation Method
1. **Compilation & Warning Check**:
   ```bash
   mix compile --warnings-as-errors
   ```
2. **Unit & E2E Test Suite Execution**:
   ```bash
   mix test test/e2e/youtube_integration_e2e_test.exs
   ```
3. **Full Test Suite & Coverage**:
   ```bash
   mix test
   mix coveralls
   ```
   Ensures >90% code coverage across all YouTube modules without network dependencies.
