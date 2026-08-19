# Adversarial Challenge Report — Milestone 1 (YouTube OAuth 2.0 & API Client)

## Challenge Summary

**Overall risk assessment**: HIGH

Milestone 1 implements the foundational OAuth 2.0 client (`Lux.Integrations.YouTube.OAuth`), HTTP client (`Lux.Integrations.YouTube.Client`), error parser and resiliency helpers (`Lux.Integrations.YouTube.Errors`), and integration setup (`Lux.Integrations.YouTube`).

Our adversarial stress testing revealed **2 Critical/High findings**, **4 Medium findings**, and **2 Low findings**. The core logic is structured cleanly with bounded retry protection, but vulnerabilities around relative URL path formatting, lack of refreshed token persistence across requests, gRPC multi-detail error parsing, and struct `nil` handling create operational risks under production conditions.

---

## Challenges

### [Critical] Challenge 1: Relative Path Concatenation Corrupts Endpoint URLs When Leading Slash Is Omitted
- **Assumption challenged**: Assumes all API call paths passed to `Client.request/3`, `Client.get/2`, etc., will strictly include a leading slash (e.g. `"/liveBroadcasts"`).
- **Attack scenario**: A caller, Lens, or Prism passes `"liveBroadcasts"` or `"videos"` without a leading slash.
  In `Lux.Integrations.YouTube.Client.build_url/1`:
  ```elixir
  defp build_url(path) do
    if String.starts_with?(path, "http") do
      path
    else
      @endpoint <> path
    end
  end
  ```
  `@endpoint <> path` evaluates to `"https://www.googleapis.com/youtube/v3liveBroadcasts"` instead of `"https://www.googleapis.com/youtube/v3/liveBroadcasts"`.
- **Blast radius**: All requests with relative paths without a leading slash will fail with HTTP 404 or corrupted route errors from Google APIs.
- **Empirical Verification**: Confirmed via `Lux.Integrations.YouTube.AdversarialChallengeTest` (`test "relative path without leading slash causes malformed URL concatenation"`).
- **Mitigation**:
  ```elixir
  defp build_url(path) do
    cond do
      String.starts_with?(path, "http") -> path
      String.starts_with?(path, "/") -> @endpoint <> path
      true -> @endpoint <> "/" <> path
    end
  end
  ```

---

### [High] Challenge 2: Stateless Token Auto-Refresh Causes Repeated 401s and Redundant Refresh Loops in Polling
- **Assumption challenged**: Assumes that retrying an individual request with the refreshed token is sufficient without persisting or propagating the new access token.
- **Attack scenario**: When `youtube_access_token` expires, `Client.request/3` catches HTTP 401, refreshes the token against `https://oauth2.googleapis.com/token`, and retries the single in-flight request. However, `new_token` is discarded after that request completes and is never saved to `Lux.Config`, ETS, or state storage.
- **Blast radius**: In continuous streaming/polling workflows (e.g. `LiveChat.Poller` polling every 1-5 seconds), every single poll starts with the expired configured token, incurs an initial 401 Unauthorized, makes an additional Google OAuth POST token refresh request, and only then succeeds. This causes:
  1. 100% latency penalty (2 roundtrips per poll instead of 1).
  2. Severe load on Google OAuth token endpoints, risking OAuth burst rate limiting (`RATE_LIMIT_EXCEEDED` on the token endpoint).
  3. Redundant refresh stampedes under concurrent agent execution.
- **Mitigation**: Provide a token cache mechanism (e.g., ETS, GenServer TokenManager, or optional persistence callback) where refreshed tokens are stored and shared across client invocations.

---

### [Medium] Challenge 3: Incomplete gRPC Multi-Detail Parsing Drops Rate Limit / Quota Reason
- **Assumption challenged**: Assumes that if `error.details` is present in Google API responses, the error reason will always be the first item in the `details` list (`[first | _]`).
- **Attack scenario**: Google Cloud APIs and gRPC HTTP gateways return multiple detail objects (e.g. `[ %{"@type" => "google.rpc.Help", ...}, %{"@type" => "google.rpc.ErrorInfo", "reason" => "RATE_LIMIT_EXCEEDED"} ]`).
  `Lux.Integrations.YouTube.Errors.extract_error_info/1` only inspects the head element:
  ```elixir
  first_detail =
    case error_map["details"] do
      [first | _] when is_map(first) -> first
      _ -> %{}
    end
  ```
  `first_detail["reason"]` is `nil`, so `reason` falls back to `nil`. Consequently, `classify/4` falls through to generic `{:error, {403, message}}`.
