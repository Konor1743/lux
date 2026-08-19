# YouTube Live Broadcasts API Integration Analysis
**Module Target**: `Lux.Integrations.YouTube.LiveBroadcasts`  
**Milestone**: Milestone 2 - YouTube Live Broadcasts Management  
**Author**: Explorer 1  
**Date**: 2026-08-17  

---

## 1. Executive Summary

This document provides the complete architectural and technical specification for implementing the `Lux.Integrations.YouTube.LiveBroadcasts` module in the Lux framework.

The `liveBroadcasts` resource in the YouTube Live Streaming API represents a scheduled or active video stream broadcast event on YouTube. This module delivers full lifecycle management for live broadcasts—creation, retrieval, search/listing, metadata updating, stream binding/unbinding, lifecycle status transitions (`testing`, `live`, `complete`), and deletion.

All HTTP operations are routed through `Lux.Integrations.YouTube.Client`, taking advantage of:
1. Automatic OAuth 2.0 Bearer token authorization and automatic 401 token refresh.
2. Structured parsing of YouTube quota exhaustion (`{:quota_exceeded, details}`), rate limits (`{:rate_limited, details}`), and domain errors via `Lux.Integrations.YouTube.Errors`.
3. Deterministic mock injection via `Req.Test` for unit and integration test suites.

---

## 2. YouTube Live Streaming API Deep Dive (`liveBroadcasts`)

### 2.1 Resource Model

A `liveBroadcast` resource represents an event streamed on YouTube. Its canonical schema comprises the following primary parts:

```json
{
  "kind": "youtube#liveBroadcast",
  "etag": "\"kZ87Fj89A_etag\"",
  "id": "broadcast_id_string",
  "snippet": {
    "publishedAt": "2026-08-17T18:00:00Z",
    "channelId": "UC_x5XG1OV2P6uZZ5FSM9Ttw",
    "title": "Live Broadcast Title",
    "description": "Broadcast description text",
    "thumbnails": {
      "default": { "url": "https://...", "width": 120, "height": 90 },
      "medium": { "url": "https://...", "width": 320, "height": 180 },
      "high": { "url": "https://...", "width": 480, "height": 360 }
    },
    "scheduledStartTime": "2026-08-17T20:00:00Z",
    "scheduledEndTime": "2026-08-17T22:00:00Z",
    "actualStartTime": "2026-08-17T20:01:15Z",
    "actualEndTime": "2026-08-17T22:05:00Z",
    "isDefaultBroadcast": false,
    "liveChatId": "live_chat_id_string"
  },
  "status": {
    "lifeCycleStatus": "created",
    "privacyStatus": "public",
    "recordingStatus": "notRecording",
    "madeForKids": false,
    "selfDeclaredMadeForKids": false
  },
  "contentDetails": {
    "boundStreamId": "stream_id_string",
    "boundStreamLastUpdateTimeMs": "1755453600000",
    "monitorStream": {
      "enableMonitorStream": true,
      "broadcastStreamDelayMs": 0,
      "embedHtml": "<iframe ...></iframe>"
    },
    "enableEmbed": true,
    "enableDvr": true,
    "enableContentEncryption": false,
    "startWithSlate": false,
    "recordFromStart": true,
    "enableClosedCaptions": false,
    "closedCaptionsType": "closedCaptionsHttpPost",
    "projection": "rectangular",
    "enableLowLatency": false,
    "latencyPreference": "low",
    "enableAutoStart": true,
    "enableAutoStop": true
  },
  "statistics": {
    "totalChatCount": 150
  }
}
```

### 2.2 Lifecycle State Machine

A broadcast transitions through the following lifecycle states:

