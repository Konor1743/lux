# Milestone 2: YouTube Live Broadcasts Integration — Handoff Report

## 1. Observation

Direct observations from codebase inspection:
1. **Existing Architecture & Contracts**:
   - `PROJECT.md:44-55` specifies the planned interface for Live Broadcasts (`create_broadcast`, `list_broadcasts`, `get_broadcast`, `update_broadcast`, `transition_broadcast`, `bind_broadcast`, `delete_broadcast`).
   - `lib/lux/integrations/youtube/client.ex:64-120` implements `Client.request(method, path, opts)` which supports `:params`, `:json`, `:headers`, `:token`, `:api_key`, `:refresh_token`, `:plug`, `:auto_refresh`. It returns `{:ok, body}` or structured error tuples `{:error, {:quota_exceeded, details}}`, `{:error, {:rate_limited, details}}`, `{:error, :invalid_token}`, `{:error, {status, message}}`.
   - `lib/lux/integrations/youtube/errors.ex:56-126` parses YouTube HTTP responses and classifies 401 (`:invalid_token`), 403 quota exhaustion (`:quota_exceeded`), 403/429 throttling (`:rate_limited`), and generic errors.
   - `test/test_helper.exs:29` configures `Application.put_env(:lux, YouTubeClient, plug: {Req.Test, YouTubeClientMock})` for all unit tests under `UnitAPICase`.
2. **YouTube API Specifics for `liveBroadcasts`**:
   - Resource path: `/liveBroadcasts` (sub-paths: `/transition`, `/bind`).
   - `create_broadcast`: `POST /liveBroadcasts?part=...` with JSON payload containing `snippet`, `status`, `contentDetails`.
   - `list_broadcasts`: `GET /liveBroadcasts?part=...` with filter query params (`mine`, `broadcastStatus`, `broadcastType`, `id`, `maxResults`, `pageToken`). When querying by `broadcastStatus`, YouTube requires `mine=true`.
   - `get_broadcast`: `GET /liveBroadcasts?id=...&part=...` returning `{:ok, broadcast}` from the items list or `{:error, :not_found}` when empty.
   - `update_broadcast`: `PUT /liveBroadcasts?part=...` with JSON payload containing `id`, `snippet`, `status`, `contentDetails`.
   - `transition_broadcast`: `POST /liveBroadcasts/transition?broadcastStatus=...&id=...&part=...` where valid statuses are `"testing"`, `"live"`, `"complete"`.
   - `bind_broadcast`: `POST /liveBroadcasts/bind?id=...&streamId=...&part=...`.
   - `delete_broadcast`: `DELETE /liveBroadcasts?id=...` returning HTTP 204.

---

## 2. Logic Chain

1. **Client Reusability (Observation 1)**: Since `Lux.Integrations.YouTube.Client` already handles token injection, auto-refresh on 401, error normalization, and `Req.Test` plug mocking, `Lux.Integrations.YouTube.LiveBroadcasts` must be a high-level domain module delegating all HTTP requests to `Client.request/3` (or `Client.get/2`, `Client.post/2`, `Client.put/2`, `Client.delete/2`).
2. **Developer Experience & Parameter Ergonomics (Observation 2)**: Callers should be able to pass flat friendly Elixir maps (e.g. `%{title: "Stream", scheduled_start_time: ~U[2026-08-17 20:00:00Z], privacy_status: :public, enable_auto_start: true}`) or standard YouTube nested maps (`%{snippet: %{title: "Stream"}}`). The module should automatically normalize datetime structs to ISO 8601 strings and atoms to string values.
3. **Robust Input Validation (Observation 2)**:
   - For `transition_broadcast/3`, status values must be validated against `[:testing, :live, :complete, "testing", "live", "complete"]`, returning `{:error, {:invalid_transition_status, status}}` immediately on invalid input.
   - For `update_broadcast/2` and `transition_broadcast/3`, missing or empty `id` must return `{:error, :missing_broadcast_id}`.
4. **Single Item Unwrapping for `get_broadcast/2` (Observation 2)**: Since YouTube returns a list wrapper for ID queries (`items: [...]`), `get_broadcast/2` should extract `List.first(items)` when present, returning `{:ok, item}`, and return `{:error, :not_found}` if `items` is empty.
5. **Testing Isolation via `Req.Test` (Observation 1)**: All unit tests in `test/unit/lux/integrations/youtube/live_broadcasts_test.exs` should use `UnitAPICase` and mock `YouTubeClientMock` with `Req.Test.expect/2`.

---

## 3. Caveats

- YouTube API requires `mine=true` when querying `broadcastStatus`. Our parameter normalizer automatically injects `mine: true` when `broadcastStatus` is set and `id` is not set.
- `transition_broadcast` status `complete` is terminal in YouTube's state machine; once a broadcast is completed, it cannot be restarted.

---

## 4. Conclusion

The specification and architecture for `Lux.Integrations.YouTube.LiveBroadcasts` is complete and documented in detail in `.agents/explorer_m2_1/analysis.md`.

The implementer can proceed immediately with:
1. Creating `lib/lux/integrations/youtube/live_broadcasts.ex` with full typespecs and 7 core functions (`create_broadcast`, `list_broadcasts`, `get_broadcast`, `update_broadcast`, `transition_broadcast`, `bind_broadcast`, `delete_broadcast`).
2. Implementing comprehensive ExUnit tests in `test/unit/lux/integrations/youtube/live_broadcasts_test.exs` covering all happy paths, parameter variations, validation failures, and error responses (`quotaExceeded`, `rateLimitExceeded`, 401 refresh, 400 invalid transition, 404).

---

## 5. Verification Method

To verify the design and subsequent implementation:
1. Check compiler warnings:
   ```bash
   mix compile --warnings-as-errors
   ```
2. Run YouTube unit tests:
   ```bash
   mix test test/unit/lux/integrations/youtube/live_broadcasts_test.exs
   ```
3. Run the full YouTube test suite:
   ```bash
   mix test test/unit/lux/integrations/youtube/
   ```
4. Invalidation Condition: If `Req.Test` mock expectations fail or `Client.request/3` fails to parse response schemas properly, the parameter mapping or error response fixture must be updated.
