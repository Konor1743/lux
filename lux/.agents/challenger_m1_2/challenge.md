# Adversarial Challenge Report — Milestone 1: YouTube API Error Handling & Client

## Challenge Summary

**Overall risk assessment**: MEDIUM-HIGH

The error handling, retry backoff calculation, and quota exhaustion detection implementations in `Lux.Integrations.YouTube.Errors` and `Lux.Integrations.YouTube.Client` provide solid core functionality for standard single-error payloads. However, empirical stress testing across diverse payload structures (gRPC format, classic format, malformed JSON bodies, HTML 500 error pages) revealed 6 concrete vulnerabilities and operational risks that can impair quota detection, cause long synchronous process blocking, and leak multi-kilobyte HTML into LLM agent contexts.

A dedicated empirical stress test suite (`test/unit/lux/integrations/youtube/errors_stress_test.exs`) containing 51 tests across 8 categories was executed to verify every challenge dimension.

---

## Challenges

### [High] Challenge 1: Quota Detection Fails on Multi-Item gRPC Error Details

- **Assumption challenged**: Assumes the first element in `details` always contains the error reason (`[first | _] = details`).
- **Attack scenario**: In Google RPC / gRPC responses, `details` is an array of typed metadata objects (`@type`). Frequently, informational objects such as `google.rpc.Help` (console links) or `google.rpc.QuotaFailure` (violations list without a root `reason` key) precede `google.rpc.ErrorInfo` (`{"reason": "QUOTA_EXCEEDED"}`).
  When `first_detail` is `Help` or `QuotaFailure`, `first_detail["reason"]` is `nil`. The reason falls back to `error_map["status"]` (`"RESOURCE_EXHAUSTED"`).
  Because `"RESOURCE_EXHAUSTED"` is not in `@quota_reasons` (`["quotaExceeded", "dailyLimitExceeded", "QUOTA_EXCEEDED", "RESOURCE_EXHAUSTED_QUOTA"]`), HTTP 403 falls through to generic error classification: `{:error, {403, message}}`.
- **Empirical Evidence**: Verified in `errors_stress_test.exs: "gRPC multi-element details where Help/QuotaFailure precedes ErrorInfo (VULNERABILITY PROBE)"`.
  `Errors.parse(403, grpc_body)` returns `{:error, {403, "Daily quota exceeded for project 123"}}` and `Errors.quota_exceeded?(parsed)` returns `false`.
- **Blast radius**: Quota limit exhaustion is misclassified as an unhandled generic 403 Forbidden error. Agents and poller loops fail to pause operations, repeatedly retrying or failing catastrophically.
- **Mitigation**:
  1. Iterate over the entire `details` list to find any object containing `"reason"` or matching `@type == "...ErrorInfo"`.
  2. Add `"RESOURCE_EXHAUSTED"` to `@quota_reasons` or inspect `status == "RESOURCE_EXHAUSTED"` when HTTP status is 403.

---

### [High] Challenge 2: Implicit Req Default Retries Block Synchronously on 429 Retry-After Headers

- **Assumption challenged**: Assumes retry management is solely controlled by the caller or `Lux.Integrations.YouTube.Errors.with_retry/2`.
- **Attack scenario**: `Client.request/3` initializes Req with `Req.new(req_options)`. By default in `Req`, the built-in `:retry` step is enabled (`:safe_transient`). When YouTube returns `HTTP 429 Too Many Requests` with a header `Retry-After: 45`:
  `Req` intercepts the response before `Client.request` receives it, logs `[warning] retry: got response with status 429, will retry in 45000ms`, and blocks the calling process with `Process.sleep(45_000)` (45 seconds).
  If the caller has also wrapped the call in `Errors.with_retry/2`, a double-retry cascade occurs: `Req` retries 3 times internally (sleeping up to 45s each), and then `with_retry` retries the outer call 3 more times ($3 \times 3 = 9$ potential requests and hundreds of seconds of blocking).
