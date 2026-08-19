# Explorer 1 Handoff Report: Poller Background Process Mock Access Remediation

## 1. Observation

### Exact Failure Output
Running `mix test test/e2e/youtube_integration_e2e_test.exs:987` fails with:
```
18:27:06.248 [error] GenServer #PID<0.278.0> terminating
** (RuntimeError) cannot find mock/stub YouTubeClientMock in process #PID<0.278.0>
    (req 0.5.10) lib/req/test.ex:389: Req.Test.__fetch_plug__/1
    (req 0.5.10) lib/req/test.ex:622: Req.Test.call/2
    (req 0.5.10) lib/req/steps.ex:1015: Req.Steps.run_plug/1
    (req 0.5.10) lib/req/request.ex:1045: Req.Request.run_request/1
    (req 0.5.10) lib/req/request.ex:989: Req.Request.run/1
    (lux 0.5.0) lib/lux/integrations/youtube/client.ex:89: Lux.Integrations.YouTube.Client.request/3
    (lux 0.5.0) lib/lux/integrations/youtube/live_chat.ex:121: Lux.Integrations.YouTube.LiveChat.list_messages/2
    (lux 0.5.0) lib/lux/integrations/youtube/live_chat/poller.ex:396: Lux.Integrations.YouTube.LiveChat.Poller.execute_poll/1
    (lux 0.5.0) lib/lux/integrations/youtube/live_chat/poller.ex:311: Lux.Integrations.YouTube.LiveChat.Poller.handle_call/3
```

### Direct Code Observations in `test/e2e/youtube_integration_e2e_test.exs`
All 8 failing tests invoke `Req.Test.allow(YouTubeClientMock, self(), poller)` **before** calling `Req.Test.expect(YouTubeClientMock, ...)`:
- Line 987 (`T1-F5-04`): `Poller.start_link` (line 988) → `Req.Test.allow` (line 996) → `Req.Test.expect` (line 1001)
- Line 1021 (`T1-F5-05`): `Poller.start_link` (line 1022) → `Req.Test.allow` (line 1032) → `Req.Test.expect` (line 1034)
- Line 1426 (`T2-F5-04`): `Poller.start_link` (line 1427) → `Req.Test.allow` (line 1435) → `Req.Test.expect` (line 1437)
- Line 1783 (`T3-PAIR-04`): `Poller.start_link` (line 1784) → `Req.Test.allow` (line 1792) → `Req.Test.expect` (line 1795)
- Line 1977 (`T3-PAIR-08`): `Poller.start_link` (line 1978) → `Req.Test.allow` (line 1986) → `Req.Test.expect` (line 1989)
- Line 2359 (`T4-SCENARIO-02`): `Poller.start_link` (line 2360) → `Req.Test.allow` (line 2368) → `Req.Test.expect` (line 2389)
- Line 2457 (`T4-SCENARIO-03`): `Poller.start_link` (line 2466) → `Req.Test.allow` (lines 2474-2475) → `Req.Test.expect` (line 2478)
- Line 2542 (`T4-SCENARIO-04`): `Poller.start_link` (line 2543) → `Req.Test.allow` (line 2552) → `Req.Test.expect` (line 2555)

### Direct Code Observations in `deps/req/lib/req/test/ownership.ex`
- Lines 153-163:
  ```elixir
  owner_pid =
    cond do
      owner_pid = state.allowances[pid_with_access][key] ->
        owner_pid

      _meta = state.owners[pid_with_access][key] ->
        pid_with_access

      true ->
        throw({:reply, {:error, %Error{key: key, reason: :not_allowed}}, state})
    end
  ```
- Lines 437-440 of `deps/req/lib/req/test.ex`: `Req.Test.stub/2` and `Req.Test.expect/3` populate `state.owners[self()][name]`.
- Calling `allow/3` prior to `expect/3` or `stub/2` evaluates to `{:error, %Error{key: key, reason: :not_allowed}}` because `self()` has no entry in `state.owners` yet.
- `Req.Test.allow/3` returns `{:error, ...}` without raising, allowing the test to continue until `Poller.poll_once/1` fails at runtime.

