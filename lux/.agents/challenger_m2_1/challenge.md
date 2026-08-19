# Adversarial Challenge Report — Milestone 2: YouTube Live Streaming Management

**Agent**: Challenger 1 (`challenger_m2_1`)  
**Target Modules**: `Lux.Integrations.YouTube.LiveBroadcasts`, `Lux.Integrations.YouTube.LiveStreams`  
**Date**: 2026-08-17  
**Overall Risk Assessment**: **MEDIUM-HIGH** (3 bugs requiring fixes, 2 minor improvements; core API architecture is robust)

---

## Executive Summary

An adversarial stress test was conducted against the YouTube Live Streaming integration modules (`LiveBroadcasts` and `LiveStreams`). A dedicated test suite (`test/unit/lux/integrations/youtube/live_streaming_adversarial_test.exs`, 39 tests) was constructed and executed alongside the standard test suite (110 total M2 tests passing, 0 compiler warnings).

While core happy-path CRUD, lifecycle state transitions, unbinding semantics, empty list handling, and error translations function reliably, **critical bugs were discovered in boolean serialization and string-keyed parameter handling for updates**.

---

## Confirmed Vulnerabilities & Challenges

### 1. [CRITICAL] Boolean `false` Dropped in `get_boolean/3` (`LiveBroadcasts`)

- **Location**: `lib/lux/integrations/youtube/live_broadcasts.ex:930-941`
- **Assumption Challenged**: `create_broadcast` and `update_broadcast` properly encode boolean parameter flags (`enable_dvr`, `enable_auto_start`, `enable_auto_stop`, `enable_content_encryption`, `enable_embed`, `record_from_start`, `enable_closed_captions`, `enable_low_latency`).
- **Attack Scenario**: Caller invokes `LiveBroadcasts.create_broadcast(%{title: "Test", enable_dvr: false, enable_auto_start: false, enable_auto_stop: true})`.
- **Observed Behavior**: `get_boolean` uses `Enum.find_value(keys, fn key -> ... end)`. In Elixir, `Enum.find_value` stops and returns on the first **truthy** value (neither `false` nor `nil`). When `Map.fetch` returns `{:ok, false}`, the lambda returns `false`, which `Enum.find_value` considers non-truthy, causing it to discard the value and continue searching, ultimately returning `nil`. `maybe_put("enableDvr", nil)` subsequently drops `"enableDvr"` from the JSON body.
- **Blast Radius**: Callers **cannot explicitly disable** default features like DVR, auto-start, auto-stop, content encryption, or embedding. The fields are completely omitted from the payload sent to YouTube, falling back to YouTube defaults.
- **Mitigation**:
  ```elixir
  defp get_boolean(map1, map2, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.fetch(map1, key) do
        {:ok, val} when is_boolean(val) -> {:halt, val}
        _ ->
          case Map.fetch(map2, key) do
            {:ok, val} when is_boolean(val) -> {:halt, val}
            _ -> {:cont, nil}
          end
      end
    end)
  end
  ```

---

### 2. [HIGH] String-Key Map Drops Updates in `update_broadcast` and `update_stream`

- **Location**: `lib/lux/integrations/youtube/live_broadcasts.ex:613-651`, `lib/lux/integrations/youtube/live_streams.ex:525-540`
- **Assumption Challenged**: `update_broadcast/2` and `update_stream/2` accept string-keyed maps (e.g. from JSON payloads or agent tool calls) as stated in typespecs.
- **Attack Scenario**: Caller invokes `LiveBroadcasts.update_broadcast(%{"id" => "bcast_123", "title" => "Updated Title"})` or `LiveStreams.update_stream(%{"id" => "stream_123", "title" => "Updated Stream"})`.
- **Observed Behavior**: `build_snippet_for_update(params)` checks `if raw_snippet || params[:title] || params[:description] ...`. Because `params` contains `"title"` as a string key, `params[:title]` is `nil`. The guard evaluates to `false`, causing `build_snippet_for_update` to return `nil`. The resulting PUT body sent to YouTube is `%{"id" => "bcast_123"}` without the `snippet` field.
- **Blast Radius**: Any caller using string-keyed maps (common in webhooks, agent inputs, and JSON deserialization) will silently fail to update broadcast or stream properties.
- **Mitigation**: In update helper guards, check both atom and string keys, e.g.:
  ```elixir
  title = params[:title] || params["title"] || snippet_map[:title] || snippet_map["title"]
  if raw_snippet || title || ... do
  ```

