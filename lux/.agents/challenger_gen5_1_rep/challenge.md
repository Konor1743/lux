# Adversarial Challenge Report — Milestone 5 Remediation (YouTube Integration)

## Challenge Summary

**Overall risk assessment**: LOW

Empirical adversarial testing was conducted against the YouTube integration components (`Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube.Errors`, `Lux.Integrations.YouTube.LiveChat`, `Lux.Integrations.YouTube.LiveChat.Poller`, `Lux.Integrations.YouTube.LiveBroadcasts`, `Lux.Integrations.YouTube.LiveStreams`, and `Lux.Integrations.YouTube.OAuth`). 

A rigorous test suite covering 4 core adversarial categories was developed and executed across 50+ concurrent GenServers, 100+ concurrent subscriber processes, rate-limiting and quota exhaustion scenarios, 401 token refresh loop boundaries, and deeply malformed/corrupted HTTP payloads.

All 493 unit tests and 75 E2E tests pass with 0 failures, and `mix compile --warnings-as-errors` passes cleanly.

---

## Challenges

### [Low] Challenge 1: Unhandled `throw(...)` in Poller `handler_fn` Callbacks

- **Assumption challenged**: Poller GenServer is fully resilient to arbitrary errors thrown by user-supplied `handler_fn` callbacks.
- **Attack scenario**: A user-supplied `handler_fn` executes `throw(:custom_tag)` rather than raising an Exception struct (`raise ...`).
- **Blast radius**: `invoke_handler/3` uses `rescue e -> ...` which catches `RuntimeError` and other Elixir exception structs, but does not catch Erlang/Elixir `throw(...)` or unhandled exits. If a callback uses `throw(...)`, the GenServer terminates with `bad return value`.
- **Observed behavior**: Under standard exception-raising callbacks (`RuntimeError`, `ArgumentError`, `UndefinedFunctionError`, `ArithmeticError`), `invoke_handler/3` cleanly catches the exception, logs a warning, and prevents the Poller from crashing.
- **Mitigation**: In future enhancements, `invoke_handler/3` could wrap the callback invocation in `try ... rescue ... catch ...` to also swallow non-local exits and throws if total crash protection is desired.

### [Low] Challenge 2: Client `:plug` Option Sharing with OAuth Refresh Sub-Requests

- **Assumption challenged**: Passing a custom `opts[:plug]` to `Client.request/3` routes only API requests to that plug, while OAuth refresh requests use their own mock.
- **Attack scenario**: If a caller passes a request-specific `:plug` to `Client.request/3`, `attempt_token_refresh/1` forwards `opts[:plug]` to `OAuth.refresh_token/2`.
- **Blast radius**: The custom plug receives both the YouTube API request and the OAuth refresh POST request. If the plug pattern matches strictly on YouTube API endpoints without matching OAuth paths, it will fail on OAuth requests.
- **Mitigation**: When defining a custom plug for `Client.request`, developers should either handle OAuth paths or rely on `Req.Test.stub(YouTubeOAuthMock, ...)` for token refresh endpoints.

---

## Stress Test Results

| Category | Scenario | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|---|
| **Poller Concurrency & Crash Resilience** | 50 concurrent `Poller` processes polling simultaneously with isolated plugs | All 50 pollers execute step polling independently without state leakage | 50/50 pollers successfully delivered isolated messages and updated metrics | **PASS** |
| **Poller Concurrency & Crash Resilience** | 100 subscribers registered, 90 abruptly terminated with `Process.exit(pid, :kill)` | Poller processes `:DOWN` messages, cleans monitor table, and delivers messages to remaining 10 | Poller remained alive, subscriber count updated to 10, all 10 surviving subscribers received message | **PASS** |
| **Poller Concurrency & Crash Resilience** | Callback handlers raising `RuntimeError`, `ArgumentError`, `UndefinedFunctionError` | Poller catches exception, logs warning, stays alive | Poller stayed alive across all exception types; subsequent polls succeeded | **PASS** |
| **Poller Concurrency & Crash Resilience** | 40 concurrent processes hammering `pause`, `resume`, `set_interval`, `get_status` | No deadlock, race conditions, or crashes | Poller handled all concurrent calls; verified healthy after bombardment | **PASS** |
| **Dynamic Polling & Throttling** | Suggested polling interval below `min_interval_ms` (200ms vs 1500ms) | Clamped to `min_interval_ms` (1500ms) | Interval updated to 1500ms | **PASS** |
| **Dynamic Polling & Throttling** | Suggested polling interval above `max_interval_ms` (50,000ms vs 8,000ms) | Clamped to `max_interval_ms` (8,000ms) | Interval updated to 8000ms | **PASS** |
| **Dynamic Polling & Throttling** | Malformed/negative/string/map `pollingIntervalMillis` | Poller safely falls back to `default_interval_ms` | Poller preserved default interval without crashing | **PASS** |
| **Dynamic Polling & Throttling** | Consecutive 429 Rate Limit responses followed by 200 OK recovery | Increments `consecutive_errors`, broadcasts `live_chat_error`, resets to 0 on 200 OK | Errors tracked correctly; recovered cleanly on 200 OK with `consecutive_errors: 0` | **PASS** |
| **401 Token Refresh & Loop Boundaries** | 401 Unauthorized with valid refresh token | Refreshes token via OAuth, retries request with new Bearer token, returns 200 OK | Request succeeded with new Bearer token on single retry | **PASS** |
| **401 Token Refresh & Loop Boundaries** | Persistent 401 Unauthorized (retry gets 401 again) | Single retry boundary halts recursion; returns `{:error, :invalid_token}` | Exactly 2 requests dispatched (initial + 1 retry); no infinite loop | **PASS** |
| **401 Token Refresh & Loop Boundaries** | 401 Unauthorized with failing OAuth endpoint (400/500/revoked) | Fails gracefully and returns `{:error, :invalid_token}` | Clean return without crash or hanging | **PASS** |
| **401 Token Refresh & Loop Boundaries** | 10 concurrent processes triggering 401 token refreshes | Each task refreshes token and receives worker-specific response | 10/10 tasks succeeded concurrently | **PASS** |
| **Malformed Payloads & Error Bodies** | Non-JSON bodies, HTML 502/503 pages, plain text 403 WAF blocks, nil body | `Errors.parse/3` returns structured `{:error, {status, body}}` tuple | Structured error tuples returned cleanly | **PASS** |
| **Malformed Payloads & Error Bodies** | Corrupt/sparse message payloads in `LiveChat.normalize_message` | Safely defaults missing keys; parses string `amountMicros` or defaults to nil | Handled all edge-case maps without crashes or exceptions | **PASS** |
| **Malformed Payloads & Error Bodies** | Top-level responses missing `nextPageToken` or containing `offlineAt` signal | Safely populates response struct and broadcasts `{:live_chat_ended, ...}` | Successfully handled missing tokens and stream termination | **PASS** |

---

## Unchallenged Areas

- **Direct Live Network Traffic**: External HTTP calls are strictly mocked via `Req.Test` and custom plugs in accordance with `CODE_ONLY` network isolation constraints.
- **Python / NLTK sentiment analysis module**: External Python environment dependency unrelated to YouTube integration.
