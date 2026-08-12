# Explorer Handoff Report: Bounty #99 (LLM Provider Abstraction Layer for Lux)

## 1. Observation
- **`lib/lux/llm.ex` (lines 28-32)**:
  `Lux.LLM` defines `@callback call(prompt(), tools(), options())` and delegates directly to `@default_module` (`Lux.LLM.OpenAI`). No provider registration, model capability metadata, dynamic router, fallback manager, or telemetry dispatch is configured in `Lux.LLM`.
- **`lib/lux/llm/open_ai.ex` (lines 6-7, 230-257)**:
  `Lux.LLM.OpenAI` implements `Lux.LLM` `@behaviour` and returns a `Lux.Signal` validated against `Lux.LLM.ResponseSignal` with `metadata` containing `usage` and `id`.
- **`lib/lux/llm/anthropic.ex` (lines 166-177)**:
  `Lux.LLM.Anthropic` returns `{:ok, %Lux.LLM.Response{content: ..., tool_calls: ..., finish_reason: ...}}` directly, resulting in response type inconsistency across provider implementations.
- **`lib/lux/llm/open_router.ex` (lines 45-56, 568-632)**:
  `Lux.LLM.OpenRouter` includes custom HTTP 429/503 retry handling and cost accounting (`cost_summary/1`, `within_budget?/2`), but this logic is isolated to OpenRouter and not available to OpenAI, Anthropic, or Gemini.
- **Missing Module**: Google Gemini (`Lux.LLM.Gemini`) is missing from `lib/lux/llm/`.
- **Monorepo Layout**: Provider code belongs in `lux/lux/lib/lux/llm/` and unit test code belongs in `lux/lux/test/unit/lux/llm/`.

## 2. Logic Chain
1. **Observation 1 & 3**: Current providers either return `Response` struct or `Lux.Signal`, and `Lux.LLM.call/3` routes directly to a static default module.
2. **Step 1 -> Inference**: A new behaviour `Lux.LLM.Provider` is required to standardize the return format (`{:ok, %Lux.Signal{schema_id: ResponseSignal}}`) and specify model capabilities (`models/0` returning `ModelConfig` structs with token costs and capability lists).
3. **Observation 4 & 5**: OpenRouter implements custom 429/503 retries, but other providers lack transparent fallbacks, and Gemini is missing.
4. **Step 3 -> Inference**: Creating `Lux.LLM.ProviderRegistry` (GenServer) allows dynamic provider registration and lookup. Creating `Lux.LLM.Router` enables `:cheapest` and `:smartest` model selection algorithms based on `ModelConfig`. Creating `Lux.LLM.Fallback` allows any provider call to transparently failover on 429/503/network errors to secondary models while attaching `fallback_history` to `signal.metadata`. Creating `Lux.LLM.Gemini` completes R1 requirements.
5. **Conclusion**: Implementing `Lux.LLM.Provider`, `Lux.LLM.ProviderRegistry`, `Lux.LLM.Router`, `Lux.LLM.Fallback`, `Lux.LLM.Gemini`, and `:telemetry` instrumentation satisfies requirements R1-R4 and allows ExUnit testing (R5) using `Req.Test` HTTP mocks.

## 3. Caveats
- No live network requests were made (CODE_ONLY mode). Verification relies on codebase analysis and `Req.Test` unit testing structure.
- `mix` CLI execution was not directly available in standard PATH during inspection, but unit test specifications follow `Req.Test` patterns verified in existing tests (`open_ai_test.exs`, `open_router_test.exs`).

## 4. Conclusion
The proposed architecture fully meets all acceptance criteria for Bounty #99:
- `Lux.LLM.Provider`: Universal behaviour defining `id/0`, `models/0`, and `call/3`.
- `Lux.LLM.ProviderRegistry`: Central GenServer process for registering, querying, and updating providers and model configurations.
- `Lux.LLM.Router`: Dynamic model selector supporting `:cheapest`, `:smartest`, and capability filtering.
- `Lux.LLM.Fallback`: Transparent failover engine catching 429/503/network errors and preserving audit trail in `fallback_history`.
- `Lux.LLM.Gemini`: Google Gemini provider implementation normalized to `ResponseSignal`.
- Telemetry & Cost Tracking: Uniform `:telemetry` events and USD cost calculations normalized in `Lux.Signal`.

## 5. Verification Method
- **Files to Inspect**:
  - `lib/lux/llm/provider.ex`
  - `lib/lux/llm/provider_registry.ex`
  - `lib/lux/llm/router.ex`
  - `lib/lux/llm/fallback.ex`
  - `lib/lux/llm/gemini.ex`
  - `.agents/teamwork_preview_explorer_init_2/analysis.md`
- **Commands**:
  - Compile check: `mix compile --warnings-as-errors`
  - Test command: `mix test test/unit/lux/llm/`