```
                  ┌──────────────┐
                  │   created    │
                  └──────┬───────┘
                         │ (bind stream & configure)
                         ▼
                  ┌──────────────┐
       ┌──────────┤    ready     ├──────────┐
       │          └──────┬───────┘          │
       │ (testing)       │                  │ (live without test)
       ▼                 │                  ▼
┌──────────────┐         │           ┌──────────────┐
│ testStarting │         │           │ liveStarting │
└──────┬───────┘         │           └──────┬───────┘
       ▼                 │                  ▼
┌──────────────┐         │           ┌──────────────┐
│   testing    ├─────────┘           │     live     │
└──────────────┘ (live from test)    └──────┬───────┘
                                            │
                                            ▼ (complete)
                                     ┌──────────────┐
                                     │   complete   │ (Terminal State)
                                     └──────────────┘
                                     
* Other terminal/non-normal states: `abandoned`, `revoked`.
```

#### Lifecycle Rules and Constraints:
1. **Transition Targets**: The transition endpoint only accepts three explicit targets for `broadcastStatus`:
   - `"testing"`: Enters testing mode where video is visible on the private monitor stream before public broadcast. Requires `monitorStream.enableMonitorStream == true`.
   - `"live"`: Starts the public broadcast. Can transition from `ready` or from `testing`.
   - `"complete"`: Ends the broadcast. This is **terminal and irreversible**—once completed, the broadcast cannot be re-opened.
2. **Auto-Start and Auto-Stop**:
   - `enableAutoStart = true`: YouTube automatically transitions the broadcast to `live` as soon as streaming data starts arriving at the bound stream ingestion point.
   - `enableAutoStop = true`: YouTube automatically transitions the broadcast to `complete` when streaming data stops.
3. **Stream Binding**:
   - A broadcast must be bound to a stream (`liveStreams` resource) to receive video data.
   - Binding is executed via `POST /liveBroadcasts/bind?id={broadcast_id}&streamId={stream_id}`.
   - Calling `bind` with an empty/nil `streamId` unbinds the stream.

### 2.3 Query and Listing Nuances
- **Endpoint**: `GET /liveBroadcasts`
- **Filter Requirements**: YouTube Data API v3 requires at least one filter:
  - `mine=true`: Lists broadcasts belonging to the authenticated channel.
  - `broadcastStatus`: Filter by status (`"all"`, `"active"`, `"completed"`, `"upcoming"`). **Important API Quirk**: Whenever `broadcastStatus` is specified, YouTube requires `mine=true` to be passed as well.
  - `id`: Filter by one or more comma-separated broadcast IDs.
- **Pagination**: Supports `maxResults` (1..50, default 25) and `pageToken` (`nextPageToken` / `prevPageToken`).

---

## 3. Module Design (`Lux.Integrations.YouTube.LiveBroadcasts`)

### 3.1 Function Matrix

| Function | HTTP Method | Endpoint | Default `part` | Primary Purpose |
|---|---|---|---|---|
| `create_broadcast/2` | `POST` | `/liveBroadcasts` | `"snippet,status,contentDetails"` | Create a new scheduled live broadcast |
| `list_broadcasts/2` | `GET` | `/liveBroadcasts` | `"snippet,status,contentDetails"` | List broadcasts with filters & pagination |
| `get_broadcast/2` | `GET` | `/liveBroadcasts` | `"snippet,status,contentDetails"` | Retrieve a single broadcast by ID |
| `update_broadcast/2` | `PUT` | `/liveBroadcasts` | `"snippet,status,contentDetails"` | Update title, description, privacy, settings |
| `transition_broadcast/3` | `POST` | `/liveBroadcasts/transition` | `"status,snippet,contentDetails"` | Transition status (`testing`, `live`, `complete`) |
| `bind_broadcast/3` | `POST` | `/liveBroadcasts/bind` | `"id,snippet,contentDetails,status"` | Bind/unbind broadcast to ingestion stream |
| `delete_broadcast/2` | `DELETE` | `/liveBroadcasts` | N/A | Delete a broadcast by ID |

---

### 3.2 Typespecs and Signatures

