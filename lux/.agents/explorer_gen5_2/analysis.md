# Detailed Investigation & Analysis: E2E Test Remediation (Explorer 2)

## Executive Summary
This report analyzes 4 failing E2E tests in `test/e2e/youtube_integration_e2e_test.exs` identified during the victory audit:
1. `T2-F2-01: 401 Auto-Refresh Infinite Loop Prevention` (line 1197)
2. `T2-F2-02: Client Handling Network Transport Error / Disconnection` (line 1220)
3. `T2-F5-02: Missing or Blank Message Text / Chat ID in insert_message/3` (line 1407)
4. `T2-F6-01: Quota Exhaustion Extraction from Varied Google Error Formats` (line 1483)

Our investigation reveals that **all four failures stem from test configuration and assertion mismatches** rather than bugs in `lib/lux/integrations/youtube/`. The core implementation in `Client`, `OAuth`, `Errors`, and `LiveChat` correctly adheres to its documented contracts and API specifications.

---

## Detailed Investigation by Test Case

### 1. T2-F2-01: 401 Auto-Refresh Infinite Loop Prevention (Line 1197)

#### Observation
- **Test location**: `test/e2e/youtube_integration_e2e_test.exs:1197-1218`
- **Error encountered**: `** (RuntimeError) expected YouTubeOAuthMock to be still used 1 more times`
- **Test Code**:
  ```elixir
  test "T2-F2-01: 401 Auto-Refresh Infinite Loop Prevention" do
    Req.Test.expect(YouTubeClientMock, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
    end)

    Req.Test.expect(YouTubeOAuthMock, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
    end)

    res =
      Client.request(:get, "/liveBroadcasts",
        token: "bad_token",
        refresh_token: "expired_refresh",
        auto_refresh: true
      )

    assert res == {:error, :invalid_token}
  end
  ```

#### Logic Chain & Root Cause
1. In `lib/lux/integrations/youtube/client.ex:93-109`:
   ```elixir
   {:ok, %{status: 401} = response} ->
     if auto_refresh and retry_count < 1 do
       case attempt_token_refresh(opts_map) do
         {:ok, new_token} -> ...
         {:error, _refresh_err} -> Errors.parse(response)
       end
     else
       Errors.parse(response)
     end
   ```
2. In `lib/lux/integrations/youtube/client.ex:220-249`:
   ```elixir
   defp attempt_token_refresh(opts) do
     refresh_token = opts[:refresh_token] || safe_config_access(:youtube_refresh_token)
     client_id = opts[:client_id] || safe_config_access(:youtube_client_id)
     client_secret = opts[:client_secret] || safe_config_access(:youtube_client_secret)

     if refresh_token && refresh_token != "" do
       oauth_opts = %{client_id: client_id, client_secret: client_secret}
       ...
       case OAuth.refresh_token(refresh_token, oauth_opts) do ... end
     else
       {:error, :no_refresh_token}
     end
   end
   ```
3. In `lib/lux/integrations/youtube/oauth.ex:131-141`:
   ```elixir
   def refresh_token(refresh_token, opts \\ %{}) when is_binary(refresh_token) do
     opts_map = to_map(opts)
     client_id = opts_map[:client_id] || get_config(:youtube_client_id)
     client_secret = opts_map[:client_secret] || get_config(:youtube_client_secret)

     if is_nil(client_id) or client_id == "" or is_nil(client_secret) or client_secret == "" do
       {:error, :missing_credentials}
     else
       ...
       execute_token_request(form_body, opts_map)
     end
   end
   ```
4. In the test, `opts` passed to `Client.request/3` did **not** specify `:client_id` or `:client_secret`.
5. Because no application environment credentials exist in the test environment (`safe_config_access(:youtube_client_id)` returns `nil`), `OAuth.refresh_token/2` returned `{:error, :missing_credentials}` immediately.
6. As a result, `execute_token_request/2` was never called, and `YouTubeOAuthMock` was never invoked (0 calls instead of 1 call).
7. `Client.request/3` caught `{:error, :missing_credentials}` and called `Errors.parse(response)` (401), returning `{:error, :invalid_token}`. The assertion passed, but `Req.Test.verify_on_exit!/0` failed because the expected `YouTubeOAuthMock` expectation was unfulfilled.

#### Remediation
Pass `client_id: "cid"` and `client_secret: "sec"` to `Client.request/3` in the test.

---

### 2. T2-F2-02: Client Handling Network Transport Error / Disconnection (Line 1220)

