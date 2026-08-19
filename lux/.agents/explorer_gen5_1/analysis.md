# Analysis: Poller GenServer Mock Sharing Remediation in E2E Tests

## Executive Summary
In Milestone 5 victory audit, 8 of the 12 failing E2E tests in `test/e2e/youtube_integration_e2e_test.exs` failed with:
`** (RuntimeError) cannot find mock/stub YouTubeClientMock in process #PID<...>`

Investigation of `Req.Test` (Req 0.5.10 / `Req.Test.Ownership`) and the test suite revealed that in every one of the 8 failing tests, `Req.Test.allow(YouTubeClientMock, self(), poller)` (and `Req.Test.allow(YouTubeOAuthMock, self(), poller)`) was invoked **before** any expectation (`Req.Test.expect/3`) or stub (`Req.Test.stub/2`) was registered on the mock by the test process (`self()`).

Because `self()` is not yet an owner of the mock key in `Req.Test.Ownership` prior to registering an expectation/stub, `Req.Test.allow/3` fails silently with `{:error, %Req.Test.OwnershipError{reason: :not_allowed}}`. When the background Poller process subsequently calls `Poller.poll_once/1`, the Poller PID has not been granted allowance and crashes when `Req.Test.__fetch_plug__/1` tries to locate the mock.

Conversely, all passing tests (e.g., unit tests in `poller_test.exs`, and E2E tests `T3-PAIR-03`, `T4-SCENARIO-01`) register expectations on `YouTubeClientMock` **before** calling `Req.Test.allow(YouTubeClientMock, self(), poller)`.

---

## Technical Root Cause Deep-Dive

### 1. Req.Test Ownership Mechanism
In `deps/req/lib/req/test/ownership.ex`:
```elixir
def handle_call({:allow, pid_with_access, pid_to_allow, key}, _from, %{mode: :private} = state) do
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
When `Req.Test.allow(YouTubeClientMock, self(), poller)` is evaluated:
- `pid_with_access` is `self()`.
- `key` is `YouTubeClientMock`.
- `state.owners[self()][YouTubeClientMock]` only exists if `Req.Test.expect(YouTubeClientMock, ...)` or `Req.Test.stub(YouTubeClientMock, ...)` was previously called by `self()`.
- If no expectation or stub has been registered yet, `allow/3` throws `{:error, :not_allowed}` and returns `{:error, ...}` without raising an exception.
- When `Poller.poll_once/1` executes inside the Poller GenServer process, `Req.Test.__fetch_plug__(YouTubeClientMock)` checks if the Poller PID is allowed. Since the allowance was never added, it raises:
  `cannot find mock/stub YouTubeClientMock in process #PID<...>`

### 2. Difference Between Passing and Failing Tests
| Test File / Test Name | Mock Setup Flow | Result |
|---|---|---|
| `test/unit/.../poller_test.exs` | `Req.Test.expect` → `Poller.start_link` → `Req.Test.allow` → `Poller.poll_once` | **PASS** |
| `test/e2e/...` (`T3-PAIR-03`) | `Req.Test.expect` → `Poller.start_link` → `Req.Test.allow` → `Poller.poll_once` | **PASS** |
| `test/e2e/...` (`T4-SCENARIO-01`) | `Req.Test.expect` (earlier phases) → `Poller.start_link` → `Req.Test.allow` → `Poller.poll_once` | **PASS** |
| `test/e2e/...` (8 failing tests) | `Poller.start_link` → `Req.Test.allow` (fails silently) → `Req.Test.expect` → `Poller.poll_once` (crashes) | **FAIL** |

---

## Detailed Audit of the 8 Failing E2E Tests

### 1. `T1-F5-04: Poller GenServer Message Ingestion & Subscriber Notification` (Line 987)
- **Current Sequence**:
  1. Line 988: `{:ok, poller} = Poller.start_link(...)`
  2. Line 996: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no expectations yet)*
  3. Line 1001: `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)`
  4. Line 1007: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Move fixture setup and `Req.Test.expect(YouTubeClientMock, ...)` before `Poller.start_link(...)` and `Req.Test.allow(YouTubeClientMock, self(), poller)`.