```elixir
defmodule Lux.Integrations.YouTube.LiveBroadcasts do
  @moduledoc """
  Manages YouTube Live Broadcasts (`liveBroadcasts` resource) via the YouTube Live Streaming API.

  Provides full lifecycle management including creating scheduled broadcasts, listing,
  retrieving, updating metadata, binding to ingestion streams, transitioning lifecycle states
  (`testing` -> `live` -> `complete`), and deleting broadcasts.

  All requests are executed through `Lux.Integrations.YouTube.Client`, providing automatic
  Bearer token authentication, token refresh on 401, quota and rate limit parsing, and
  testing support with `Req.Test`.
  """

  alias Lux.Integrations.YouTube.Client

  @default_parts "snippet,status,contentDetails"
  @default_max_results 25

  @type privacy_status :: :public | :private | :unlisted | String.t()
  @type broadcast_status :: :all | :active | :completed | :upcoming | String.t()
  @type broadcast_type :: :all | :event | :persistent | String.t()
  @type transition_status :: :testing | :live | :complete | String.t()
  @type latency_preference :: :normal | :low | :ultraLow | :ultra_low | String.t()

  @type broadcast :: %{String.t() => term()}
  @type broadcast_list_response :: %{
          String.t() => term(),
          optional("items") => [broadcast()],
          optional("nextPageToken") => String.t(),
          optional("prevPageToken") => String.t(),
          optional("pageInfo") => map()
        }

  @type create_broadcast_params ::
          %{
            required(:title) => String.t(),
            required(:scheduled_start_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:description) => String.t(),
            optional(:scheduled_end_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:privacy_status) => privacy_status(),
            optional(:is_default_broadcast) => boolean(),
            optional(:self_declared_made_for_kids) => boolean(),
            optional(:enable_auto_start) => boolean(),
            optional(:enable_auto_stop) => boolean(),
            optional(:enable_dvr) => boolean(),
            optional(:enable_content_encryption) => boolean(),
            optional(:enable_embed) => boolean(),
            optional(:record_from_start) => boolean(),
            optional(:start_with_slate) => boolean(),
            optional(:enable_closed_captions) => boolean(),
            optional(:closed_captions_type) => String.t(),
            optional(:enable_low_latency) => boolean(),
            optional(:latency_preference) => latency_preference(),
            optional(:monitor_stream) => %{
              optional(:enable_monitor_stream) => boolean(),
              optional(:broadcast_stream_delay_ms) => non_neg_integer()
            }
          }
          | %{String.t() => term()}
          | map()

  @type list_broadcasts_params ::
          %{
            optional(:broadcast_status) => broadcast_status(),
            optional(:broadcastStatus) => broadcast_status(),
            optional(:broadcast_type) => broadcast_type(),
            optional(:broadcastType) => broadcast_type(),
            optional(:id) => String.t() | [String.t()],
            optional(:mine) => boolean(),
            optional(:max_results) => pos_integer(),
            optional(:maxResults) => pos_integer(),
            optional(:page_token) => String.t(),
            optional(:pageToken) => String.t(),
            optional(:part) => String.t() | [String.t() | atom()]
          }
          | keyword()
          | map()

  @type update_broadcast_params ::
          %{
            required(:id) => String.t(),
            optional(:title) => String.t(),
            optional(:description) => String.t(),
            optional(:scheduled_start_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:scheduled_end_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:privacy_status) => privacy_status(),
            optional(:self_declared_made_for_kids) => boolean(),
            optional(:enable_auto_start) => boolean(),
            optional(:enable_auto_stop) => boolean(),
            optional(:enable_dvr) => boolean(),
            optional(:enable_content_encryption) => boolean(),
            optional(:enable_embed) => boolean(),
            optional(:record_from_start) => boolean(),
            optional(:enable_closed_captions) => boolean(),
            optional(:latency_preference) => latency_preference(),
            optional(:snippet) => map(),
            optional(:status) => map(),
            optional(:contentDetails) => map()
          }
          | %{String.t() => term()}
          | map()

  @type request_opts :: Client.request_opts() | keyword()
```

---

### 3.3 Method Detailed Specifications

