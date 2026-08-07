## 2026-08-07T21:03:06Z
<USER_REQUEST>
You are Explorer 1 for Milestone 1 (Coinbase REST Client & Rate Limiter Architecture).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md

Objective:
1. Inspect existing Binance implementation in `lib/lux/binance/` and tests in `test/lux/binance/`.
2. Analyze client architecture, authentication pattern (HMAC-SHA256 signature generation, timestamp, headers), request handling using Req, and rate limiting middleware.
3. Research Coinbase Advanced Trade REST API specs for authentication (HMAC-SHA256: timestamp + method + request_path + body, `CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`) and rate limiting (429 handling, backoff headers).
4. Formulate exact design and step-by-step implementation guide for:
   - `lib/lux/coinbase/client.ex` (`Lux.Coinbase.Client`)
   - `lib/lux/coinbase/rate_limiter.ex` (`Lux.Coinbase.RateLimiter`)
   - `test/lux/coinbase/client_test.exs`
   - `test/lux/coinbase/rate_limiter_test.exs`

Write your full findings and blueprint to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1/analysis.md` and `handoff.md`, then send a message back to parent with a summary.
</USER_REQUEST>
