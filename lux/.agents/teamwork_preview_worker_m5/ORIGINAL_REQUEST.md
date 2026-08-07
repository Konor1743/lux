## 2026-08-07T21:09:59Z
You are Worker 4 for Milestone 5 (Spot Trading Prisms).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m5
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md
Explorer Blueprint: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_3/analysis.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Tasks:
1. Implement `Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism` in `lib/lux/prisms/coinbase/spot_account_prism.ex`.
   - `use Lux.Prism` behavior. Query `GET /api/v3/brokerage/accounts` using `Lux.Coinbase.Client.request/4`.
2. Implement `Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism` in `lib/lux/prisms/coinbase/spot_order_prism.ex`.
   - `use Lux.Prism` behavior. Input schema for product_id, side, type, base_size, price, stop_price. Format `order_configuration` payload for `POST /api/v3/brokerage/orders`.
3. Implement `Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism` in `lib/lux/prisms/coinbase/spot_cancel_order_prism.ex`.
   - `use Lux.Prism` behavior. Input schema for order_id or order_ids array. Format `{"order_ids": [...]}` payload for `POST /api/v3/brokerage/orders/batch_cancel`.
4. Implement `Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism` in `lib/lux/prisms/coinbase/spot_open_orders_prism.ex`.
   - `use Lux.Prism` behavior. Query `GET /api/v3/brokerage/orders/historical/batch` with status filter `order_status=OPEN`.
5. Implement unit tests in `test/lux/coinbase/prisms_test.exs`.
   - Test Prism registrations, schemas, handler executions with `Req.Test` mocking for all 4 Prisms.
6. Run verification commands:
   - `mix compile --warnings-as-errors`
   - `mix format`
   - `mix test test/lux/coinbase/`
7. Document all outputs and command logs in `handoff.md`, then send a summary message back to parent.
