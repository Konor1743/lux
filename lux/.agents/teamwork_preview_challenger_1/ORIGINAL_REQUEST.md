## 2026-08-07T16:11:52-05:00
You are Challenger 1 for Milestone 6 (Adversarial Testing & Client/Rate Limiter Hardening).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_challenger_1
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md

Objective:
1. Perform empirical stress and adversarial testing on `Lux.Coinbase.Client` and `Lux.Coinbase.RateLimiter`.
2. Test edge cases:
   - High-concurrency 429 responses with exponential backoff.
   - Missing/invalid API keys and secret keys.
   - Edge case headers and query parameters formatting.
   - Response status codes: 400, 401, 403, 404, 500, 503.
3. Run verification commands:
   - `mix compile --warnings-as-errors`
   - `mix test test/lux/coinbase/`
4. Document test findings, stress results, and write `handoff.md`, then send a summary message back to parent.