### 2. `T1-F5-05: Poller Dynamic Polling Interval Adjustment` (Line 1021)
- **Current Sequence**:
  1. Line 1022: `{:ok, poller} = Poller.start_link(...)`
  2. Line 1032: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no expectations yet)*
  3. Line 1034: `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)`
  4. Line 1040: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Define `Req.Test.expect(YouTubeClientMock, ...)` before `Poller.start_link(...)` and `Req.Test.allow(YouTubeClientMock, self(), poller)`.

### 3. `T2-F5-04: Poller Handling Broadcast Termination Signal (offlineAt)` (Line 1426)
- **Current Sequence**:
  1. Line 1427: `{:ok, poller} = Poller.start_link(...)`
  2. Line 1435: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no expectations yet)*
  3. Line 1437: `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)`
  4. Line 1446: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Define `Req.Test.expect(YouTubeClientMock, ...)` before `Poller.start_link(...)` and `Req.Test.allow(YouTubeClientMock, self(), poller)`.

### 4. `T3-PAIR-04: F5 (LiveChat) + F6 (Resiliency) - Poller 429 Throttle & 403 Quota Recovery` (Line 1783)
- **Current Sequence**:
  1. Line 1784: `{:ok, poller} = Poller.start_link(...)`
  2. Line 1792: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no expectations yet)*
  3. Line 1795: Stage 1 `Req.Test.expect(YouTubeClientMock, ...)` (429 Rate Limit)
  4. Line 1805: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Define Stage 1 `Req.Test.expect(YouTubeClientMock, ...)` before `Poller.start_link(...)` and `Req.Test.allow(YouTubeClientMock, self(), poller)`.

### 5. `T3-PAIR-08: F3 + F5 + F4 - Full Teardown & Broadcast Termination Signal Propagation` (Line 1977)
- **Current Sequence**:
  1. Line 1978: `{:ok, poller} = Poller.start_link(...)`
  2. Line 1986: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no expectations yet)*
  3. Line 1989: `Req.Test.expect(YouTubeClientMock, ...)` for `transition_broadcast` (called in test process)
  4. Line 2004: `Req.Test.expect(YouTubeClientMock, ...)` for Poller offlineAt detection
  5. Line 2013: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Execute Step 1 (`transition_broadcast`) first, then start Poller and call `Req.Test.allow(YouTubeClientMock, self(), poller)` (since `self()` is already an owner after Step 1's expect), or define expectations before `allow`.

### 6. `T4-SCENARIO-02: Automated Chat Bot & Live Moderation Workflow` (Line 2359)
- **Current Sequence**:
  1. Line 2360: `{:ok, poller} = Poller.start_link(...)`
  2. Line 2368: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no expectations yet)*
  3. Line 2389: `Req.Test.expect(YouTubeClientMock, ...)` for chat message list
  4. Line 2395: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Define fixtures and first `Req.Test.expect(YouTubeClientMock, ...)` before `Poller.start_link(...)` and `Req.Test.allow(YouTubeClientMock, self(), poller)`.

### 7. `T4-SCENARIO-03: Token Expiration and Resilient Recovery During Active Broadcast` (Line 2457)
- **Current Sequence**:
  1. Line 2466: `{:ok, poller} = Poller.start_link(...)`
  2. Line 2474: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no YouTubeClientMock expectations yet)*
  3. Line 2475: `Req.Test.allow(YouTubeOAuthMock, self(), poller)` *(Fails: no YouTubeOAuthMock expectations yet)*
  4. Line 2478: `Req.Test.expect(YouTubeClientMock, ...)` (401 response)
  5. Line 2487: `Req.Test.expect(YouTubeOAuthMock, ...)` (token refresh response)
  6. Line 2499: `Req.Test.expect(YouTubeClientMock, ...)` (retried chat list request)
  7. Line 2507: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Define `Req.Test.expect(YouTubeClientMock, ...)` (401), `Req.Test.expect(YouTubeOAuthMock, ...)`, and `Req.Test.expect(YouTubeClientMock, ...)` (retry) before calling `Req.Test.allow(YouTubeClientMock, self(), poller)` and `Req.Test.allow(YouTubeOAuthMock, self(), poller)`.

