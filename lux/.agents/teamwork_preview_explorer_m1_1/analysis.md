# Analysis Report: Credential Merging in `Lux.LLM.Router` (Requirement R1)

## Executive Summary
This report analyzes Requirement R1 for PR #99, focusing on how `Lux.LLM.Router.call/3` merges provider credentials from `Lux.LLM.ProviderRegistry` with application-level and user-provided configurations.

Currently, `Router.call/3` unconditionally injects provider credentials (`api_key` and `endpoint`) from `ProviderConfig` into the call options map using `Map.put_new/3`. Because default providers in `ProviderRegistry` have `api_key: nil` and `endpoint: nil`, `Map.put_new/3` inserts key-value pairs `api_key: nil` and `endpoint: nil` into the options passed to provider implementations (e.g., `Lux.LLM.OpenAI`). Provider implementations merge these options into their configuration using `Map.merge/2`, which overwrites application-level configured API keys with `nil`.

To resolve this issue, `Router.call/3` must be modified to only inject `api_key` and `endpoint` from `ProviderConfig` if their values are **not `nil`**.

---

## 1. Codebase Investigation & Problem Analysis

### 1.1 `Router.call/3` Current Implementation
Location: `lib/lux/llm/router.ex:33-53`

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

### 1.2 Provider Registration Defaults
Location: `lib/lux/llm/provider_registry.ex:115-129` & `lib/lux/llm/provider.ex:45-52`

When providers (e.g., `Lux.LLM.OpenAI`, `Lux.LLM.Gemini`, `Lux.LLM.Anthropic`) are registered in `ProviderRegistry` by module atom, `ProviderRegistry` initializes `%ProviderConfig{}` as:
```elixir
%ProviderConfig{
  id: module.id(),
  module: module,
  models: models,
  status: :active,
  api_key: nil,      # Defaults to nil
  endpoint: nil      # Defaults to nil
}
```

### 1.3 How Provider Modules Handle `call_opts`
Location: `lib/lux/llm/open_ai.ex:98-117` (and similarly in `Anthropic`, `OpenRouter`, `Gemini`, `TogetherAI`)

```elixir
def call(prompt, tools, config) do
  opts_map = cond do ... end

  config =
    struct(
      Config,
      Map.merge(
        %{
          model: Application.get_env(:lux, :open_ai_models)[:default] || "gpt-4",
          api_key: Application.get_env(:lux, :api_keys)[:openai]
        },
        opts_map
      )
    )
```

### 1.4 Step-by-Step Failure Sequence
1. The developer sets an application-level API key, e.g., `Application.put_env(:lux, :api_keys, [openai: "sk-app-secret-123"])`.
2. The user invokes `Router.call("prompt", [], strategy: :cheapest)`. Here `opts_map` does not contain `:api_key`.
3. `Router.call/3` calls `route/3`, which returns `{provider_config, model_config}` from `ProviderRegistry`. `provider_config.api_key` is `nil`.
4. `Router.call/3` constructs `call_opts`:
   `Map.put_new(opts_map, :api_key, provider_config.api_key)`
   Since `:api_key` key is missing in `opts_map`, `Map.put_new` adds `:api_key => nil` to `call_opts`.
5. `provider_config.module.call(prompt, tools, call_opts)` is invoked.
6. Inside `OpenAI.call/3`, `Map.merge(%{api_key: "sk-app-secret-123"}, %{api_key: nil, ...})` is evaluated.
7. Result: `config.api_key` becomes `nil`! The application-level key is overwritten by `nil` and lost.

---

## 2. Recommendation & Implementation Proposal (R1)

Modify `Router.call/3` in `lib/lux/llm/router.ex` to introduce a private helper function `maybe_put_new/3` (or `maybe_put_config/3`) that skips inserting keys when the value is `nil`.

### Proposed Code Patch for `lib/lux/llm/router.ex`

```elixir
# In Router.call/3 (lines 41-47):
      {:ok, {provider_config, model_config}} ->
        call_opts =
          opts_map
          |> Map.put(:model, model_config.id)
          |> maybe_put_new(:api_key, provider_config.api_key)
          |> maybe_put_new(:endpoint, provider_config.endpoint)

        provider_config.module.call(prompt, tools, call_opts)

# Private helper function in Lux.LLM.Router:
defp maybe_put_new(map, _key, nil), do: map
defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)
```

