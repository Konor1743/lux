# Handoff Report — Milestone 2: Live Streaming Workflow, Hardening & Test Design

**Agent**: Explorer 3 (`explorer_m2_3`)  
**Target Recipient**: Orchestrator / Implementer for Milestone 2  
**Working Directory**: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m2_3`  
**Date**: 2026-08-17  

---

## 1. Observation

Direct observations from codebase inspection and adversarial challenge reports:

1. **URL Construction in `Client.ex` (`lib/lux/integrations/youtube/client.ex:136-142`)**:
   ```elixir
   defp build_url(path) do
     if String.starts_with?(path, "http") do
       path
     else
       @endpoint <> path
     end
   end
   ```
   When `path` is passed without a leading slash (e.g. `"liveBroadcasts"`), `@endpoint <> path` produces `"https://www.googleapis.com/youtube/v3liveBroadcasts"` resulting in HTTP 404.

2. **Req Synchronous Sleep in `Client.ex:76-88` and Challenger 2 Report (`.agents/challenger_m1_2/challenge.md:30-40`)**:
   `Client.request/3` calls `Req.new(req_options)`. Req defaults `:retry` to `:safe_transient`. When YouTube returns `429 Too Many Requests` with `Retry-After: 45`, Req intercepts the response and performs a synchronous `Process.sleep(45_000)`, freezing the caller GenServer/process for 45 seconds.

3. **gRPC Multi-Item Details and Status in `Errors.ex` (`lib/lux/integrations/youtube/errors.ex:130-158`)**:
   ```elixir
   first_detail =
     case error_map["details"] do
       [first | _] when is_map(first) -> first
       _ -> %{}
     end
   ```
   When Google API returns multiple details (e.g. `[google.rpc.Help, google.rpc.ErrorInfo]`), `first_detail["reason"]` is `nil`, dropping the error reason. Furthermore, `@quota_reasons` (`errors.ex:36-41`) lacks `"RESOURCE_EXHAUSTED"`, causing HTTP 403 `RESOURCE_EXHAUSTED` responses to fall back to generic `{403, msg}` rather than `{:quota_exceeded, details}`.

4. **Arithmetic Float Overflow in `Errors.ex:301` (`lib/lux/integrations/youtube/errors.ex:301`)**:
   ```elixir
   temp_delay = min(max_delay, trunc(base * :math.pow(2, max(0, attempt - 1))))
   ```
   For `attempt >= 1025`, `:math.pow(2, 1024)` raises `ArithmeticError: bad argument in arithmetic expression` instead of clamping to `max_backoff_ms`.

5. **Lens `headers: nil` in `YouTube.ex:60` (`lib/lux/integrations/youtube.ex:60`)**:
   ```elixir
   %{lens | headers: lens.headers ++ [{"Authorization", "Bearer #{token}"}]}
   ```
   Raises `ArgumentError: cannot concatenate nil with list` when `lens.headers` is `nil`.

6. **Live Streaming Domain Architecture (`PROJECT.md:10-12, 44-55`)**:
   Requires `Lux.Integrations.YouTube.LiveBroadcasts` and `Lux.Integrations.YouTube.LiveStreams` managing broadcast lifecycle (`create_broadcast`, `list_broadcasts`, `get_broadcast`, `update_broadcast`, `transition_broadcast`, `bind_broadcast`, `delete_broadcast`) and stream ingestion (`create_stream`, `list_streams`, `get_stream`, `update_stream`, `delete_stream`).

---

## 2. Logic Chain

1. **From Observation 1**: Any call from `LiveBroadcasts` or `LiveStreams` or external users invoking `Client.get("liveBroadcasts")` without a leading slash fails due to string concatenation. Adding `String.starts_with?(path, "/")` check with conditional leading slash injection guarantees valid URL construction regardless of caller formatting.
2. **From Observation 2**: Centralizing retry backoff into `Errors.with_retry/2` and defaulting `retry: false` in `Client.request/3` prevents unmanaged 45s synchronous sleeping in the Req pipeline, eliminating GenServer timeout crashes in live chat pollers and background tasks.
3. **From Observation 3**: Scanning the entire `details` list in `Errors.extract_error_info/1` and adding `"RESOURCE_EXHAUSTED"` to `@quota_reasons` ensures accurate quota exhaustion classification across all Google API / gRPC response schemas.
4. **From Observation 4**: Clamping `attempt` exponent in `Errors.backoff_delay/2` with `min(max(0, attempt - 1), 30)` prevents floating-point overflow while preserving the configured `max_backoff_ms` cap.
5. **From Observation 5**: Defaulting `lens.headers || []` prevents crashes when initializing lenses with `headers: nil`.
6. **From Observation 6**: Connecting `create_broadcast`, `create_stream`, `bind_broadcast`, and `transition_broadcast` establishes the end-to-end live streaming state machine. Viewer-facing metadata is captured in the broadcast (including `snippet.liveChatId`), ingestion endpoints are captured in the stream (`cdn.ingestionInfo.ingestionAddress`, `streamName`), and binding them links the encoder ingestion pipe to the broadcast.
7. **From Test Design**: Simulating this entire multi-step pipeline with `Req.Test.expect/2` verifies parameter encoding, token auth headers, URL paths, and error mapping without external network access under CODE_ONLY constraints.

---

## 3. Caveats

- **RTMP Ingestion Socket Connection**: Live stream creation provides RTMP endpoints and stream keys for external encoders (OBS, ffmpeg, Lux media worker). Testing RTMP TCP socket streaming requires external media encoders, which is outside the scope of the REST API client unit test suite (mocked via HTTP REST schemas).
- **YouTube Live Chat Linkage**: The broadcast's `snippet.liveChatId` returned in step 1 is the primary identifier passed to Milestone 3's `Lux.Integrations.YouTube.LiveChat` and `LiveChat.Poller`.
- **CODE_ONLY Network Constraint**: All verification must rely on `Req.Test` and ExUnit mocks; live requests to Google's real production endpoints are restricted.

---

## 4. Conclusion

The Live Streaming workflow design, Challenger 1 & 2 hardening refinements, and `Req.Test` unit test suite for Milestone 2 are fully specified:
1. **Workflow Pipeline**: 4-step sequence (`LiveBroadcasts.create_broadcast` $\to$ `LiveStreams.create_stream` $\to$ `LiveBroadcasts.bind_broadcast` $\to$ `LiveBroadcasts.transition_broadcast`) with support for snake_case/camelCase parameter mapping.
2. **Hardening Fixes**: Exact code replacements provided for `Client.build_url/1`, Req `retry: false`, `Errors.extract_error_info/1`, `@quota_reasons`, `Errors.backoff_delay/2`, and `YouTube.add_auth_header/1`.
3. **Test Suite**: Detailed test fixtures designed for `live_broadcasts_test.exs`, `live_streams_test.exs`, and `live_workflow_test.exs` with 100% path and error branch coverage.

---

## 5. Verification Method

To independently verify these designs and implementations:

1. **Inspect Detailed Analysis Report**:
   - File: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m2_3/analysis.md`
2. **Review Implementation Files Once Created by Implementer**:
   - `lib/lux/integrations/youtube/live_broadcasts.ex`
   - `lib/lux/integrations/youtube/live_streams.ex`
   - `lib/lux/integrations/youtube/client.ex`
   - `lib/lux/integrations/youtube/errors.ex`
   - `lib/lux/integrations/youtube.ex`
3. **Execute Test Suite**:
   ```bash
   mix test test/unit/lux/integrations/youtube/
   mix compile --warnings-as-errors
   ```
4. **Invalidation Conditions**:
   - `Client.get("liveBroadcasts")` produces a URL missing a slash (`/v3liveBroadcasts`).
   - `Errors.parse(403, grpc_body)` with multi-item details fails to detect `{:error, {:quota_exceeded, _}}`.
   - `LiveBroadcasts.bind_broadcast/3` fails to pass `streamId` query parameter.
   - `LiveBroadcasts.transition_broadcast/3` rejects atom lifecycle statuses (`:testing`, `:live`, `:complete`).