- **Empirical Evidence**: Verified during test execution when mock returned 429 with `Retry-After: 45`, freezing test execution for 45,000ms until killed.
- **Blast radius**: Synchronously blocking a GenServer (such as `LiveChat.Poller`) for 45 seconds causes GenServer call timeouts (`:timeout`), backlog in the process mailbox, and crashes supervisor trees.
- **Mitigation**: In `Client.request/3`, default `:retry` to `false` in `req_options` unless explicitly overridden by the caller (`maybe_put_opt(:retry, Map.get(opts_map, :retry, false))`), centralizing retry backoff in `Errors.with_retry/2`.

---

### [Medium] Challenge 3: Multi-Kilobyte HTML Error Payloads Leak into LLM Agent Prompts

- **Assumption challenged**: Assumes error payloads are small error messages or structured JSON.
- **Attack scenario**: When upstream infrastructure (Cloudflare WAF, Nginx, Google Frontend) fails with 500, 502, 503, or 504, it returns an HTML error page ranging from 10KB to 1MB.
  `Jason.decode/1` fails, and `extract_error_info/1` stores the entire raw HTML string as `message`.
  `classify/4` returns `{:error, {status, raw_html_string}}`.
- **Empirical Evidence**: Verified in `errors_stress_test.exs: "large multi-kilobyte HTML error page (stress memory / string parsing)"` and `"Google Frontend (GFE) 502 Bad Gateway HTML page"`.
- **Blast radius**: In the Lux framework, error tuples are passed directly into LLM prompts, agent memory, or logging pipelines. A 50KB HTML error payload consumes thousands of LLM tokens, wastes context window capacity, and may confuse the LLM reasoning loop.
- **Mitigation**: Detect HTML error payloads in `classify/4` (e.g. `String.starts_with?(msg, "<!DOCTYPE")` or `String.starts_with?(msg, "<html")`) and summarize as `"<HTML Error Page: #{status} #{default_message_for_status(status)}>"` or truncate to a maximum length (e.g. 200 characters).

---

### [Medium] Challenge 4: Atom-Keyed Response Payloads Degrade to Generic Fallback Messages

- **Assumption challenged**: Assumes all parsed error maps have string keys.
- **Attack scenario**: If internal mocks, unit test stubs, or middleware transform payloads into atom-keyed maps (e.g. `%{error: %{message: "Quota exceeded", errors: [%{reason: "quotaExceeded"}]}}`), `extract_error_info/1` does not match `%{"error" => ...}` and falls through to the catch-all `extract_error_info(_)`, returning `%{reason: nil, domain: nil, message: nil}`.
  `classify/4` returns `{:error, {403, "Forbidden"}}`, losing all error details and reasons.
- **Empirical Evidence**: Verified in `errors_stress_test.exs: "classic with atom-keyed maps (VULNERABILITY PROBE)"`.
- **Blast radius**: Test suites and internal lenses that use atom keys lose quota classification and error messages.
- **Mitigation**: Add clauses in `extract_error_info/1` for atom-keyed maps (`%{error: %{} = err}`, `%{error: err}`, `%{message: msg}`).

---

### [Low] Challenge 5: Floating-Point Arithmetic Overflow in `backoff_delay/2` at Attempt >= 1025

- **Assumption challenged**: Assumes exponential calculation `:math.pow(2, max(0, attempt - 1))` never exceeds IEEE 754 float limits.
- **Attack scenario**: If a long-running process or poller increments `attempt` without resetting it, calling `backoff_delay(1025)` attempts to compute $2^{1024}$, triggering `:math.pow` overflow.
- **Empirical Evidence**: Verified in `errors_stress_test.exs: "extreme attempt >= 1025 float exponentiation limits (VULNERABILITY PROBE)"`.
  Executing `Errors.backoff_delay(1025)` raises `ArithmeticError: bad argument in arithmetic expression: :math.pow(2, 1024)`.
- **Blast radius**: Unhandled crash in background poller or retry loop on high attempt counts.
- **Mitigation**: Clamp `attempt` to a safe upper bound (e.g. `min(max(0, attempt - 1), 30)`) before invoking `:math.pow`.

---

### [Low] Challenge 6: Malformed JSON with `content-type: application/json` Intercepted by Req

