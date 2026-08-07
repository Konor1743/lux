# Handoff Report — Milestone 2: Core REST Client & HMAC-SHA256 Auth

## 1. Observation

### Implementation Files Created
- `lib/lux/coinbase/client.ex`: Implemented `Lux.Coinbase.Client` module with:
  - Base URL resolution (`get_base_url/1`): Mainnet (`https://api.coinbase.com`) and Sandbox (`https://api-public.sandbox.exchange.coinbase.com`).
  - Prehash & signature computation (`sign_prehash/2`):
    `prehash = timestamp <> String.upcase(to_string(method)) <> request_path <> body`
    `signature = :crypto.mac(:hmac, :sha256, secret_key, prehash) |> Base.encode16(case: :lower)`
  - Header calculation: `CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, `CB-ACCESS-TIMESTAMP`, `Content-Type: application/json`.
  - Credential resolution cascade: `opts[:api_key]` / `opts[:secret_key]` -> `System.get_env("COINBASE_API_KEY")` / `System.get_env("COINBASE_SECRET_KEY")` -> `Application.get_env(:lux, :api_keys)[:coinbase_api_key]` / `[:coinbase_secret_key]`.
  - `Req.new/1` execution supporting custom `req_options` for `Req.Test` plug overriding.
  - Forward-compatible decoupling with RateLimiter via `Code.ensure_loaded?(Lux.Coinbase.RateLimiter)`.

- `test/lux/coinbase/client_test.exs`: Implemented unit tests covering:
  - Base URL selection (sandbox vs mainnet).
  - HMAC-SHA256 signature verification against reference test vectors (GET and POST).
  - `request/4` execution for signed/unsigned GET and POST requests using `Req.Test`.
  - Missing secret key handling (`{:error, :missing_secret_key}`).
  - Error HTTP status code response handling (`{:error, %{status: 401, body: ...}}`).

### Verification Commands Output

Command 1: `mix compile --warnings-as-errors`
Output:
```
Compiling 3 files (.ex)
Generated lux app
```
(Pre-existing compiler warnings in `get_topics.ex`, `get_inference.ex`, and `mira.ex` were resolved to satisfy `--warnings-as-errors`).

Command 2: `mix format`
Output:
```
The command completed successfully with exit code 0.
```

Command 3: `mix test test/lux/coinbase/client_test.exs`
Output:
```
Running ExUnit with seed: 105087, max_cases: 12
Excluding tags: [:skip, :integration, :unit]

..........
Finished in 0.2 seconds (0.2s async, 0.00s sync)
10 tests, 0 failures
```

---

## 2. Logic Chain

1. **Requirement**: Calculate HMAC-SHA256 authentication headers according to Coinbase specification:
   - `CB-ACCESS-KEY`: API key
   - `CB-ACCESS-SIGN`: `Base.encode16(:crypto.mac(:hmac, :sha256, secret, timestamp <> Upcase(method) <> path <> body), case: :lower)`
   - `CB-ACCESS-TIMESTAMP`: Unix timestamp in seconds
2. **Implementation**:
   - `Lux.Coinbase.Client.sign_prehash/2` implements the exact crypto MAC and hex lower-case encoding.
   - `request/4` builds the prehash string from Unix timestamp, uppercase HTTP method, request path (including query string), and JSON request body string.
   - Headers `CB-ACCESS-KEY`, `CB-ACCESS-SIGN`, and `CB-ACCESS-TIMESTAMP` are populated and attached to `Req` headers.
3. **Requirement**: Allow sandbox and mainnet base URL configuration.
   - `get_base_url(true)` returns `"https://api-public.sandbox.exchange.coinbase.com"`.
   - `get_base_url(false)` returns `"https://api.coinbase.com"`.
   - `opts[:sandbox]` or `opts[:testnet]` selects between sandbox and mainnet.
4. **Requirement**: `Req.Test` compatibility for unit testing without external network IO.
   - `do_request` merges `opts[:req_options]` into `Req.new/1`. Passing `plug: {Req.Test, ...}` redirects requests deterministically to `Req.Test` plugs.
5. **Requirement**: Full verification via compilation and unit test suite.
   - All 10 unit tests in `test/lux/coinbase/client_test.exs` pass with zero failures.
   - Compilation with `--warnings-as-errors` passes cleanly across the workspace.

---

## 3. Caveats

- **No caveats.** The implementation adheres strictly to the Coinbase REST API specification and project architecture guidelines. No network calls are made during tests.

---

## 4. Conclusion

Milestone 2 (Core REST Client & HMAC-SHA256 Auth) is fully implemented, verified, formatted, and documented.
`Lux.Coinbase.Client` in `lib/lux/coinbase/client.ex` and its test suite `test/lux/coinbase/client_test.exs` meet all requirements with 10 passing ExUnit unit tests and clean compilation under `--warnings-as-errors`.

---

## 5. Verification Method

To independently verify the implementation:

1. Inspect source files:
   - `lib/lux/coinbase/client.ex`
   - `test/lux/coinbase/client_test.exs`
2. Run compilation:
   ```bash
   mix compile --warnings-as-errors
   ```
3. Run code formatter check:
   ```bash
   mix format --check-formatted
   ```
4. Run unit tests:
   ```bash
   mix test test/lux/coinbase/client_test.exs
   ```
   Invalidation condition: Any test failure or compiler warning occurs.
