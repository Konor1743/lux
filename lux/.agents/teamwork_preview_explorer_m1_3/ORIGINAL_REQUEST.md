## 2026-08-07T21:03:06Z
You are Explorer 3 for Milestone 1 (Coinbase Spot Trading Prisms Architecture).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_3
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md

Objective:
1. Inspect existing Binance Prisms in `lib/lux/prisms/binance/` (`BinanceSpotAccountPrism`, `BinanceSpotOrderPrism`, `BinanceSpotCancelOrderPrism`, `BinanceSpotOpenOrdersPrism`) and `lib/lux/prism.ex` to understand Lux Prism architecture, behaviors, schemas, and API integration.
2. Analyze how Binance Prisms interface with `Lux.Binance.Client`, parse parameters, transform responses, handle errors, and integrate with Lux runtime.
3. Map Coinbase Advanced Trade REST endpoints for:
   - Account Details: GET /api/v3/brokerage/accounts
   - Create Order: POST /api/v3/brokerage/orders
   - Cancel Order: POST /api/v3/brokerage/orders/batch_cancel
   - List Open Orders: GET /api/v3/brokerage/orders/historical/fills or GET /api/v3/brokerage/orders/historical/batch
4. Formulate exact design and step-by-step implementation guide for:
   - `lib/lux/prisms/coinbase/spot_account_prism.ex` (`Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism`)
   - `lib/lux/prisms/coinbase/spot_order_prism.ex` (`Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism`)
   - `lib/lux/prisms/coinbase/spot_cancel_order_prism.ex` (`Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism`)
   - `lib/lux/prisms/coinbase/spot_open_orders_prism.ex` (`Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism`)
   - `test/lux/coinbase/prisms_test.exs`

Write your full findings and blueprint to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_3/analysis.md` and `handoff.md`, then send a message back to parent with a summary.