### Precedence Matrix After Fix
| User `opts[:api_key]` | Registry `provider_config.api_key` | Application Config `api_keys` | Resulting Key Used | Rationale |
|---|---|---|---|---|
| `"sk-user-key"` | `"sk-registry-key"` | `"sk-app-key"` | `"sk-user-key"` | User explicit option has highest priority. |
| `"sk-user-key"` | `nil` | `"sk-app-key"` | `"sk-user-key"` | User explicit option is preserved (`maybe_put_new` ignores `nil`). |
| `nil` / Not set | `"sk-registry-key"` | `"sk-app-key"` | `"sk-registry-key"` | Registry non-nil key overrides application config. |
| `nil` / Not set | `nil` | `"sk-app-key"` | `"sk-app-key"` | Registry `nil` is ignored; Provider falls back to application config. |

---

## 3. Analysis of Existing Test Suite

- **File**: `test/unit/lux/llm/router_test.exs`
- **Current status**: 11 tests passing (when run with `--include unit`).
- **Existing Coverage**:
  - `route/3` selection strategies (`:cheapest`, `:smartest`, custom function).
  - `route/3` capability filtering and auto-inferring `:tools`.
  - `route/3` provider ID and model filtering.
  - `calculate_cost/3` token cost calculation.
  - `call/3` basic execution with `MockProvider`.
  - Handling unstarted registry GenServer.
- **Coverage Gap**:
  - None of the existing tests verify credential fallback to `Application.get_env(:lux, :api_keys)`.
  - `MockProvider` in `router_test.exs` currently ignores `:api_key` and does not test `Application.get_env`.

---

## 4. Test Plan for Acceptance Criterion 1 (AC1)

### Acceptance Criterion 1 Statement
*"Existe una prueba automatizada que verifica que una llave (`api_key`) configurada a nivel de aplicación no se pierde ni sobrescribe al usar el registro por defecto."*

### Proposed Test Code Snippet
Add to `test/unit/lux/llm/router_test.exs` under a new `describe "credential resolution (R1)"` block:

```elixir
defmodule AppKeyTestProvider do
  @behaviour Lux.LLM.Provider

  alias Lux.LLM.ModelConfig
  alias Lux.LLM.ResponseSignal

  @impl true
  def id, do: :app_key_test_provider

  @impl true
  def models do
    [
      %ModelConfig{
        id: "app-key-model",
        name: "App Key Model",
        provider_id: :app_key_test_provider,
        cost_per_1k_prompt_tokens: 0.001,
        cost_per_1k_completion_tokens: 0.002,
        capabilities: [:tools]
      }
    ]
  end

  @impl true
  def call(_prompt, _tools, opts) do
    opts_map = Enum.into(opts, %{})

    # Mimic real provider credential resolution logic:
    # Application config serves as default, merged with opts_map
    app_key = Application.get_env(:lux, :api_keys)[:app_key_test_provider]
    merged_config = Map.merge(%{api_key: app_key}, opts_map)

    payload = %{
      content: %{"response" => "ok"},
      api_key: merged_config[:api_key]
    }

    {:ok, Lux.Signal.new(%{schema_id: ResponseSignal, payload: payload, metadata: %{})}
  end
end

describe "credential resolution (R1)" do
  test "preserves application-level api_key when registry provider api_key is nil", %{registry_name: reg} do
    # 1. Set application-level API key
    Application.put_env(:lux, :api_keys, [app_key_test_provider: "sk-app-configured-secret"])

    on_exit(fn ->
      Application.delete_env(:lux, :api_keys)
    end)

    # 2. Register provider module with default nil api_key in ProviderConfig
    {:ok, _} = ProviderRegistry.register_provider(AppKeyTestProvider, registry_name: reg)

    # 3. Call Router without passing explicit :api_key in opts
    assert {:ok, %Signal{} = signal} =
             Router.call("test prompt", [], registry_name: reg, provider_id: :app_key_test_provider)

    # 4. Verify application-level API key was preserved and passed to provider
    assert signal.payload.api_key == "sk-app-configured-secret"
  end
end
```