#### 1. `create_broadcast/2`
```elixir
@doc """
Creates a new YouTube Live Broadcast.

## Parameters
- `params`: Map of broadcast parameters (supports flat friendly keys or nested YouTube JSON structure).
- `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3` (e.g. `:token`, `:plug`, `:part`).

## Required Parameters
- `:title` (or `snippet.title`): Title of the broadcast.
- `:scheduled_start_time` (or `snippet.scheduledStartTime`): ISO 8601 string or `DateTime`.

## Optional Parameters
- `:description`: Broadcast description text.
- `:scheduled_end_time`: ISO 8601 string or `DateTime`.
- `:privacy_status`: `:public`, `:private`, or `:unlisted` (default `:public`).
- `:enable_auto_start`: Boolean flag to auto-start when stream starts (default `false`).
- `:enable_auto_stop`: Boolean flag to auto-stop when stream stops (default `false`).
- `:enable_dvr`: Boolean flag for DVR (rewind) capability (default `true`).
- `:enable_content_encryption`: Boolean flag for DRM encryption.
- `:enable_embed`: Boolean flag for embedding permission.
- `:record_from_start`: Boolean flag to archive entire broadcast.
- `:latency_preference`: `:normal`, `:low`, or `:ultraLow` (or `:ultra_low`).
- `:self_declared_made_for_kids`: Boolean flag for COPPA compliance.
- `:monitor_stream`: Map with `:enable_monitor_stream` and `:broadcast_stream_delay_ms`.

## Returns
- `{:ok, broadcast_map}` on success
- `{:error, reason}` on failure
"""
@spec create_broadcast(create_broadcast_params(), request_opts()) ::
        {:ok, broadcast()} | {:error, term()}
```

#### 2. `list_broadcasts/2`
```elixir
@doc """
Lists live broadcasts for the authenticated channel or filtered by ID/status.

## Parameters
- `params`: Query filters and pagination options (map or keyword list).
  - `:broadcast_status` / `:broadcastStatus`: `:all`, `:active`, `:completed`, `:upcoming` (automatically enables `mine: true`).
  - `:broadcast_type` / `:broadcastType`: `:all`, `:event`, `:persistent` (default `:event`).
  - `:id`: Filter by broadcast ID or list of IDs.
  - `:mine`: Boolean, defaults to `true` when querying by status.
  - `:max_results` / `:maxResults`: Integer (1..50, default 25).
  - `:page_token` / `:pageToken`: Pagination cursor.
  - `:part`: Resource parts string or list (default `"snippet,status,contentDetails"`).
- `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3`.

## Returns
- `{:ok, broadcast_list_response}` on success
- `{:error, reason}` on failure
"""
@spec list_broadcasts(list_broadcasts_params(), request_opts()) ::
        {:ok, broadcast_list_response()} | {:error, term()}
```

#### 3. `get_broadcast/2`
```elixir
@doc """
Retrieves a single live broadcast by ID.

## Parameters
- `id`: YouTube broadcast ID string.
- `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3` (supports `:part`, `:token`, `:plug`).

## Returns
- `{:ok, broadcast_map}` if found
- `{:error, :not_found}` if no broadcast matches the given ID
- `{:error, reason}` on API or network failure
"""
@spec get_broadcast(String.t(), request_opts()) ::
        {:ok, broadcast()} | {:error, term()}
```

#### 4. `update_broadcast/2`
```elixir
@doc """
Updates an existing YouTube live broadcast's metadata and settings.

## Parameters
- `params`: Map containing `:id` and updated broadcast fields (`snippet`, `status`, `contentDetails`, or flat friendly fields).
- `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3`.

## Returns
- `{:ok, updated_broadcast_map}` on success
- `{:error, :missing_broadcast_id}` if `:id` is not supplied
- `{:error, reason}` on API or network failure
"""
@spec update_broadcast(update_broadcast_params(), request_opts()) ::
        {:ok, broadcast()} | {:error, term()}
```