### Direct Code Observations in Unit Tests and Passing E2E Tests
- `test/unit/lux/integrations/youtube/poller_test.exs:104-123`:
  `Req.Test.expect(YouTubeClientMock, ...)` is called FIRST, followed by `Poller.start_link(...)` and `Req.Test.allow(YouTubeClientMock, self(), poller)`.
- `test/e2e/youtube_integration_e2e_test.exs:1700-1764` (`T3-PAIR-03`):
  `Req.Test.expect(YouTubeClientMock, ...)` is called in preceding steps, so `Req.Test.allow(YouTubeClientMock, self(), poller)` succeeds.

---

## 2. Logic Chain

1. **Step 1**: In `Req.Test`'s private ownership mode (default for unshared ExUnit tests), an allowance for a mock key can only be delegated by a process that is currently an owner of that key (`deps/req/lib/req/test/ownership.ex:153-163`).
2. **Step 2**: A process only becomes an owner of a mock key when `Req.Test.expect/3` or `Req.Test.stub/2` is called in that process (`deps/req/lib/req/test.ex:437-440`).
3. **Step 3**: In the 8 failing E2E tests, `Req.Test.allow(YouTubeClientMock, self(), poller)` is called before any `Req.Test.expect` or `Req.Test.stub` has been invoked by `self()`.
4. **Step 4**: As a direct consequence, `Req.Test.allow` returns `{:error, :not_allowed}` and does not add the poller GenServer PID to `state.allowances`.
5. **Step 5**: When `Poller.poll_once/1` is called, the poller GenServer process executes `Req.Test.__fetch_plug__(YouTubeClientMock)`, which fails to find any allowance for the poller PID and raises `** (RuntimeError) cannot find mock/stub YouTubeClientMock in process #PID<...>`.
6. **Step 6**: Moving `Req.Test.expect(YouTubeClientMock, ...)` (and `Req.Test.expect(YouTubeOAuthMock, ...)` for `T4-SCENARIO-03`) before `Req.Test.allow` guarantees `self()` is registered as an owner, enabling `allow` to grant the poller GenServer access to the mock plugs.

---

## 3. Caveats
- `T4-SCENARIO-03` tests token expiration on a 401 response and subsequent token refresh; it requires allowances for **both** `YouTubeClientMock` and `YouTubeOAuthMock`. Both expectations must be declared before their respective `Req.Test.allow` invocations.
- No production source code modifications in `lib/lux/integrations/youtube/` are required to fix these 8 failures; all fixes are strictly test structure remediation in `test/e2e/youtube_integration_e2e_test.exs`.
- Other non-poller failures reported in the victory audit (e.g. `T2-F2-01`, `T2-F2-02`, `T2-F5-02`, `T2-F6-01`, and `live_chat.ex` unit test coverage) are handled separately by their assigned explorer/implementer agents.

---

## 4. Conclusion
The 8 failing poller E2E tests are resolved by reordering the test setup statements in `test/e2e/youtube_integration_e2e_test.exs` so that `Req.Test.expect(YouTubeClientMock, ...)` (and `YouTubeOAuthMock` where applicable) is called **before** `Req.Test.allow(..., self(), poller)`.

Complete drop-in code snippets for all 8 tests are documented in `analysis.md`.

---

## 5. Verification Method

### Test Commands
1. Run individual poller E2E tests:
   ```bash
   mix test test/e2e/youtube_integration_e2e_test.exs:987
   mix test test/e2e/youtube_integration_e2e_test.exs:1021
   mix test test/e2e/youtube_integration_e2e_test.exs:1426
   mix test test/e2e/youtube_integration_e2e_test.exs:1783
   mix test test/e2e/youtube_integration_e2e_test.exs:1977
   mix test test/e2e/youtube_integration_e2e_test.exs:2359
   mix test test/e2e/youtube_integration_e2e_test.exs:2457
   mix test test/e2e/youtube_integration_e2e_test.exs:2542
   ```
2. Run full poller unit and E2E suites:
   ```bash
   mix test test/unit/lux/integrations/youtube/poller_test.exs
   mix test test/e2e/youtube_integration_e2e_test.exs
   ```

### Invalidation Conditions
The conclusion would be invalidated if `Req.Test.allow/3` succeeded even when called before `expect/3`, or if `Poller` background requests failed after placing `expect` before `allow`. The code inspection of `Req.Test.Ownership.handle_call({:allow, ...})` confirms this cannot occur.
