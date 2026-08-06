## 2026-08-05T22:30:33Z
You are the Worker subagent for Milestones 3-6 of Bounty #99 (Universal LLM Provider Abstraction Layer for Spectral-Finance/lux).

Your working directory is `/home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_m3_m5`.
Project root is `/home/Konor1743/Operacion Dolar/lux/lux`.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Your Tasks:
1. Environment Setup: Run `mix deps.get` in `/home/Konor1743/Operacion Dolar/lux/lux` to fetch dependencies for the test environment.
2. Read existing codebase in `lib/lux/llm/` and `test/unit/lux/llm/` to understand existing structures (`Lux.LLM.Provider`, `Lux.LLM.ProviderRegistry`, `Lux.LLM.Gemini`, `Lux.LLM.OpenAI`, etc.).
3. Milestone 3: Implement Dynamic Router (`Lux.LLM.Router` in `lib/lux/llm/router.ex`):
   - Implement selection algorithms (`:cheapest`, `:smartest`, capability filtering like `:vision`, `:tools`, token pricing calculations).
   - Integrate with `Lux.LLM.ProviderRegistry` to list and evaluate registered provider/model candidates.
4. Milestone 4: Implement Smart Fallback (`Lux.LLM.Fallback` in `lib/lux/llm/fallback.ex`):
   - Implement failover engine that catches network errors, HTTP 429 (Rate Limit), and HTTP 503 (Service Unavailable).
   - Transparently try primary provider spec, then fallback specs sequentially.
   - Attach `fallback_history` to `Lux.Signal` metadata.
5. Milestone 5: Implement Telemetry & Cost Tracking (`Lux.LLM.Telemetry` in `lib/lux/llm/telemetry.ex`):
   - Instrument LLM calls to measure latency and token usage.
   - Emit `:telemetry` events (`[:lux, :llm, :call, :start]`, `[:lux, :llm, :call, :stop]`, etc.).
   - Calculate prompt/completion token costs and normalize in `Lux.Signal` metadata.
6. Milestone 6: Complete ExUnit test suite and documentation:
   - Create `test/unit/lux/llm/router_test.exs`, `test/unit/lux/llm/fallback_test.exs`, `test/unit/lux/llm/telemetry_test.exs`.
   - Ensure all tests in `test/unit/lux/llm/` run cleanly using `Req.Test` or mocks (0 network or real API calls).
   - Add `@moduledoc` and `@doc` documentation to all modules in `lib/lux/llm/`.
7. Build & Test Verification:
   - Run `mix compile --warnings-as-errors`
   - Run `mix test test/unit/lux/llm/`
8. Deliver handoff report: Write `handoff.md` in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_m3_m5/handoff.md` detailing:
   - Files created/modified
   - Compilation and test commands executed with exact output snippets
   - Handoff status
9. Send a message to parent when completed.
