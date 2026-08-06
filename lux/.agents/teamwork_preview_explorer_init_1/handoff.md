# Handoff Report: Explorer 1 - Codebase Investigation for Bounty #99

## 1. Observation

1. **Project Entry Point & Configuration**:
   - `mix.exs`: Lines 1-168 define `:lux` app version `0.5.0`, Elixir `~> 1.18`, dependencies including `:bandit`, `:req`, `:venomous`, `:ex_json_schema`, `:telemetry`, `:excoveralls`.
   - `config/config.exs`: Lines 4-16 configure LLM model defaults for `:open_ai_models` (`cheapest: "gpt-4o-mini"`, `smartest: "gpt-4o"`), `:together_ai_models`, and `:open_router_models`.
   - `config/runtime.exs`: Lines 16-36 resolve API keys for `openai`, `mira`, `together`, `anthropic`, `openrouter`.

2. **LLM Provider Architecture**:
   - `lib/lux/llm.ex`: Lines 1-34 define `Lux.LLM` behaviour (`@callback call(prompt(), tools(), options())`), response struct `Lux.LLM.Response`, and default module delegation `@default_module`.
   - `lib/lux/llm/anthropic.ex`: Lines 1-211 implement `Lux.LLM.Anthropic`. Returns `{:ok, %Lux.LLM.Response{...}}` (lines 165-177).
   - `lib/lux/llm/open_ai.ex`: Lines 1-344 implement `Lux.LLM.OpenAI`. Converts tools to OpenAI functions (lines 195-228). Returns `{:ok, %Lux.Signal{schema_id: ResponseSignal, payload: ...}}` (lines 230-258).
   - `lib/lux/llm/open_router.ex`: Lines 1-737 implement `Lux.LLM.OpenRouter`. Features model fallbacks (`models: [...]`), cost calculation in metadata, retries on 429/503 status codes, and HTTP 200 error envelope decoding.
   - `lib/lux/llm/together_ai.ex` & `lib/lux/llm/mira.ex`: Implement Together AI and Mira Network providers returning `%Lux.Signal{schema_id: ResponseSignal}`.
   - `lib/lux/llm/response_signal.ex`: Lines 1-41 define `Lux.LLM.ResponseSignal` (`llm_response`, v1.0.0 schema).

3. **GenServer, Registry, and Telemetry Usage**:
   - `lib/lux/agent.ex`: Lines 96-280 use `GenServer` to manage agent state and execute `Lux.LLM.call/3`.
   - `lib/lux/agent_hub.ex`: Lines 18-234 use `GenServer` for central agent process registration, capability matching, and process monitoring via `Process.monitor/1`.
   - `lib/lux/company/execution_engine/supervisor.ex`: Lines 60-61, 182-183 use Elixir `Registry` (`{Registry, keys: :unique, name: ...}`) and lookup via `{:via, Registry, ...}`.
   - `config/anthropic.exs`: Lines 26-28 show Telemetry configuration (`config :lux, Lux.LLM.Anthropic.Telemetry, enabled: true, sample_rate: 0.1`).

4. **Monorepo & Placement Guidelines**:
   - `guides/contributing.md`: Lines 10-16 dictate structure: `lib/lux/prisms/`, `lib/lux/lenses/`, `lib/lux/beams/`, `lib/lux/signals/`, `lib/lux/schemas/`.
   - Unit tests are located under `test/unit/lux/` and mock HTTP requests using `Req.Test` and `UnitAPICase` (`test/test_helper.exs`).

---

## 2. Logic Chain

1. **Observation 1 & 2**: `Lux.LLM` provides a single compile-time callback interface (`call/3`), but return types differ between providers (`Anthropic` returns `%Lux.LLM.Response{}`, while `OpenAI`/`OpenRouter`/`TogetherAI`/`Mira` return `%Lux.Signal{schema_id: Lux.LLM.ResponseSignal}`).
   - *Deduction*: A universal `Lux.LLM.Provider` abstraction must normalize all LLM outputs into a unified response format (specifically `Lux.Signal` with `ResponseSignal`).

2. **Observation 2 & 3**: `OpenRouter` already has advanced fallback (`models: [...]`) and cost tracking logic, whereas standard providers (`OpenAI`, `Anthropic`, `TogetherAI`) lack built-in multi-provider failover, uniform telemetry emission, and dynamic registry capabilities.
   - *Deduction*: Implementing `Lux.LLM.ProviderRegistry` and a centralized LLM Router will allow dynamic provider registration, strategy selection (`:cheapest`, `:smartest`), multi-provider fallbacks (failover on 429/503/network error), and standardized `:telemetry` events for all calls.

3. **Observation 3**: Process lifecycle management across Lux relies on OTP patterns (`GenServer` for state management, `Registry` for dynamic process discovery, `Task.Supervisor` for async tasks).
   - *Deduction*: `ProviderRegistry` should be implemented as a `GenServer` (or use `Registry`) supervised under `Lux.Application`.

4. **Observation 4**: Contributing guidelines (`guides/contributing.md`) and test suite conventions (`test_helper.exs`) require modular placement under `lib/lux/llm/` and unit test co-location under `test/unit/lux/llm/` using `UnitAPICase` and `Req.Test`.
   - *Deduction*: New abstraction modules (`Lux.LLM.Provider`, `Lux.LLM.ProviderRegistry`, Router, Fallback, Telemetry) should be created under `lib/lux/llm/` with comprehensive unit tests in `test/unit/lux/llm/`.

---

## 3. Caveats

- **Network Execution**: Commands requiring system `mix` execution failed due to environment PATH restrictions in the runner sandbox environment.
- **Provider API Keys**: Integration tests require live API keys configured in `runtime.exs` or `test.envrc`. Unit tests using `Req.Test` should be prioritized for deterministic testing.

---

## 4. Conclusion

The Lux codebase possesses a solid OTP foundation with established patterns for Signals, GenServers, Registries, and HTTP client testing (`Req.Test`). However, the existing LLM implementations lack a unified provider behavior contract, dynamic provider registry, cross-provider fallback router, and standardized telemetry/cost tracking.

Designing `Lux.LLM.Provider`, `Lux.LLM.ProviderRegistry`, `Lux.LLM.Router`, and a Telemetry/Cost tracking module according to the findings in `analysis.md` will fulfill all requirements for Bounty #99 without breaking existing agent workflows.

---

## 5. Verification Method

1. **File Inspection**:
   - Inspect `lib/lux/llm.ex` and `lib/lux/llm/` to verify provider implementations.
   - Inspect `analysis.md` at `.agents/teamwork_preview_explorer_init_1/analysis.md`.
2. **Codebase Guidelines Compliance**:
   - Verify all proposed module paths adhere to `guides/contributing.md`.