#### 5. `transition_broadcast/3`
```elixir
@doc """
Transitions the lifecycle status of a live broadcast.

Valid transition target statuses:
- `:testing` / `"testing"`: Enters monitor stream testing before going live.
- `:live` / `"live"`: Transitions to public streaming.
- `:complete` / `"complete"`: Terminates the broadcast (irreversible).

## Parameters
- `broadcast_id`: YouTube broadcast ID string.
- `broadcast_status`: Target status atom (`:testing`, `:live`, `:complete`) or string.
- `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3` (supports `:part`, default `"status,snippet,contentDetails"`).

## Returns
- `{:ok, updated_broadcast_map}` on success
- `{:error, {:invalid_transition_status, status}}` if the status is not valid
- `{:error, reason}` on API failure (e.g. 400 invalidTransition)
"""
@spec transition_broadcast(String.t(), transition_status(), request_opts()) ::
        {:ok, broadcast()} | {:error, term()}
```

#### 6. `bind_broadcast/3`
```elixir
@doc """
Binds a live broadcast to a live stream (ingestion point) or unbinds it.

## Parameters
- `broadcast_id`: YouTube broadcast ID string.
- `stream_id`: YouTube live stream ID string, or `nil`/`""` to unbind.
- `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3` (supports `:part`, default `"id,snippet,contentDetails,status"`).

## Returns
- `{:ok, updated_broadcast_map}` on success
- `{:error, reason}` on API or network failure
"""
@spec bind_broadcast(String.t(), String.t() | nil, request_opts()) ::
        {:ok, broadcast()} | {:error, term()}
```

#### 7. `delete_broadcast/2`
```elixir
@doc """
Deletes a YouTube live broadcast by ID.

## Parameters
- `broadcast_id`: YouTube broadcast ID string.
- `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3`.

## Returns
- `{:ok, %{}}` on successful deletion (HTTP 204)
- `{:error, reason}` on API or network failure
"""
@spec delete_broadcast(String.t(), request_opts()) ::
        {:ok, map()} | {:error, term()}
```

---

## 4. Parameter Normalization & Construction Strategy

To provide an exceptional developer experience, the module will support both **flat friendly Elixir keys** and **standard nested YouTube v3 structures**, transforming values automatically.

### 4.1 Field Mapping Dictionary

| Elixir Flat Key | YouTube Nested Path | Type Transformation |
|---|---|---|
| `:title` / `"title"` | `snippet.title` | `to_string/1` |
| `:description` / `"description"` | `snippet.description` | `to_string/1` |
| `:scheduled_start_time` / `"scheduledStartTime"` | `snippet.scheduledStartTime` | `DateTime.to_iso8601/1` |
| `:scheduled_end_time` / `"scheduledEndTime"` | `snippet.scheduledEndTime` | `DateTime.to_iso8601/1` |
| `:is_default_broadcast` | `snippet.isDefaultBroadcast` | `boolean` |
| `:privacy_status` / `"privacyStatus"` | `status.privacyStatus` | `:public` -> `"public"`, etc. |
| `:self_declared_made_for_kids` | `status.selfDeclaredMadeForKids` | `boolean` |
| `:enable_auto_start` | `contentDetails.enableAutoStart` | `boolean` |
| `:enable_auto_stop` | `contentDetails.enableAutoStop` | `boolean` |
| `:enable_dvr` | `contentDetails.enableDvr` | `boolean` |
| `:enable_content_encryption` | `contentDetails.enableContentEncryption` | `boolean` |
| `:enable_embed` | `contentDetails.enableEmbed` | `boolean` |
| `:record_from_start` | `contentDetails.recordFromStart` | `boolean` |
| `:start_with_slate` | `contentDetails.startWithSlate` | `boolean` |
| `:enable_closed_captions` | `contentDetails.enableClosedCaptions` | `boolean` |
| `:closed_captions_type` | `contentDetails.closedCaptionsType` | `to_string/1` |
| `:enable_low_latency` | `contentDetails.enableLowLatency` | `boolean` |
| `:latency_preference` | `contentDetails.latencyPreference` | `:ultra_low` -> `"ultraLow"`, etc. |
| `:monitor_stream` | `contentDetails.monitorStream` | `map` |