- **Assumption challenged**: Assumes malformed JSON responses reach `Errors.parse/3` and return `{status, message}` tuples.
- **Attack scenario**: When a server returns an invalid JSON string accompanied by `content-type: application/json`, Req's `decode_body` step attempts to parse it and returns `{:error, %Jason.DecodeError{}}`. `Client.request/3` forwards this error directly, bypassing `Errors.parse/3`.
- **Empirical Evidence**: Verified in `errors_stress_test.exs: "handles malformed JSON body on 400 Bad Request via Req.Test mock"`.
- **Blast radius**: The caller receives `{:error, %Jason.DecodeError{}}` instead of structured `{:error, {400, "..."}}`. `Errors.retryable?` returns `false`.
- **Mitigation**: Clarify interface contract or wrap `%Jason.DecodeError{}` in `Client.request/3` if uniform `{status, message}` tuples are required.

---

## Stress Test Results

| Scenario | Expected Behavior | Actual Behavior | Pass / Fail |
|:---|:---|:---|:---:|
| gRPC ErrorInfo with QUOTA_EXCEEDED | `{:error, {:quota_exceeded, details}}` | `{:error, {:quota_exceeded, details}}` | PASS |
| gRPC ErrorInfo with RATE_LIMIT_EXCEEDED | `{:error, {:rate_limited, details}}` | `{:error, {:rate_limited, details}}` | PASS |
| gRPC RESOURCE_EXHAUSTED_QUOTA | `{:error, {:quota_exceeded, details}}` | `{:error, {:quota_exceeded, details}}` | PASS |
| gRPC multi-element details (Help before ErrorInfo) | Extract reason from 2nd detail | Falls back to generic `{403, msg}` (misses quota) | VULNERABILITY CONFIRMED |
| gRPC status RESOURCE_EXHAUSTED without details on 403 | Classified as quota exceeded | Falls back to generic `{403, msg}` | VULNERABILITY CONFIRMED |
| Classic quotaExceeded & dailyLimitExceeded | `{:error, {:quota_exceeded, details}}` | `{:error, {:quota_exceeded, details}}` | PASS |
| Classic rate limiting reasons (4 variants) | `{:error, {:rate_limited, details}}` | `{:error, {:rate_limited, details}}` | PASS |
| Atom-keyed maps | Extract reason and error message | Falls through to `{403, "Forbidden"}` | VULNERABILITY CONFIRMED |
| Truncated / malformed JSON (text/plain) | `{:error, {status, raw_body}}` | `{:error, {status, raw_body}}` | PASS |
| Non-string / non-map bodies (atoms, tuples, ints) | Default status message | Default status message | PASS |
| HTML 500 / 502 / 503 / 504 error pages | Classified as retryable with HTML body | Classified as retryable; body contains 100KB raw HTML | PASS (Leaking HTML) |
| Retry-After header variants (casing, spaces, ints) | Extract integer seconds | Extracted properly | PASS |
| Backoff calculation bounds (attempts 1..10) | Within [50, 16_000] ms | Within [50, 16_000] ms | PASS |
| Jitter statistical distribution (1,000 samples) | Mean ~2000 ms for attempt 3 | Mean: ~2014 ms, spread [50, 4000] | PASS |
| Attempt >= 1025 float exponentiation | Clamped delay | Raises `ArithmeticError` | VULNERABILITY CONFIRMED |
| `with_retry/2` on 500, 502, 503, 504 | Retries up to max_retries | Retries and recovers / exhausts | PASS |
| `with_retry/2` abort on 400, 401, 404, quota | Aborts immediately on attempt 1 | Aborts on attempt 1 | PASS |
| Req 429 Retry-After interaction | Non-blocking or coordinated retry | Req sleeps 45s synchronously | VULNERABILITY CONFIRMED |

---

## Unchallenged Areas

- **OAuth token grant refresh rotation across distributed multi-node clusters**: Out of scope for client error parser unit review; requires distributed cluster simulation.
- **YouTube Live Streaming RTMP ingestion endpoint socket timeouts**: Handled in Milestone 2 (`LiveStreams`).
