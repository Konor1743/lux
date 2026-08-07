# BRIEFING — 2026-08-07T21:14:45Z

## Mission
Perform empirical stress and adversarial testing on Coinbase WebSocket Lenses and Spot Trading Prisms.

## 🔒 My Identity
- Archetype: EMPIRICAL CHALLENGER
- Roles: critic, specialist
- Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_challenger_2
- Original parent: 0ae574be-04d1-4d94-821f-874ecd93079d
- Milestone: Milestone 6
- Instance: Challenger 2

## 🔒 Key Constraints
- Review-only — do NOT modify implementation code (unless needed for tests, but we write test files in test suite, check if we modify implementation - rules state "Run build and tests to verify the work product. Report any failures as findings — do NOT fix them yourself.")
- Write only to your folder /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_challenger_2 for metadata.

## Current Parent
- Conversation ID: 0ae574be-04d1-4d94-821f-874ecd93079d
- Updated: 2026-08-07T21:14:45Z

## Review Scope
- **Files to review/test**: 
  - WebSocket Lenses: `CoinbaseTickerPriceLens`, `CoinbaseExchangeInfoLens`
  - Spot Trading Prisms: `SpotAccountPrism`, `SpotOrderPrism`, `SpotCancelOrderPrism`, `SpotOpenOrdersPrism`
- **Interface contracts**: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md`
- **Review criteria**: Correctness under adversarial conditions, edge cases (malformed WS JSON, unsupported order types, missing required fields, empty order ID arrays, credential inheritance vs override precedence).

## Attack Surface
- **Hypotheses tested**:
  1. WS Lenses handle malformed JSON / unexpected event arrays gracefully.
  2. `SpotOrderPrism` rejects or safely handles unsupported order types and missing required fields.
  3. `SpotCancelOrderPrism` safely handles empty `order_ids` arrays and single `order_id` fallback.
  4. Context credential inheritance correctly gives input parameters precedence over context, including boolean options (`sandbox`).
- **Vulnerabilities found**:
  1. Option Override Precedence Bug (`sandbox`): Input `sandbox: false` fails to override context `sandbox: true` because `false || Map.get(ctx, :sandbox)` evaluates to `true`.
  2. Context Credential Key Resolution Bug: Context string keys (`"api_key"`) are ignored by `build_opts`, causing `{:error, :missing_secret_key}`.
  3. Silent Order Type Fallback: `SpotOrderPrism` silently defaults any unrecognized/unsupported order type to `LIMIT` GTC order configuration rather than returning an error tuple.
  4. Non-Map Unhandled Exceptions: `normalize_ws_frame/1` crashes with `BadMapError` / `FunctionClauseError` when `events`, `tickers`, or `products` contain non-map items (e.g. `[123]`).
- **Untested angles**:
  - Live socket network disconnect / reconnect under high message throughput.

## Loaded Skills
- None loaded.

## Key Decisions Made
- Created 32 targeted adversarial tests in `test/lux/coinbase/adversarial_lenses_prisms_test.exs`.
- Ran full test suite (113 tests, 0 failures, zero compilation warnings with `--warnings-as-errors`).

## Artifact Index
- ORIGINAL_REQUEST.md — Original request details
- BRIEFING.md — Working briefing index
- progress.md — Heartbeat & execution log
- test/lux/coinbase/adversarial_lenses_prisms_test.exs — Adversarial test suite
- handoff.md — Final 5-component handoff report
