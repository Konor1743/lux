# Lux Codebase Analysis Report: LLM Provider Abstraction Layer (Bounty #99)

## Executive Summary
This report presents a detailed analysis of the Lux framework codebase (`/home/Konor1743/Operacion Dolar/lux/lux`) to inform the design and implementation of Bounty #99 (Universal LLM Provider Abstraction Layer). The analysis covers codebase architecture, existing LLM implementations (`lib/lux/llm.ex`, `lib/lux/llm/`), GenServer and Registry usage, Telemetry configuration, Signal structures (`Lux.Signal`, `Lux.SignalSchema`), and monorepo design rules.

---

## 1. Project & Codebase Architecture

### 1.1 Directory Structure
The repository follows a modular Elixir OTP structure:
- `lib/lux.ex`: Top-level helper functions (`prism?/1`, `beam?/1`, `lens?/1`).
- `lib/lux/llm.ex`: Current `Lux.LLM` behaviour definition and delegation mechanism.
- `lib/lux/llm/`: Current LLM provider implementations (`anthropic.ex`, `mira.ex`, `open_ai.ex`, `open_router.ex`, `together_ai.ex`, `response_signal.ex`).
- `lib/lux/agent.ex` & `lib/lux/agent/`: Core Agent macros, GenServer process logic, hub integration, and loaders.
- `lib/lux/agent_hub.ex`: Agent process registry and capability discovery server.
- `lib/lux/signal.ex`, `lib/lux/signal_schema.ex`, `lib/lux/signal/`: Signal definition, schema validation macros, and local signal router.
- `lib/lux/company/`: Execution engine, DSL, objectives, roles, task tracker, artifact store.
- `lib/lux/prism.ex`, `lib/lux/lens.ex`, `lib/lux/beam.ex`: Core primitives for agent actions, external integrations, and multi-step workflows.
- `config/`: System and environment configuration (`config.exs`, `runtime.exs`, `anthropic.exs`).
- `test/unit/lux/`: Unit tests using `UnitAPICase` and `Req.Test`.

### 1.2 Monorepo and Placement Rules (`guides/contributing.md`)
- **Module Naming & Location**:
  - `lib/lux/prisms/` -> `Lux.Prisms.<Name>Prism`
  - `lib/lux/lenses/` -> `Lux.Lenses.<Name>Lens`
  - `lib/lux/beams/` -> `Lux.Beams.<Name>Beam`
  - `lib/lux/llm/` -> `Lux.LLM.<ProviderName>`
  - `lib/lux/signals/` or `lib/lux/signal/` -> Signal schemas and routers
- **Component File Conventions**: One component per file; file name in `snake_case`, module name in `PascalCase`.
- **Test Co-location & Testing**: Unit tests belong in `test/unit/lux/<module_path>_test.exs` tagged with `@moduletag :unit` and utilizing `UnitAPICase` for HTTP mocking via `Req.Test`.

---

## 2. LLM Provider Infrastructure Analysis

### 2.1 Current `Lux.LLM` Behaviour (`lib/lux/llm.ex`)
```elixir
defmodule Lux.LLM do
  defmodule Response do
    @type t :: %__MODULE__{
            content: String.t() | nil,
            tool_calls: [%{type: String.t(), name: String.t(), params: map()}],
            finish_reason: String.t() | nil,
            structured_output: map() | nil
          }
    defstruct content: nil, tool_calls: [], finish_reason: nil, structured_output: nil
  end

  @type prompt :: String.t()
  @type tools :: [Lux.Prism.t() | Lux.Beam.t() | Lux.Lens.t()]
  @type options :: map() | keyword()

  @callback call(prompt(), tools(), options()) :: {:ok, Response.t()} | {:error, String.t()}

  @default_module Application.compile_env(:lux, [Lux.LLM, :default_module], Lux.LLM.OpenAI)
  defdelegate call(prompt, tools, options), to: @default_module
end
```

### 2.2 Provider Implementations Comparison

