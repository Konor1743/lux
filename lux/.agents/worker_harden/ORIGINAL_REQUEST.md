## 2026-08-05T22:42:54Z
Your working directory is `/home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_harden`. Project root is `/home/Konor1743/Operacion Dolar/lux/lux`.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Tasks:
1. Harden `Lux.LLM.Telemetry.normalize_usage/1` (`lib/lux/llm/telemetry.ex`): Handle token counts when passed as strings (e.g., `%{"prompt_tokens" => "100"}`) by safely parsing integers (`parse_integer` / `String.to_integer` fallback) to prevent `ArithmeticError`.
2. Harden `Lux.LLM.Router.route/3` (`lib/lux/llm/router.ex`): Check `GenServer.whereis(Lux.LLM.ProviderRegistry)` or catch unstarted process exit, returning `{:error, :registry_not_running}` cleanly if the registry GenServer is not running.
3. Harden `Lux.LLM.Fallback.fallback_error?/2` (`lib/lux/llm/fallback.ex`): Add classifier support for additional error terms/atoms (`:rate_limit`, `:too_many_requests`, `:service_unavailable`, `:timeout`, `:connect_timeout`) and HTTP status codes (408, 429, 503, 500, 502, 504, 507, 529).
4. Run `mix compile --warnings-as-errors` to ensure zero compilation warnings.
5. Run `mix test --include unit test/unit/lux/llm/` to ensure all tests (including `stress_test.exs`) pass 100% green.
6. Deliver handoff report at `/home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_harden/handoff.md` and message parent agent when complete.
