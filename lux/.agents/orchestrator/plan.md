# Execution Plan: PR #99 Defects & Acceptance Criteria

## Objectives
1. R1: Fix null credential propagation in `Router.call/3` (only inject non-null config properties from registry).
2. R2: Filter control options in `Router.call/3` (avoid passing `:strategy`, `:capabilities`, `:registry_name`, `:estimated_prompt_tokens`, `:primary`, `:fallbacks` to strict provider configs to avoid KeyError).
3. R3: Respect dynamic `config.endpoint` in `Lux.LLM.OpenAI` (instead of static `@endpoint`).
4. Ensure automated test coverage for all 3 criteria and verify full test suite passes.

## Phase 1: Exploration
- Dispatch 3 `teamwork_preview_explorer` agents to analyze:
  - Codebase structure around `Router.call/3`, `Lux.LLM.OpenAI`, and registry credential merging.
  - Existing test suite setup, test helpers, and HTTP mocking mechanism (e.g. bypass/req/finch/etc.).
  - Detailed fix requirements and exact locations for R1, R2, R3, and test implementations.

## Phase 2: Implementation & Verification Loop
- Dispatch `teamwork_preview_worker` to apply fixes for R1, R2, R3 and add unit/integration tests for each criteria.
- Worker runs `mix test` and reports results.

## Phase 3: Review & Challenge
- Dispatch 2 `teamwork_preview_reviewer` agents to review code quality, edge cases, and adherence to requirements.
- Dispatch 2 `teamwork_preview_challenger` agents to perform empirical stress testing / adversarial verification.

## Phase 4: Forensic Audit & Gating
- Dispatch `teamwork_preview_auditor` to run integrity checks (authentic implementation, no hardcoded test results).
- If CLEAN and tests pass, finalize and report back to Sentinel.
