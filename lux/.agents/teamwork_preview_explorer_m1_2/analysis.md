# Analysis Report: Requirement R2 — Control Option Filtering in `Lux.LLM.Router`

## 1. Executive Summary

Requirement R2 addresses an abstraction boundary leak where internal control options intended for `Lux.LLM.Router` and `Lux.LLM.Fallback` (such as `:strategy`, `:capabilities`, `:registry_name`, `:estimated_prompt_tokens`, `:estimated_completion_tokens`, `:provider_id`, `:primary`, `:fallbacks`, and `:fallback_on_all_errors`) are passed unmodified down to LLM provider adapters (`provider_config.module.call/3`). When a strict provider adapter uses `struct!(ConfigModule, opts)`, `Keyword.fetch!/2`, or schema validation, receiving unexpected control options causes a `KeyError`.

This investigation details the option flow in `Router.call/3`, catalogs all control options, demonstrates the exact mechanics of the `KeyError`, provides the precise filtering mechanism (`Map.drop/2`), and establishes an automated test plan satisfying Acceptance Criterion 2 (AC2).

---

## 2. Option Flow Analysis (`Router.call/3` & `Fallback.call/3`)

### 2.1 Current Implementation in `lib/lux/llm/router.ex`

In `lib/lux/llm/router.ex` (lines 33–53):

```elixir
def call(prompt, tools \\ [], opts \\ []) do
  opts_map = to_map(opts)

  req_caps = Map.get(opts_map, :capabilities, [])
  req_caps = if tools != [] and :tools not in req_caps, do: [:tools | req_caps], else: req_caps
  opts_with_caps = Map.put(opts_map, :capabilities, req_caps)

  case route(prompt, tools, opts_with_caps) do
    {:ok, {provider_config, model_config}} ->
      call_opts =
        opts_map
        |> Map.put(:model, model_config.id)
        |> Map.put_new(:api_key, provider_config.api_key)
        |> Map.put_new(:endpoint, provider_config.endpoint)

      provider_config.module.call(prompt, tools, call_opts)

    {:error, reason} ->
      {:error, reason}
  end
end
```

### 2.2 Identification of Option Leakage Point

1. **Option Propagation**:
   `call_opts` is constructed directly from `opts_map`. If a caller calls:
   ```elixir
   Router.call(prompt, tools,
     strategy: :smartest,
     capabilities: [:vision],
     registry_name: MyRegistry,
     estimated_prompt_tokens: 500,
     estimated_completion_tokens: 500,
     provider_id: :openai
   )
   ```
   All of these options remain inside `opts_map` when `Map.put(:model, ...)` is called.
2. **Fallback Integration Leakage**:
   When `Lux.LLM.Fallback.call/3` invokes `Router` (e.g. via `primary: {Router, spec_opts}` or default fallback options), `opts_map` will additionally contain `:primary`, `:fallbacks`, and `:fallback_on_all_errors`.
3. **Result**:
   The entire keyword list / map of control options is passed straight into `provider_config.module.call(prompt, tools, call_opts)`.

---

## 3. Control Options Catalog & `KeyError` Mechanics

### 3.1 Catalog of Router & Fallback Control Options

| Option Key | Used By | Purpose | Provider Relevant? |
|---|---|---|---|
| `:strategy` | `Router.route/3` | Model selection algorithm (`:cheapest`, `:smartest`, or custom function) | No |
| `:capabilities` | `Router.route/3` | List of required capability atoms (e.g. `[:tools, :vision]`) | No |
| `:registry_name` | `Router.route/3`, `Fallback` | GenServer process name of `ProviderRegistry` | No |
| `:estimated_prompt_tokens` | `Router.route/3` | Prompt token count for cost estimation | No |
| `:estimated_completion_tokens` | `Router.route/3` | Completion token count for cost estimation | No |
| `:provider_id` | `Router.route/3` | Candidate filter by provider ID atom | No |
| `:primary` | `Fallback.call/3` | Primary provider spec for failover | No |
| `:fallbacks` | `Fallback.call/3` | List of fallback provider specs | No |
| `:fallback_on_all_errors` | `Fallback.call/3` | Boolean flag to trigger failover on any error | No |

