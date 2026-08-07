# Handoff Report — Coinbase REST Client & Rate Limiter Architecture (Milestone 1)

## 1. Observation
- **Binance Architecture**:
  - `lib/lux/binance/auth.ex` (lines 22-54, 60-63, 76-80): Uses HMAC-SHA256 parameter/query signing via `sign_params/3` and `sign/2`. Appends `timestamp` (ms) and `recvWindow` to parameters, appends `signature=` to query string, injects header `X-MBX-APIKEY`.
  - `lib/lux/binance/client.ex` (lines 46-68, 86-99): Uses `Req` with `RateLimiter.attach(req)`. Selects base URL based on market type (`:spot`, `:futures`) and `testnet?` flag. Passes `req_options` to `Req.new/1` to allow plug-based mocking (`Req.Test`).
  - `lib/lux/binance/rate_limiter.ex` (lines 12, 34-43, 48-71, 107-113): Maintains ETS table `:lux_binance_rate_limiter`. Records response status 429/418 and `retry-after` header to calculate `backoff_until` timestamp in ms. Attaches request/response steps to `Req.Request`.
  - `test/lux/binance/client_test.exs` & `test/lux/binance/rate_limiter_test.exs`: Uses `Req.Test` and `ExUnit.Case` with `async: true` / `async: false`.
- **Coinbase Advanced Trade API Specs**:
  - Requires HMAC-SHA256 signature in `CB-ACCESS-SIGN` HTTP header.
  - Requires `CB-ACCESS-KEY` (API Key string) and `CB-ACCESS-TIMESTAMP` (Unix timestamp in **seconds**).
  - Prehash format: `timestamp <> method <> request_path <> body`. Signature is lower-case hex encoded string (`Base.encode16(case: :lower)`).
  - Mainnet base URL: `https://api.coinbase.com`. Sandbox base URL: `https://api-public.sandbox.exchange.coinbase.com`.
  - Rate limiting header on 429: `retry-after`, plus quota headers `cb-ratelimit-limit`, `cb-ratelimit-remaining`, `cb-ratelimit-reset`.

## 2. Logic Chain
1. *From Binance Inspection*: `Lux.Binance` establishes the standard Lux HTTP client pattern using `Req`, with auth helpers for signature generation and a GenServer/ETS rate limiter middleware attached to `Req`.
2. *From Coinbase API Analysis*: Coinbase API authentication requires headers (`CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`) rather than query parameters (`signature=`). The prehash formula `timestamp <> method <> request_path <> body` must be constructed inside the client or auth helper. Timestamp must be Unix timestamp in **seconds** (unlike Binance's milliseconds).
3. *From Rate Limiting Analysis*: Coinbase returns 429 status code with `retry-after` header and quota tracking headers (`cb-ratelimit-*`). Creating `Lux.Coinbase.RateLimiter` with ETS table `:lux_coinbase_rate_limiter` following `Lux.Binance.RateLimiter` will provide backoff enforcement and quota tracking.
4. *From Testing Pattern Analysis*: Using `Req.Test` plug mocking allows full testing of signature calculation, header injection, base URL selection, and rate limiter backoff without live network calls.

## 3. Caveats
- Coinbase Advanced Trade API has multiple API key formats (Cloud API Key / CDP Key vs legacy API key). Both use the standard HMAC-SHA256 signature scheme header format (`CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`).
- JWT authentication is also supported by Coinbase Cloud API for some endpoints, but HMAC-SHA256 is the standard REST authentication mechanism for Advanced Trade REST endpoints and matches the project scope requirements.
- No source code in `lib/lux/coinbase` or `test/lux/coinbase` was modified or created in this step (read-only investigation constraint).

## 4. Conclusion
The architectural design and step-by-step implementation guide for Coinbase REST Client (`Lux.Coinbase.Client`) and Rate Limiter (`Lux.Coinbase.RateLimiter`) with unit tests (`test/lux/coinbase/client_test.exs` and `test/lux/coinbase/rate_limiter_test.exs`) are complete and documented in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1/analysis.md`. The design is fully compatible with the existing `Lux` framework conventions and ready for implementation in Milestone 2 & 3.

## 5. Verification Method
- Inspect analysis report: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1/analysis.md`
- Inspect handoff report: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1/handoff.md`
- When code is implemented in subsequent milestones, verify with:
  ```bash
  mix test test/lux/binance/
  mix test test/lux/coinbase/
  ```
