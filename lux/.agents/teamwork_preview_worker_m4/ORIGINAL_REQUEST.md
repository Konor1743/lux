## 2026-08-07T21:08:08Z
You are Worker 3 for Milestone 4 (WebSockets & Market Data Spot Lenses).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m4
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md
Explorer Blueprint: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/analysis.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Tasks:
1. Implement `Lux.Coinbase.WebSocket.Client` in `lib/lux/coinbase/web_socket/client.ex`.
   - WebSockex process handling connection to Coinbase WS feed (`wss://advanced-trade-ws.coinbase.com` / `wss://ws-feed.exchange.coinbase.com`).
   - Subscribe channel frames (`type: "subscribe"`, `product_ids`, `channel`).
   - Parse incoming frames, handle pings/pongs, auto-reconnection, emit `%Lux.Signal{}` signals.
2. Implement `Lux.Lenses.Coinbase.CoinbaseTickerPriceLens` in `lib/lux/lenses/coinbase/ticker_price_lens.ex`.
   - `use Lux.Lens` behaviour with input schema (`product_id` / `symbol`).
   - `focus/2` snapshot query using `Lux.Coinbase.Client.request/4`.
   - Normalization of WebSocket ticker events.
3. Implement `Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens` in `lib/lux/lenses/coinbase/exchange_info_lens.ex`.
   - `use Lux.Lens` behaviour with input schema.
   - `focus/2` snapshot query for product details/exchange status using `Lux.Coinbase.Client.request/4`.
   - Normalization of WebSocket status events.
4. Implement unit tests in `test/lux/coinbase/lenses_test.exs`.
   - Test Lens registration and schema definitions.
   - Test snapshot queries with `Req.Test` mocking.
   - Test WS frame parsing and signal generation.
5. Run verification commands:
   - `mix compile --warnings-as-errors`
   - `mix format`
   - `mix test test/lux/coinbase/`
6. Document all outputs and command results in `handoff.md`, then send a summary message back to parent.
