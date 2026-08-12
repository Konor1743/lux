# Handoff Report: LLM Abstraction Layer Empirical Challenge

## 1. Observation

### Build & Unit Test Verification
- Command: `mix compile --warnings-as-errors`
  - Output: Exit status `0` (Success with zero warnings).
- Command: `mix test --include unit test/unit/lux/llm/`
  - Output: `101 tests, 0 failures` across 11 test modules including `stress_test.exs`.

### Empirical Findings

#### Finding A: `Lux.LLM.Telemetry.normalize_usage/1` Crashes on String Token Counts
- **Location**: `lib/lux/llm/telemetry.ex`, line 191
  ```elixir
  total =
    Map.get(usage, :total_tokens) ||
      Map.get(usage, "total_tokens") ||
      Map.get(usage, "totalTokenCount") ||
      (prompt + completion)
  ```
- **Observed behavior**: When raw provider usage maps contain string-encoded values (e.g., `%{"prompt_tokens" => "100", "completion_tokens" => "200"}`), `prompt + completion` attempts `+("100", "200")` in Erlang, raising:
  ```
  ** (ArithmeticError) bad argument in arithmetic expression: "100" + "200"
  ```
- **Line 194 behavior**: Even if `total_tokens` is provided, `max(0, prompt)` returns `"100"` due to Elixir term ordering where binaries are greater than integers. Subsequent floating-point calculations in `calculate_cost/5` (`"100" / 1000.0`) raise `ArithmeticError`.

#### Finding B: `Lux.LLM.Fallback` Last-Fallback Non-Retryable Error Masking
- **Location**: `lib/lux/llm/fallback.ex`, lines 103-111
  ```elixir
  if remaining != [] and fallback_error?(reason, opts) do
    execute_specs(remaining, prompt, tools, opts, new_history)
  else
    if remaining == [] do
      {:error, {:all_fallbacks_failed, Enum.reverse(new_history)}}
    else
      {:error, reason}
    end
  end
  ```
- **Observed behavior**: When the primary spec encounters a retryable error (e.g. `{429, "Rate limit"}`), `Fallback` advances to `remaining = [fallback_1]`. If `fallback_1` (the last spec in the chain) fails with a NON-retryable error (e.g. `:invalid_api_key`), `remaining != []` evaluates to `false`. In the `else` block, `remaining == []` evaluates to `true`, causing `Fallback.call` to return `{:error, {:all_fallbacks_failed, history}}` instead of returning `{:error, :invalid_api_key}`. This masks non-retryable errors on final fallbacks.

#### Finding C: `Lux.LLM.Fallback.fallback_error?/2` Pattern Matching Gaps
- **Location**: `lib/lux/llm/fallback.ex`, lines 52-79
- **Observed behavior**:
  1. Atom errors: Only `:econnrefused`, `:nxdomain`, `:timeout`, and `:closed` match `true`. Common atom representations like `:rate_limit`, `:too_many_requests`, `:service_unavailable`, and `:overloaded` return `false`.
  2. Exception structs: Only `%Req.TransportError{}` and `%Mint.TransportError{}` return `true`. Custom exception structs or standard exceptions (e.g. `%RuntimeError{message: "429 Rate limit"}`) evaluate to `false` regardless of message contents because line 60 fails the whitelist check and skips binary/tuple checks.
  3. HTTP Status Codes: Only HTTP `429`, `500`, `502`, `503`, `504` are checked. HTTP status codes such as `507`, `508`, `509`, `529` (Cloudflare site overloaded), and `408` (Request Timeout) return `false`.

#### Finding D: `Lux.LLM.Router.route/3` Process Exit Risk
- **Location**: `lib/lux/llm/router.ex`, line 80
  ```elixir
  models = ProviderRegistry.list_models(filter_opts)
  ```
- **Observed behavior**: Calling `Router.route/3` when `ProviderRegistry` GenServer is unstarted or has crashed causes `GenServer.call` to exit immediately with `{:noproc, ...}` without returning an error tuple.

