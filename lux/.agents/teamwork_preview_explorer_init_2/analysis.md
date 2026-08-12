# Deep Analysis & Technical Design Proposal: LLM Provider Abstraction Layer for Lux (Bounty #99)

## 1. Executive Summary

This document presents a complete architectural analysis and detailed implementation design for **Bounty #99 (Universal LLM Provider Abstraction Layer for Lux)**.

The objective of this design is to establish a robust, production-grade abstraction layer comprising:
1. **Universal Provider Interface (`Lux.LLM.Provider`)** and **Central Provider Registry (`Lux.LLM.ProviderRegistry`)** for dynamic registration and management of LLM providers (OpenAI, Gemini, Anthropic, OpenRouter).
2. **Dynamic Routing Engine (`Lux.LLM.Router`)** supporting model selection strategies (`:cheapest`, `:smartest`, capability matching).
3. **Smart Fallback Manager (`Lux.LLM.Fallback`)** to ensure high availability and transparent failover upon HTTP 429 (Rate Limit), HTTP 503 (Service Unavailable), and network errors.
4. **Normalized Cost Tracking & Telemetry (R4)** providing unified `Lux.Signal` outputs and `:telemetry` events across all providers.
5. **Comprehensive ExUnit Test Suite Plan (R5)** utilizing `Req.Test` HTTP mocks without live API calls.

---

## 2. Codebase Baseline & Gap Analysis

### 2.1 Existing Codebase Structure
An inspection of `lib/lux/` and `lib/lux/llm/` reveals the following current state:

- **`Lux.LLM` (`lib/lux/llm.ex`)**:
  Defines a minimal behaviour callback `@callback call(prompt(), tools(), options()) :: {:ok, Response.t()} | {:error, String.t()}`. Delegating directly to `@default_module` (`Lux.LLM.OpenAI`).
- **Provider Modules (`lib/lux/llm/*.ex`)**:
  - `Lux.LLM.OpenAI`: Implements `Lux.LLM` `@behaviour`, uses `Req`, normalizes output into `Lux.Signal` with `ResponseSignal`.
  - `Lux.LLM.Anthropic`: Implements `Lux.LLM` `@behaviour`, but returns `{:ok, %Lux.LLM.Response{}}` directly instead of a `Lux.Signal`.
  - `Lux.LLM.OpenRouter`: Implements `Lux.LLM` `@behaviour`, contains bespoke fallback (`models: [...]`) and usage cost accounting (`cost_summary/1`, `within_budget?/2`).
  - `Lux.LLM.Mira` & `Lux.LLM.TogetherAI`: Implement `Lux.LLM` with provider-specific configs.
  - `Lux.LLM.Gemini`: **Not implemented yet**.
- **`Lux.Agent` (`lib/lux/agent.ex`)**:
  Configured with `llm_config: %{provider: :openai, model: "gpt-4"}` and invokes `Lux.LLM.call/3`.

### 2.2 Critical Technical Gaps
1. **Lack of Provider Contract (`Lux.LLM.Provider`)**: Providers lack standard metadata specs (pricing per token, performance rating, capability flags).
2. **No Dynamic Registry (`Lux.LLM.ProviderRegistry`)**: No central process exists to add/remove/configure providers at runtime.
3. **Absence of Unified Router (`Lux.LLM.Router`)**: Model selection logic is non-existent outside hardcoded provider modules.
4. **Lack of Generalized Smart Fallbacks (`Lux.LLM.Fallback`)**: Standard providers fail immediately on 429/503 errors rather than attempting transparent redirection to backup providers.
5. **Inconsistent Signal Outputs & Missing Telemetry**: Anthropic returns `%Response{}` while OpenAI returns `%Signal{}`. Telemetry events (`:telemetry.execute/3`) are not emitted.

---

## 3. Detailed Component Designs

### 3.1 Requirement R1: Universal Provider Interface & Registry

#### 3.1.1 `Lux.LLM.Provider` Behaviour Interface
```elixir
defmodule Lux.LLM.Provider do
  @moduledoc """
  Unified behaviour interface for all LLM providers in Lux.
  """
  alias Lux.LLM.Provider.ModelConfig
  alias Lux.Signal

  @type prompt :: String.t() | [map()]
  @type tools :: [Lux.Prism.t() | Lux.Beam.t() | Lux.Lens.t()]
  @type options :: map() | keyword()

  @doc "Unique atom identifier for the provider (e.g. :openai, :gemini, :anthropic, :openrouter)."
  @callback id() :: atom()

  @doc "List of supported ModelConfig definitions and capabilities."
  @callback models() :: [ModelConfig.t()]

  @doc "Executes an LLM request, returning a normalized Lux.Signal struct on success."
  @callback call(prompt(), tools(), options()) :: {:ok, Signal.t()} | {:error, term()}
end
```

