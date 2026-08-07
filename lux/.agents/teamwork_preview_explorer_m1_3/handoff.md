# Handoff Report — Coinbase Spot Trading Prisms Architecture

## 1. Observation
- **Inspected Files & Modules**:
  - `lib/lux/prism.ex`: Core Prism behaviour defining `@callback handler/2`, macro compile-time registration of `@prism_config` and `@prism_struct`, and `run/2` dispatcher (lines 88-137).
  - `lib/lux/prisms/binance/spot_account_prism.ex`: `Lux.Prisms.Binance.SpotAccountPrism` using `Lux.Binance.Client.request/5` for `GET /api/v3/account` (lines 26-33).
  - `lib/lux/prisms/binance/spot_order_prism.ex`: `Lux.Prisms.Binance.SpotOrderPrism` with input schema property definitions and parameter extraction via `build_order_params/1` for `POST /api/v3/order` (lines 44-63).
  - `lib/lux/prisms/binance/spot_cancel_order_prism.ex`: `Lux.Prisms.Binance.SpotCancelOrderPrism` mapping `symbol`, `orderId`, `origClientOrderId` for `DELETE /api/v3/order` (lines 31-46).
  - `lib/lux/prisms/binance/spot_open_orders_prism.ex`: `Lux.Prisms.Binance.SpotOpenOrdersPrism` querying `GET /api/v3/openOrders` (lines 23-38).
  - `test/lux/prisms/binance/spot_prisms_test.exs`: ExUnit tests utilizing `Req.Test` mocking (`Req.Test.expect/2`, `Req.Test.json/2`) with `req_options: [plug: {Req.Test, ...}]` passed in Prism inputs (lines 14-101).
- **Coinbase Advanced Trade API Endpoints Mapped**:
  - Account Details: `GET /api/v3/brokerage/accounts` & `GET /api/v3/brokerage/accounts/{account_uuid}`
  - Create Order: `POST /api/v3/brokerage/orders` (requires `client_order_id`, `product_id`, `side`, `order_configuration`)
  - Cancel Order: `POST /api/v3/brokerage/orders/batch_cancel` (requires body JSON `{"order_ids": [...]}`)
  - List Open Orders: `GET /api/v3/brokerage/orders/historical/batch` with `order_status=OPEN`
- **Output Files Generated**:
  - `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_3/analysis.md`

## 2. Logic Chain
1. **Observation**: Binance Prisms extract credentials (`api_key`, `secret_key`) and options (`req_options`) dynamically from input maps or `context` in `build_opts/2`.
   **Inference**: Coinbase Prisms must implement identical `build_opts/2` logic to seamlessly resolve credentials from input parameters, agent contexts, or application envs.
2. **Observation**: Coinbase Advanced Trade API uses `product_id` (e.g. `"BTC-USD"`), nested `order_configuration` maps, and batch cancellation arrays (`order_ids`), whereas Binance uses flat parameters (`symbol`, `type`, `quantity`, `price`).
   **Inference**: Coinbase Spot Prisms must accept flat agent-friendly parameters (`product_id`, `side`, `type`, `base_size`, `price`, `stop_price`) or `symbol` aliases and convert them internally to Coinbase REST payload formats in `SpotOrderPrism` and `SpotCancelOrderPrism`.
3. **Observation**: `Req.Test` mocking in `test/lux/prisms/binance/spot_prisms_test.exs` allows complete isolation of REST HTTP calls without hitting live endpoints.
   **Inference**: `test/lux/coinbase/prisms_test.exs` will utilize `Req.Test.expect/2` and `Req.Test.json/2` plug injection for deterministic ExUnit test execution.

## 3. Caveats
- **Read-Only Scope**: This analysis is read-only. No source files were modified in `lib/` or `test/`. Implementation will take place in Milestone 5.
- **REST Client Dependency**: Coinbase Prisms assume `Lux.Coinbase.Client.request(method, path, body_or_params, opts)` will be provided by Milestone 2 (`lib/lux/coinbase/client.ex`).

## 4. Conclusion
The Coinbase Spot Trading Prisms architecture (`SpotAccountPrism`, `SpotOrderPrism`, `SpotCancelOrderPrism`, `SpotOpenOrdersPrism`) is fully specified, aligned with Lux framework standards, and ready for implementation. Full code blueprints and test suites are documented in `analysis.md`.

## 5. Verification Method
1. **Inspect Analysis File**:
   Verify complete specifications exist in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_3/analysis.md`.
2. **Future Implementation Verification**:
   When files are written in M5, run:
   ```bash
   mix test test/lux/coinbase/prisms_test.exs
   ```
   Invalidation condition: any failure in parameter translation, credential resolution, or API path formatting.