---

### 3. [MEDIUM] `opts` Ignored for Content Owner in `list_broadcasts` and `list_streams`

- **Location**: `lib/lux/integrations/youtube/live_broadcasts.ex:870-871`, `lib/lux/integrations/youtube/live_streams.ex:650-655`
- **Assumption Challenged**: `onBehalfOfContentOwner` and `onBehalfOfContentOwnerChannel` can be supplied in `opts` across all API functions.
- **Attack Scenario**: Caller calls `LiveBroadcasts.list_broadcasts(%{}, on_behalf_of_content_owner: "owner_123")`.
- **Observed Behavior**: `build_list_query_params` only inspects `params` (unlike `create_broadcast`, `get_broadcast`, `bind_broadcast`, etc. which check `params_map` and `opts_map`).
- **Blast Radius**: Content owner options passed in `opts` are silently ignored for list queries.
- **Mitigation**: Update `build_list_query_params` to accept both `params_map` and `opts_map` or merge them prior to query construction.

---

### 4. [MEDIUM] Single Atom `part` Parameter Ignored

- **Location**: `lib/lux/integrations/youtube/live_broadcasts.ex:921-928`, `lib/lux/integrations/youtube/live_streams.ex:665-672`
- **Assumption Challenged**: Passing `part: :snippet` or `part: :status` sets the requested API part.
- **Attack Scenario**: Caller passes `part: :snippet` to minimize YouTube API quota usage.
- **Observed Behavior**: `resolve_part` only matches `is_list` or `is_binary`, falling back to default parts (`"snippet,status,contentDetails"`) for non-binary atom values.
- **Blast Radius**: Quota optimization attempts using atom keys fail silently and fetch full parts.
- **Mitigation**: Add `part when is_atom(part) and not is_nil(part) -> to_string(part)` in `resolve_part`.

---

### 5. [LOW] Asymmetric RTMP Fallback for Backup RTMPS in `stream_url/2`

- **Location**: `lib/lux/integrations/youtube/live_streams.ex:409-416`
- **Assumption Challenged**: `stream_url(stream, protocol: :rtmps, backup: true)` falls back to backup RTMP if backup RTMPS is absent, consistent with primary RTMPS behavior.
- **Attack Scenario**: YouTube returns `ingestionAddress`, `backupIngestionAddress`, and `rtmpsIngestionAddress`, but omits `rtmpsBackupIngestionAddress`.
- **Observed Behavior**: Primary RTMPS falls back to `ingestionAddress`, but backup RTMPS does not fall back to `backupIngestionAddress` and returns `nil`.
- **Mitigation**: Update `{:rtmps, true} -> rtmps_backup_ingestion_address(stream) || backup_ingestion_address(stream)`.

---

## Stress Test Results Matrix