#### 3.1.2 Struct Specifications

```elixir
defmodule Lux.LLM.Provider.ModelConfig do
  @moduledoc """
  Configuration and capability metadata for an LLM model.
  """
  @type capability :: :tools | :json_schema | :streaming | :vision | :reasoning

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          provider_id: atom(),
          cost_per_1k_prompt_tokens: float(),     # USD per 1,000 prompt tokens
          cost_per_1k_completion_tokens: float(), # USD per 1,000 completion tokens
          max_context_tokens: integer(),
          capabilities: [capability()],
          performance_score: float(),             # Benchmark rating (0.0 - 1.0) for :smartest strategy
          active: boolean()
        }

  defstruct [
    :id,
    :name,
    :provider_id,
    cost_per_1k_prompt_tokens: 0.0,
    cost_per_1k_completion_tokens: 0.0,
    max_context_tokens: 128_000,
    capabilities: [:tools, :json_schema],
    performance_score: 0.5,
    active: true
  ]
end

defmodule Lux.LLM.Provider.ProviderConfig do
  @moduledoc """
  Configuration struct for registered provider instances in ProviderRegistry.
  """
  @type t :: %__MODULE__{
          id: atom(),
          module: module(),
          api_key: String.t() | nil,
          endpoint: String.t() | nil,
          default_model: String.t(),
          models: [Lux.LLM.Provider.ModelConfig.t()],
          options: map()
        }

  defstruct [
    :id,
    :module,
    :api_key,
    :endpoint,
    :default_model,
    models: [],
    options: %{}
  ]
end
```

#### 3.1.3 `Lux.LLM.ProviderRegistry` (GenServer State & API)

```elixir
defmodule Lux.LLM.ProviderRegistry do
  @moduledoc """
  Central GenServer registry for managing active LLM providers and models dynamically.
  """
  use GenServer

  alias Lux.LLM.Provider.ProviderConfig

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register_provider(%ProviderConfig{} = config) do
    GenServer.call(__MODULE__, {:register_provider, config})
  end

  def unregister_provider(provider_id) when is_atom(provider_id) do
    GenServer.call(__MODULE__, {:unregister_provider, provider_id})
  end

  def get_provider(provider_id) when is_atom(provider_id) do
    GenServer.call(__MODULE__, {:get_provider, provider_id})
  end

  def list_providers do
    GenServer.call(__MODULE__, :list_providers)
  end

  def list_models(filter_opts \\ []) do
    GenServer.call(__MODULE__, {:list_models, filter_opts})
  end

  def set_default_provider(provider_id) when is_atom(provider_id) do
    GenServer.call(__MODULE__, {:set_default_provider, provider_id})
  end

  def get_default_provider do
    GenServer.call(__MODULE__, :get_default_provider)
  end
end
```

---

### 3.2 Requirement R2: Dynamic Selection Algorithms & Router

```elixir
defmodule Lux.LLM.Router do
  @moduledoc """
  Selection and routing engine for LLM models based on strategies and capabilities.
  """

  alias Lux.LLM.ProviderRegistry

  @doc """
  Selects the optimal Provider module and ModelConfig tuple based on criteria.
  Criteria options:
  - `:strategy` -> `:default` | `:cheapest` | `:smartest`
  - `:capabilities` -> list of required atoms (e.g. `[:tools, :json_schema]`)
  - `:provider` -> explicit provider atom override (e.g. `:anthropic`)
  - `:model` -> explicit model ID override (e.g. `"gpt-4o"`)
  """
  def select_model(opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :default)
    required_capabilities = Keyword.get(opts, :capabilities, [])
    requested_provider = Keyword.get(opts, :provider)
    requested_model = Keyword.get(opts, :model)

    models = ProviderRegistry.list_models(capabilities: required_capabilities, active: true)

    models =
      if requested_provider do
        Enum.filter(models, &(&1.provider_id == requested_provider))
      else
        models
      end

    models =
      if requested_model do
        Enum.filter(models, &(&1.id == requested_model || &1.name == requested_model))
      else
        models
      end

    case sort_by_strategy(models, strategy) do
      [best_model | _] ->
        case ProviderRegistry.get_provider(best_model.provider_id) do
          {:ok, provider_config} -> {:ok, {provider_config.module, best_model}}
          error -> error
        end

      [] ->
        {:error, :no_matching_model}
    end
  end

  defp sort_by_strategy(models, :cheapest) do
    Enum.sort_by(models, fn m -> m.cost_per_1k_prompt_tokens + m.cost_per_1k_completion_tokens end, :asc)
  end

  defp sort_by_strategy(models, :smartest) do
    Enum.sort_by(models, fn m -> m.performance_score end, :desc)
  end

  defp sort_by_strategy(models, _default) do
    models
  end
end
```