- **Blast radius**: Rate limit errors with multiple detail elements are misclassified as generic 403 errors, `Errors.rate_limited?/1` returns `false`, and `Errors.retryable?/1` returns `false`, preventing automatic retries in `Errors.with_retry/2`.
- **Empirical Verification**: Confirmed via `Lux.Integrations.YouTube.AdversarialChallengeTest` (`test "parses 403 with multiple details elements where reason is in second element"`).
- **Mitigation**:
  ```elixir
  reason_from_details =
    case error_map["details"] do
      list when is_list(list) ->
        Enum.find_value(list, fn
          %{"reason" => r} when is_binary(r) -> r
          _ -> nil
        end)
      _ -> nil
    end
  ```

---

### [Medium] Challenge 4: Google gRPC `RESOURCE_EXHAUSTED` Status String Dropped on HTTP 403
- **Assumption challenged**: Assumes `@quota_reasons` covers all standard Google quota exhaustion reason strings.
- **Attack scenario**: When Google API returns HTTP 403 with top-level `status: "RESOURCE_EXHAUSTED"` and empty `errors: []`, `reason` is extracted as `"RESOURCE_EXHAUSTED"`. `@quota_reasons` only contains `["quotaExceeded", "dailyLimitExceeded", "QUOTA_EXCEEDED", "RESOURCE_EXHAUSTED_QUOTA"]`.
- **Blast radius**: The response is classified as generic `{:error, {403, "..."}}` rather than `{:error, {:quota_exceeded, details}}`.
- **Empirical Verification**: Confirmed in `Lux.Integrations.YouTube.AdversarialChallengeTest` (`test "parses 403 with empty errors list and gRPC RESOURCE_EXHAUSTED status"`).
- **Mitigation**: Add `"RESOURCE_EXHAUSTED"` to `@quota_reasons`.

---

### [Medium] Challenge 5: `Lux.Integrations.YouTube.add_auth_header/1` Crashes on Lens With `nil` Headers
- **Assumption challenged**: Assumes `%Lux.Lens{}` always has a list for `:headers`.
- **Attack scenario**: A `%Lux.Lens{}` struct initialized with `headers: nil` is passed to `YouTube.add_auth_header/1`.
  `%{lens | headers: lens.headers ++ [{"Authorization", ...}]}` fails with `ArgumentError: cannot concatenate nil with list`.
- **Blast radius**: Any lens constructed with `headers: nil` crashes when evaluated.
- **Empirical Verification**: Confirmed via `Lux.Integrations.YouTube.AdversarialChallengeTest` (`test "add_auth_header with lens having nil headers raises ArgumentError"`).
- **Mitigation**: Use `(lens.headers || []) ++ ...`.

---

### [Medium] Challenge 6: `Req` Auto JSON Decompression Masks HTTP Status on Malformed JSON Errors
- **Assumption challenged**: Assumes error response bodies with `content-type: application/json` are always valid JSON.
- **Attack scenario**: A proxy, firewall, or edge server returns a 400 or 502 with truncated JSON. `Req` tries to parse it automatically and returns `{:error, %Jason.DecodeError{...}}` instead of `{:ok, %Req.Response{status: status, body: raw_body}}`.
- **Blast radius**: `Client.request/3` returns `{:error, %Jason.DecodeError{}}` instead of passing the response to `Errors.parse/3`, losing the HTTP status code.
- **Mitigation**: Handle `{:error, %Jason.DecodeError{data: body}}` in `Client.request/3` or pass raw error body to `Errors.parse`.

---