| Provider | Config Module | Return Type | Tool Formatting | Special Features |
|---|---|---|---|---|
| **OpenAI** (`Lux.LLM.OpenAI`) | `Lux.LLM.OpenAI.Config` | `{:ok, Lux.Signal.t()}` with `ResponseSignal` | Converts Beam/Prism/Lens via `tool_to_function/1` | JSON schema response formatting |
| **Anthropic** (`Lux.LLM.Anthropic`) | `Lux.LLM.Anthropic.Config` | `{:ok, Lux.LLM.Response.t()}` | Maps tools to Claude tool spec | System/User role mapping |
| **OpenRouter** (`Lux.LLM.OpenRouter`) | `Lux.LLM.OpenRouter.Config` | `{:ok, Lux.Signal.t()}` with `ResponseSignal` | Converts Beam/Prism/Lens tools | Fallback model list (`models: [...]`), cost calculation metadata, 429/503 backoff retries, HTTP 200 error decoding |
| **TogetherAI** (`Lux.LLM.TogetherAI`) | `Lux.LLM.TogetherAI.Config` | `{:ok, Lux.Signal.t()}` with `ResponseSignal` | Converts Beam/Prism/Lens tools | Mistral/Llama parameter handling |
| **Mira** (`Lux.LLM.Mira`) | `Lux.LLM.Mira.Config` | `{:ok, Lux.Signal.t()}` with `ResponseSignal` | Converts Beam/Prism/Lens tools | Network gateway decoding |

### 2.3 Key Inconsistencies & Requirements for Abstraction Layer
1. **Return Type Discrepancy**: `Anthropic` returns `{:ok, %Lux.LLM.Response{}}`, while `OpenAI`, `OpenRouter`, `TogetherAI`, and `Mira` return `{:ok, %Lux.Signal{schema_id: Lux.LLM.ResponseSignal}}`. A unified abstraction layer must normalize responses.
2. **Provider Dispatch & Routing**: `Lux.LLM` currently uses static compile-time/runtime configuration for delegation (`@default_module`). There is no dynamic provider registry or fallback router across different providers (e.g., fallback from OpenAI to Anthropic on HTTP 429/503).
3. **Telemetry & Cost Tracking**: Cost tracking logic exists inside `Lux.LLM.OpenRouter` metadata extraction, but is absent or un-standardized across other providers.

---

## 3. Concurrency, Registration, Telemetry & Signal Patterns

### 3.1 GenServer Usage Patterns
GenServer is used across Lux for stateful process management:
- `Lux.Agent` / `Lux.Agent.Base`: GenServer encapsulating agent state, memory configuration, and action execution.
- `Lux.AgentHub`: GenServer managing active agent instances, status tracking (`:available`, `:busy`, `:offline`), and capability querying. Monitors agent processes via `Process.monitor/1`.
- `Lux.Signal.Router.Local`: GenServer for local signal routing and subscription management.

### 3.2 Registry Usage Patterns
Elixir `Registry` is used in `Lux.Company.ExecutionEngine.Supervisor` for process lookup and dynamic naming:
- Process registration via `{:via, Registry, {registry_name, key}}`.
- Dynamic module names constructed with `Module.concat(objective_id, TaskRegistry)`.
- Querying registered processes using `Registry.lookup/2` and `Registry.select/2`.

### 3.3 Telemetry Patterns
- `:telemetry` dependency is installed (v1.3.0 in `mix.lock`).
- Config pattern shown in `config/anthropic.exs`:
  ```elixir
  config :lux, Lux.LLM.Anthropic.Telemetry,
    enabled: true,
    sample_rate: 0.1
  ```

### 3.4 Lux Signal & SignalSchema Architecture
- `Lux.Signal`: Core communication data structure `%Lux.Signal{id, payload, sender, recipient, timestamp, topic, metadata, schema_id}`.
- `Lux.SignalSchema`: Macro framework generating JSON Schema validation using `ExJsonSchema.Schema.resolve/1` and `ExJsonSchema.Validator.validate/2`.
- `Lux.LLM.ResponseSignal`: Standard schema representing LLM response content, model, finish_reason, tool_calls, and tool_calls_results.

---

## 4. Recommendations for Implementation (Bounty #99)
1. **Unified Provider Behaviour (`Lux.LLM.Provider`)**: Standardize prompt, options, tool schemas, and response normalization into `%Lux.Signal{schema_id: Lux.LLM.ResponseSignal}`.
2. **Provider Registry (`Lux.LLM.ProviderRegistry`)**: Implement a GenServer/Registry for registering LLM providers dynamically at runtime.
3. **Router & Fallback Mechanism**: Implement selection strategies (`:cheapest`, `:smartest`, capability-based) and automatic error failover (429/503/network error) across registered providers.
4. **Cost Tracking & Telemetry**: Emit `:telemetry` events for LLM calls (latency, token usage, USD cost) and attach cost metadata consistently to signal responses.