### 4.2 Helper Logic Example
```elixir
defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"
defp format_datetime(str) when is_binary(str), do: str
defp format_datetime(nil), do: nil

defp normalize_privacy(:public), do: "public"
defp normalize_privacy(:private), do: "private"
defp normalize_privacy(:unlisted), do: "unlisted"
defp normalize_privacy(val) when is_binary(val), do: val
defp normalize_privacy(_), do: "public"

defp normalize_latency(:normal), do: "normal"
defp normalize_latency(:low), do: "low"
defp normalize_latency(:ultraLow), do: "ultraLow"
defp normalize_latency(:ultra_low), do: "ultraLow"
defp normalize_latency(val) when is_binary(val), do: val
defp normalize_latency(_), do: nil

defp format_part(parts) when is_list(parts), do: parts |> Enum.map(&to_string/1) |> Enum.join(",")
defp format_part(part) when is_binary(part), do: part
defp format_part(_), do: @default_parts
```

---

## 5. Error Handling Architecture

Errors encountered in `LiveBroadcasts` operations are propagated with zero loss of fidelity through `Lux.Integrations.YouTube.Client` and `Lux.Integrations.YouTube.Errors`:

1. **Parameter Validation Failures (Pre-HTTP)**:
   - Missing required broadcast ID in `update_broadcast/2` -> `{:error, :missing_broadcast_id}`.
   - Missing broadcast ID in `transition_broadcast/3` -> `{:error, :missing_broadcast_id}`.
   - Invalid status atom/string in `transition_broadcast/3` -> `{:error, {:invalid_transition_status, status}}`.
2. **Resource Not Found (`get_broadcast/2`)**:
   - When the YouTube API list response contains `items: []`, `get_broadcast/2` cleanly returns `{:error, :not_found}`.
3. **HTTP 400 Bad Request (API level)**:
   - Invalid transition (e.g. attempting to start a broadcast before stream is active, or transitioning a completed broadcast):
     `{:error, {400, "The broadcast cannot transition to the testing status."}}`.
4. **HTTP 401 Unauthorized**:
   - Handled automatically by `Client.request/3` with refresh token rotation. If refresh fails, returns `{:error, :invalid_token}`.
5. **HTTP 403 Quota Exceeded**:
   - `{:error, {:quota_exceeded, %{reason: "quotaExceeded", message: "...", status: 403, domain: "youtube.quota"}}}`.
6. **HTTP 403 / 429 Rate Limited**:
   - `{:error, {:rate_limited, %{reason: "userRateLimitExceeded", status: 403, retry_after: 15}}}`.
7. **HTTP 404 / 500 / Network**:
   - `{:error, {404, "Not Found"}}`, `{:error, {500, "Internal Server Error"}}`, or `{:error, %Req.TransportError{}}`.

---

## 6. Testing Strategy & `Req.Test` Fixtures

Tests will be placed in `test/unit/lux/integrations/youtube/live_broadcasts_test.exs` using `use UnitAPICase, async: false` and `Req.Test.expect(YouTubeClientMock, fn conn -> ... end)`.

### 6.1 Standard Mock Fixtures

#### Fixture 1: Created Broadcast
```elixir
def broadcast_fixture(overrides \\ %{}) do
  Map.merge(
    %{
      "kind" => "youtube#liveBroadcast",
      "etag" => "\"etag_broadcast_123\"",
      "id" => "b_test_123",
      "snippet" => %{
        "publishedAt" => "2026-08-17T18:00:00Z",
        "channelId" => "UC_mock_channel_123",
        "title" => "Lux Live Event",
        "description" => "Streaming agent workflows",
        "scheduledStartTime" => "2026-08-17T20:00:00Z",
        "scheduledEndTime" => "2026-08-17T22:00:00Z",
        "isDefaultBroadcast" => false,
        "liveChatId" => "chat_id_abc"
      },
      "status" => %{
        "lifeCycleStatus" => "created",
        "privacyStatus" => "public",
        "recordingStatus" => "notRecording",
        "madeForKids" => false,
        "selfDeclaredMadeForKids" => false
      },
      "contentDetails" => %{
        "boundStreamId" => nil,
        "monitorStream" => %{
          "enableMonitorStream" => true,
          "broadcastStreamDelayMs" => 0,
          "embedHtml" => "<iframe src=\"https://youtube.com/embed/b_test_123\"></iframe>"
        },
        "enableEmbed" => true,
        "enableDvr" => true,
        "enableContentEncryption" => false,
        "startWithSlate" => false,
        "recordFromStart" => true,
        "enableClosedCaptions" => false,
        "latencyPreference" => "low",
        "enableAutoStart" => true,
        "enableAutoStop" => true
      }
    },
    overrides
  )
end
```