#### Observation
- **Test location**: `test/e2e/youtube_integration_e2e_test.exs:1220-1228`
- **Error encountered**: `** (ArgumentError) expected to return %Plug.Conn{}, got: {:error, %Req.TransportError{reason: :econnrefused}}`
- **Test Code**:
  ```elixir
  test "T2-F2-02: Client Handling Network Transport Error / Disconnection" do
    Req.Test.expect(YouTubeClientMock, fn _conn ->
      {:error, %Req.TransportError{reason: :econnrefused}}
    end)

    res = Client.get("/liveBroadcasts", token: "tok")
    assert match?({:error, %Req.TransportError{reason: :econnrefused}}, res)
    assert Errors.retryable?(res) == true
  end
  ```

#### Logic Chain & Root Cause
1. `Req.Test` uses Plug adapters to intercept HTTP requests in test suites. The stub/expectation callback in `Req.Test.expect(PlugMock, fn conn -> ... end)` MUST return a `%Plug.Conn{}` struct.
2. In Elixir Plug, returning a non-conn term (such as a tuple `{:error, ...}`) raises `ArgumentError: expected to return %Plug.Conn{}` when Plug attempts to process the connection.
3. Req provides a dedicated helper specifically for simulating transport and network connection failures:
   `Req.Test.transport_error(conn, reason)` (defined in `deps/req/lib/req/test.ex:325`).
4. Calling `Req.Test.transport_error(conn, :econnrefused)` sets `conn.private[:req_test_exception]` to `%Req.TransportError{reason: :econnrefused}` and returns the updated `conn`. Req's pipeline then safely turns this into `{:error, %Req.TransportError{reason: :econnrefused}}` returned to `Client.get/2`.

#### Remediation
Change the mock callback to:
```elixir
Req.Test.expect(YouTubeClientMock, fn conn ->
  Req.Test.transport_error(conn, :econnrefused)
end)
```

---

### 3. T2-F5-02: Missing or Blank Message Text / Chat ID in insert_message/3 (Line 1407)

#### Observation
- **Test location**: `test/e2e/youtube_integration_e2e_test.exs:1407-1412`
- **Error encountered**: `match (=) failed. left: {:error, :invalid_message_text}, right: {:error, :empty_message_text}`
- **Test Code**:
  ```elixir
  test "T2-F5-02: Missing or Blank Message Text / Chat ID in insert_message/3" do
    assert {:error, :invalid_message_text} = LiveChat.insert_message("chat1", "", token: "tok")
    assert {:error, :invalid_message_text} = LiveChat.insert_message("chat1", nil, token: "tok")
    assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "Hello", token: "tok")
  end
  ```

#### Logic Chain & Root Cause
1. In `lib/lux/integrations/youtube/live_chat.ex:142-160`:
   ```elixir
   @doc """
   ...
   ## Returns
   - `{:ok, message_map}` with the created message item.
   - `{:error, :missing_live_chat_id}` if `live_chat_id` is blank.
   - `{:error, :empty_message_text}` if `message_text` is blank.
   - `{:error, reason}` on API or network failure.
   """
   @spec insert_message(live_chat_id(), String.t(), client_opts()) ::
           {:ok, map()} | {:error, term()}
   def insert_message(live_chat_id, message_text, opts \\ %{})

   def insert_message(live_chat_id, _message_text, _opts)
       when not is_binary(live_chat_id) or live_chat_id == "" do
     {:error, :missing_live_chat_id}
   end

   def insert_message(_live_chat_id, message_text, _opts)
       when not is_binary(message_text) or message_text == "" do
     {:error, :empty_message_text}
   end
   ```
2. The implementation, `@doc`, `@spec`, and all unit tests in the repository (`test/unit/lux/integrations/youtube/live_chat_test.exs:314`, `live_chat_fault_injection_test.exs:1086`, `lenses_prisms_domain_adversarial_test.exs:29`) consistently use and test `{:error, :empty_message_text}`.
3. The E2E test asserted `{:error, :invalid_message_text}`, causing a pattern match error.

#### Remediation
Update the E2E test assertions to expect `{:error, :empty_message_text}`.

---

### 4. T2-F6-01: Quota Exhaustion Extraction from Varied Google Error Formats (Line 1483)

#### Observation
- **Test location**: `test/e2e/youtube_integration_e2e_test.exs:1483-1491`
- **Error encountered**: `match (=) failed. left: {:error, {:quota_exceeded, _}}, right: {:error, {403, "RESOURCE_EXHAUSTED"}}`
- **Test Code**:
  ```elixir
  test "T2-F6-01: Quota Exhaustion Extraction from Varied Google Error Formats" do
    b1 = %{"error" => "QUOTA_EXCEEDED"}
    b2 = %{"error" => %{"errors" => [%{"reason" => "dailyLimitExceeded"}]}}
    b3 = "RESOURCE_EXHAUSTED"

    assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b1, [])
    assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b2, [])
    assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b3, [])
  end
  ```

