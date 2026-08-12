# Project: PR #99 Defects Resolution & Acceptance Verification

## Architecture
- Router (`Lux.LLM.Router` / `Router.call/3`): Enroutes requests to LLM providers. Handles registry lookups, option passing, fallback handling.
- OpenAI Provider (`Lux.LLM.OpenAI`): Provider implementation for OpenAI API. Uses module configuration for HTTP calls.
- Registry: Registry for LLM provider configs.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Exploration & Strategy | Code investigation of Router, OpenAI provider, tests | none | DONE |
| 2 | Implementation (R1, R2, R3) | Implement fixes in Router.call/3 and Lux.LLM.OpenAI + automated tests | M1 | DONE |
| 3 | Verification & Review | Code review, stress test, forensic audit | M2 | DONE |

## Interface Contracts
- `Router.call/3`: Filters control options (`:strategy`, `:capabilities`, `:registry_name`, `:estimated_prompt_tokens`, `:estimated_completion_tokens`, `:provider_id`, `:primary`, `:fallbacks`, `:fallback_on_all_errors`) before passing to provider. Only injects non-null registry configuration properties over app/user config.
- `Lux.LLM.OpenAI`: Respects dynamic `config.endpoint` from runtime config instead of `@endpoint`.

## Code Layout
- `lib/`: Implementation files
- `test/`: Test files
