# Handoff Report: Milestone 6 (Adversarial Testing & Lenses/Prisms Hardening)

## 1. Observation

### System Verification Commands & Results
- **Command**: `mix compile --warnings-as-errors`
  - **Result**: Success. Zero warnings.
- **Command**: `mix test test/lux/coinbase/`
  - **Result**: `113 tests, 0 failures` (including 32 new adversarial test cases added in `test/lux/coinbase/adversarial_lenses_prisms_test.exs`).

### Code Inspection & Empirical Findings

1. **Option Precedence Flaw (Boolean Short-Circuiting)**:
   - **Location**: `lib/lux/prisms/coinbase/spot_account_prism.ex:61`, `spot_order_prism.ex:126`, `spot_cancel_order_prism.ex:66`, `spot_open_orders_prism.ex:62`, `lib/lux/lenses/coinbase/ticker_price_lens.ex:58`, `exchange_info_lens.ex:54`.
   - **Code Quote**:
     ```elixir
     sandbox? = Map.get(input, :sandbox) || Map.get(input, "sandbox") || Map.get(ctx, :sandbox, false)
     ```
   - **Empirical Observation**: When `input = %{sandbox: false}` and `context = %{sandbox: true}`, `Map.get(input, :sandbox)` evaluates to `false`. In Elixir, `false || Map.get(ctx, :sandbox, false)` evaluates to `true`. Thus, setting `sandbox: false` in the input fails to override `sandbox: true` in the context, incorrectly routing production calls to the sandbox URL.

2. **Context Credential Key Resolution Bug**:
   - **Location**: `lib/lux/prisms/coinbase/spot_account_prism.ex:58-59` (and all Spot Prisms).
   - **Code Quote**:
     ```elixir
     api_key = Map.get(input, :api_key) || Map.get(input, "api_key") || Map.get(ctx, :api_key)
     secret_key = Map.get(input, :secret_key) || Map.get(input, "secret_key") || Map.get(ctx, :secret_key)
     ```
   - **Empirical Observation**: While `input` checks both atom `:api_key` and string `"api_key"`, `ctx` (context) ONLY checks atom `:api_key`. Passing context with string keys (e.g. `%{"api_key" => "k", "secret_key" => "s"}`) causes `api_key` and `secret_key` to resolve to `nil`, resulting in `{:error, :missing_secret_key}`.

3. **Unsupported Order Types Fall Through to LIMIT Order Config**:
   - **Location**: `lib/lux/prisms/coinbase/spot_order_prism.ex:87-113`.
   - **Code Quote**:
     ```elixir
     case String.upcase(to_string(type)) do
       "MARKET" -> ...
       "STOP_LIMIT" -> ...
       _ -> # Default LIMIT (GTC)
         ...
     ```
   - **Empirical Observation**: Any unrecognized or unsupported order type string (e.g., `"FOK"`, `"STOP_LOSS"`, `"INVALID_TYPE"`, or `nil`) is caught by the catch-all `_ ->` clause and silently constructed as a `LIMIT` (GTC) order configuration (`limit_limit_gtc`) without returning an error.

4. **Unhandled Exception on Non-Map Items in Frame Normalization**:
   - **Location**: `lib/lux/lenses/coinbase/ticker_price_lens.ex:108-110` and `exchange_info_lens.ex:93-95`.
   - **Code Quote**:
     ```elixir
     tickers =
       events
       |> Enum.flat_map(fn event -> Map.get(event, "tickers", []) end)
       |> Enum.map(fn ticker -> %{"product_id" => ticker["product_id"], ...} end)
     ```
   - **Empirical Observation**: If `events` or `tickers`/`products` list contains non-map items (e.g. `events: [123]` or `tickers: ["invalid"]`), `Map.get(123, "tickers")` raises `BadMapError` or `ticker["product_id"]` raises `FunctionClauseError` on `Access.get/3`, rather than returning `{:error, {:unsupported_frame, frame}}`.