| # | Test Area / Scenario | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|---|
| 1 | Lifecycle transitions (`:testing`, `:live`, `:complete`) | Maps atom/string to valid transition query param | Correctly mapped to `POST /liveBroadcasts/transition` | **PASS** |
| 2 | Invalid transition statuses (`:unknown`, `:ready`, `"LIVE"`, etc.) | Rejection before HTTP call with `{:error, {:invalid_transition_status, status}}` | Rejected immediately | **PASS** |
| 3 | Blank broadcast ID on transition/bind/get/delete | Rejection with `{:error, :missing_broadcast_id}` | Rejected without HTTP call | **PASS** |
| 4 | Terminal state transition (completed -> live) | Propagate 400 `invalidTransition` error tuple | Returns `{:error, {400, message}}` | **PASS** |
| 5 | Redundant transition (live -> live) | Propagate 400 `redundantTransition` | Returns `{:error, {400, message}}` | **PASS** |
| 6 | 403 `liveStreamingNotEnabled` on transition | Propagate 403 error tuple | Returns `{:error, {403, message}}` | **PASS** |
| 7 | Stream bind to valid stream ID | `POST /liveBroadcasts/bind` with `streamId` param | Correctly bound | **PASS** |
| 8 | Stream unbind via `nil` or `""` | `POST /liveBroadcasts/bind` without `streamId` param | Correctly unbinds | **PASS** |
| 9 | Stream bind collision (already bound) | Propagate 400 `streamAlreadyBound` | Returns `{:error, {400, message}}` | **PASS** |
| 10 | Stream bind not found (404) | Propagate 404 `streamNotFound` | Returns `{:error, {404, message}}` | **PASS** |
| 11 | Concurrent stream binds across 8 tasks | Independent binds complete without race conditions | All 8 tasks succeeded with correct IDs | **PASS** |
| 12 | `get_broadcast` / `get_stream` with `items: []` | Returns `{:error, :not_found}` | Returns `{:error, :not_found}` | **PASS** |
| 13 | `list_broadcasts` / `list_streams` with `items: []` | Returns `{:ok, %{"items" => []}}` | Returns `{:ok, resp}` with totalResults: 0 | **PASS** |
| 14 | Missing CDN ingestion keys / nil `streamName` | Extractors return `nil` without raising | Returns `nil` safely | **PASS** |
| 15 | `stream_url` construction with trailing slashes | Cleanly trims trailing slash, attaches key | `rtmp://.../live2/key-123` | **PASS** |
| 16 | `stream_url` construction with query strings | Appends key before query string | `rtmp://.../live2/key-123?backup=1` | **PASS** |
| 17 | Unicode, emojis, and HTML in title/desc | Decodes and serializes valid UTF-8 JSON payload | Sent and parsed without corruption | **PASS** |
| 18 | Auto-refresh token rotation on 401 | 401 triggers OAuth refresh and retries with new Bearer token | Transparent recovery | **PASS** |
| 19 | 403 `quotaExceeded` parsing | Returns `{:error, {:quota_exceeded, details}}` | Structured error tuple returned | **PASS** |
| 20 | 429 `rateLimitExceeded` with `Retry-After: 15` | Returns `{:error, {:rate_limited, details}}` with `retry_after: 15` | Structured error tuple returned | **PASS** |
| 21 | Explicit boolean `false` in `create_broadcast` | Retain `enableDvr: false` in body | **FAILED**: Dropped by `Enum.find_value` | **FAIL** |
| 22 | String keys in `update_broadcast` | Update snippet with `"title" => "New"` | **FAILED**: Dropped by atom-only guard | **FAIL** |

---

## Recommendations for Implementer

1. **Fix `get_boolean/3` in `live_broadcasts.ex`**: Use `Enum.reduce_while` instead of `Enum.find_value` so `false` is not treated as a search miss.
2. **Fix update body helpers in `live_broadcasts.ex` and `live_streams.ex`**: Ensure `build_snippet_for_update`, `build_status_for_update`, and `build_cdn_for_update` inspect string keys as well as atom keys in their conditional guards.
3. **Normalize `onBehalfOfContentOwner` across list functions**: Pass `opts_map` to `build_list_query_params` in both `live_broadcasts.ex` and `live_streams.ex`.
4. **Support single atom in `resolve_part/3`**: Add `part when is_atom(part) and not is_nil(part) -> to_string(part)`.
