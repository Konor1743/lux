## 2026-08-07T21:04:32Z
You are Worker 1 for Milestone 2 (Core REST Client & HMAC-SHA256 Auth).
Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_worker_m2
Project Scope: /home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator/PROJECT.md
Explorer Blueprint: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1/analysis.md

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Tasks:
1. Implement `Lux.Coinbase.Client` in `lib/lux/coinbase/client.ex`.
   - Implement HMAC-SHA256 authentication header calculation (`CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`).
   - Signature formula: `Base.encode16(:crypto.mac(:hmac, :sha256, secret, timestamp <> Upcase(method) <> path <> body), case: :lower)`. Timestamp in Unix seconds.
   - Base URL selection (default `https://api.coinbase.com`, sandbox `https://api-public.sandbox.exchange.coinbase.com`).
   - Req client execution using `Req.new/1` allowing `req_options` for `Req.Test` plug overriding.
2. Implement unit tests in `test/lux/coinbase/client_test.exs`.
   - Test signed GET and POST requests using `Req.Test`.
   - Test signature validity against reference test vectors.
   - Test sandbox vs mainnet configuration options.
3. Run verification commands:
   - `mix compile --warnings-as-errors`
   - `mix format`
   - `mix test test/lux/coinbase/client_test.exs`
4. Document all outputs, test results, and command logs in `handoff.md` inside your working directory, then send a summary message back to parent.