5. **Valid Behaviors Verified**:
   - Empty `order_ids` list (`order_ids: []`) in `SpotCancelOrderPrism` with no `order_id` correctly returns `{:error, :missing_order_ids}`.
   - Non-empty `order_ids` list takes precedence over single `order_id`.
   - Single `order_id` fallback works when `order_ids` is `[]` or omitted.
   - Non-string order IDs (`[101, :atom]`) are correctly stringified to `["101", "atom"]`.
   - WS frame normalization for valid Advanced Trade WS and Exchange Feed WS frames maps correctly to Lux structure.

---

## 2. Logic Chain

1. *From Observation 1*: The expression `Map.get(input, :sandbox) || Map.get(ctx, :sandbox, false)` treats boolean `false` as falsy in short-circuit evaluation. Therefore, when a caller explicitly passes `sandbox: false` in `input` while `context` has `sandbox: true`, the evaluation proceeds to `Map.get(ctx, :sandbox, false)` and returns `true`. *Conclusion*: Option override logic is flawed for boolean fields where `false` is a valid override value.

2. *From Observation 2*: In `build_opts`, `Map.get(ctx, :secret_key)` is used without a fallback to `Map.get(ctx, "secret_key")`. When context is passed as a string-keyed map, `secret_key` evaluates to `nil`, causing `Client.request/4` to halt with `{:error, :missing_secret_key}`. *Conclusion*: Context lookup should support both atom and string keys, matching input resolution.

3. *From Observation 3*: `SpotOrderPrism` uses `case String.upcase(to_string(type)) do` with `_ ->` acting as default `LIMIT` (GTC). An invalid type input is neither rejected nor validated, creating unexpected order types sent to the exchange. *Conclusion*: Explicit pattern matching or validation should return `{:error, {:unsupported_order_type, type}}` for unknown values.

4. *From Observation 4*: `normalize_ws_frame/1` assumes elements in `events`, `tickers`, and `products` are maps. Non-map elements crash `Enum.flat_map` or `Access.get`. *Conclusion*: Adding `is_map/1` guards or `try/rescue` inside normalizers prevents process crashes on malformed frames.

---

## 3. Caveats

- Live WebSocket connection dropping under extreme network packet loss was tested via unit mocks (`WSClient.handle_incoming_frame/2` and mock TCP server loop), not live network sockets, due to isolated test environment restrictions.

---

## 4. Conclusion

The Coinbase WebSocket Lenses (`CoinbaseTickerPriceLens`, `CoinbaseExchangeInfoLens`) and Spot Trading Prisms (`SpotAccountPrism`, `SpotOrderPrism`, `SpotCancelOrderPrism`, `SpotOpenOrdersPrism`) are functionally operational and pass all 113 unit and adversarial tests.

Four specific hardening findings were surfaced:
1. **High Priority**: Fix boolean short-circuit precedence in `build_opts` / `focus` so `sandbox: false` in input overrides `sandbox: true` in context.
2. **Medium Priority**: Standardize `Map.get(ctx, :key) || Map.get(ctx, "key")` for context credential extraction in prisms.
3. **Medium Priority**: Explicitly validate order types in `SpotOrderPrism` to reject unrecognized type strings instead of defaulting to `LIMIT`.
4. **Low Priority**: Add `is_map` checks in `normalize_ws_frame` list enumerations to handle malformed list contents gracefully.

---

## 5. Verification Method

To independently verify these findings and stress tests:

1. Run the full Coinbase test suite:
   ```bash
   mix compile --warnings-as-errors && mix test test/lux/coinbase/
   ```
2. Inspect the adversarial test suite created at:
   - `test/lux/coinbase/adversarial_lenses_prisms_test.exs`
3. Specifically review the tests:
   - `"EXPOSURE BUG: input sandbox: false CANNOT override context sandbox: true due to || boolean expression"`
   - `"context with string keys is NOT recognized by build_opts (returns :missing_secret_key error)"`
   - `"unsupported order type defaults to LIMIT order configuration"`
