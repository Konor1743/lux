# Analysis Report: Requirement R3 & Test Suite Investigation (PR #99)

## Executive Summary
This investigation analyzes Requirement R3 and the test suite strategy for PR #99 in the `lux` codebase.
Specifically:
1. **Requirement R3 Analysis**: `Lux.LLM.OpenAI` currently hardcodes `@endpoint` (`"https://api.openai.com/v1/chat/completions"`) in `call/3` (line 134), ignoring `config.endpoint` set in `%Lux.LLM.OpenAI.Config{}` or passed options. Modifying `url: @endpoint` to `url: Lux.Config.resolve(config.endpoint || @endpoint)` resolves this issue dynamically while remaining consistent with sibling provider modules like `Lux.LLM.Anthropic` and `Lux.LLM.OpenRouter`.
2. **HTTP Mocking Patterns**: HTTP calls across `lux` are intercepted using `Req.Test`. `test/test_helper.exs` configures `Application.put_env(:lux, OpenAI, plug: {Req.Test, OpenAI})`, allowing `Req.Test.expect(OpenAI, fn conn -> ... end)` to inspect `Plug.Conn` properties (`scheme`, `host`, `port`, `request_path`, `headers`).
3. **Acceptance Criterion 3 Test Plan**: We design unit tests in `test/unit/lux/llm/open_ai_test.exs` that pass custom `endpoint` values to `OpenAI.call/3` and assert inside `Req.Test.expect` that `conn.scheme`, `conn.host`, `conn.port`, and `conn.request_path` match the overridden endpoint URL.
4. **Acceptance Criterion 4 Test Suite Verification**: Running `mix test` passes cleanly with **1,367 tests and 0 failures**.

---

## 1. Investigation of `Lux.LLM.OpenAI` and HTTP Request Construction

### File Location
- Source: `/home/Konor1743/Operacion Dolar/lux/lux/lib/lux/llm/open_ai.ex`

### Current Implementation Details
In `lib/lux/llm/open_ai.ex`:
- **Module attribute**: `@endpoint "https://api.openai.com/v1/chat/completions"` (line 18)
- **Config struct**: `Lux.LLM.OpenAI.Config` (lines 56–95) defines `endpoint: "https://api.openai.com/v1/chat/completions"`.
- **Function `call/3`** (lines 98–157):
  ```elixir
  98: def call(prompt, tools, config) do
  ...
  107:   config =
  108:     struct(
  109:       Config,
  110:       Map.merge(
  111:         %{
  112:           model: Application.get_env(:lux, :open_ai_models)[:default] || "gpt-4",
  113:           api_key: Application.get_env(:lux, :api_keys)[:openai]
  114:         },
  115:         opts_map
  116:       )
  117:     )
  ...
  133:   [
  134:     url: @endpoint,
  135:     json: body,
  136:     headers: [
  137:       {"Authorization", "Bearer #{Lux.Config.resolve(config.api_key)}"},
  138:       {"Content-Type", "application/json"}
  139:     ]
  140:   ]
  141:   |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
  142:   |> Req.new()
  143:   |> Req.post()
  ```

### Problem Identified
Line 134 uses `url: @endpoint`. Even when a caller provides a custom endpoint (e.g. `endpoint: "http://localhost:4000/v1/chat/completions"` or `endpoint: "https://custom-openai-proxy.com/v1/chat/completions"`) via `%Lux.LLM.OpenAI.Config{}` or keyword/map options, the `config.endpoint` field is populated in `config` but ignored when creating the `Req` options list.

### Comparison with Sibling LLM Providers
- `Lux.LLM.Anthropic` (`lib/lux/llm/anthropic.ex` line 129):
  `url: Lux.Config.resolve(config.endpoint || @endpoint)`
- `Lux.LLM.OpenRouter` (`lib/lux/llm/open_router.ex` line 213):
  `url: Lux.Config.resolve(config.endpoint || @default_endpoint)`

---

## 2. Requirement R3: Detailed Technical Design & Proposed Changes

### Proposed Code Modification
Modify `lib/lux/llm/open_ai.ex` at line 134:

**Before (line 134):**
```elixir
url: @endpoint,
```

**After (line 134):**
```elixir
url: Lux.Config.resolve(config.endpoint || @endpoint),
```

### Key Rationale
1. **Dynamic endpoint resolution**: Uses the `endpoint` key from `config` struct, allowing callers to point to custom base URLs, local proxies, or mock endpoints.
2. **Support for `Lux.Config.resolve/1`**: Calling `Lux.Config.resolve/1` allows config values to be env/system tuples such as `endpoint: {:env, "OPENAI_BASE_URL"}` or `endpoint: {:system, "OPENAI_BASE_URL"}`.
3. **Fallback safety**: `config.endpoint || @endpoint` guarantees that if `config.endpoint` is somehow `nil`, it gracefully falls back to `@endpoint` (`"https://api.openai.com/v1/chat/completions"`).
4. **Consistency**: Matches the exact pattern used in `Lux.LLM.Anthropic`.

---

## 3. Inspection of HTTP Mocking and Testing Architecture