### 8. `T4-SCENARIO-04: Quota Degradation & Rate Limit Backoff Handling during Peak Chat Traffic` (Line 2542)
- **Current Sequence**:
  1. Line 2543: `{:ok, poller} = Poller.start_link(...)`
  2. Line 2552: `Req.Test.allow(YouTubeClientMock, self(), poller)` *(Fails: no expectations yet)*
  3. Line 2555: Stage 1 `Req.Test.expect(YouTubeClientMock, ...)` (429 rate limit)
  4. Line 2565: `Poller.poll_once(poller)` *(Crashes)*
- **Remediation**:
  Define Stage 1 `Req.Test.expect(YouTubeClientMock, ...)` before `Poller.start_link(...)` and `Req.Test.allow(YouTubeClientMock, self(), poller)`.

---

## LiveChat.start_poller/1 Verification
- `LiveChat.start_poller/1` (`lib/lux/integrations/youtube/live_chat.ex:251`) delegates directly to `Poller.start_link(opts)`.
- It returns `{:ok, pid}` on success and `{:error, reason}` on failure.
- Both `Poller.start_link/1` and `LiveChat.start_poller/1` behave identically with respect to `Req.Test.allow/3`.

---

## Exact Code Remediation Proposals

Below are the exact before/after code blocks for implementers.

### Fix 1: T1-F5-04 (`test/e2e/youtube_integration_e2e_test.exs:987`)
```elixir
    test "T1-F5-04: Poller GenServer Message Ingestion & Subscriber Notification" do
      msg1 = chat_message_fixture("m1", "Hi 1")
      msg2 = chat_message_fixture("m2", "Hi 2")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg1, msg2], "cursor_2", 3000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_poller_1",
          auto_start: false,
          subscriber: self(),
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, msgs} = Poller.poll_once(poller)
      assert length(msgs) == 2

      assert_receive {:live_chat_messages, "chat_poller_1", received_msgs}
      assert length(received_msgs) == 2

      status = Poller.get_status(poller)
      assert status.page_token == "cursor_2"
      assert status.message_count == 2
      assert status.poll_count == 1

      Poller.stop(poller)
    end
```

### Fix 2: T1-F5-05 (`test/e2e/youtube_integration_e2e_test.exs:1021`)
```elixir
    test "T1-F5-05: Poller Dynamic Polling Interval Adjustment" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([], "c3", 8500)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_interval_test",
          default_interval_ms: 5000,
          min_interval_ms: 1000,
          max_interval_ms: 30_000,
          auto_start: false,
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, _} = Poller.poll_once(poller)
      assert Poller.get_status(poller).interval_ms == 8500

      Poller.stop(poller)
    end
```

### Fix 3: T2-F5-04 (`test/e2e/youtube_integration_e2e_test.exs:1426`)
```elixir
    test "T2-F5-04: Poller Handling Broadcast Termination Signal (offlineAt)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(chat_list_fixture([], "c_end", 3000, "2026-08-20T22:00:00Z"))
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_ended_test",
          subscriber: self(),
          auto_start: false,
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, _} = Poller.poll_once(poller)

      assert_receive {:live_chat_ended, "chat_ended_test", %{offline_at: "2026-08-20T22:00:00Z"}}
      status = Poller.get_status(poller)
      assert status.status == :ended
      assert status.offline_at == "2026-08-20T22:00:00Z"

      Poller.stop(poller)
    end
```

### Fix 4: T3-PAIR-04 (`test/e2e/youtube_integration_e2e_test.exs:1783`)
```elixir
    test "T3-PAIR-04: F5 (LiveChat) + F6 (Resiliency) - Poller 429 Throttle & 403 Quota Recovery" do
      # 1. 429 Rate Limit
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "rateLimitExceeded"}]}})
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_401",
          subscriber: self(),
          auto_start: false,
          token: "tok_valid"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_401", {:rate_limited, %{retry_after: 2}}}
      assert Poller.get_status(poller).consecutive_errors == 1

      # 2. 403 Quota Exhaustion
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "quotaExceeded"}]}})
        )
      end)

      assert {:error, {:quota_exceeded, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_401", {:quota_exceeded, %{reason: "quotaExceeded"}}}
      assert Poller.get_status(poller).consecutive_errors == 2

      # 3. Recovery 200 OK
      msg = chat_message_fixture("m_rec", "Recovered!")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg], "tok_page_3", 3000)))
      end)

      assert {:ok, [rec_msg]} = Poller.poll_once(poller)
      assert rec_msg.id == "m_rec"
      assert_receive {:live_chat_messages, "chat_401", [rec_msg]}

      status = Poller.get_status(poller)
      assert status.consecutive_errors == 0
      assert status.message_count == 1
      assert status.last_error == nil

      Poller.stop(poller)
    end
```

