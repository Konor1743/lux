# Orchestration Plan — Bounty #99 (Universal LLM Provider Abstraction Layer)

## Goal
Implement a complete Universal LLM Provider Abstraction Layer (`Lux.LLM.Provider`, `Lux.LLM.ProviderRegistry`, `Lux.LLM.Router`, `Lux.LLM.Fallback`, `Lux.LLM.Telemetry`, `Lux.LLM.Gemini`, provider adapters, and ExUnit test suite) meeting requirements R1-R5 and all acceptance criteria.

## Milestones & Strategy

### Milestone 1: Provider Abstraction (`Lux.LLM.Provider`) & Adapters
- **Objective**: Define `Lux.LLM.Provider` behaviour, `ModelConfig` & `ProviderConfig` structs, normalize return type to `Lux.Signal` with `ResponseSignal`, and implement `Lux.LLM.Gemini` provider alongside adapting OpenAI, Anthropic, OpenRouter, TogetherAI.
- **Worker**: `teamwork_preview_worker`
- **Verification**: Code compiles without warnings, provider modules conform to behaviour.

### Milestone 2: Provider Registry (`Lux.LLM.ProviderRegistry`)
- **Objective**: Implement GenServer process for registering, querying, updating, and unregistering providers and their models.
- **Worker**: `teamwork_preview_worker`
- **Verification**: GenServer starts, supports dynamic registration/lookup, passes unit tests.

### Milestone 3: Dynamic Router (`Lux.LLM.Router`)
- **Objective**: Implement selection algorithms (`:cheapest`, `:smartest`, capability filtering like `:vision`, `:tools`, token costs).
- **Worker**: `teamwork_preview_worker`
- **Verification**: Router selects correct model based on criteria and provider status.

### Milestone 4: Resilience & Smart Fallback (`Lux.LLM.Fallback`)
- **Objective**: Implement transparent failover engine catching HTTP 429, HTTP 503, and network errors, trying fallback model specs sequentially, and appending `fallback_history` metadata.
- **Worker**: `teamwork_preview_worker`
- **Verification**: 429/503 errors trigger fallback seamlessly.

### Milestone 5: Telemetry, Cost Tracking & Signal Normalization (`Lux.LLM.Telemetry`)
- **Objective**: Implement `:telemetry` event dispatch, prompt/completion token pricing calculation, and signal metadata enrichment.
- **Worker**: `teamwork_preview_worker`
- **Verification**: Telemetry events emitted, token costs populated in signal metadata.

### Milestone 6: ExUnit Test Suite & Documentation
- **Objective**: Implement unit tests in `test/unit/lux/llm/` (`provider_registry_test.exs`, `router_test.exs`, `fallback_test.exs`, `telemetry_test.exs`, `gemini_test.exs`) using `UnitAPICase` and `Req.Test` HTTP mocks. Add `@moduledoc` and `@doc` documentation.
- **Worker**: `teamwork_preview_worker`
- **Verification**: 100% green tests in `mix test test/unit/lux/llm/`.

### Milestone 7: Verification & Forensic Audit
- **Objective**: Run Reviewer, Challenger, and Forensic Auditor checks to verify monorepo compilation, 100% green test execution, and code integrity.
- **Agents**: Reviewer, Challenger, Forensic Auditor (`teamwork_preview_auditor`).
- **Gate**: Zero compiler warnings, 100% test pass, CLEAN audit verdict.

## Execution Topology
We will dispatch Worker subagents for sequential/grouped milestone implementation, followed by Reviewer, Challenger, and Forensic Auditor for rigorous verification.
