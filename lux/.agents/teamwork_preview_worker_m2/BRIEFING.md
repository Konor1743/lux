# BRIEFING — 2026-08-07T16:05:54Z

## Mission
Implement `Lux.Coinbase.Client` with HMAC-SHA256 authentication and unit test suite in `test/lux/coinbase/client_test.exs`.

## 🔒 My Identity
- Archetype: implementer
- Roles: implementer, qa, specialist
- Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m2
- Original parent: 0ae574be-04d1-4d94-821f-874ecd93079d
- Milestone: Milestone 2 (Core REST Client & HMAC-SHA256 Auth)

## 🔒 Key Constraints
- CODE_ONLY network mode: no external HTTP requests.
- Use exact HMAC-SHA256 formula: `Base.encode16(:crypto.mac(:hmac, :sha256, secret, timestamp <> Upcase(method) <> path <> body), case: :lower)`.
- Support mainnet (`https://api.coinbase.com`) and sandbox (`https://api-public.sandbox.exchange.coinbase.com`).
- Req client execution using `Req.new/1` allowing `req_options` for `Req.Test` plug overriding.
- Minimal changes principle, genuine implementation, no cheating or hardcoding.

## Current Parent
- Conversation ID: 0ae574be-04d1-4d94-821f-874ecd93079d
- Updated: 2026-08-07T16:05:54Z

## Task Summary
- **What to build**: `Lux.Coinbase.Client` in `lib/lux/coinbase/client.ex` and `Lux.Coinbase.ClientTest` in `test/lux/coinbase/client_test.exs`.
- **Success criteria**:
  1. `Lux.Coinbase.Client` correctly calculates HMAC-SHA256 signature headers.
  2. Environment URLs selection for mainnet vs sandbox.
  3. All ExUnit tests in `test/lux/coinbase/client_test.exs` pass with `Req.Test`.
  4. `mix compile --warnings-as-errors`, `mix format`, and `mix test test/lux/coinbase/client_test.exs` pass cleanly.
- **Interface contracts**: `PROJECT.md` and `analysis.md`.
- **Code layout**: `lib/lux/coinbase/client.ex` and `test/lux/coinbase/client_test.exs`.

## Key Decisions Made
- `Code.ensure_loaded?(Lux.Coinbase.RateLimiter)` used to attach RateLimiter middleware if compiled, ensuring clean decouple with Milestone 3.
- `sign_prehash/2` exposed as public function for direct reference vector verification.
- Pre-existing compiler warnings resolved cleanly so `mix compile --warnings-as-errors` passes repository-wide.

## Change Tracker
- **Files modified**:
  - `lib/lux/coinbase/client.ex` — Implemented Coinbase REST client with HMAC-SHA256 signing & environment configuration
  - `test/lux/coinbase/client_test.exs` — Implemented 10 ExUnit unit tests with Req.Test
  - `lib/lux/lenses/allora/get_topics.ex` — Fixed pre-existing unused variable warnings
  - `lib/lux/lenses/allora/get_inference.ex` — Removed pre-existing invalid @impl true annotation
  - `lib/lux/llm/mira.ex` — Fixed pre-existing unused variable and attribute warnings
- **Build status**: `mix compile --warnings-as-errors` PASS, `mix format` PASS, `mix test` PASS (10 tests, 0 failures)
- **Pending issues**: None

## Quality Status
- **Build/test result**: PASS
- **Lint status**: 0 violations / warnings
- **Tests added/modified**: 10 tests in `test/lux/coinbase/client_test.exs`

## Loaded Skills
- None

## Artifact Index
- `.agents/teamwork_preview_worker_m2/ORIGINAL_REQUEST.md` — Original prompt request log
- `.agents/teamwork_preview_worker_m2/BRIEFING.md` — Agent briefing & working memory
- `.agents/teamwork_preview_worker_m2/progress.md` — Progress tracker
- `.agents/teamwork_preview_worker_m2/handoff.md` — Handoff report
