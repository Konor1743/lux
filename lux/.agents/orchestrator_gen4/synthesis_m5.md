# Milestone 5 Test Plan Synthesis

## Synthesis Overview
Milestone 5 executes the full end-to-end testing suite (Tiers 1-4) in `test/e2e/youtube_integration_e2e_test.exs` and prepares `TEST_READY.md`.

## Test Matrix Breakdown

### Tier 1: Feature Coverage (30 test cases, 5 per feature)
- **F1 (OAuth)**:
  1. `authorize_url/1` generates correct Google OAuth2 URL with default and custom scopes (`youtube.force-ssl`).
  2. `authorize_url/1` includes state, access_type=offline, and prompt=consent when requested.
  3. `exchange_code/2` exchanges authorization code for access_token, refresh_token, expires_in.
  4. `refresh_token/2` refreshes expired token with new access_token.
  5. `exchange_code/2` parses token response with custom client credentials.
- **F2 (Client & Auth Injection)**:
  6. `request/3` GET request sends Authorization header and query params.
  7. `request/3` POST request encodes JSON body and sends Content-Type application/json.
  8. `request/3` PUT and DELETE methods execute correctly.
  9. `request/3` performs automatic token refresh on 401 when refresh_token is present.
  10. `request/3` returns structured `{:error, {:http_error, status, body}}` on standard errors.
- **F3 (Live Broadcasts)**:
  11. `create_broadcast/2` creates broadcast with title, scheduled start time, and privacy status.
  12. `get_broadcast/2` retrieves single broadcast by ID.
  13. `list_broadcasts/2` lists broadcasts with mine=true and broadcastStatus filter.
  14. `update_broadcast/2` updates broadcast title, description, or status.
  15. `transition_broadcast/3` transitions broadcast through testing, live, and complete states.
- **F4 (Live Streams)**:
  16. `create_stream/2` creates stream with ingestionType rtmp and resolution 1080p.
  17. `get_stream/2` retrieves stream by ID with ingestionAddress and streamName.
  18. `list_streams/2` lists user's active/created streams.
  19. `delete_stream/2` deletes an existing stream.
  20. `bind_broadcast/3` binds live stream ID to broadcast ID.
- **F5 (Live Chat & Poller)**:
  21. `list_messages/2` fetches live chat messages for given liveChatId.
  22. `list_messages/2` returns nextPageToken and pollingIntervalMillis.
  23. `insert_message/3` posts text message to live chat.
  24. `Poller` starts and emits messages to target process.
  25. `Poller` respects polling interval and updates pagination tokens.
- **F6 (Errors, Resiliency, Lenses & Prisms)**:
  26. Client maps HTTP 403 `quotaExceeded` to `{:error, {:quota_exceeded, details}}`.
  27. Client maps HTTP 429 to `{:error, {:rate_limited, details}}`.
  28. `ListBroadcastsLens` fetches and validates broadcast data via Lens schema.
  29. `GetChatMessagesLens` fetches live chat messages via Lens schema.
  30. `CreateBroadcastPrism` and `SendMessagePrism` execute and return structured output via Prism schema.

### Tier 2: Boundary & Corner Cases (30 test cases, 5 per feature)
- **F1 (OAuth Boundaries)**:
  31. Empty/missing client ID or secret in OAuth functions returns structured error.
  32. Invalid/expired authorization code on exchange returns `{:error, :invalid_grant}`.
  33. Revoked refresh token returns `{:error, :invalid_grant}`.
  34. OAuth endpoint returning malformed/empty JSON body is gracefully handled.
  35. Non-200 HTTP response codes from token endpoint map to error tuples.
- **F2 (Client Boundaries)**:
  36. 401 response without refresh_token returns `{:error, :unauthorized}` without infinite refresh loop.
  37. 401 response with failing refresh token fails gracefully.
  38. Empty response body on 204 No Content is handled cleanly (`{:ok, %{}}`).
  39. Network/transport failure (connection refused / timeout) returns structured error tuple.
  40. Malformed JSON payload returned from API returns `{:error, :invalid_json}`.
