## 2026-08-07T21:03:06Z
<USER_REQUEST>
You are Explorer 2 for Milestone 1 (Coinbase WebSockets Market Lenses Architecture).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md

Objective:
1. Inspect existing Binance Lenses in `lib/lux/lenses/binance/` (e.g. `BinanceTickerPriceLens`, `BinanceExchangeInfoLens`) and `lib/lux/lenses/` to understand Lux Lens abstractions and WebSockex usage.
2. Analyze WebSocket behavior: connection URL, subscription channels, heartbeat/ping-pong, message parsing, state management, auto-reconnection, data normalization.
3. Research Coinbase Advanced Trade WebSocket API specifications (wss://ws-feed.exchange.coinbase.com or wss://advanced-trade-ws.coinbase.com, ticker channels, status channels).
4. Formulate exact design and step-by-step implementation guide for:
   - `lib/lux/lenses/coinbase/ticker_price_lens.ex` (`Lux.Lenses.Coinbase.CoinbaseTickerPriceLens`)
   - `lib/lux/lenses/coinbase/exchange_info_lens.ex` (`Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens`)
   - `test/lux/coinbase/lenses_test.exs`

Write your full findings and blueprint to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/analysis.md` and `handoff.md`, then send a message back to parent with a summary.
</USER_REQUEST>
