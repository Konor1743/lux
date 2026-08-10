# BRIEFING — 2026-08-10T00:15:30Z

## Mission
Investigate Requirement R2 for PR #99: filtering router-exclusive control options passed to LLM providers in Lux.LLM.Router.

## 🔒 My Identity
- Archetype: Explorer
- Roles: Read-only investigation, code analysis, test planning, handoff report writing
- Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2
- Original parent: c8499ecb-1f89-4c10-b76d-d5d31f946cdc
- Milestone: m1

## 🔒 Key Constraints
- Read-only investigation — do NOT implement or edit source code files.
- Deliver findings in `analysis.md` and handoff report in `handoff.md`.
- Notify orchestrator via `send_message` when complete.

## Current Parent
- Conversation ID: c8499ecb-1f89-4c10-b76d-d5d31f946cdc
- Updated: 2026-08-10T00:15:30Z

## Investigation State
- **Explored paths**: `lib/lux/llm/router.ex`, `lib/lux/llm/fallback.ex`, built-in providers (`open_ai.ex`, `anthropic.ex`, `gemini.ex`, `open_router.ex`, `together_ai.ex`, `mira.ex`), unit tests (`test/unit/lux/llm/router_test.exs`, `test/unit/lux/llm/fallback_test.exs`).
- **Key findings**:
  - `Router.call/3` passes `call_opts` built directly from `opts_map` to provider `.call/3` without dropping router/fallback control options.
  - Strict providers using `struct!(ConfigModule, opts)` raise `KeyError` when unexpected control options are present.
  - Identified full 9-item control options set: `[:strategy, :capabilities, :registry_name, :estimated_prompt_tokens, :estimated_completion_tokens, :provider_id, :primary, :fallbacks, :fallback_on_all_errors]`.
  - Recommends `Map.drop(opts_map, @control_opts)` inside `Router.call/3`.
  - Formulated AC2 test suite plan with `StrictProvider` (`struct!`) and real provider adapters (`Lux.LLM.OpenAI`) using `Req.Test` HTTP mocks.
- **Unexplored areas**: None (investigation complete).

## Key Decisions Made
- Completed analysis and detailed handoff report in `analysis.md` and `handoff.md`.

## Artifact Index
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/ORIGINAL_REQUEST.md — Original request instructions
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/BRIEFING.md — Persistent briefing index
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/analysis.md — Detailed analysis report for Requirement R2
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/handoff.md — 5-component handoff report
