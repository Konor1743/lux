# Orchestrator Execution Plan: Coinbase Exchange Integration

## Objective
Lead the end-to-end implementation of the Coinbase Exchange integration in Elixir for Spectral-Finance/lux framework according to requirements R1 to R5 and acceptance criteria.

## Work Breakdown & Milestones

### Phase 1: Architectural Exploration
- Dispatch `teamwork_preview_explorer` (x3) to inspect existing Binance implementation (`lib/lux/binance/`, `lib/lux/prisms/binance/`, `lib/lux/lenses/binance/`, `test/lux/binance/`) and Coinbase requirements.
- Produce comprehensive blueprint in `.agents/explorer_1/analysis.md`.

### Phase 2: Core REST Client & HMAC-SHA256 Auth (R1)
- Module: `Lux.Coinbase.Client` (`lib/lux/coinbase/client.ex`)
- Responsibilities: HTTP requests using Req, HMAC-SHA256 signature generation (timestamp, method, request_path, body), headers format.

### Phase 3: Rate Limiter Middleware (R4)
- Module: `Lux.Coinbase.RateLimiter` (`lib/lux/coinbase/rate_limiter.ex`)
- Responsibilities: Intercept `429 Too Many Requests`, exponential backoff, retry logic, pause execution.

### Phase 4: WebSockets & Market Data Spot Lenses (R2)
- Modules:
  - `Lux.Lenses.Coinbase.CoinbaseTickerPriceLens` (`lib/lux/lenses/coinbase/ticker_price_lens.ex`)
  - `Lux.Lenses.Coinbase.CoinbaseExchangeInfoLens` (`lib/lux/lenses/coinbase/exchange_info_lens.ex`)
- Responsibilities: WebSockex connection, automatic reconnection, data normalization.

### Phase 5: Spot Trading Prisms (R3)
- Modules:
  - `Lux.Prisms.Coinbase.CoinbaseSpotAccountPrism` (`lib/lux/prisms/coinbase/spot_account_prism.ex`)
  - `Lux.Prisms.Coinbase.CoinbaseSpotOrderPrism` (`lib/lux/prisms/coinbase/spot_order_prism.ex`)
  - `Lux.Prisms.Coinbase.CoinbaseSpotCancelOrderPrism` (`lib/lux/prisms/coinbase/spot_cancel_order_prism.ex`)
  - `Lux.Prisms.Coinbase.CoinbaseSpotOpenOrdersPrism` (`lib/lux/prisms/coinbase/spot_open_orders_prism.ex`)
- Responsibilities: Lux Prism behavior implementation matching Binance abstractions.

### Phase 6: Automated ExUnit Testing & Hardening (R5)
- Location: `test/lux/coinbase/`
- Mocking: `Req.Test` and ExUnit unit/integration tests.
- Gates: `mix compile --warnings-as-errors`, `mix format`, `mix test test/lux/coinbase/`.
- Independent Reviewers, Challengers, and Forensic Auditor verification.