#### Logic Chain & Root Cause
1. `Errors.parse/3` is designed to parse error responses from three primary Google API formats:
   - Format 1 (OAuth flat error): `%{"error" => "QUOTA_EXCEEDED"}`
   - Format 2 (YouTube Data API v3 classic JSON): `%{"error" => %{"errors" => [%{"reason" => "dailyLimitExceeded"}]}}`
   - Format 3 (Google Cloud API / gRPC status error): `%{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}` (or `%{"error" => %{"code" => 403, "status" => "RESOURCE_EXHAUSTED"}}`).
2. In `lib/lux/integrations/youtube/errors.ex:132-150`:
   ```elixir
   reason =
     first_error["reason"] ||
       first_error[:reason] ||
       detail_reason ||
       error_map["reason"] ||
       error_map[:reason] ||
       error_map["status"] ||
       error_map[:status]
   ```
   `Errors.extract_error_info/1` inspects `error_map["status"]` to detect gRPC status codes like `"RESOURCE_EXHAUSTED"`.
3. In `lib/lux/integrations/youtube/errors.ex:36-42`:
   `"RESOURCE_EXHAUSTED"` is explicitly registered in `@quota_reasons`.
4. However, the test passed `b3 = "RESOURCE_EXHAUSTED"` as a bare unparsed string rather than the Google Cloud error map structure `%{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}`.
5. When `b3` is a bare string, `Jason.decode(b3)` fails with a decode error, falling back to `%{reason: nil, message: "RESOURCE_EXHAUSTED"}`. Since `reason` is `nil`, `classify/4` classifies it as a generic `{403, "RESOURCE_EXHAUSTED"}` error.

#### Remediation
Update `b3` in the test to `%{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}`.

---

## Proposed Code Changes

Target file: `/home/Konor1743/Operacion Dolar/lux/lux/test/e2e/youtube_integration_e2e_test.exs`

### Chunk 1: T2-F2-01 & T2-F2-02 (Lines 1197-1228)
```elixir
<<<<
    test "T2-F2-01: 401 Auto-Refresh Infinite Loop Prevention" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      res =
        Client.request(:get, "/liveBroadcasts",
          token: "bad_token",
          refresh_token: "expired_refresh",
          auto_refresh: true
        )

      assert res == {:error, :invalid_token}
    end

    test "T2-F2-02: Client Handling Network Transport Error / Disconnection" do
      Req.Test.expect(YouTubeClientMock, fn _conn ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      res = Client.get("/liveBroadcasts", token: "tok")
      assert match?({:error, %Req.TransportError{reason: :econnrefused}}, res)
      assert Errors.retryable?(res) == true
    end
====
    test "T2-F2-01: 401 Auto-Refresh Infinite Loop Prevention" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"code" => 401}}))
      end)

      Req.Test.expect(YouTubeOAuthMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      res =
        Client.request(:get, "/liveBroadcasts",
          token: "bad_token",
          refresh_token: "expired_refresh",
          client_id: "cid",
          client_secret: "sec",
          auto_refresh: true
        )

      assert res == {:error, :invalid_token}
    end

    test "T2-F2-02: Client Handling Network Transport Error / Disconnection" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      res = Client.get("/liveBroadcasts", token: "tok")
      assert match?({:error, %Req.TransportError{reason: :econnrefused}}, res)
      assert Errors.retryable?(res) == true
    end
>>>>
```

### Chunk 2: T2-F5-02 (Lines 1407-1412)
```elixir
<<<<
    test "T2-F5-02: Missing or Blank Message Text / Chat ID in insert_message/3" do
      assert {:error, :invalid_message_text} = LiveChat.insert_message("chat1", "", token: "tok")
      assert {:error, :invalid_message_text} = LiveChat.insert_message("chat1", nil, token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "Hello", token: "tok")
    end
====
    test "T2-F5-02: Missing or Blank Message Text / Chat ID in insert_message/3" do
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat1", "", token: "tok")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat1", nil, token: "tok")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message("", "Hello", token: "tok")
    end
>>>>
```

### Chunk 3: T2-F6-01 (Lines 1483-1491)
```elixir
<<<<
    test "T2-F6-01: Quota Exhaustion Extraction from Varied Google Error Formats" do
      b1 = %{"error" => "QUOTA_EXCEEDED"}
      b2 = %{"error" => %{"errors" => [%{"reason" => "dailyLimitExceeded"}]}}
      b3 = "RESOURCE_EXHAUSTED"

      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b1, [])
      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b2, [])
      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b3, [])
    end
====
    test "T2-F6-01: Quota Exhaustion Extraction from Varied Google Error Formats" do
      b1 = %{"error" => "QUOTA_EXCEEDED"}
      b2 = %{"error" => %{"errors" => [%{"reason" => "dailyLimitExceeded"}]}}
      b3 = %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}

      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b1, [])
      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b2, [])
      assert {:error, {:quota_exceeded, _}} = Errors.parse(403, b3, [])
    end
>>>>
```