- **F3 (Broadcast Boundaries)**:
  41. Creating broadcast with missing mandatory snippet returns validation error.
  42. Fetching non-existent broadcast ID (HTTP 404) returns `{:error, :not_found}`.
  43. Invalid lifecycle transition (e.g. complete -> live) returns YouTube error.
  44. Large batch list pagination with maxResults=50 boundary.
  45. Empty broadcast list returns `{:ok, %{items: [], ...}}`.
- **F4 (Stream Boundaries)**:
  46. Creating stream with invalid frameRate or resolution returns validation error.
  47. Deleting non-existent stream ID (404) returns appropriate error.
  48. Binding invalid stream ID to broadcast returns YouTube error.
  49. List streams with invalid page token returns error.
  50. Stream response missing CDN ingestion fields handled safely.
- **F5 (Chat & Poller Boundaries)**:
  51. Polling chat with inactive/closed liveChatId handles 404/403 gracefully.
  52. Polling chat with 0 new messages does not emit empty message events.
  53. Chat message insertion with text exceeding max character limit handled.
  54. Poller process termination during active poll cleans up without crashing parent.
  55. Rapid consecutive polls respect minimum pollingIntervalMillis constraint.
- **F6 (Resiliency & Lenses/Prisms Boundaries)**:
  56. Quota exceeded during Lens execution returns structured error in lens result.
  57. Rate limit exceeded during Prism execution triggers exponential backoff retry.
  58. Prism validation failure on invalid input parameters before HTTP call.
  59. Lens timeout on slow response returns error tuple without crashing process.
  60. Concurrent Prism executions with distinct credentials remain isolated.

### Tier 3: Cross-Feature Combinations (8 test cases)
- 61. **F1 + F2**: OAuth code exchange -> Client API request with automatic 401 token refresh on expiry.
- 62. **F3 + F4**: Create stream -> Create broadcast -> Bind stream to broadcast -> Verify bound status.
- 63. **F3 + F5**: Create broadcast -> Transition to live -> Extract liveChatId -> Start chat poller.
- 64. **F4 + F5**: Stream creation with CDN settings + Live chat poller emitting chat events concurrently.
- 65. **F5 + F6**: LiveChat poller encountering 403 quota exhaustion, applying backoff, and resuming.
- 66. **F2 + F6**: Client request encountering 429 rate limit, using `with_backoff/2` to retry and succeed.
- 67. **F3 + F6**: `ListBroadcastsLens` feeds into `CreateBroadcastPrism` with quota error handling.
- 68. **F5 + F6**: `GetChatMessagesLens` feeds into `SendMessagePrism` with token refresh.

### Tier 4: Real-World Application Scenarios (5 multi-step workflows)
- 69. **Scenario 1 - Complete Live Production Workflow**:
  Create Stream -> Create Broadcast -> Bind -> Transition to Testing -> Transition to Live -> Chat Polling & Interaction -> Transition to Complete.
- 70. **Scenario 2 - Autonomous AI Live Moderator & Chat Bot**:
  Start Broadcast -> Poller streams chat -> Agent detects "!help" / "!status" command -> Agent uses `SendMessagePrism` to reply in live chat -> Poller gracefully stops.
- 71. **Scenario 3 - Live Session Resilient Token Rotation**:
  Active live stream session where access token expires mid-stream across multiple API calls (broadcast update, stream status check, chat post) -> Transparent OAuth token refresh on every 401 without stream interruption.
- 72. **Scenario 4 - Peak Traffic Quota & Rate Limit Degradation & Recovery**:
  High-volume chat traffic with burst requests triggering HTTP 429 rate limits and temporary 403 quota errors -> System applies exponential jitter backoff, buffers messages, and recovers once limits reset.
- 73. **Scenario 5 - Full Autonomous Lux Agent Orchestration**:
  Lux Agent initialized with YouTube Lenses and Prisms -> Queries broadcast state via Lens -> Evaluates streaming health -> Generates live announcement via Prism -> Verifies final state.

Total Count: 73 E2E test cases across Tiers 1-4!