### Fix 5: T3-PAIR-08 (`test/e2e/youtube_integration_e2e_test.exs:1977`)
```elixir
    test "T3-PAIR-08: F3 + F5 + F4 - Full Teardown & Broadcast Termination Signal Propagation" do
      # 1. Complete Broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
        assert conn.query_string =~ "broadcastStatus=complete"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(broadcast_fixture(%{"id" => "bcast_801", "status" => %{"lifeCycleStatus" => "complete"}}))
        )
      end)

      assert {:ok, _} = LiveBroadcasts.transition_broadcast("bcast_801", :complete, token: "tok")

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_801",
          subscriber: self(),
          auto_start: false,
          token: "tok"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      # 2. Poller detects offlineAt
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(chat_list_fixture([], "c_done", 3000, "2026-08-17T21:00:00Z"))
        )
      end)

      assert {:ok, _} = Poller.poll_once(poller)
      assert_receive {:live_chat_ended, "chat_801", %{offline_at: "2026-08-17T21:00:00Z"}}
      assert Poller.get_status(poller).status == :ended

      # 3. Teardown stream and broadcast
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveStreams"

        conn |> Plug.Conn.send_resp(204, "")
      end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"

        conn |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{deleted: true}} = LiveStreams.delete_stream("stream_801", token: "tok")
      assert {:ok, %{deleted: true}} = LiveBroadcasts.delete_broadcast("bcast_801", token: "tok")
      assert :ok = Poller.stop(poller)
    end
```

### Fix 6: T4-SCENARIO-02 (`test/e2e/youtube_integration_e2e_test.exs:2359`)
```elixir
    test "T4-SCENARIO-02: Automated Chat Bot & Live Moderation Workflow" do
      m_cmd = chat_message_fixture("m_cmd", "!help", %{"authorDetails" => %{"displayName" => "Alice"}})
      m_spam = chat_message_fixture("m_spam", "BUY CHEAP COINS http://scam.net", %{"authorDetails" => %{"displayName" => "SpamBot"}})

      m_super =
        chat_message_fixture("m_super", "Great stream!", %{
          "snippet" => %{
            "type" => "superChatEvent",
            "superChatDetails" => %{
              "amountMicros" => 10_000_000,
              "currency" => "USD",
              "amountDisplayString" => "$10.00",
              "userComment" => "Great stream!"
            }
          },
          "authorDetails" => %{"displayName" => "Bob"}
        })

      m_regular = chat_message_fixture("m_chat", "Hello everyone!", %{"authorDetails" => %{"displayName" => "Charlie"}})

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([m_cmd, m_spam, m_super, m_regular], "cursor_mod_2", 3000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_mod_202",
          subscriber: self(),
          auto_start: false,
          token: "tok_mod"
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:ok, messages} = Poller.poll_once(poller)
      assert length(messages) == 4

      # Moderation agent logic
      actions_taken =
        Enum.map(messages, fn msg ->
          cond do
            msg.message_text == "!help" ->
              Req.Test.expect(YouTubeClientMock, fn conn ->
                {:ok, body, conn} = Plug.Conn.read_body(conn)
                decoded = Jason.decode!(body)
                assert decoded["snippet"]["textMessageDetails"]["messageText"] =~ "Commands"

                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "resp_help"}))
              end)

              LiveChat.insert_message("chat_mod_202", "@Alice Bot Commands: !help, !schedule, !about", token: "tok_mod")
              :command_replied

            msg.message_text =~ "http://" or msg.message_text =~ "scam" ->
              :spam_flagged

            LiveChat.super_chat?(msg) ->
              amount = LiveChat.super_chat_amount(msg)

              Req.Test.expect(YouTubeClientMock, fn conn ->
                {:ok, body, conn} = Plug.Conn.read_body(conn)
                decoded = Jason.decode!(body)
                assert decoded["snippet"]["textMessageDetails"]["messageText"] =~ "$10.00"

                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "resp_super"}))
              end)

              LiveChat.insert_message("chat_mod_202", "Thank you Bob for the #{amount} Super Chat!", token: "tok_mod")
              :super_chat_acknowledged

            true ->
              :regular_recorded
          end
        end)

      assert actions_taken == [:command_replied, :spam_flagged, :super_chat_acknowledged, :regular_recorded]

      # Subsequent poll with empty delta
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=cursor_mod_2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([], "cursor_mod_3", 3000)))
      end)

      assert {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).page_token == "cursor_mod_3"

      Poller.stop(poller)
    end
```