**Complete Control Option Set**:
```elixir
@control_opts [
  :strategy,
  :capabilities,
  :registry_name,
  :estimated_prompt_tokens,
  :estimated_completion_tokens,
  :provider_id,
  :primary,
  :fallbacks,
  :fallback_on_all_errors
]
```

### 3.2 Mechanics of `KeyError` in Strict Providers

In Elixir:
- Standard `struct(Module, map)` ignores keys in `map` that are not defined as fields in `%Module{}`.
- Strict `struct!(Module, map)` validates that every key in `map` corresponds to a struct field defined in `%Module{}`. If an unexpected key is encountered, Elixir raises a `KeyError`:
  ```elixir
  ** (KeyError) key :strategy not found in: %MyStrictProvider.Config{api_key: nil, endpoint: "...", model: "gpt-4o"}
  ```
- Additionally, if `:strategy` is passed as an anonymous function (e.g. `strategy: fn model -> ... end`), passing functions into provider adapters can cause failures if providers log, inspect, or serialize `call_opts` into JSON.

---

## 4. Proposed Fix & Filtering Strategy

### 4.1 Recommended Changes to `lib/lux/llm/router.ex`

Define `@control_opts` module attribute in `Lux.LLM.Router` and filter `opts_map` using `Map.drop/2` in `call/3`:

```elixir
@control_opts [
  :strategy,
  :capabilities,
  :registry_name,
  :estimated_prompt_tokens,
  :estimated_completion_tokens,
  :provider_id,
  :primary,
  :fallbacks,
  :fallback_on_all_errors
]

@spec call(prompt(), tools(), opts()) :: {:ok, Signal.t()} | {:error, term()}
def call(prompt, tools \\ [], opts \\ []) do
  opts_map = to_map(opts)

  req_caps = Map.get(opts_map, :capabilities, [])
  req_caps = if tools != [] and :tools not in req_caps, do: [:tools | req_caps], else: req_caps
  opts_with_caps = Map.put(opts_map, :capabilities, req_caps)

  case route(prompt, tools, opts_with_caps) do
    {:ok, {provider_config, model_config}} ->
      call_opts =
        opts_map
        |> Map.drop(@control_opts)
        |> Map.put(:model, model_config.id)
        |> Map.put_new(:api_key, provider_config.api_key)
        |> Map.put_new(:endpoint, provider_config.endpoint)

      provider_config.module.call(prompt, tools, call_opts)

    {:error, reason} ->
      {:error, reason}
  end
end
```

### 4.2 Why `Map.drop/2` over `Map.take/2`?

`Map.drop/2` explicitly removes the known, closed set of router-exclusive and fallback-exclusive control options while allowing any open set of provider-specific parameters (e.g. `:temperature`, `:max_tokens`, `:top_p`, `:top_k`, `:seed`, `:user`, `:frequency_penalty`, `:repetition_penalty`, `:system`, `:json_response`, `:json_schema`, `:receive_timeout`, `:plug`) passed by the user to reach the provider safely.

---

## 5. Existing Tests & Acceptance Criterion 2 (AC2) Test Plan

### 5.1 Analysis of Existing Tests

1. `test/unit/lux/llm/router_test.exs`:
   - Uses `MockProvider` and `VisionOnlyProvider`.
   - `MockProvider.call/3` uses `Map.get(opts, :model, "cheap-model")` without validating unknown keys, masking option leakage defects.
2. `test/unit/lux/llm/fallback_test.exs`:
   - Uses anonymous functions (`fn _p, _t -> ... end`) for `primary_spec` and `fallback_spec`.
   - Does not test option propagation through `Router` to provider modules.

### 5.2 Test Plan for AC2

**Acceptance Criterion 2**:
*"Las pruebas usan proveedores integrados reales a través de `Router` y `Fallback` (no solo simulaciones permisivas) para garantizar que no haya `KeyError` por opciones de control."*

To satisfy AC2, we will add three specific test cases in `test/unit/lux/llm/router_test.exs` and `test/unit/lux/llm/fallback_test.exs`:

