# ExUnit Test Strategy Analysis for LLM Provider Abstraction Layer (Requirement R5)

## Executive Summary
This document details the ExUnit test strategy for the **Universal LLM Provider Abstraction Layer** (Bounty #99) in `lux`. It establishes a comprehensive blueprint for testing `Lux.LLM.ProviderRegistry`, model routing (`:cheapest`, `:smartest`, capability matching), smart 429/503 fallback mechanisms, and cost/telemetry tracking under `test/unit/lux/llm/`. All tests run deterministically in isolations without external network calls or real API keys, utilizing the existing `Req.Test` plug infrastructure integrated into `UnitAPICase`.

---

## 1. Test Environment & Mocking Infrastructure Assessment

### 1.1 Test Suite Organization
- **Configuration File**: `mix.exs`
  - Defines aliases: `"test.unit": "test --include unit"`, `"test.integration": "test --include integration"`.
  - Dependencies available for testing: `:req` (~> 0.5.0, includes `Req.Test`), `:mock` (~> 0.3.0), `:stream_data` (~> 1.0), `:excoveralls` (~> 0.18).
- **Test Helper**: `test/test_helper.exs`
  - `ExUnit.start(exclude: [:skip, :integration, :unit])` excludes `:unit` by default so running `mix test` targets un-tagged tests while `mix test.unit` (or `mix test --include unit`) runs unit tests.
  - Defines `UnitAPICase` using `ExUnit.CaseTemplate` tagged with `@moduletag :unit`.

### 1.2 HTTP Mocking Mechanism (`Req.Test`)
Existing LLM tests (`anthropic_test.exs`, `open_ai_test.exs`, `open_router_test.exs`, `together_ai_test.exs`) rely on `Req.Test`, configured in `test/test_helper.exs`:
```elixir
setup do
  Application.put_env(:lux, :req_options, plug: {Req.Test, Lux.Lens})
  Application.put_env(:lux, OpenAI, plug: {Req.Test, OpenAI})
  Application.put_env(:lux, Anthropic, plug: {Req.Test, Anthropic})
  Application.put_env(:lux, TogetherAI, plug: {Req.Test, TogetherAI})
  Application.put_env(:lux, OpenRouter, plug: {Req.Test, OpenRouter})
  :ok
end
```
- In unit test cases (`use UnitAPICase, async: true`), test setup calls `Req.Test.verify_on_exit!()`.
- Stubs and expectations are defined via `Req.Test.expect(AdapterModule, fn conn -> ... end)` or `Req.Test.stub(AdapterModule, fn conn -> ... end)`.
- HTTP response simulation:
  - **Success (200 OK)**: `Req.Test.json(conn, %{...})`
  - **Rate Limit (429)**: `conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(429, Jason.encode!(%{...}))`
  - **Service Unavailable (503)**: `conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(503, Jason.encode!(%{...}))`
  - **Network Error**: `Req.Test.transport_error(conn, :econnrefused)`

---

## 2. R5 Test Suite Architecture (`test/unit/lux/llm/`)

To fulfill requirement R5 and ensure 100% green test coverage for the LLM Abstraction Layer, the test suite is structured into 4 dedicated test modules:

```
test/unit/lux/llm/
├── provider_registry_test.exs   # Tests for Lux.LLM.ProviderRegistry (R1)
├── router_test.exs              # Tests for model routing & selection logic (R2)
├── fallback_test.exs            # Tests for 429/503/network failover mechanisms (R3)
└── telemetry_test.exs           # Tests for token cost tracking & telemetry (R4)
```

---

## 3. Detailed Test Design & Specifications

### 3.1 `test/unit/lux/llm/provider_registry_test.exs`
**Target Module**: `Lux.LLM.ProviderRegistry`

| Test Case | Description | Verification Method |
|---|---|---|
| `start_link/1 & default initialization` | Verifies registry starts cleanly under supervision and populates default built-in providers (OpenAI, Anthropic, Gemini, OpenRouter). | `assert {:ok, _pid} = ProviderRegistry.start_link([])` or `assert [_|_] = ProviderRegistry.list_providers()` |
| `register/2 dynamic registration` | Registers custom provider struct `%Lux.LLM.Provider{id: :custom_llm, adapter: Lux.LLM.OpenAI, ...}`. | `assert :ok = ProviderRegistry.register(:custom_llm, provider_spec)` |
| `register/2 duplicate error handling` | Attempts to register an already existing provider ID. | `assert {:error, :already_registered} = ProviderRegistry.register(:openai, spec)` |
| `get_provider/1 retrieval` | Fetches provider metadata by ID. | `assert {:ok, %Lux.LLM.Provider{name: "OpenAI"}} = ProviderRegistry.get_provider(:openai)` |
| `list_providers/1 capability filtering` | Filters registered providers by required capabilities (e.g., `capabilities: [:tools, :json]`). | `providers = ProviderRegistry.list_providers(capabilities: [:tools])`<br>`assert Enum.all?(providers, & :tools in &1.capabilities)` |
| `unregister/1 removal` | Removes provider from registry. | `assert :ok = ProviderRegistry.unregister(:custom_llm)`<br>`assert {:error, :not_found} = ProviderRegistry.get_provider(:custom_llm)` |
| `health_status management` | Updates health state of a provider (`:healthy`, `:degraded`, `:unhealthy`). | `ProviderRegistry.mark_degraded(:openai, :rate_limited)`<br>`assert %{health: :degraded} = ProviderRegistry.get_provider!(:openai)` |

---

### 3.2 `test/unit/lux/llm/router_test.exs`
**Target Module**: `Lux.LLM.Router`

| Test Case | Description | Verification Method |
|---|---|---|
| `select/2 with strategy: :cheapest` | Evaluates registered providers by combined input + output token cost and picks lowest cost option. | Setup 3 providers with cost metadata ($0.001 vs $0.01 vs $0.03).<br>`assert {:ok, provider} = Router.select(strategy: :cheapest)`<br>`assert provider.id == :cheapest_provider` |
| `select/2 with strategy: :smartest` | Selects highest tier reasoning model (e.g. `claude-3-5-sonnet` or `gpt-4o`). | `assert {:ok, provider} = Router.select(strategy: :smartest)`<br>`assert provider.model =~ "gpt-4o"` or `"claude-3-5-sonnet"` |
| `select/2 with capability constraints` | Restricts candidate pool to models supporting required capabilities (e.g. `[:vision, :tools]`). | `assert {:ok, provider} = Router.select(capabilities: [:vision])`<br>`assert :vision in provider.capabilities` |
| `select/2 with context window constraint` | Restricts candidate pool to models supporting `min_context_tokens: 64000`. | `assert {:ok, provider} = Router.select(min_context: 64_000)`<br>`assert provider.max_context >= 64_000` |
| `select/2 when no provider matches` | Returns error tuple when criteria cannot be satisfied. | `assert {:error, :no_matching_provider} = Router.select(capabilities: [:non_existent_capability])` |
| `select/2 excluding degraded providers` | Verifies router skips providers marked as `:degraded` or `:unhealthy`. | Mark cheapest provider as degraded.<br>`assert {:ok, provider} = Router.select(strategy: :cheapest)`<br>`assert provider.id != :degraded_cheapest` |

---

### 3.3 `test/unit/lux/llm/fallback_test.exs`
**Target Module**: `Lux.LLM.Fallback` / `Lux.LLM.call_with_fallback/3`

| Test Case | Description | Verification Method |
|---|---|---|
| `429 Rate Limit Failover` | Primary provider returns HTTP 429. Secondary fallback provider receives call and returns 200 OK with valid response. | Mock Primary (OpenAI) with 429 response via `Req.Test.expect`.<br>Mock Secondary (Anthropic) with 200 OK via `Req.Test.expect`.<br>Invoke call.<br>`assert {:ok, response} = Lux.LLM.call(...)`<br>`assert response.content == "Fallback success"`<br>`assert response.metadata.provider == Anthropic` |
| `503 Service Unavailable Failover` | Primary provider returns HTTP 503. Fallback mechanism intercepts 503 and routes to secondary. | Mock Primary with 503 response.<br>Mock Secondary with 200 OK.<br>`assert {:ok, response} = Lux.LLM.call(...)`<br>`assert response.metadata.fallback_attempts == 1` |
| `Network Transport Error Failover` | Primary provider experiences `:econnrefused` connection error. Secondary provider succeeds. | `Req.Test.expect(OpenAI, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)`<br>`Req.Test.expect(Anthropic, fn conn -> Req.Test.json(conn, %{...}) end)`<br>`assert {:ok, response} = Lux.LLM.call(...)` |
| `Cascading Chain Failure` | Primary (429), Secondary (503), Tertiary (timeout) all fail. Fallback handler returns aggregated error. | Mock 3 providers to fail.<br>`assert {:error, %Lux.LLM.FallbackError{attempts: attempts}} = Lux.LLM.call(...)`<br>`assert length(attempts) == 3` |
| `Fallback Metadata Audit` | Verifies `response.metadata` accurately contains fallback execution log (attempted providers, error reasons, latency). | Check `response.metadata.fallback_history` contains `[%{provider: OpenAI, error: 429}, %{provider: Anthropic, status: :ok}]`. |

---

### 3.4 `test/unit/lux/llm/telemetry_test.exs`
**Target Module**: `Lux.LLM.Telemetry` / Signal Metadata

| Test Case | Description | Verification Method |
|---|---|---|
| `Token & Cost Calculation` | Normalizes prompt tokens, completion tokens, and calculates total cost based on provider rate. | Mock API response with 100 prompt, 50 completion tokens.<br>`assert {:ok, signal} = Lux.LLM.call(...)`<br>`assert signal.metadata.usage.prompt_tokens == 100`<br>`assert signal.metadata.usage.cost > 0.0` |
| `Telemetry Event Emission` | Attaches `:telemetry` handler for `[:lux, :llm, :call, :stop]` and verifies measurements & metadata. | Attach telemetry handler.<br>Execute LLM call.<br>`assert_receive {:telemetry_event, [:lux, :llm, :call, :stop], measurements, metadata}`<br>`assert measurements.duration > 0`<br>`assert metadata.provider == OpenAI` |
| `Telemetry Exception Handling` | Verifies `[:lux, :llm, :call, :exception]` is dispatched when an unhandled error occurs. | Attach exception telemetry handler.<br>Trigger error.<br>`assert_receive {:telemetry_event, [:lux, :llm, :call, :exception], _, _}` |

---

## 4. Test Code Blueprints

Below are complete, production-grade test suite blueprints for the implementer:

### 4.1 Blueprint: `test/unit/lux/llm/provider_registry_test.exs`
```elixir
defmodule Lux.LLM.ProviderRegistryTest do
  use UnitAPICase, async: false

  alias Lux.LLM.Provider
  alias Lux.LLM.ProviderRegistry

  setup do
    # Start or reset registry for clean test state
    start_supervised!({ProviderRegistry, name: :test_registry})
    :ok
  end

  describe "register/2 and get_provider/2" do
    test "successfully registers and retrieves a provider" do
      provider = %Provider{
        id: :mock_openai,
        name: "Mock OpenAI",
        adapter: Lux.LLM.OpenAI,
        models: ["gpt-4o", "gpt-4o-mini"],
        capabilities: [:tools, :json, :vision],
        cost_per_1k_input: 0.005,
        cost_per_1k_output: 0.015
      }

      assert :ok == ProviderRegistry.register(:test_registry, provider)
      assert {:ok, fetched} = ProviderRegistry.get_provider(:test_registry, :mock_openai)
      assert fetched.name == "Mock OpenAI"
      assert fetched.capabilities == [:tools, :json, :vision]
    end

    test "returns error on duplicate registration" do
      provider = %Provider{id: :dup_provider, name: "Dup", adapter: Lux.LLM.OpenAI}

      assert :ok == ProviderRegistry.register(:test_registry, provider)
      assert {:error, :already_registered} == ProviderRegistry.register(:test_registry, provider)
    end
  end

  describe "list_providers/2 filtering" do
    test "filters providers by capabilities" do
      p1 = %Provider{id: :p1, capabilities: [:tools, :vision], adapter: Lux.LLM.OpenAI}
      p2 = %Provider{id: :p2, capabilities: [:tools], adapter: Lux.LLM.Anthropic}

      :ok = ProviderRegistry.register(:test_registry, p1)
      :ok = ProviderRegistry.register(:test_registry, p2)

      vision_providers = ProviderRegistry.list_providers(:test_registry, capabilities: [:vision])
      assert length(vision_providers) == 1
      assert hd(vision_providers).id == :p1
    end
  end
end
```

### 4.2 Blueprint: `test/unit/lux/llm/fallback_test.exs`
```elixir
defmodule Lux.LLM.FallbackTest do
  use UnitAPICase, async: true

  alias Lux.LLM.Anthropic
  alias Lux.LLM.OpenAI

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "smart fallback failover" do
    test "transparently falls back from OpenAI 429 to Anthropic 200 OK" do
      # 1. Primary provider (OpenAI) returns 429 Rate Limit
      Req.Test.expect(OpenAI, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{
          "error" => %{"message" => "Rate limit exceeded", "type" => "rate_limit_error"}
        }))
      end)

      # 2. Secondary provider (Anthropic) succeeds with 200 OK
      Req.Test.expect(Anthropic, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_fallback_123",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Fallback response from Anthropic"}],
          "model" => "claude-3-5-sonnet",
          "stop_reason" => "end_turn"
        })
      end)

      # 3. Call unified LLM layer with fallback strategy enabled
      opts = %{
        providers: [:openai, :anthropic],
        fallback_on: [429, 503, :econnrefused]
      }

      assert {:ok, response} = Lux.LLM.call("Test prompt", [], opts)
      assert response.content == "Fallback response from Anthropic"
      assert response.metadata.provider == Anthropic
      assert response.metadata.fallback_triggered == true
    end

    test "transparently falls back from OpenAI network error to Anthropic 200 OK" do
      Req.Test.expect(OpenAI, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      Req.Test.expect(Anthropic, fn conn ->
        Req.Test.json(conn, %{
          "id" => "msg_fallback_net",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Network fallback success"}],
          "model" => "claude-3-5-sonnet",
          "stop_reason" => "end_turn"
        })
      end)

      opts = %{providers: [:openai, :anthropic]}

      assert {:ok, response} = Lux.LLM.call("Test prompt", [], opts)
      assert response.content == "Network fallback success"
    end
  end
end
```

---

## 5. Verification Guidelines & Execution Commands

1. **Running New Unit Test Suite**:
   ```bash
   mix test test/unit/lux/llm/
   ```
2. **Running Complete Unit Test Environment**:
   ```bash
   mix test.unit
   ```
3. **Checking Code Quality & Linting**:
   ```bash
   mix compile --warnings-as-errors
   mix credo --strict
   ```
4. **Coverage Audit**:
   ```bash
   mix coveralls.detail --include unit
   ```

---

## 6. Summary & Recommendations for Implementer
- Use `UnitAPICase` for all tests under `test/unit/lux/llm/`.
- Rely exclusively on `Req.Test.expect/2` and `Req.Test.stub/2` for HTTP mocking.
- Never pass real API key strings in test configs (use `"test_key"` or `"mock_api_key"`).
- Verify that metadata includes `fallback_triggered: true`, token usage statistics, and cost calculations.