### [Low] Challenge 7: Arithmetic Float Overflow in `Errors.backoff_delay/2` for Large Attempt Counts
- **Assumption challenged**: Assumes `attempt` argument passed to `backoff_delay/2` will always be a small integer.
- **Attack scenario**: If `attempt > 1024`, `:math.pow(2, max(0, attempt - 1))` overflows 64-bit float precision and raises `ArithmeticError` instead of returning `max_backoff_ms`.
- **Mitigation**: Cap `attempt` before calculating exponent: `capped = min(attempt, 30)`.

---

### [Low] Challenge 8: `OAuth.authorize_url/1` Crashes on Non-Binary Scopes
- **Assumption challenged**: Assumes scopes are passed only as binaries or binary lists.
- **Attack scenario**: Passing `scope: [:youtube, :youtube_readonly]` raises `ArgumentError` in `Enum.join/2`.
- **Mitigation**: Coerce with `Enum.map_join(scopes, " ", &to_string/1)`.

---

## Stress Test Results

| Scenario / Test Case | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|
| Relative path `"liveBroadcasts"` | Resolves to `/youtube/v3/liveBroadcasts` | Resolved to `/youtube/v3liveBroadcasts` (Concatenation bug) | **CONFIRMED BUG** |
| Empty path `""` | Resolves to base endpoint `/youtube/v3` | Resolved to `/youtube/v3` | **PASS** |
| Absolute URL `"https://..."` | Preserves custom URL and headers | Preserves custom URL and headers | **PASS** |
| Unicode & Special Chars in params | Properly percent-encoded in query | Successfully URL encoded | **PASS** |
| Nil & keyword list params | Handled gracefully without crash | Handled gracefully | **PASS** |
| Array JSON body `[1, 2, 3]` | Encoded and transmitted as JSON array | Successfully transmitted | **PASS** |
| Empty scopes list in OAuth | Encodes `scope=` parameter safely | Safely encoded | **PASS** |
| Missing / empty credentials `""` | Returns `{:error, :missing_credentials}` | Returned `{:error, :missing_credentials}` | **PASS** |
| Nested Google OAuth error body | Parsed to `{:error, {:oauth_error, ...}}` | Parsed to `{:error, {:oauth_error, ...}}` | **PASS** |
| Standard RFC 6749 OAuth error | Parsed to `{:error, {:oauth_error, ...}}` | Parsed to `{:error, {:oauth_error, ...}}` | **PASS** |
| HTML 502 on OAuth endpoint | Parsed to `{:error, {502, html}}` | Parsed to `{:error, {502, html}}` | **PASS** |
| Persistent 401 after token refresh | Terminates with `{:error, :invalid_token}` | Bounded to 1 retry, no infinite loop | **PASS** |
| 401 followed by 403 quotaExceeded | Retried request parses to `{:quota_exceeded, _}` | Correctly parsed to `{:quota_exceeded, _}` | **PASS** |
| 10 Concurrent 401s | All tasks independently refresh & complete | All 10 tasks completed successfully | **PASS** |
| Multi-element `details` array | Finds `reason` in any detail element | Only reads 1st element; reason dropped | **CONFIRMED BUG** |
| HTTP 403 `RESOURCE_EXHAUSTED` | Parsed as `{:quota_exceeded, _}` | Parsed as generic `{403, message}` | **CONFIRMED BUG** |
| Unrecognized status codes (418, 504) | Returns structured `{status, msg}` | Returns structured `{status, msg}` | **PASS** |
| Malformed / Date `Retry-After` | Returns `nil` without crashing | Returns `nil` safely | **PASS** |
| Lens with `headers: nil` | Safely defaults headers | Crashes with `ArgumentError` | **CONFIRMED BUG** |
| Plug.Conn without token | Leaves conn untouched | Leaves conn untouched | **PASS** |

---

## Unchallenged Areas

- **Live Streaming & Chat modules (`LiveBroadcasts`, `LiveStreams`, `LiveChat`, `Poller`)**: Out of scope for Milestone 1; covered under Milestones 2 and 3.
- **External Network Latency / TLS Handshake Timeouts**: Tested via `Req.Test` simulated transport errors (`:nxdomain`, `:econnrefused`); actual external Google endpoint latency profiles are governed by network environment and CODE_ONLY restrictions.