#### Test 1: Strict Provider with `struct!/2` through `Router.call/3`
Define a `StrictProvider` test module:
```elixir
defmodule StrictProvider do
  @behaviour Lux.LLM.Provider

  defmodule Config do
    defstruct [:model, :api_key, :endpoint, :temperature]
  end

  def id, do: :strict_provider
  def models do
    [
      %ModelConfig{
        id: "strict-model",
        name: "Strict Model",
        provider_id: :strict_provider,
        capabilities: [:tools]
      }
    ]
  end

  def call(prompt, _tools, opts) do
    # struct!/2 will raise KeyError if any key in opts is not in Config
    config = struct!(Config, opts)
    payload = %{content: %{"response" => "strict ok"}, model: config.model}
    {:ok, Lux.Signal.new(%{schema_id: ResponseSignal, payload: payload, metadata: %{}})}
  end
end
```
Test code:
```elixir
test "filters router control options and prevents KeyError in strict providers", %{registry_name: reg} do
  ProviderRegistry.register_provider(StrictProvider, registry_name: reg)

  assert {:ok, signal} =
           Router.call("hello", [],
             registry_name: reg,
             provider_id: :strict_provider,
             strategy: :smartest,
             capabilities: [:tools],
             estimated_prompt_tokens: 500,
             estimated_completion_tokens: 500,
             primary: :foo,
             fallbacks: [:bar],
             fallback_on_all_errors: true
           )

  assert signal.payload.content["response"] == "strict ok"
end
```

#### Test 2: Real Built-In Provider (`Lux.LLM.OpenAI`) through `Router.call/3`
Use `Req.Test` plug mock to test real `Lux.LLM.OpenAI` provider invoked via `Router.call/3` with control options:
```elixir
test "invokes real OpenAI provider through Router without control option leakage", %{registry_name: reg} do
  Req.Test.expect(Lux.LLM.OpenAI, fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    decoded = Jason.decode!(body)

    # Verify standard request body sent to API
    assert decoded["model"] == "gpt-4o-mini"
    Req.Test.json(conn, %{
      "choices" => [%{"message" => %{"content" => "{\"result\":\"ok\"}"}, "finish_reason" => "stop"}],
      "model" => "gpt-4o-mini",
      "id" => "chatcmpl-123",
      "created" => 123456
    })
  end)

  # Register real OpenAI provider in test registry
  openai_config = %ProviderConfig{
    id: :openai,
    module: Lux.LLM.OpenAI,
    api_key: "sk-test",
    models: Lux.LLM.OpenAI.models()
  }
  ProviderRegistry.register_provider(openai_config, registry_name: reg)

  assert {:ok, signal} =
           Router.call("test prompt", [],
             registry_name: reg,
             provider_id: :openai,
             strategy: :cheapest,
             capabilities: [:tools],
             estimated_prompt_tokens: 1000,
             primary: {Router, []},
             fallbacks: []
           )

  assert signal.payload.content["result"] == "ok"
end
```

#### Test 3: Real Built-In Provider through `Fallback` -> `Router` Pipeline
Test `Fallback.call/3` delegating to `Router` with real provider and control options:
```elixir
test "executes Fallback through Router to real provider cleanly", %{registry_name: reg} do
  Req.Test.stub(Lux.LLM.OpenAI, fn conn ->
    Req.Test.json(conn, %{
      "choices" => [%{"message" => %{"content" => "{\"result\":\"fallback ok\"}"}, "finish_reason" => "stop"}],
      "model" => "gpt-4o-mini",
      "id" => "chatcmpl-456"
    })
  end)

  openai_config = %ProviderConfig{
    id: :openai,
    module: Lux.LLM.OpenAI,
    api_key: "sk-test",
    models: Lux.LLM.OpenAI.models()
  }
  ProviderRegistry.register_provider(openai_config, registry_name: reg)

  assert {:ok, signal} =
           Fallback.call("fallback prompt", [],
             primary: {Router, [registry_name: reg, provider_id: :openai, strategy: :cheapest]},
             fallbacks: [],
             fallback_on_all_errors: true,
             registry_name: reg
           )

  assert signal.payload.content["result"] == "fallback ok"
end
```

---

## 6. Verification Method

1. Run unit tests for LLM module:
   ```bash
   mix test test/unit/lux/llm/router_test.exs test/unit/lux/llm/fallback_test.exs
   ```
2. Run full test suite:
   ```bash
   mix test
   ```