---

### 3.3 Requirement R3: Smart Fallback Handling (`Lux.LLM.Fallback`)

```elixir
defmodule Lux.LLM.Fallback do
  @moduledoc """
  Resilience manager that transparently executes fallback chains on rate-limit (429),
  server (503, 500), or network errors.
  """
  require Logger

  @retryable_statuses [429, 503, 500, 502, 504]

  @doc """
  Executes call across a fallback chain of `{provider_module, model_config}` tuples.
  """
  def execute(prompt, tools, options, fallback_chain) do
    do_execute(prompt, tools, options, fallback_chain, [])
  end

  defp do_execute(prompt, tools, options, [{provider_mod, model_config} | rest], history) do
    opts = Map.merge(Map.new(options), %{model: model_config.id})

    case provider_mod.call(prompt, tools, opts) do
      {:ok, signal} ->
        updated_metadata = Map.put(signal.metadata, :fallback_history, Enum.reverse(history))
        {:ok, %{signal | metadata: updated_metadata}}

      {:error, reason} ->
        if retryable?(reason) and rest != [] do
          attempt = %{
            provider: provider_mod.id(),
            model: model_config.id,
            error: reason,
            timestamp: DateTime.utc_now()
          }
          Logger.warning("Primary provider #{inspect(provider_mod.id())} failed with #{inspect(reason)}. Redirecting to fallback.")
          do_execute(prompt, tools, options, rest, [attempt | history])
        else
          {:error, {reason, fallback_history: Enum.reverse(history)}}
        end
    end
  end

  def retryable?({:error, {status, _msg}}) when status in @retryable_statuses, do: true
  def retryable?({:error, {status, _msg, _meta}}) when status in @retryable_statuses, do: true
  def retryable?({:error, :timeout}), do: true
  def retryable?({:error, :econnrefused}), do: true
  def retryable?({:error, :closed}), do: true
  def retryable?(_), do: false
end
```

---

### 3.4 Requirement R4: Cost Tracking, Telemetry & Signal Normalization

#### 3.4.1 Signal Normalization Standard
All provider modules (`OpenAI`, `Gemini`, `Anthropic`, `OpenRouter`) normalize API responses into a `Lux.Signal` using `Lux.LLM.ResponseSignal`.

**Payload**:
```elixir
%{
  "content" => content,
  "model" => model_name,
  "finish_reason" => finish_reason,
  "tool_calls" => tool_calls,
  "tool_calls_results" => tool_calls_results
}
```

**Metadata**:
```elixir
%{
  id: response_id,
  provider: provider_id,
  model: model_name,
  created: timestamp,
  latency_ms: duration_ms,
  usage: %{
    "prompt_tokens" => prompt_tokens,
    "completion_tokens" => completion_tokens,
    "total_tokens" => total_tokens,
    "cost" => cost_usd
  },
  fallback_history: []
}
```

#### 3.4.2 Telemetry Event Dispatching
Providers wrap calls with `:telemetry.span/3`:
- Event: `[:lux, :llm, :call, :start]`
- Event: `[:lux, :llm, :call, :stop]` with measurements `%{duration_ms: ms, prompt_tokens: p, completion_tokens: c, total_tokens: t, cost_usd: cost}`
- Event: `[:lux, :llm, :call, :exception]` on error

---

### 3.5 Google Gemini Implementation (`Lux.LLM.Gemini`)

Module `Lux.LLM.Gemini`:
- Adopts `Lux.LLM.Provider` behaviour.
- Default models: `"gemini-1.5-pro"`, `"gemini-1.5-flash"`.
- Calculates USD costs ($0.00125/1k prompt, $0.005/1k completion for gemini-1.5-pro).
- Formats request payloads and parses Gemini choices/content into `Lux.Signal`.

---

## 4. Verification Plan (ExUnit Suite R5)

1. `test/unit/lux/llm/provider_registry_test.exs`:
   - Tests registering dynamic providers and retrieving configurations.
   - Tests model listing by capability and active state.
2. `test/unit/lux/llm/router_test.exs`:
   - Tests `:cheapest` selection algorithm choosing the lowest cost per token model.
   - Tests `:smartest` selection choosing highest performance score.
3. `test/unit/lux/llm/fallback_test.exs`:
   - Uses `Req.Test` to simulate a primary provider returning 429 Rate Limit.
   - Verifies transparent redirection to backup provider and return of tagged `{:ok, signal}`.
   - Verifies `fallback_history` attached in metadata.

---