### Fix 7: T4-SCENARIO-03 (`test/e2e/youtube_integration_e2e_test.exs:2457`)
```elixir
    test "T4-SCENARIO-03: Token Expiration and Resilient Recovery During Active Broadcast" do
      opts = [
        token: "tok_expired_init",
        refresh_token: "ref_valid_303",
        client_id: "client_303",
        client_secret: "sec_303",
        auto_refresh: true
      ]

      # 1. Background Poller triggers 401
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_expired_init"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      # OAuth token refresh
      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "tok_refreshed_303", "expires_in" => 3600})
        )
      end)

      # Poller retried request with new token
      msg = chat_message_fixture("m_rec_303", "Live stream message")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_refreshed_303"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([msg], "c_303_next", 3000)))
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_303",
          subscriber: self(),
          auto_start: false,
          client_opts: opts
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      Req.Test.allow(YouTubeOAuthMock, self(), poller)

      assert {:ok, msgs} = Poller.poll_once(poller)
      assert length(msgs) == 1

      # 2. Foreground operator broadcast query using refreshed token
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_refreshed_303"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [broadcast_fixture(%{"id" => "bcast_303", "status" => %{"lifeCycleStatus" => "live"}})]
          })
        )
      end)

      assert {:ok, bcast} = LiveBroadcasts.get_broadcast("bcast_303", token: "tok_refreshed_303")
      assert LiveBroadcasts.active?(bcast)

      # 3. Next poller cycle works cleanly with zero errors
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_refreshed_303"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture([], "c_303_final", 3000)))
      end)

      assert {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_status(poller).consecutive_errors == 0

      Poller.stop(poller)
    end
```

### Fix 8: T4-SCENARIO-04 (`test/e2e/youtube_integration_e2e_test.exs:2542`)
```elixir
    test "T4-SCENARIO-04: Quota Degradation & Rate Limit Backoff Handling during Peak Chat Traffic" do
      # Stage 1: 429 Rate Limit
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "rateLimitExceeded"}]}})
        )
      end)

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "chat_burst_404",
          subscriber: self(),
          auto_start: false,
          token: "tok_burst",
          default_interval_ms: 1000
        )

      Req.Test.allow(YouTubeClientMock, self(), poller)

      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_burst_404", {:rate_limited, %{retry_after: 2}}}
      assert Poller.get_status(poller).consecutive_errors == 1

      # Stage 2: 403 Quota Exhaustion
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{"error" => %{"errors" => [%{"reason" => "quotaExceeded"}]}})
        )
      end)

      assert {:error, {:quota_exceeded, _}} = Poller.poll_once(poller)
      assert_receive {:live_chat_error, "chat_burst_404", {:quota_exceeded, _}}
      assert Poller.get_status(poller).consecutive_errors == 2

      # Stage 3: Limit Reset & Backlog Delivery (10 queued messages)
      backlog = Enum.map(1..10, fn i -> chat_message_fixture("m_burst_#{i}", "Burst message #{i}") end)

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(chat_list_fixture(backlog, "cursor_recovered", 5000)))
      end)

      assert {:ok, delivered} = Poller.poll_once(poller)
      assert length(delivered) == 10
      assert_receive {:live_chat_messages, "chat_burst_404", received}
      assert length(received) == 10

      status = Poller.get_status(poller)
      assert status.consecutive_errors == 0
      assert status.message_count == 10
      assert status.interval_ms == 5000

      Poller.stop(poller)
    end
```