#### Finding E: `Lux.LLM.Router` Strategy Handling
- **Location**: `lib/lux/llm/router.ex`, lines 119-140
- **Observed behavior**: Invalid strategy atoms (e.g., `:invalid_strategy`) or non-atom values (e.g., `123`, `"cheapest"`) silently fall back to `:cheapest`. Functions with arity other than 1 (e.g. 2-arity) also silently fall back to `:cheapest`. A 1-arity function strategy that raises an unhandled exception will crash the router caller.

---

## 2. Logic Chain

1. **Telemetry Normalization**: `Telemetry.normalize_usage/1` reads map values using `Map.get/2`. It assumes values are integers without parsing string representations. Line 191 executes `prompt + completion`. In Elixir/Erlang, string addition via `+` is invalid and raises `ArithmeticError`. Furthermore, line 194 uses `max(0, prompt)` which evaluates `"100"` as greater than `0` due to Erlang term ordering (`integer < binary`), allowing non-integer types into cost calculation functions.
2. **Fallback Execution Loop**: In `Fallback.execute_specs/5`, the decision to fail over relies on `remaining != [] and fallback_error?(reason, opts)`. When evaluating the final fallback element (`remaining == []`), `remaining != []` is `false` regardless of whether `fallback_error?(reason, opts)` is `true` or `false`. Consequently, control falls into the `else` block where `remaining == []` is `true`, returning `{:error, {:all_fallbacks_failed, history}}`. This logic fails to distinguish between a final fallback failing with a retryable error vs a final fallback failing with a fatal non-retryable error.
3. **Fallback Error Classifier**: `fallback_error?/2` uses explicit function clauses for atoms and structs. Because struct matching in clause line 60 is restricted to `Req.TransportError` and `Mint.TransportError`, all other struct types bypass binary string matching. Additionally, atom error matching is hardcoded to 4 atoms, omitting idiomatic Elixir atom error terms.
4. **Router Process Dependency**: `Router.route/3` delegates candidate listing to `ProviderRegistry.list_models/1`, which makes a synchronous `GenServer.call`. Without a process check or rescue block, any registry downtime results in caller crash.
5. **Router Selection Fallback**: In `select_candidate/3`, clause line 138 acts as a catch-all for any strategy term not matching `:cheapest`, `:smartest`, or `is_function(fun, 1)`, delegating to `select_candidate(candidates, :cheapest, opts)` without error feedback.

---

## 3. Caveats

- Live network HTTP requests to external LLM provider endpoints (e.g. OpenAI API, Anthropic API) were not performed due to `CODE_ONLY` network environment restrictions.
- All provider responses were simulated and verified via unit tests, mock implementations, and synthetic error injection in `test/unit/lux/llm/stress_test.exs`.

---

## 4. Conclusion

The LLM abstraction layer (`Lux.LLM.Router`, `Lux.LLM.Fallback`, `Lux.LLM.Telemetry`) is overall functional and satisfies basic routing, telemetry, and fallback operations. However, stress testing revealed 5 edge-case vulnerabilities:
1. `Telemetry.normalize_usage/1` arithmetic crash on string token inputs.
2. `Fallback` error classification masking non-retryable errors on the final fallback.
3. Gaps in `fallback_error?/2` for atom error formats, non-whitelisted structs, and secondary HTTP status codes (507, 509, 529, 408).
4. `Router.route/3` process exit on unstarted/crashed `ProviderRegistry`.
5. `Router` strategy selection silently defaulting on malformed strategy values.

---

## 5. Verification Method

To independently verify these findings and execute the full test suite:

1. **Compile with warnings as errors**:
   ```bash
   mix compile --warnings-as-errors
   ```
2. **Execute LLM unit and stress test suite**:
   ```bash
   mix test --include unit test/unit/lux/llm/
   ```
3. **Inspect stress test assertions**:
   - Inspect `test/unit/lux/llm/stress_test.exs` for empirical test cases covering empty registries, strategy fallbacks, last-fallback error structure, error classification, and string token normalization.
