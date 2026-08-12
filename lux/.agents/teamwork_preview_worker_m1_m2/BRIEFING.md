# BRIEFING — 2026-08-02T23:56:00Z

## Mission
Implement Milestone 1 & 2 for Bounty #99: Universal LLM Provider Abstraction Layer for Lux (Provider Abstraction, Data Schemas, ProviderRegistry, Gemini Provider, adapt existing providers).

## 🔒 My Identity
- Archetype: implementer
- Roles: implementer, qa, specialist
- Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m1_m2/
- Original parent: 010d1bd7-eb58-4e6b-a024-7c2589ff0610
- Milestone: Milestone 1 & 2

## 🔒 Key Constraints
- DO NOT CHEAT. Genuine implementations only. No hardcoded outputs or facade implementations.
- Zero compilation warnings (`mix compile --warnings-as-errors`).
- All existing tests must pass.
- Handoff report in `.agents/teamwork_preview_worker_m1_m2/handoff.md`.

## Current Parent
- Conversation ID: 010d1bd7-eb58-4e6b-a024-7c2589ff0610
- Updated: 2026-08-02T23:56:00Z

## Task Summary
- **What to build**:
  1. `lib/lux/llm/provider.ex` (ModelConfig, ProviderConfig, Provider behaviour).
  2. `lib/lux/llm/provider_registry.ex` (GenServer registry with API).
  3. `lib/lux/llm/gemini.ex` (Google Gemini provider using Provider behaviour, Req, returning Signal with ResponseSignal schema).
  4. Adapt existing providers (`open_ai.ex`, `anthropic.ex`, `open_router.ex`, `together_ai.ex`) to adopt `@behaviour Lux.LLM.Provider` and return `{:ok, %Lux.Signal{schema_id: Lux.LLM.ResponseSignal}}`.
  5. Clean compilation and pass test suite.
- **Success criteria**: Zero warnings on compilation, passing tests, compliant handoff.
- **Interface contracts**: `PROJECT.md` & `.agents/teamwork_preview_explorer_init_2/analysis.md`.
- **Code layout**: `lib/lux/llm/`

## Key Decisions Made
- [TBD]

## Artifact Index
- `.agents/teamwork_preview_worker_m1_m2/ORIGINAL_REQUEST.md` — Original request
- `.agents/teamwork_preview_worker_m1_m2/BRIEFING.md` — Agent working memory

## Change Tracker
- **Files modified**: None yet
- **Build status**: Pending
- **Pending issues**: None

## Quality Status
- **Build/test result**: Pending
- **Lint status**: Pending
- **Tests added/modified**: Pending

## Loaded Skills
- None
