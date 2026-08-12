## 2026-08-02T23:55:57Z
You are Worker 1 for task Bounty #99 (Universal LLM Provider Abstraction Layer for Lux).
Your working directory is `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m1_m2/`.
Project root is `/home/Konor1743/Operacion Dolar/lux/lux`.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope: Milestone 1 & 2 (Provider Abstraction, Data Schemas, ProviderRegistry, and Gemini Provider).

Task:
1. Read `/home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md` and `.agents/teamwork_preview_explorer_init_2/analysis.md` for architectural design specs.
2. Create `lib/lux/llm/provider.ex`:
   - Define `Lux.LLM.ModelConfig` struct (`:id`, `:name`, `:provider_id`, `:cost_per_1k_prompt_tokens`, `:cost_per_1k_completion_tokens`, `:capabilities`, `:context_window`).
   - Define `Lux.LLM.ProviderConfig` struct (`:id`, `:module`, `:api_key`, `:endpoint`, `:models`, `:status`).
   - Define `Lux.LLM.Provider` behaviour (`@callback id() :: atom()`, `@callback models() :: [Lux.LLM.ModelConfig.t()]`, `@callback call(prompt :: String.t(), tools :: list(), opts :: map() | keyword()) :: {:ok, Lux.Signal.t()} | {:error, term()}`).
3. Create `lib/lux/llm/provider_registry.ex`:
   - Implement GenServer `Lux.LLM.ProviderRegistry`.
   - Provide public API: `start_link/1`, `register_provider/2`, `unregister_provider/1`, `get_provider/1`, `list_providers/0`, `list_models/1`, `update_provider_status/2`.
   - Ensure it can be supervised or started dynamically in application supervision tree if appropriate.
4. Create `lib/lux/llm/gemini.ex`:
   - Implement Google Gemini provider adopting `Lux.LLM.Provider` behaviour.
   - Converts prompt and tools into Gemini API format (`contents`, `tools`, etc.).
   - Employs `Req` for HTTP communication, returning `{:ok, %Lux.Signal{schema_id: Lux.LLM.ResponseSignal}}`.
5. Adapt existing providers (`open_ai.ex`, `anthropic.ex`, `open_router.ex`, `together_ai.ex`) to adopt `@behaviour Lux.LLM.Provider` and ensure `call/3` returns `{:ok, %Lux.Signal{schema_id: Lux.LLM.ResponseSignal}}`.
6. Compile the codebase with `mix compile` (or `mix compile --warnings-as-errors`) to verify there are zero warnings.
7. Write your completion report to `.agents/teamwork_preview_worker_m1_m2/handoff.md` and send a message to orchestrator (`010d1bd7-eb58-4e6b-a024-7c2589ff0610`).