#### Fixture 2: Broadcast List Response
```elixir
def broadcast_list_fixture(items \\ [broadcast_fixture()]) do
  %{
    "kind" => "youtube#liveBroadcastListResponse",
    "etag" => "\"etag_list_123\"",
    "nextPageToken" => "PAGE_TOKEN_NEXT",
    "prevPageToken" => nil,
    "pageInfo" => %{
      "totalResults" => length(items),
      "resultsPerPage" => 25
    },
    "items" => items
  }
end
```

### 6.2 Unit Test Matrix

1. **`create_broadcast/2`**:
   - Creates broadcast with minimal required params (`title`, `scheduled_start_time`).
   - Creates broadcast with all optional parameters (`description`, `privacy_status`, `enable_auto_start`, `enable_auto_stop`, `latency_preference`, `monitor_stream`).
   - Accepts `DateTime` struct for scheduled times.
   - Accepts pre-structured nested YouTube map (`snippet`, `status`, `contentDetails`).
   - Propagates client errors (`403 quotaExceeded`, `401 invalid_token`).

2. **`list_broadcasts/2`**:
   - Lists broadcasts with default parameters (`mine=true`).
   - Filters by `broadcastStatus` (`:active`, `:upcoming`, `:completed`, `:all`).
   - Filters by `id` (single string and list of strings).
   - Handles pagination (`maxResults`, `pageToken`).
   - Returns decoded response structure with items and tokens.

3. **`get_broadcast/2`**:
   - Successfully retrieves a single broadcast by ID.
   - Returns `{:error, :not_found}` when the API returns empty items list `[]`.
   - Propagates API error when response is non-2xx.

4. **`update_broadcast/2`**:
   - Successfully updates broadcast snippet and status fields.
   - Validates that `:id` is present, returning `{:error, :missing_broadcast_id}` when omitted.
   - Handles partial field updates.

5. **`transition_broadcast/3`**:
   - Successfully transitions to `:testing` (`broadcastStatus=testing`).
   - Successfully transitions to `:live` (`broadcastStatus=live`).
   - Successfully transitions to `:complete` (`broadcastStatus=complete`).
   - Rejects invalid transition status with `{:error, {:invalid_transition_status, status}}`.
   - Rejects missing broadcast ID with `{:error, :missing_broadcast_id}`.
   - Propagates YouTube API 400 `invalidTransition` error.

6. **`bind_broadcast/3`**:
   - Binds broadcast to stream ID (`POST /liveBroadcasts/bind?id=...&streamId=...`).
   - Unbinds broadcast when `streamId` is `nil` or `""`.
   - Propagates API errors.

7. **`delete_broadcast/2`**:
   - Deletes broadcast by ID (`DELETE /liveBroadcasts?id=...`).
   - Handles HTTP 204 No Content response properly returning `{:ok, %{}}`.
   - Propagates 404 or 403 API errors.

---

## 7. Next Steps for Implementer

1. Create `lib/lux/integrations/youtube/live_broadcasts.ex` conforming to this exact specification.
2. Create `test/unit/lux/integrations/youtube/live_broadcasts_test.exs` with 100% endpoint and error path coverage.
3. Verify compilation clean with `mix compile --warnings-as-errors`.
4. Run ExUnit test suite and ensure all tests pass.
