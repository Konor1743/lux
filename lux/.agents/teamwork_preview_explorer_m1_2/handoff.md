# Handoff Report — Explorer 2 (Milestone 1: Coinbase WebSockets Market Lenses Architecture)

## 1. Observation
- **Existing Binance Lens Implementation**:
  - `lib/lux/lens.ex:68-115`: `use Lux.Lens` registers `@behaviour Lux.Lens`, builds compile-time `@lens_struct`, defines `view/0`, `focus/2`, `before_focus/1`, `after_focus/1`.
  - `lib/lux/lenses/binance/ticker_price_lens.ex:16-60`: `BinanceTickerPriceLens` uses `use Lux.Lens` with schema, overrides `focus/2` calling `Lux.Binance.Client.request(:get, market_type, path, params, opts)`.
  - `lib/lux/lenses/binance/exchange_info_lens.ex:16-60`: `BinanceExchangeInfoLens` uses `use Lux.Lens` with schema, overrides `focus/2` calling `Lux.Binance.Client.request(:get, market_type, path, params, opts)`.
  - `lib/lux/binance/web_socket/client.ex:9-175`: `Lux.Binance.WebSocket.Client` uses `use WebSockex`, manages subscriptions, handles `{:ping, data}` pong replies, parses JSON text frames, emits `%Lux.Signal{}` and `{:ws_event, data}`, handles reconnection with an in-memory TCP mock server.
- **Coinbase WebSockets Architecture**:
  - Advanced Trade WS base URL: `wss://advanced-trade-ws.coinbase.com` (sandbox: `wss://advanced-trade-ws-sandbox.coinbase.com`).
  - Exchange Feed WS base URL: `wss://ws-feed.exchange.coinbase.com`.
  - Subscription frame format: `{"type": "subscribe", "product_ids": ["BTC-USD"], "channel": "ticker"}`.
  - Channels: `ticker` (price, bid/ask, 24h volume/high/low), `status` (product status, increments, currencies), `heartbeats`.
- **Target Deliverable Paths**:
  - `lib/lux/coinbase/web_socket/client.ex` (`Lux.Coinbase.WebSocket.Client`)
  - `lib/lux/lenses/coinbase/ticker_price_lens.ex` (`Lux.Lenses.Coinbase.CoinbaseTickerPriceLens`)
  - `lib/lux/lenses/coinbase/exchange_info_lens.ex` (`Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens`)
  - `test/lux/coinbase/lenses_test.exs` (`Lux.Coinbase.LensesTest`)

## 2. Logic Chain
1. *Observation*: Binance market lenses (`BinanceTickerPriceLens`, `BinanceExchangeInfoLens`) adopt a two-tier pattern: REST snapshot queries through `focus/2` and real-time streaming via `Lux.Binance.WebSocket.Client`.
2. *Reasoning*: Following this pattern in Coinbase integration ensures architectural consistency across exchange integrations within `Spectral-Finance/lux`.
3. *Observation*: Coinbase Advanced Trade WS API uses `channel` and `product_ids` array parameters in subscription frames (`type: "subscribe"`), and encapsulates streaming ticker and status updates inside top-level JSON envelopes containing `channel` and `events`.
4. *Reasoning*: `Lux.Coinbase.WebSocket.Client` must manage WebSockex process state, send channel subscription frames, reply to ping/pong control frames, decode JSON payloads, wrap frames in `%Lux.Signal{}` structs, and broadcast to subscribers.
5. *Observation*: `CoinbaseTickerPriceLens` and `CoinbaseExchangeInfoLens` must implement `use Lux.Lens` for REST snapshot queries via `Lux.Coinbase.Client`, while adding `normalize_ws_frame/1` and `subscribe_stream/2` helpers to bridge WebSocket stream events into standard Lux maps.
6. *Observation*: Existing test suites (`test/lux/binance/web_socket_test.exs`) rely on `Req.Test` for HTTP mocks and synthetic `handle_incoming_frame` calls for WebSockex test isolation.
7. *Reasoning*: Designing `test/lux/coinbase/lenses_test.exs` with `Req.Test` and `handle_incoming_frame` guarantees that unit tests execute deterministically in offline environments without external network IO.

## 3. Caveats
- No actual source code in `lib/lux/coinbase/` was modified during this read-only investigation turn, adhering to Explorer role guidelines.
- Authenticated Coinbase WebSocket user channels (e.g. `user`, `futures_balance_summary`) require signature calculation inside subscription frames. Public market channels (`ticker`, `status`, `heartbeats`) do not require authentication headers/signatures.

## 4. Conclusion
The Coinbase WebSockets Market Lenses Architecture is fully analyzed and designed. The design includes:
1. `Lux.Coinbase.WebSocket.Client` (`lib/lux/coinbase/web_socket/client.ex`) for WebSockex transport, topic subscriptions, heartbeat handling, auto-reconnection, and signal distribution.
2. `Lux.Lenses.Coinbase.CoinbaseTickerPriceLens` (`lib/lux/lenses/coinbase/ticker_price_lens.ex`) for snapshot ticker focus and WebSocket frame normalization.
3. `Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens` (`lib/lux/lenses/coinbase/exchange_info_lens.ex`) for snapshot exchange rules focus and status frame normalization.
4. `test/lux/coinbase/lenses_test.exs` for ExUnit unit testing with `Req.Test` and synthetic frame assertions.

Detailed implementation code blueprints are published in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/analysis.md`.

## 5. Verification Method
1. Inspect the full blueprint in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/analysis.md`.
2. Once implemented in Milestone 4, run:
   ```bash
   mix test test/lux/coinbase/lenses_test.exs
   ```
3. Run `mix format --check-formatted` and `mix compile --warnings-as-errors` to verify quality.
