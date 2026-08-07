# BRIEFING — 2026-08-07T21:09:00Z

## Mission
Implement Coinbase WebSocket client, CoinbaseTickerPriceLens, CoinbaseExchangeInfoLens, and unit tests for Coinbase integration in Lux.

## 🔒 My Identity
- Archetype: implementer/qa/specialist
- Roles: implementer, qa, specialist
- Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m4
- Original parent: 0ae574be-04d1-4d94-821f-874ecd93079d
- Milestone: Milestone 4 (WebSockets & Market Data Spot Lenses)

## 🔒 Key Constraints
- CODE_ONLY network mode: no external HTTP/WS requests allowed during tests.
- DO NOT CHEAT. All implementations must be genuine.
- Minimal change principle.
- Full compliance with Elixir code formatting and warning rules.

## Current Parent
- Conversation ID: 0ae574be-04d1-4d94-821f-874ecd93079d
- Updated: 2026-08-07T21:09:00Z

## Task Summary
- **What to build**:
  1. `Lux.Coinbase.WebSocket.Client` in `lib/lux/coinbase/web_socket/client.ex`
  2. `Lux.Lenses.Coinbase.CoinbaseTickerPriceLens` in `lib/lux/lenses/coinbase/ticker_price_lens.ex`
  3. `Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens` in `lib/lux/lenses/coinbase/exchange_info_lens.ex`
  4. Unit tests in `test/lux/coinbase/lenses_test.exs`
- **Success criteria**:
  - `mix compile --warnings-as-errors` passes cleanly (PASS).
  - `mix format` checks pass (PASS).
  - `mix test test/lux/coinbase/` runs and passes completely (36 tests, 0 failures).
  - Handoff report in `handoff.md`.
- **Interface contracts**: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md`
- **Code layout**: `lib/lux/...`, `test/lux/...`

## Key Decisions Made
- `Lux.Coinbase.WebSocket.Client` implements `WebSockex` with auto-reconnection loopback TCP fallback, support for channel subscriptions (`ticker`, `status`), control frames (ping/pong), and signal emissions (`%Lux.Signal{}`).
- `CoinbaseTickerPriceLens` supports both `product_id` and `symbol` keys in input schema, REST snapshot queries via `Lux.Coinbase.Client.request/4`, and normalization for Advanced Trade & Exchange Feed WS ticker events.
- `CoinbaseExchangeInfoLens` supports optional `product_id` filtering or full product listing, REST snapshot queries, and normalization for status WS events.
- `test/lux/coinbase/lenses_test.exs` provides comprehensive ExUnit tests using `Req.Test` mocking for REST endpoints and process messaging for WS streams.

## Change Tracker
- **Files modified**:
  - `lib/lux/coinbase/web_socket/client.ex`: Implemented `Lux.Coinbase.WebSocket.Client`
  - `lib/lux/lenses/coinbase/ticker_price_lens.ex`: Implemented `Lux.Lenses.Coinbase.CoinbaseTickerPriceLens`
  - `lib/lux/lenses/coinbase/exchange_info_lens.ex`: Implemented `Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens`
  - `test/lux/coinbase/lenses_test.exs`: Implemented ExUnit tests
- **Build status**: PASS (`mix compile --warnings-as-errors`)
- **Pending issues**: None

## Quality Status
- **Build/test result**: 36 tests passing in `test/lux/coinbase/` (94 tests passing in `test/lux/`)
- **Lint status**: `mix format --check-formatted` passed with 0 violations
- **Tests added/modified**: `test/lux/coinbase/lenses_test.exs` added with 10 test cases

## Loaded Skills
- None

## Artifact Index
- `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m4/ORIGINAL_REQUEST.md` — Original request
- `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m4/BRIEFING.md` — Briefing document
- `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m4/progress.md` — Progress log
- `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m4/handoff.md` — Handoff report
