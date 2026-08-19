# Adversarial Challenge Report — Milestone 5 Remediation (YouTube Integration)

## Challenge Summary

**Overall risk assessment**: LOW
**Verdict**: CONFIRMED

The YouTube integration components (`Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube.OAuth`, `Lux.Integrations.YouTube.LiveChat`, `Lux.Integrations.YouTube.LiveChat.Poller`, and `Lux.Integrations.YouTube.Errors`) and test suites (`test/e2e/youtube_integration_e2e_test.exs`, `test/unit/lux/integrations/youtube/`) were subjected to adversarial stress testing and boundary condition fuzzing. All components proved resilient against concurrency races, subscriber crashes, handler exceptions, token refresh loop recursion, rate limiting throttles, and malformed/HTML error payloads.

---

## Adversarial Challenge Dimensions & Empirical Verification Results

### 1. Poller Concurrency, Mock Isolation, and Crash Resilience

- **Assumption tested**: Multiple poller instances running concurrently do not suffer from mock cross-talk, race conditions, or state leakage.
  - **Empirical test**: Spawned 20 concurrent Poller instances querying different live chat IDs simultaneously via `Task.async_stream` / `Task.await_many`.
  - **Result**: PASSED. Each Poller process maintained isolated state, pagination cursors, and metrics.
- **Assumption tested**: Poller GenServer survives massive unexpected subscriber deaths without crashing or leaking monitor references.
  - **Empirical test**: Subscribed 50 processes to a single Poller instance, then brutally terminated 45 processes (`Process.exit(pid, :kill)`).
  - **Result**: PASSED. Poller correctly handled `:DOWN` messages, pruned terminated pids from `subscribers` MapSet and `monitors` map (subscribers_count went from 50 to 5), remained alive, and reliably dispatched new messages to the surviving subscribers.
- **Assumption tested**: Hostile or broken handler callbacks (`handler_fn`) do not crash the Poller GenServer.
  - **Empirical test**: Tested handler callbacks raising 1-arity `RuntimeError`, 2-arity `ArithmeticError` (`:erlang.error(:badarith)`), MFA targeting non-existent modules (`UndefinedFunctionError`), and invalid handler term types.
  - **Result**: PASSED. All exceptions were caught and logged via `Logger.warning`; Poller GenServer continued uninterrupted.

### 2. Dynamic Polling Interval Adjustments & Stream Lifecycle

- **Assumption tested**: Dynamic `pollingIntervalMillis` returned by YouTube Data API v3 is strictly clamped to configured min and max bounds.
  - **Empirical test**: Injected API responses with intervals of 200 ms (below 1000 ms min limit), 999,999 ms (above 10,000 ms max limit), and 4,500 ms (in-bounds).
  - **Result**: PASSED. Poller clamped interval to 1,000 ms, 10,000 ms, and 4,500 ms respectively.
- **Assumption tested**: Stream termination signals (`offlineAt` and HTTP 404) transition Poller to `:ended` status and broadcast termination events.
  - **Empirical test**: Injected response with `offlineAt: "2026-08-18T23:59:59Z"` and 404 response with `liveChatEnded` error reason.
  - **Result**: PASSED. Poller transitioned to `:ended` and broadcasted `{:live_chat_ended, id, %{offline_at: ...}}` and `{:live_chat_ended, id, {404, ...}}`.
- **Assumption tested**: Transient errors (503 Service Unavailable) trigger backoff and increment consecutive errors, and subsequent success resets error state.
  - **Empirical test**: Fired 3 consecutive 503 errors followed by a 200 OK success.
  - **Result**: PASSED. `consecutive_errors` incremented to 3 with `{:live_chat_error, ...}` broadcasts; on the 4th poll, `consecutive_errors` reset to 0, `last_error` cleared to nil, and interval restored.

### 3. 401 Token Refresh Loop Boundaries & Multi-Process Mock Sharing

- **Assumption tested**: Client handles 401 Unauthorized by attempting a single OAuth refresh, retrying the request with the new access token, and terminating without infinite recursion if the second request also fails with 401.
  - **Empirical test**: 
    1. Single 401 followed by successful refresh: Client retried request with new access token in `authorization: Bearer <new_token>` and succeeded.
    2. Double 401 (refreshed token also gets 401): Client terminated after `retry_count < 1` check and returned `{:error, :invalid_token}` without invoking OAuth again.
    3. 401 with failing OAuth refresh (e.g. HTTP 400 `invalid_grant` / revoked token): Gracefully returned `{:error, :invalid_token}`.
    4. `auto_refresh: false`: Immediately returned `{:error, :invalid_token}` without calling OAuth.
  - **Result**: PASSED.
- **Assumption tested**: Concurrent requests across multiple processes sharing `Req.Test` mocks do not produce race conditions during 401 refresh.
  - **Empirical test**: Spawned 10 concurrent processes all encountering 401s simultaneously using `Req.Test.set_req_test_to_shared`.
  - **Result**: PASSED. All 10 processes successfully refreshed and executed requests.

### 4. Malformed API Payloads & Edge-Case Error Bodies

- **Assumption tested**: `Errors.parse/3` and `LiveChat.normalize_message/1` handle non-JSON, gateway HTML, empty, or corrupt payloads without throwing exceptions.
  - **Empirical test**:
    - Cloudflare / nginx HTML 502/503 error pages -> returned `{:error, {502, ...}}` and marked retryable.
    - Raw string bodies in 400/403/429/500 responses -> returned structured tuples preserving status and message.
    - Malformed `Retry-After` headers (floats, negative ints, lists, unparseable strings) -> handled safely returning integer or nil.
    - Sparse / malformed message items (empty map, superchat with string micros, non-map inputs) -> normalized cleanly with safe default booleans.
  - **Result**: PASSED.

---

## Verification Test Commands & Summary

| Command | Status | Result |
|---------|--------|--------|
| `mix compile --warnings-as-errors` | PASSED | 0 warnings, 0 errors |
| `mix test test/e2e/youtube_integration_e2e_test.exs` | PASSED | 75 tests, 0 failures |
| `mix test` | PASSED | 1 doctest, 4 properties, 1841 tests, 0 failures, 1697 excluded |
| `mix test --include unit test/unit/lux/integrations/youtube/` | PASSED | 479 tests, 0 failures |

## Unchallenged Areas

- Live YouTube API network latency and Google production infrastructure quirks (out of scope under offline test mode).