### How HTTP Calls are Mocked in `lux`
The test suite utilizes `Req.Test` (built into `Req`) for HTTP mocking across LLM providers and Lenses:
1. **Test Environment Configuration** (`test/test_helper.exs` line 23):
   ```elixir
   Application.put_env(:lux, OpenAI, plug: {Req.Test, OpenAI})
   ```
2. **Req Pipeline Integration** (`lib/lux/llm/open_ai.ex` line 141):
   `Keyword.merge(Application.get_env(:lux, __MODULE__, []))` merges `[plug: {Req.Test, Lux.LLM.OpenAI}]` into the Keyword list supplied to `Req.new()`.
3. **Test Interception**:
   In tests (e.g. `test/unit/lux/llm/open_ai_test.exs`), `Req.Test.expect(OpenAI, fn conn -> ... end)` sets up an expectation plug that receives a `Plug.Conn` struct representing the request.

### `Plug.Conn` Properties for URL Verification
When `Req` issues a request to a URL, `Req.Test` parses the destination URL into `Plug.Conn`:
- `conn.scheme`: Atom or String (`:http` / `:https` or `"http"` / `"https"`)
- `conn.host`: Target hostname (e.g. `"localhost"` or `"custom-proxy.example.com"`)
- `conn.port`: Target port number (e.g. `4000` or `443`)
- `conn.request_path`: Target URL path (e.g. `"/v1/chat/completions"` or `"/custom/v1/chat/completions"`)

---

## 4. Test Strategy for Acceptance Criterion 3

### Criterion Requirement
"Existe una prueba que intercepta la petición HTTP de OpenAI y afirma (assert) que la URL destino corresponde al `endpoint` sobreescrito en la configuración."

### Proposed Test Implementation
Add the following test case into `test/unit/lux/llm/open_ai_test.exs` under `describe "call/3"`:

```elixir
test "uses dynamic endpoint from config when overridden" do
  custom_endpoint = "http://localhost:4000/custom/v1/chat/completions"

  config = %{
    api_key: "test_key",
    model: "gpt-4o",
    endpoint: custom_endpoint
  }

  Req.Test.expect(OpenAI, fn conn ->
    assert conn.method == "POST"
    assert conn.host == "localhost"
    assert conn.port == 4000
    assert conn.request_path == "/custom/v1/chat/completions"

    request_url = "#{conn.scheme}://#{conn.host}:#{conn.port}#{conn.request_path}"
    assert request_url == custom_endpoint

    Req.Test.json(conn, %{
      "model" => "gpt-4o",
      "choices" => [
        %{
          "message" => %{
            "content" => ~s({"result": "custom endpoint success"})
          },
          "finish_reason" => "stop"
        }
      ]
    })
  end)

  assert {:ok, %Signal{payload: %{content: %{"result" => "custom endpoint success"}}}} =
           OpenAI.call("test prompt", [], config)
end
```

### Additional Test Case (Struct & Runtime Config Resolution)
```elixir
test "resolves dynamic endpoint specified as struct and runtime env tuple" do
  System.put_env("TEST_OPENAI_ENDPOINT", "https://custom-proxy.test/v1/chat/completions")

  config = %OpenAI.Config{
    api_key: "test_key",
    model: "gpt-4o",
    endpoint: {:env, "TEST_OPENAI_ENDPOINT"}
  }

  Req.Test.expect(OpenAI, fn conn ->
    assert conn.host == "custom-proxy.test"
    assert conn.request_path == "/v1/chat/completions"

    Req.Test.json(conn, %{
      "model" => "gpt-4o",
      "choices" => [%{"message" => %{"content" => ~s({"result": "OK"})}, "finish_reason" => "stop"}]
    })
  end)

  assert {:ok, %Signal{}} = OpenAI.call("test prompt", [], config)
end
```

---

## 5. Verification of Acceptance Criterion 4 (`mix test`)

### Test Suite Execution Summary
- Command: `mix test`
- Outcome: **1,367 tests passed, 0 failures** (Finished in 13.9s).
- Direct module run (`mix test test/unit/lux/llm/open_ai_test.exs --include unit`): **5/5 tests passed, 0 failures**.

### Explanation of ExUnit Tag Configuration
- In `test/test_helper.exs`:
  `ExUnit.start(exclude: [:skip, :integration, :unit])`
- By default, standard `mix test` excludes `:unit` and `:integration` tags to avoid unmocked external API network attempts during default local builds.
- All non-excluded tests pass cleanly. `mix test` passes 100% locally.

---

## 6. Recommendations for Implementation (For Implementer Agent)

1. **Modify `lib/lux/llm/open_ai.ex`**:
   - Change line 134 to:
     `url: Lux.Config.resolve(config.endpoint || @endpoint),`
2. **Add Unit Test in `test/unit/lux/llm/open_ai_test.exs`**:
   - Add the test case for custom `endpoint` interception and URL assertions.
3. **Verify locally**:
   - Run `mix test test/unit/lux/llm/open_ai_test.exs --include unit`
   - Run `mix test`
