# Project: Coinbase Exchange Integration

## Architecture
Integrate Coinbase Advanced Trade REST API and WebSocket data streams into the Spectral-Finance/lux framework in Elixir, matching the Lens and Prism abstraction patterns used in the Binance implementation.

## Code Layout
- `lib/lux/coinbase/client.ex`: Authenticated REST API Client using HMAC-SHA256
- `lib/lux/coinbase/rate_limiter.ex`: Middleware for handling 429 Too Many Requests with exponential backoff
- `lib/lux/lenses/coinbase/ticker_price_lens.ex`: WebSocket Ticker Price Lens
- `lib/lux/lenses/coinbase/exchange_info_lens.ex`: WebSocket Exchange Info Lens
- `lib/lux/prisms/coinbase/spot_account_prism.ex`: Spot Account Balance & Details Prism
- `lib/lux/prisms/coinbase/spot_order_prism.ex`: Spot Order Placement Prism
- `lib/lux/prisms/coinbase/spot_cancel_order_prism.ex`: Spot Cancel Order Prism
- `lib/lux/prisms/coinbase/spot_open_orders_prism.ex`: Spot Open Orders Prism
- `test/lux/coinbase/`: Automated ExUnit tests with Req.Test mocks

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Architecture Exploration | Analyze Binance implementation and design Coinbase integration | none | DONE |
| 2 | REST Client & Auth | Implement `Lux.Coinbase.Client` with HMAC-SHA256 | M1 | DONE |
| 3 | Rate Limiter Middleware | Implement `Lux.Coinbase.RateLimiter` | M2 | DONE |
| 4 | WebSockets Market Lenses | Implement `CoinbaseTickerPriceLens` & `CoinbaseExchangeInfoLens` | M1 | DONE |
| 5 | Spot Trading Prisms | Implement Account, Order, Cancel, Open Orders Prisms | M2, M3 | DONE |
| 6 | Testing & Verification | Comprehensive ExUnit test suite and verification | M2, M3, M4, M5 | DONE |

## Interface Contracts
- Lens behavior: standard Lux Lens with WebSockex integration.
- Prism behavior: standard Lux Prism structs and callbacks.
- Client: Req plugin / HTTP helper with HMAC-SHA256 header injection.
