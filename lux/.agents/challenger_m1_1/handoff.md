# Handoff Report — Challenger 1 (Milestone 1)

## 1. Observation

1. **URL Concatenation without leading slash in `Client.build_url/1`**:
   - File: `lib/lux/integrations/youtube/client.ex`, lines 136–142
   - Verbatim code:
     ```elixir
     defp build_url(path) do
       if String.starts_with?(path, "http") do
         path
       else
         @endpoint <> path
       end
     end
     ```
   - When calling `Client.get("liveBroadcasts", token: "tok")`, `@endpoint <> path` produces `"https://www.googleapis.com/youtube/v3liveBroadcasts"`. Plug test output confirmed: `conn.request_path == "/youtube/v3liveBroadcasts"`.

2. **Stateless Token Refresh in `Client.request/3`**:
   - File: `lib/lux/integrations/youtube/client.ex`, lines 93–109
   - When 401 occurs, `attempt_token_refresh(opts_map)` obtains `new_token` and retries `request(method, path, new_opts)`. However, `new_token` is not persisted to `Lux.Config` or any ETS/shared state. Subsequent calls starting from config still use the expired token.

3. **Incomplete gRPC Multi-Detail Extraction in `Errors.extract_error_info/1`**:
   - File: `lib/lux/integrations/youtube/errors.ex`, lines 137–142
   - Verbatim code:
     ```elixir
     first_detail =
       case error_map["details"] do
         [first | _] when is_map(first) -> first
         _ -> %{}
       end
     ```
   - When Google APIs return `details: [%{"@type" => "google.rpc.Help"}, %{"@type" => "google.rpc.ErrorInfo", "reason" => "RATE_LIMIT_EXCEEDED"}]`, `first_detail` lacks `"reason"`, resulting in `Errors.parse/3` falling back to `{:error, {403, "User rate limit hit"}}` instead of `{:error, {:rate_limited, ...}}`.

4. **Missing `"RESOURCE_EXHAUSTED"` in `@quota_reasons`**:
   - File: `lib/lux/integrations/youtube/errors.ex`, lines 36–41
   - Verbatim list: `["quotaExceeded", "dailyLimitExceeded", "QUOTA_EXCEEDED", "RESOURCE_EXHAUSTED_QUOTA"]`.
   - When Google returns HTTP 403 with `status: "RESOURCE_EXHAUSTED"`, `Errors.parse/3` returns `{:error, {403, message}}` instead of `{:error, {:quota_exceeded, ...}}`.

5. **`ArgumentError` on Lens with `headers: nil` in `YouTube.add_auth_header/1`**:
   - File: `lib/lux/integrations/youtube.ex`, line 60
   - Verbatim code: `%{lens | headers: lens.headers ++ [{"Authorization", "Bearer #{token}"}]}`.
   - When `lens.headers` is `nil`, `nil ++ [...]` raises `ArgumentError: cannot concatenate nil with list`.

6. **Req JSON Decoding on Malformed Error Response Bodies**:
   - When a server returns status 400 with malformed JSON body and `content-type: application/json`, `Req.request()` returns `{:error, %Jason.DecodeError{...}}` directly instead of passing the response to `Errors.parse/3`.

7. **Empirical Test Suite Execution**:
   - Command: `mix test test/unit/lux/integrations/youtube test/unit/lux/integrations/youtube_test.exs --include unit`
   - Result: 87 tests passing across `adversarial_challenge_test.exs`, `client_test.exs`, `oauth_test.exs`, `errors_test.exs`, and `youtube_test.exs`.

---

## 2. Logic Chain

1. From Observation 1, if any caller invokes `Client.get("endpoint")` omitting the initial `/`, the resulting URL concatenates `"https://www.googleapis.com/youtube/v3"` directly with `"endpoint"`, forming `"https://www.googleapis.com/youtube/v3endpoint"`. This causes an immediate 404 / route mismatch.
2. From Observation 2, because `Client.request/3` is a pure function that does not write refreshed tokens back to configuration or a shared store, polling GenServers (such as Live Chat pollers) that rely on `Lux.Config.youtube_access_token()` will trigger a 401 on every single polling cycle, generating 2 HTTP requests per poll and adding 100% overhead.
3. From Observation 3 and 4, Google Cloud APIs use gRPC HTTP mappings that include `RESOURCE_EXHAUSTED` at the status level or include multiple objects in `details`. Because `Errors.ex` only inspects the first detail and lacks `"RESOURCE_EXHAUSTED"` in `@quota_reasons`, these errors fail to be tagged as rate-limited or quota-exceeded, breaking retry loops in `Errors.with_retry/2`.
4. From Observation 5, passing a `%Lux.Lens{headers: nil}` immediately crashes with `ArgumentError`, making lens integration brittle when default structs are manipulated.
5. Therefore, while core OAuth and Client fundamentals (bounded 401 auto-refresh, token exchange, query encoding, header generation) are functionally sound and pass ExUnit tests, there are 2 high/critical and 4 medium bugs that should be resolved by the Implementer before Milestone 1 is approved.

---

## 3. Caveats

- Milestone 1 review was strictly bounded to `lib/lux/integrations/youtube/` and `lib/lux/integrations/youtube.ex`. Higher-level domain modules (Milestones 2–4: `LiveBroadcasts`, `LiveStreams`, `LiveChat`, `Poller`, Lenses/Prisms) were not evaluated as part of this review.
- External network requests to Google were simulated using `Req.Test` plugs per project architecture standards.

---

## 4. Conclusion

Milestone 1 implementation provides a solid foundation with well-designed error structures, bounded auto-refresh retry recursion, and comprehensive unit tests. However, **6 specific defects** require remediation:
1. **Fix URL path concatenation**: Add leading slash normalization in `Client.build_url/1`.
2. **Support Token Persistence / Caching**: Provide a callback or TokenManager ETS storage so that token auto-refresh persists new access tokens across requests.
3. **Traverse all elements in `details`**: Update `Errors.extract_error_info/1` to inspect all list elements for `"reason"`.
4. **Include `"RESOURCE_EXHAUSTED"`**: Add `"RESOURCE_EXHAUSTED"` to `@quota_reasons` in `Errors.ex`.
5. **Safely handle `nil` lens headers**: Use `(lens.headers || [])` in `YouTube.add_auth_header/1`.
6. **Gracefully handle `Jason.DecodeError`**: Catch decode errors in `Client.request/3` to preserve error response details.

---

## 5. Verification Method

To independently verify these findings:
1. Run the adversarial challenge test suite:
   ```bash
   mix test test/unit/lux/integrations/youtube/adversarial_challenge_test.exs --include unit
   ```
2. Inspect `lib/lux/integrations/youtube/client.ex:136-142` to verify path concatenation logic.
3. Inspect `lib/lux/integrations/youtube/errors.ex:137-142` to verify `[first | _]` single-element detail parsing.
4. Inspect `lib/lux/integrations/youtube.ex:60` to verify `lens.headers ++ [...]` without `nil` check.
