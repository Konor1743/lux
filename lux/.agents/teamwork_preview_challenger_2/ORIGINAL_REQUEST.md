## 2026-08-07T21:11:52Z
<USER_REQUEST>
You are Challenger 2 for Milestone 6 (Adversarial Testing & Lenses/Prisms Hardening).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_challenger_2
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md

Objective:
1. Perform empirical stress and adversarial testing on WebSockets Lenses (`CoinbaseTickerPriceLens`, `CoinbaseExchangeInfoLens`) and Spot Trading Prisms (`SpotAccountPrism`, `SpotOrderPrism`, `SpotCancelOrderPrism`, `SpotOpenOrdersPrism`).
2. Test edge cases:
   - Malformed WebSocket JSON frames and unexpected event structures.
   - Unsupported order types or missing required fields in `SpotOrderPrism`.
   - Empty order ID arrays in `SpotCancelOrderPrism`.
   - Context credential inheritance vs option override precedence.
3. Run verification commands:
   - `mix compile --warnings-as-errors`
   - `mix test test/lux/coinbase/`
4. Document test findings, stress results, and write `handoff.md`, then send a summary message back to parent.
</USER_REQUEST>
