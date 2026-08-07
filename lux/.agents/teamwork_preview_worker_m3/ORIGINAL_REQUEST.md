## 2026-08-07T21:06:18Z
You are Worker 2 for Milestone 3 (Rate Limiter Middleware).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m3
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md
Explorer Blueprint: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1/analysis.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Tasks:
1. Implement `Lux.Coinbase.RateLimiter` in `lib/lux/coinbase/rate_limiter.ex`.
   - Implement GenServer initializing ETS table `:lux_coinbase_rate_limiter`.
   - Implement `attach/1` attaching request and response steps to `Req.Request`.
   - Handle 429 status code responses with `retry-after` header, calculating exponential backoff and recording `backoff_until` timestamp.
   - Record quota headers `cb-ratelimit-limit`, `cb-ratelimit-remaining`, `cb-ratelimit-reset` in ETS.
   - Delay outgoing requests when current time is less than `backoff_until`.
2. Connect RateLimiter into `Lux.Coinbase.Client` (`lib/lux/coinbase/client.ex`).
3. Implement unit tests in `test/lux/coinbase/rate_limiter_test.exs`.
   - Test 429 response handling and backoff calculation.
   - Test ETS quota tracking (`cb-ratelimit-*`).
   - Test request delaying when rate limited using `Req.Test`.
4. Run verification commands:
   - `mix compile --warnings-as-errors`
   - `mix format`
   - `mix test test/lux/coinbase/`
5. Document all outputs and results in `handoff.md`, then send a summary message back to parent.
