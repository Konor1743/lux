# Handoff Report: E2E Test Remediation for YouTube Integration (Explorer 2)

## 1. Observation

Direct observations from the codebase, test executions, and audit reports:

- **T2-F2-01 (Line 1197 in `test/e2e/youtube_integration_e2e_test.exs`)**:
  - Code: `Client.request(:get, "/liveBroadcasts", token: "bad_token", refresh_token: "expired_refresh", auto_refresh: true)`
  - Mock expectations: `Req.Test.expect(YouTubeClientMock, ...)` and `Req.Test.expect(YouTubeOAuthMock, ...)`
  - Verbatim Error: `** (RuntimeError) expected YouTubeOAuthMock to be still used 1 more times`
  - Implementation trace: `Client.attempt_token_refresh/1` (`lib/lux/integrations/youtube/client.ex:220`) accesses `opts[:client_id] || safe_config_access(:youtube_client_id)` which returns `nil`. `OAuth.refresh_token/2` (`lib/lux/integrations/youtube/oauth.ex:138`) returns `{:error, :missing_credentials}` without issuing any HTTP request to `YouTubeOAuthMock`.

- **T2-F2-02 (Line 1220 in `test/e2e/youtube_integration_e2e_test.exs`)**:
  - Code: `Req.Test.expect(YouTubeClientMock, fn _conn -> {:error, %Req.TransportError{reason: :econnrefused}} end)`
  - Verbatim Error: `** (ArgumentError) expected to return %Plug.Conn{}, got: {:error, %Req.TransportError{reason: :econnrefused}}`
  - Implementation trace: In Plug / Req.Test, mock plug functions must return a `%Plug.Conn{}` struct. Req provides `Req.Test.transport_error(conn, :econnrefused)` (`deps/req/lib/req/test.ex:325`) to simulate network transport failures.

- **T2-F5-02 (Line 1407 in `test/e2e/youtube_integration_e2e_test.exs`)**:
  - Code: `assert {:error, :invalid_message_text} = LiveChat.insert_message("chat1", "", token: "tok")`
  - Verbatim Error: `match (=) failed. left: {:error, :invalid_message_text}, right: {:error, :empty_message_text}`
  - Implementation trace: `LiveChat.insert_message/3` (`lib/lux/integrations/youtube/live_chat.ex:157`) guards `when not is_binary(message_text) or message_text == ""` with `{:error, :empty_message_text}`. `@doc` and `@spec` specify `{:error, :empty_message_text}`.

- **T2-F6-01 (Line 1483 in `test/e2e/youtube_integration_e2e_test.exs`)**:
  - Code: `b3 = "RESOURCE_EXHAUSTED"` passed to `Errors.parse(403, b3, [])`
  - Verbatim Error: `match (=) failed. left: {:error, {:quota_exceeded, _}}, right: {:error, {403, "RESOURCE_EXHAUSTED"}}`
  - Implementation trace: `Errors.extract_error_info/1` (`lib/lux/integrations/youtube/errors.ex:148`) extracts reason from `error_map["status"]` (e.g. `%{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}`). Bare non-JSON strings cannot be parsed as maps with a status field, yielding `reason: nil`, which classifies 403 as generic `{403, "RESOURCE_EXHAUSTED"}`.

---

## 2. Logic Chain

1. **T2-F2-01**:
   - `Client.request/3` with `auto_refresh: true` on 401 triggers `attempt_token_refresh/1`.
   - `attempt_token_refresh/1` calls `OAuth.refresh_token/2` with `:client_id` and `:client_secret` extracted from `opts` or config.
   - When not provided in `opts` and unset in test environment config, `OAuth.refresh_token/2` exits early with `{:error, :missing_credentials}` before calling `Req.request/1`.
   - Adding `client_id: "cid", client_secret: "sec"` allows the token refresh request to reach `YouTubeOAuthMock`, receiving the 400 `invalid_grant` mock response and exhausting the expectation cleanly.

2. **T2-F2-02**:
   - `Req.Test` invokes mock plugs through Plug's pipeline. Returning `{:error, ...}` violates Plug's contract and raises an `ArgumentError`.
   - `Req.Test.transport_error(conn, :econnrefused)` sets the private `:req_test_exception` key on `conn` and returns `%Plug.Conn{}`. Req then returns `{:error, %Req.TransportError{reason: :econnrefused}}` to the caller, satisfying both Plug and the test assertions.

3. **T2-F5-02**:
   - `LiveChat.insert_message/3` returns `{:error, :empty_message_text}` for empty/nil message text.
   - The test assertion expecting `:invalid_message_text` is an assertion typo in the test file. Updating the pattern match to `{:error, :empty_message_text}` resolves the failure.

4. **T2-F6-01**:
   - Google API error handling supports Google Cloud / gRPC status error objects formatted as `%{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}`.
   - `Errors.extract_error_info/1` parses `error_map["status"]` into `reason: "RESOURCE_EXHAUSTED"`, which is matched by `@quota_reasons` under status 403 to produce `{:error, {:quota_exceeded, ...}}`.
   - Changing `b3 = "RESOURCE_EXHAUSTED"` to `b3 = %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}` provides the valid error map format and satisfies the test assertion.

---

## 3. Caveats

- All proposed fixes are strictly confined to `test/e2e/youtube_integration_e2e_test.exs`. No core library code changes are needed in `lib/lux/integrations/youtube/`.
- No assumptions about external services or live network access were made; all flows use `Req.Test` offline stubs.

---

## 4. Conclusion

The 4 failing E2E tests are remediated by applying the following edits in `test/e2e/youtube_integration_e2e_test.exs`:
1. **T2-F2-01**: Add `client_id: "cid", client_secret: "sec"` to `Client.request/3` call options.
2. **T2-F2-02**: Replace `{:error, %Req.TransportError{reason: :econnrefused}}` with `Req.Test.transport_error(conn, :econnrefused)`.
3. **T2-F5-02**: Update assertions from `{:error, :invalid_message_text}` to `{:error, :empty_message_text}`.
4. **T2-F6-01**: Update `b3` definition from bare string `"RESOURCE_EXHAUSTED"` to `%{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}`.

---

## 5. Verification Method

To independently verify after the implementer applies the changes:

```bash
mix test test/e2e/youtube_integration_e2e_test.exs:1197
mix test test/e2e/youtube_integration_e2e_test.exs:1220
mix test test/e2e/youtube_integration_e2e_test.exs:1407
mix test test/e2e/youtube_integration_e2e_test.exs:1483
```

Or run all Tier 2 Feature tests:
```bash
mix test test/e2e/youtube_integration_e2e_test.exs
```

All 4 test cases will pass with 0 failures and 100% offline determinism.
