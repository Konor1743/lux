# Technical Investigation & Architectural Design: YouTube Live Streams Management

**Agent**: Explorer 2 (Milestone 2)  
**Target Module**: `Lux.Integrations.YouTube.LiveStreams` (`lib/lux/integrations/youtube/live_streams.ex`)  
**Associated Test Module**: `Lux.Integrations.YouTube.LiveStreamsTest` (`test/unit/lux/integrations/youtube/live_streams_test.exs`)  
**Related Modules**: `Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube.LiveBroadcasts`, `Lux.Integrations.YouTube.Errors`  
**Date**: 2026-08-17  

---

## 1. Executive Summary

This report establishes the complete specification, architectural design, type definitions, and test fixtures for the YouTube Live Streams management module (`Lux.Integrations.YouTube.LiveStreams`).

A **`liveStream`** resource represents the video ingestion pipeline that receives video from an encoder (e.g. OBS, FFmpeg, Wirecast, vMix) via RTMP/RTMPS protocols and provides the video stream to a **`liveBroadcast`**.

`Lux.Integrations.YouTube.LiveStreams` provides:
1. **Full CRUD operations**:
   - `create_stream/2`: Creates a stream with snippet (`title`, `description`), CDN settings (`ingestionType`, `resolution`, `frameRate`), and content details (`isReusable`).
   - `list_streams/2`: Lists streams filtered by `mine=true` or specific `id`s with pagination (`maxResults`, `pageToken`).
   - `get_stream/2`: Fetches a single stream by `id` with unwrapping and `:not_found` error detection.
   - `update_stream/2`: Updates stream metadata and ingestion settings.
   - `delete_stream/2`: Deletes an existing live stream by `id`.
2. **Ingestion & Status Extraction Helpers**:
   - Extraction of Stream Key (`cdn.ingestionInfo.streamName`), primary & backup RTMP/RTMPS ingestion addresses.
   - Dynamic construction of complete stream URLs (`stream_url/2`).
   - Health status inspection (`health_status/1`), status predicates (`active?/1`, `ready?/1`, `error?/1`).
3. **Ergonomic Parameter Normalization**:
   - Polymorphic handling of keyword lists and maps with camelCase or snake_case keys.
   - Automatic defaults for `part` (`"snippet,cdn,status,contentDetails"`), `ingestionType` (`"rtmp"`), `resolution` (`"variable"`), `frameRate` (`"variable"`), and `isReusable` (`true`).
4. **Transparent Error Propagation**:
   - Full integration with `Lux.Integrations.YouTube.Client` and `Lux.Integrations.YouTube.Errors` (`:invalid_token`, `{:quota_exceeded, details}`, `{:rate_limited, details}`, `{status, message}`).
5. **Full Test Mocking Support**:
   - Deterministic testing via `Req.Test` plug injection using `YouTubeClientMock`.

---

## 2. YouTube `liveStreams` Resource Architecture & Schema

### 2.1 Protocol and Workflow Overview

```
+------------------+         +-------------------------------+         +-----------------------+
|  Video Encoder   |  RTMP   | YouTube Ingestion             | Bind    | YouTube LiveBroadcast |
| (OBS / FFmpeg)   |-------->| liveStreams (Ingestion Point) |-------->| (Public Viewer URL /  |
|                  |         | - ingestionAddress            |         |  Live Watch Page)     |
|                  |         | - streamName (Stream Key)     |         |                       |
+------------------+         +-------------------------------+         +-----------------------+
                                             ^
                                             | REST API Calls (Lux.Integrations.YouTube.LiveStreams)
                                             |
                                 +-----------+-----------+
                                 | Lux Framework Agent   |
                                 | / Streaming Workflow  |
                                 +-----------------------+
```

### 2.2 Live Stream JSON Schema

The YouTube Data API v3 `liveStream` resource has the following canonical structure:

```json
{
  "kind": "youtube#liveStream",
  "etag": "\"etag_hash\"",
  "id": "stream_id_string",
  "snippet": {
    "publishedAt": "2026-08-17T18:00:00.000Z",
    "channelId": "UC_channel_id",
    "title": "Stream Title",
    "description": "Stream Description",
    "isDefaultStream": false
  },
  "cdn": {
    "ingestionType": "rtmp",
    "ingestionInfo": {
      "streamName": "xxxx-xxxx-xxxx-xxxx",
      "ingestionAddress": "rtmp://a.rtmp.youtube.com/live2",
      "backupIngestionAddress": "rtmp://b.rtmp.youtube.com/live2?backup=1",
      "rtmpsIngestionAddress": "rtmps://a.rtmp.youtube.com/live2",
      "rtmpsBackupIngestionAddress": "rtmps://b.rtmp.youtube.com/live2?backup=1"
    },
    "resolution": "1080p",
    "frameRate": "60fps"
  },
  "status": {
    "streamStatus": "ready",
    "healthStatus": {
      "status": "good",
      "lastUpdateTimeSeconds": 1787076000,
      "configurationIssues": [
        {
          "type": "bitrateHigh",
          "severity": "warning",
          "reason": "Stream bitrate is above recommended target",
          "description": "Encoder is sending 12 Mbps, target is 9 Mbps"
        }
      ]
    }
  },
  "contentDetails": {
    "closedCaptionsIngestionUrl": "http://upload.youtube.com/closedcaption?id=stream_id",
    "isReusable": true
  }
}
```

### 2.3 Resource Fields Definition

| Section | Field | Type | Modifiable | Description |
|---|---|---|---|---|
| Top-level | `id` | `String.t()` | No (Assigned by YouTube) | Unique ID of the stream |
| Top-level | `kind` | `String.t()` | No | Always `"youtube#liveStream"` |
| Top-level | `etag` | `String.t()` | No | ETag identifier |
| `snippet` | `title` | `String.t()` | Yes (Create/Update) | Stream title (1-128 characters) |
| `snippet` | `description` | `String.t()` | Yes (Create/Update) | Stream description (up to 10,000 chars) |
| `snippet` | `channelId` | `String.t()` | No | Channel ID owning the stream |
| `snippet` | `publishedAt` | `String.t()` | No | Creation timestamp (ISO 8601) |
| `snippet` | `isDefaultStream` | `boolean()` | No | True if default stream for channel |
| `cdn` | `ingestionType` | `String.t()` | Yes (Create) | `"rtmp"`, `"dash"`, or `"hls"` (default: `"rtmp"`) |
| `cdn` | `resolution` | `String.t()` | Yes (Create/Update) | `"240p"`, `"360p"`, `"480p"`, `"720p"`, `"1080p"`, `"1440p"`, `"2160p"`, `"variable"` |
| `cdn` | `frameRate` | `String.t()` | Yes (Create/Update) | `"30fps"`, `"60fps"`, `"variable"` |
| `cdn.ingestionInfo` | `streamName` | `String.t()` | No (Generated) | Stream key for encoder auth |
| `cdn.ingestionInfo` | `ingestionAddress` | `String.t()` | No (Generated) | Primary RTMP ingestion endpoint |
| `cdn.ingestionInfo` | `backupIngestionAddress` | `String.t()` | No (Generated) | Backup RTMP ingestion endpoint |
| `cdn.ingestionInfo` | `rtmpsIngestionAddress` | `String.t()` | No (Generated) | Secure primary RTMPS ingestion endpoint |
| `cdn.ingestionInfo` | `rtmpsBackupIngestionAddress` | `String.t()` | No (Generated) | Secure backup RTMPS ingestion endpoint |
| `status` | `streamStatus` | `String.t()` | No | `"active"`, `"created"`, `"error"`, `"inactive"`, `"ready"` |
| `status.healthStatus` | `status` | `String.t()` | No | `"good"`, `"ok"`, `"bad"`, `"noData"` |
| `status.healthStatus` | `configurationIssues` | `list(map())` | No | List of configuration warnings/errors |
| `contentDetails` | `isReusable` | `boolean()` | Yes (Create) | Whether stream can be bound multiple times |
| `contentDetails` | `closedCaptionsIngestionUrl` | `String.t()` | No | Ingestion URL for closed captions |

---

## 3. Detailed Endpoint & Method Specifications

### 3.1 `create_stream/2`

Inserts a new live stream resource.

- **HTTP Verb & Endpoint**: `POST /liveStreams`
- **Default Query Parameters**: `part=snippet,cdn,status,contentDetails`
- **Function Signature**:
  ```elixir
  @spec create_stream(create_stream_params(), client_opts()) :: {:ok, stream_item()} | {:error, term()}
  ```
- **Supported Parameter Formats**:
  1. Flat map / keyword list:
     ```elixir
     LiveStreams.create_stream(%{
       title: "Lux Live Ingestion",
       description: "Automated agent stream",
       ingestion_type: "rtmp",
       resolution: "1080p",
       frame_rate: "60fps",
       is_reusable: true
     }, opts)
     ```
  2. Structured YouTube resource map:
     ```elixir
     LiveStreams.create_stream(%{
       snippet: %{title: "Lux Live Ingestion", description: "Automated agent stream"},
       cdn: %{ingestionType: "rtmp", resolution: "1080p", frameRate: "60fps"},
       contentDetails: %{isReusable: true}
     }, opts)
     ```
- **Payload Normalization**:
  - `title`: defaults to `"Live Stream #{DateTime.utc_now() |> DateTime.to_iso8601()}"` if omitted.
  - `cdn.ingestionType`: defaults to `"rtmp"`.
  - `cdn.resolution`: defaults to `"variable"`.
  - `cdn.frameRate`: defaults to `"variable"`.
  - `contentDetails.isReusable`: defaults to `true`.
- **Response**: `{:ok, stream_map}` with `cdn.ingestionInfo` containing stream key and RTMP endpoints.

---

### 3.2 `list_streams/2`

Retrieves a list of live streams matching the criteria.

- **HTTP Verb & Endpoint**: `GET /liveStreams`
- **Default Query Parameters**: `part=snippet,cdn,status,contentDetails`
- **Function Signature**:
  ```elixir
  @spec list_streams(list_streams_params(), client_opts()) :: {:ok, stream_list_response()} | {:error, term()}
  ```
- **Filter Parameters**:
  - `:mine` (boolean): `true` to list streams belonging to the authenticated channel (default `true` when `:id` is not supplied).
  - `:id` (string or list of strings): Filter by stream ID(s).
  - `:max_results` / `:maxResults` (integer): Maximum results per page (1..50, default 25).
  - `:page_token` / `:pageToken` (string): Token for paginating forward or backward.
  - `:on_behalf_of_content_owner` / `:onBehalfOfContentOwner` (string): YouTube CMS content owner.
  - `:on_behalf_of_content_owner_channel` / `:onBehalfOfContentOwnerChannel` (string): Specific channel within CMS.
- **Response**: `{:ok, %{"kind" => "youtube#liveStreamListResponse", "items" => [...], "pageInfo" => %{...}, ...}}`.

---

### 3.3 `get_stream/2`

Fetches a single live stream by its unique identifier.

- **HTTP Verb & Endpoint**: `GET /liveStreams`
- **Query Parameters**: `id=stream_id`, `part=snippet,cdn,status,contentDetails`
- **Function Signature**:
  ```elixir
  @spec get_stream(String.t(), client_opts()) :: {:ok, stream_item()} | {:error, :not_found | term()}
  ```
- **Unwrapping Behavior**:
  - YouTube API returns `%{ "items" => [stream] }` when found.
  - `get_stream/2` unwraps the single stream map `hd(items)`.
  - If `items` is empty (`[]`), returns `{:error, :not_found}`.
  - Matches `PROJECT.md` line 53 specification: `get_stream(id, opts \\ %{}) :: {:ok, stream} | {:error, term()}`.

---

### 3.4 `update_stream/2`

Updates an existing live stream's metadata and ingestion configuration.

- **HTTP Verb & Endpoint**: `PUT /liveStreams`
- **Default Query Parameters**: `part=snippet,cdn,contentDetails`
- **Function Signature**:
  ```elixir
  @spec update_stream(update_stream_params(), client_opts()) :: {:ok, stream_item()} | {:error, term()}
  ```
- **Validation**:
  - Requires `:id` or `"id"` in params.
  - Returns `{:error, :missing_stream_id}` if `id` is nil or empty.
- **Response**: `{:ok, updated_stream_map}`.

---

### 3.5 `delete_stream/2`

Deletes a live stream.

- **HTTP Verb & Endpoint**: `DELETE /liveStreams`
- **Query Parameters**: `id=stream_id`
- **Function Signature**:
  ```elixir
  @spec delete_stream(String.t(), client_opts()) :: {:ok, map()} | {:error, term()}
  ```
- **Validation**:
  - Requires valid binary stream ID.
  - Returns `{:error, :missing_stream_id}` if `id` is nil or empty.
- **Response**:
  - YouTube returns HTTP 204 No Content.
  - Returns `{:ok, %{id: id, deleted: true}}` conforming to `{:ok, map()}` in `PROJECT.md` line 54.

---

### 3.6 Ingestion & Health Helper Functions

To make stream management ergonomic for Elixir agents, lenses, and streaming pipelines, `LiveStreams` provides pure helper functions:

| Function | Signature | Description |
|---|---|---|
| `stream_key/1` | `(stream_or_cdn) :: String.t() \| nil` | Extracts `cdn.ingestionInfo.streamName` |
| `ingestion_address/1` | `(stream_or_cdn) :: String.t() \| nil` | Extracts `cdn.ingestionInfo.ingestionAddress` |
| `backup_ingestion_address/1` | `(stream_or_cdn) :: String.t() \| nil` | Extracts `cdn.ingestionInfo.backupIngestionAddress` |
| `rtmps_ingestion_address/1` | `(stream_or_cdn) :: String.t() \| nil` | Extracts `cdn.ingestionInfo.rtmpsIngestionAddress` |
| `rtmps_backup_ingestion_address/1` | `(stream_or_cdn) :: String.t() \| nil` | Extracts `cdn.ingestionInfo.rtmpsBackupIngestionAddress` |
| `stream_url/2` | `(stream_or_cdn, opts \\ []) :: String.t() \| nil` | Builds full URL (e.g. `"rtmp://a.rtmp.youtube.com/live2/key"`) with `:rtmp`/`:rtmps` and `:backup` options |
| `stream_status/1` | `(stream) :: String.t() \| nil` | Extracts `status.streamStatus` (`"active"`, `"created"`, `"error"`, `"inactive"`, `"ready"`) |
| `health_status/1` | `(stream) :: String.t() \| nil` | Extracts `status.healthStatus.status` (`"good"`, `"ok"`, `"bad"`, `"noData"`) |
| `active?/1` | `(stream) :: boolean()` | `true` if `stream_status(stream) == "active"` |
| `ready?/1` | `(stream) :: boolean()` | `true` if `stream_status(stream) in ["ready", "active"]` |
| `error?/1` | `(stream) :: boolean()` | `true` if `stream_status(stream) == "error"` or `health_status(stream) == "bad"` |

---

## 4. Full Module Implementation Design

Here is the proposed code for `lib/lux/integrations/youtube/live_streams.ex`:

```elixir
defmodule Lux.Integrations.YouTube.LiveStreams do
  @moduledoc """
  Manages YouTube Live Streaming ingestion endpoints (`liveStreams` resource).

  Provides functionality to:
  - Create (`create_stream/2`) RTMP/RTMPS live stream ingestion points
  - List (`list_streams/2`) streams belonging to the authenticated channel or by ID
  - Fetch (`get_stream/2`) specific stream details
  - Update (`update_stream/2`) stream metadata and video resolution/framerate
  - Delete (`delete_stream/2`) streams
  - Extract stream keys, RTMP addresses, and evaluate stream health/status
  """

  alias Lux.Integrations.YouTube.Client

  @default_part "snippet,cdn,status,contentDetails"
  @valid_resolutions ~w(240p 360p 480p 720p 1080p 1440p 2160p variable)
  @valid_frame_rates ~w(30fps 60fps variable)
  @valid_ingestion_types ~w(rtmp dash hls)

  # --- Typespecs ---

  @type ingestion_type :: String.t()
  @type resolution :: String.t()
  @type frame_rate :: String.t()
  @type stream_status :: String.t()
  @type health_status_value :: String.t()

  @type stream_item :: %{
          required(String.t()) => term()
        }

  @type stream_list_response :: %{
          required(String.t()) => term(),
          optional("items") => [stream_item()],
          optional("nextPageToken") => String.t(),
          optional("prevPageToken") => String.t(),
          optional("pageInfo") => map()
        }

  @type client_opts :: Client.request_opts() | keyword()

  @type create_stream_params :: %{
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:ingestion_type) => ingestion_type(),
          optional(:ingestionType) => ingestion_type(),
          optional(:resolution) => resolution(),
          optional(:frame_rate) => frame_rate(),
          optional(:frameRate) => frame_rate(),
          optional(:is_reusable) => boolean(),
          optional(:isReusable) => boolean(),
          optional(:snippet) => map(),
          optional(:cdn) => map(),
          optional(:contentDetails) => map(),
          optional(:content_details) => map(),
          optional(String.t()) => term()
        } | Keyword.t()

  @type update_stream_params :: %{
          required(:id) => String.t(),
          optional(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:ingestion_type) => ingestion_type(),
          optional(:ingestionType) => ingestion_type(),
          optional(:resolution) => resolution(),
          optional(:frame_rate) => frame_rate(),
          optional(:frameRate) => frame_rate(),
          optional(:snippet) => map(),
          optional(:cdn) => map(),
          optional(:contentDetails) => map(),
          optional(:content_details) => map(),
          optional(String.t()) => term()
        } | Keyword.t()

  @type list_streams_params :: %{
          optional(:mine) => boolean(),
          optional(:id) => String.t() | [String.t()],
          optional(:max_results) => non_neg_integer(),
          optional(:maxResults) => non_neg_integer(),
          optional(:page_token) => String.t(),
          optional(:pageToken) => String.t(),
          optional(:part) => String.t() | [String.t() | atom()],
          optional(:on_behalf_of_content_owner) => String.t(),
          optional(:onBehalfOfContentOwner) => String.t(),
          optional(:on_behalf_of_content_owner_channel) => String.t(),
          optional(:onBehalfOfContentOwnerChannel) => String.t()
        } | Keyword.t()

  # --- Public API ---

  @doc """
  Returns the default part parameter for live stream requests.
  """
  @spec default_part() :: String.t()
  def default_part, do: @default_part

  @doc """
  Creates a new YouTube Live Stream resource.

  ## Parameters
  - `params`: Map or keyword list of stream configuration properties:
    - `:title` (string): Stream title.
    - `:description` (string, optional): Stream description.
    - `:ingestion_type` / `:ingestionType` (string): `"rtmp"`, `"dash"`, or `"hls"` (default `"rtmp"`).
    - `:resolution` (string): `"1080p"`, `"720p"`, `"variable"`, etc. (default `"variable"`).
    - `:frame_rate` / `:frameRate` (string): `"60fps"`, `"30fps"`, `"variable"` (default `"variable"`).
    - `:is_reusable` / `:isReusable` (boolean): Whether stream is reusable across broadcasts (default `true`).
    - Alternatively, a nested map with `:snippet`, `:cdn`, `:contentDetails`.
  - `opts`: Client options (`:token`, `:plug`, `:auto_refresh`, etc.).

  ## Returns
  - `{:ok, stream}` on success (including `cdn.ingestionInfo.streamName` and `ingestionAddress`).
  - `{:error, reason}` on failure.
  """
  @spec create_stream(create_stream_params(), client_opts()) :: {:ok, stream_item()} | {:error, term()}
  def create_stream(params, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    part = resolve_part(params_map, opts_map, @default_part)
    body = build_create_body(params_map)

    query_params =
      [part: part]
      |> maybe_put_query(:onBehalfOfContentOwner, params_map[:onBehalfOfContentOwner] || params_map[:on_behalf_of_content_owner])
      |> maybe_put_query(:onBehalfOfContentOwnerChannel, params_map[:onBehalfOfContentOwnerChannel] || params_map[:on_behalf_of_content_owner_channel])

    client_opts =
      opts_map
      |> Map.put(:params, query_params)
      |> Map.put(:json, body)

    Client.post("/liveStreams", client_opts)
  end

  @doc """
  Lists live streams.

  ## Parameters
  - `params`: Filter and pagination options:
    - `:mine` (boolean): List authenticated channel's streams (default `true` if no `:id`).
    - `:id` (string or list): Filter by stream ID(s).
    - `:max_results` / `:maxResults` (integer): Results per page (1..50).
    - `:page_token` / `:pageToken` (string): Token for page navigation.
    - `:part` (string or list): Resource parts to include.
  - `opts`: Client options.

  ## Returns
  - `{:ok, stream_list_response}` with `items` and pagination metadata.
  - `{:error, reason}` on failure.
  """
  @spec list_streams(list_streams_params(), client_opts()) :: {:ok, stream_list_response()} | {:error, term()}
  def list_streams(params \\ %{}, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    part = resolve_part(params_map, opts_map, @default_part)
    query_params = build_list_query_params(params_map, part)

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    Client.get("/liveStreams", client_opts)
  end

  @doc """
  Gets a single live stream by its ID.

  ## Parameters
  - `id`: Unique stream ID string.
  - `opts`: Client options (can include `:part`).

  ## Returns
  - `{:ok, stream}` on success (unwrapped from items list).
  - `{:error, :not_found}` if no stream exists with the given ID.
  - `{:error, reason}` on failure.
  """
  @spec get_stream(String.t(), client_opts()) :: {:ok, stream_item()} | {:error, term()}
  def get_stream(id, opts \\ %{}) when is_binary(id) and id != "" do
    opts_map = to_map(opts)
    part = resolve_part(opts_map, opts_map, @default_part)

    query_params =
      [part: part, id: id]
      |> maybe_put_query(:onBehalfOfContentOwner, opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner])
      |> maybe_put_query(:onBehalfOfContentOwnerChannel, opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel])

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    case Client.get("/liveStreams", client_opts) do
      {:ok, %{"items" => [stream | _]}} ->
        {:ok, stream}

      {:ok, %{"items" => []}} ->
        {:error, :not_found}

      {:ok, %{"kind" => "youtube#liveStream"} = stream} ->
        {:ok, stream}

      {:ok, other} ->
        {:ok, other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_stream(_id, _opts), do: {:error, :missing_stream_id}

  @doc """
  Updates an existing live stream's metadata or configuration.

  ## Parameters
  - `params`: Stream update parameters. Must contain `:id` (or `"id"`).
  - `opts`: Client options.

  ## Returns
  - `{:ok, updated_stream}` on success.
  - `{:error, :missing_stream_id}` if `id` is omitted.
  - `{:error, reason}` on failure.
  """
  @spec update_stream(update_stream_params(), client_opts()) :: {:ok, stream_item()} | {:error, term()}
  def update_stream(params, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    id = params_map[:id] || params_map["id"]

    if is_nil(id) or id == "" do
      {:error, :missing_stream_id}
    else
      part = resolve_part(params_map, opts_map, "snippet,cdn,contentDetails")
      body = build_update_body(params_map)

      query_params =
        [part: part]
        |> maybe_put_query(:onBehalfOfContentOwner, params_map[:onBehalfOfContentOwner] || params_map[:on_behalf_of_content_owner])
        |> maybe_put_query(:onBehalfOfContentOwnerChannel, params_map[:onBehalfOfContentOwnerChannel] || params_map[:on_behalf_of_content_owner_channel])

      client_opts =
        opts_map
        |> Map.put(:params, query_params)
        |> Map.put(:json, body)

      Client.put("/liveStreams", client_opts)
    end
  end

  @doc """
  Deletes an existing live stream.

  ## Parameters
  - `id`: Stream ID to delete.
  - `opts`: Client options.

  ## Returns
  - `{:ok, %{id: id, deleted: true}}` on successful deletion (HTTP 204).
  - `{:error, :missing_stream_id}` if `id` is invalid.
  - `{:error, reason}` on failure.
  """
  @spec delete_stream(String.t(), client_opts()) :: {:ok, map()} | {:error, term()}
  def delete_stream(id, opts \\ %{})

  def delete_stream(id, opts) when is_binary(id) and id != "" do
    opts_map = to_map(opts)

    query_params =
      [id: id]
      |> maybe_put_query(:onBehalfOfContentOwner, opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner])
      |> maybe_put_query(:onBehalfOfContentOwnerChannel, opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel])

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    case Client.delete("/liveStreams", client_opts) do
      {:ok, _body} -> {:ok, %{id: id, deleted: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_stream(_id, _opts), do: {:error, :missing_stream_id}

  # --- Stream Ingestion & Status Extractors ---

  @doc """
  Extracts the stream key (`streamName`) from a stream resource or `cdn` map.
  """
  @spec stream_key(map() | nil) :: String.t() | nil
  def stream_key(nil), do: nil
  def stream_key(%{"cdn" => %{"ingestionInfo" => %{"streamName" => key}}}), do: key
  def stream_key(%{cdn: %{ingestionInfo: %{streamName: key}}}), do: key
  def stream_key(%{cdn: %{ingestion_info: %{stream_name: key}}}), do: key
  def stream_key(%{"ingestionInfo" => %{"streamName" => key}}), do: key
  def stream_key(%{ingestionInfo: %{streamName: key}}), do: key
  def stream_key(%{ingestion_info: %{stream_name: key}}), do: key
  def stream_key(_), do: nil

  @doc """
  Extracts the primary RTMP ingestion address from a stream resource.
  """
  @spec ingestion_address(map() | nil) :: String.t() | nil
  def ingestion_address(nil), do: nil
  def ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"ingestionAddress" => addr}}}), do: addr
  def ingestion_address(%{cdn: %{ingestionInfo: %{ingestionAddress: addr}}}), do: addr
  def ingestion_address(%{cdn: %{ingestion_info: %{ingestion_address: addr}}}), do: addr
  def ingestion_address(%{"ingestionInfo" => %{"ingestionAddress" => addr}}), do: addr
  def ingestion_address(%{ingestionInfo: %{ingestionAddress: addr}}), do: addr
  def ingestion_address(%{ingestion_info: %{ingestion_address: addr}}), do: addr
  def ingestion_address(_), do: nil

  @doc """
  Extracts the backup RTMP ingestion address from a stream resource.
  """
  @spec backup_ingestion_address(map() | nil) :: String.t() | nil
  def backup_ingestion_address(nil), do: nil
  def backup_ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"backupIngestionAddress" => addr}}}), do: addr
  def backup_ingestion_address(%{cdn: %{ingestionInfo: %{backupIngestionAddress: addr}}}), do: addr
  def backup_ingestion_address(%{cdn: %{ingestion_info: %{backup_ingestion_address: addr}}}), do: addr
  def backup_ingestion_address(%{"ingestionInfo" => %{"backupIngestionAddress" => addr}}), do: addr
  def backup_ingestion_address(%{ingestionInfo: %{backupIngestionAddress: addr}}), do: addr
  def backup_ingestion_address(_), do: nil

  @doc """
  Extracts the secure primary RTMPS ingestion address from a stream resource.
  """
  @spec rtmps_ingestion_address(map() | nil) :: String.t() | nil
  def rtmps_ingestion_address(nil), do: nil
  def rtmps_ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"rtmpsIngestionAddress" => addr}}}), do: addr
  def rtmps_ingestion_address(%{cdn: %{ingestionInfo: %{rtmpsIngestionAddress: addr}}}), do: addr
  def rtmps_ingestion_address(%{cdn: %{ingestion_info: %{rtmps_ingestion_address: addr}}}), do: addr
  def rtmps_ingestion_address(%{"ingestionInfo" => %{"rtmpsIngestionAddress" => addr}}), do: addr
  def rtmps_ingestion_address(%{ingestionInfo: %{rtmpsIngestionAddress: addr}}), do: addr
  def rtmps_ingestion_address(_), do: nil

  @doc """
  Extracts the secure backup RTMPS ingestion address from a stream resource.
  """
  @spec rtmps_backup_ingestion_address(map() | nil) :: String.t() | nil
  def rtmps_backup_ingestion_address(nil), do: nil
  def rtmps_backup_ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"rtmpsBackupIngestionAddress" => addr}}}), do: addr
  def rtmps_backup_ingestion_address(%{cdn: %{ingestionInfo: %{rtmpsBackupIngestionAddress: addr}}}), do: addr
  def rtmps_backup_ingestion_address(%{cdn: %{ingestion_info: %{rtmps_backup_ingestion_address: addr}}}), do: addr
  def rtmps_backup_ingestion_address(%{"ingestionInfo" => %{"rtmpsBackupIngestionAddress" => addr}}), do: addr
  def rtmps_backup_ingestion_address(%{ingestionInfo: %{rtmpsBackupIngestionAddress: addr}}), do: addr
  def rtmps_backup_ingestion_address(_), do: nil

  @doc """
  Constructs the full RTMP/RTMPS stream URL by combining the ingestion address and stream key.

  ## Options
  - `:protocol`: `:rtmp` (default) or `:rtmps`
  - `:backup`: boolean (default `false`)
  """
  @spec stream_url(map() | nil, keyword() | map()) :: String.t() | nil
  def stream_url(nil, _opts), do: nil

  def stream_url(stream, opts \\ []) do
    opts_map = to_map(opts)
    protocol = Map.get(opts_map, :protocol, :rtmp)
    backup = Map.get(opts_map, :backup, false)

    key = stream_key(stream)

    addr =
      case {protocol, backup} do
        {:rtmps, true} -> rtmps_backup_ingestion_address(stream)
        {:rtmps, false} -> rtmps_ingestion_address(stream) || ingestion_address(stream)
        {_rtmp, true} -> backup_ingestion_address(stream)
        {_rtmp, false} -> ingestion_address(stream)
      end

    if is_binary(addr) and is_binary(key) and addr != "" and key != "" do
      base = String.trim_trailing(addr, "/")
      if String.contains?(base, "?") do
        [path, query] = String.split(base, "?", parts: 2)
        "#{path}/#{key}?#{query}"
      else
        "#{base}/#{key}"
      end
    else
      nil
    end
  end

  @doc """
  Extracts the streamStatus from a live stream (`"active"`, `"created"`, `"error"`, `"inactive"`, `"ready"`).
  """
  @spec stream_status(map() | nil) :: String.t() | nil
  def stream_status(nil), do: nil
  def stream_status(%{"status" => %{"streamStatus" => status}}), do: status
  def stream_status(%{status: %{streamStatus: status}}), do: status
  def stream_status(%{status: %{stream_status: status}}), do: status
  def stream_status(_), do: nil

  @doc """
  Extracts the stream health status (`"good"`, `"ok"`, `"bad"`, `"noData"`).
  """
  @spec health_status(map() | nil) :: String.t() | nil
  def health_status(nil), do: nil
  def health_status(%{"status" => %{"healthStatus" => %{"status" => status}}}), do: status
  def health_status(%{status: %{healthStatus: %{status: status}}}), do: status
  def health_status(%{status: %{health_status: %{status: status}}}), do: status
  def health_status(_), do: nil

  @doc """
  Returns true if the stream is currently actively transmitting data.
  """
  @spec active?(map() | nil) :: boolean()
  def active?(stream), do: stream_status(stream) == "active"

  @doc """
  Returns true if the stream is ready to receive data or actively receiving data.
  """
  @spec ready?(map() | nil) :: boolean()
  def ready?(stream), do: stream_status(stream) in ["ready", "active"]

  @doc """
  Returns true if the stream status is `"error"` or health status is `"bad"`.
  """
  @spec error?(map() | nil) :: boolean()
  def error?(stream), do: stream_status(stream) == "error" or health_status(stream) == "bad"

  # --- Private Builders & Normalization Helpers ---

  defp build_create_body(params) do
    snippet = build_snippet(params)
    cdn = build_cdn(params)
    content_details = build_content_details(params)

    %{}
    |> Map.put("snippet", snippet)
    |> Map.put("cdn", cdn)
    |> maybe_put_map("contentDetails", content_details)
  end

  defp build_update_body(params) do
    id = params[:id] || params["id"]

    body =
      %{"id" => id}
      |> maybe_put_map("snippet", build_snippet_for_update(params))
      |> maybe_put_map("cdn", build_cdn_for_update(params))
      |> maybe_put_map("contentDetails", build_content_details(params))

    body
  end

  defp build_snippet(params) do
    raw_snippet = params[:snippet] || params["snippet"] || %{}
    snippet_map = to_map(raw_snippet)

    title =
      params[:title] ||
        params["title"] ||
        snippet_map[:title] ||
        snippet_map["title"] ||
        "Live Stream #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    description =
      params[:description] ||
        params["description"] ||
        snippet_map[:description] ||
        snippet_map["description"] ||
        ""

    is_default =
      params[:is_default_stream] ||
        params[:isDefaultStream] ||
        snippet_map[:is_default_stream] ||
        snippet_map[:isDefaultStream] ||
        snippet_map["isDefaultStream"] ||
        false

    %{
      "title" => title,
      "description" => description,
      "isDefaultStream" => is_default
    }
  end

  defp build_snippet_for_update(params) do
    raw_snippet = params[:snippet] || params["snippet"]

    if raw_snippet || params[:title] || params[:description] do
      snippet_map = if raw_snippet, do: to_map(raw_snippet), else: %{}

      %{}
      |> maybe_put("title", params[:title] || snippet_map[:title] || snippet_map["title"])
      |> maybe_put("description", params[:description] || snippet_map[:description] || snippet_map["description"])
    else
      nil
    end
  end

  defp build_cdn(params) do
    raw_cdn = params[:cdn] || params["cdn"] || %{}
    cdn_map = to_map(raw_cdn)

    ingestion_type =
      params[:ingestion_type] ||
        params[:ingestionType] ||
        cdn_map[:ingestion_type] ||
        cdn_map[:ingestionType] ||
        cdn_map["ingestionType"] ||
        "rtmp"

    resolution =
      params[:resolution] ||
        cdn_map[:resolution] ||
        cdn_map["resolution"] ||
        "variable"

    frame_rate =
      params[:frame_rate] ||
        params[:frameRate] ||
        cdn_map[:frame_rate] ||
        cdn_map[:frameRate] ||
        cdn_map["frameRate"] ||
        "variable"

    %{
      "ingestionType" => to_string(ingestion_type),
      "resolution" => to_string(resolution),
      "frameRate" => to_string(frame_rate)
    }
  end

  defp build_cdn_for_update(params) do
    raw_cdn = params[:cdn] || params["cdn"]

    if raw_cdn || params[:resolution] || params[:frame_rate] || params[:frameRate] || params[:ingestion_type] do
      cdn_map = if raw_cdn, do: to_map(raw_cdn), else: %{}

      %{}
      |> maybe_put("ingestionType", params[:ingestion_type] || params[:ingestionType] || cdn_map[:ingestion_type] || cdn_map[:ingestionType] || cdn_map["ingestionType"])
      |> maybe_put("resolution", params[:resolution] || cdn_map[:resolution] || cdn_map["resolution"])
      |> maybe_put("frameRate", params[:frame_rate] || params[:frameRate] || cdn_map[:frame_rate] || cdn_map[:frameRate] || cdn_map["frameRate"])
    else
      nil
    end
  end

  defp build_content_details(params) do
    raw_cd = params[:content_details] || params[:contentDetails] || params["contentDetails"]

    if raw_cd || Map.has_key?(params, :is_reusable) || Map.has_key?(params, :isReusable) do
      cd_map = if raw_cd, do: to_map(raw_cd), else: %{}

      is_reusable =
        cond do
          Map.has_key?(params, :is_reusable) -> params[:is_reusable]
          Map.has_key?(params, :isReusable) -> params[:isReusable]
          Map.has_key?(cd_map, :is_reusable) -> cd_map[:is_reusable]
          Map.has_key?(cd_map, :isReusable) -> cd_map[:isReusable]
          Map.has_key?(cd_map, "isReusable") -> cd_map["isReusable"]
          true -> true
        end

      %{"isReusable" => is_reusable}
    else
      %{"isReusable" => true}
    end
  end

  defp build_list_query_params(params, part) do
    id_param = format_id_param(params[:id] || params["id"])

    base = [part: part]

    base =
      if is_binary(id_param) and id_param != "" do
        Keyword.put(base, :id, id_param)
      else
        mine =
          case Map.fetch(params, :mine) do
            {:ok, val} -> val
            :error -> Map.get(params, "mine", true)
          end

        Keyword.put(base, :mine, mine)
      end

    base
    |> maybe_put_query(:maxResults, params[:max_results] || params[:maxResults] || params["maxResults"])
    |> maybe_put_query(:pageToken, params[:page_token] || params[:pageToken] || params["pageToken"])
    |> maybe_put_query(:onBehalfOfContentOwner, params[:onBehalfOfContentOwner] || params[:on_behalf_of_content_owner])
    |> maybe_put_query(:onBehalfOfContentOwnerChannel, params[:onBehalfOfContentOwnerChannel] || params[:on_behalf_of_content_owner_channel])
  end

  defp format_id_param(nil), do: nil
  defp format_id_param(ids) when is_list(ids), do: Enum.join(ids, ",")
  defp format_id_param(id) when is_binary(id), do: id
  defp format_id_param(_), do: nil

  defp resolve_part(params, opts, default) do
    case params[:part] || params["part"] || opts[:part] || opts["part"] do
      nil -> default
      parts when is_list(parts) -> Enum.map_join(parts, ",", &to_string/1)
      part when is_binary(part) -> part
      _ -> default
    end
  end

  defp maybe_put_query(list, _key, nil), do: list
  defp maybe_put_query(list, key, value), do: Keyword.put(list, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, _key, empty_map) when map_size(empty_map) == 0, do: map
  defp maybe_put_map(map, key, submap), do: Map.put(map, key, submap)

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(_), do: %{}
end
```

---

## 5. Comprehensive Unit & Mock Test Plan (`live_streams_test.exs`)

Here is the complete specification for `test/unit/lux/integrations/youtube/live_streams_test.exs`:

```elixir
defmodule Lux.Integrations.YouTube.LiveStreamsTest do
  use UnitAPICase, async: true

  alias Lux.Integrations.YouTube.LiveStreams

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "create_stream/2" do
    test "creates a stream with flat parameters" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "part=snippet,cdn,status,contentDetails"
        assert decoded["snippet"]["title"] == "Primary OBS Stream"
        assert decoded["snippet"]["description"] == "Automated broadcast stream"
        assert decoded["cdn"]["ingestionType"] == "rtmp"
        assert decoded["cdn"]["resolution"] == "1080p"
        assert decoded["cdn"]["frameRate"] == "60fps"
        assert decoded["contentDetails"]["isReusable"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStream",
            "id" => "stream_created_123",
            "snippet" => %{
              "title" => "Primary OBS Stream",
              "description" => "Automated broadcast stream",
              "isDefaultStream" => false
            },
            "cdn" => %{
              "ingestionType" => "rtmp",
              "ingestionInfo" => %{
                "streamName" => "key-abcd-1234",
                "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
                "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
                "rtmpsIngestionAddress" => "rtmps://a.rtmp.youtube.com/live2",
                "rtmpsBackupIngestionAddress" => "rtmps://b.rtmp.youtube.com/live2?backup=1"
              },
              "resolution" => "1080p",
              "frameRate" => "60fps"
            },
            "status" => %{
              "streamStatus" => "ready",
              "healthStatus" => %{"status" => "noData"}
            },
            "contentDetails" => %{"isReusable" => true}
          })
        )
      end)

      params = %{
        title: "Primary OBS Stream",
        description: "Automated broadcast stream",
        ingestion_type: "rtmp",
        resolution: "1080p",
        frame_rate: "60fps",
        is_reusable: true
      }

      assert {:ok, stream} = LiveStreams.create_stream(params, token: "test_token")
      assert stream["id"] == "stream_created_123"
      assert LiveStreams.stream_key(stream) == "key-abcd-1234"
      assert LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"
      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key-abcd-1234"
    end

    test "creates a stream with structured nested payload and default fallback" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["cdn"]["resolution"] == "variable"
        assert decoded["cdn"]["frameRate"] == "variable"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "str_default"}))
      end)

      assert {:ok, %{"id" => "str_default"}} =
               LiveStreams.create_stream(%{title: "Quick Stream"}, token: "tok")
    end

    test "handles quotaExceeded error from Client" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "errors" => [%{"reason" => "quotaExceeded", "message" => "Quota exceeded"}]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveStreams.create_stream(%{title: "Fails"}, token: "tok")

      assert details.reason == "quotaExceeded"
    end
  end

  describe "list_streams/2" do
    test "lists streams with mine=true default and pagination" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveStreams"
        assert conn.query_string =~ "mine=true"
        assert conn.query_string =~ "maxResults=10"
        assert conn.query_string =~ "pageToken=tok_next"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStreamListResponse",
            "items" => [
              %{"id" => "str_1", "status" => %{"streamStatus" => "active"}},
              %{"id" => "str_2", "status" => %{"streamStatus" => "ready"}}
            ],
            "nextPageToken" => "tok_page_2"
          })
        )
      end)

      params = %{max_results: 10, page_token: "tok_next"}
      assert {:ok, resp} = LiveStreams.list_streams(params, token: "tok")
      assert length(resp["items"]) == 2
      assert resp["nextPageToken"] == "tok_page_2"
    end

    test "lists streams filtered by multiple IDs list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "id=id1%2Cid2"
        refute conn.query_string =~ "mine=true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [%{"id" => "id1"}]}))
      end)

      assert {:ok, resp} = LiveStreams.list_streams(%{id: ["id1", "id2"]}, token: "tok")
      assert length(resp["items"]) == 1
    end
  end

  describe "get_stream/2" do
    test "fetches single stream and unwraps items list" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.query_string =~ "id=str_target"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveStreamListResponse",
            "items" => [
              %{
                "id" => "str_target",
                "snippet" => %{"title" => "Target Stream"},
                "status" => %{"streamStatus" => "active", "healthStatus" => %{"status" => "good"}}
              }
            ]
          })
        )
      end)

      assert {:ok, stream} = LiveStreams.get_stream("str_target", token: "tok")
      assert stream["id"] == "str_target"
      assert LiveStreams.active?(stream) == true
      assert LiveStreams.health_status(stream) == "good"
    end

    test "returns {:error, :not_found} when stream list is empty" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:error, :not_found} = LiveStreams.get_stream("nonexistent", token: "tok")
    end

    test "returns error on missing ID" do
      assert {:error, :missing_stream_id} = LiveStreams.get_stream("", token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.get_stream(nil, token: "tok")
    end
  end

  describe "update_stream/2" do
    test "updates stream metadata with PUT request" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "PUT"
        assert decoded["id"] == "stream_to_update"
        assert decoded["snippet"]["title"] == "Updated Title"
        assert decoded["cdn"]["resolution"] == "720p"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "stream_to_update",
            "snippet" => %{"title" => "Updated Title"},
            "cdn" => %{"resolution" => "720p"}
          })
        )
      end)

      params = %{
        id: "stream_to_update",
        title: "Updated Title",
        resolution: "720p"
      }

      assert {:ok, updated} = LiveStreams.update_stream(params, token: "tok")
      assert updated["snippet"]["title"] == "Updated Title"
    end

    test "returns error when ID is missing in update" do
      assert {:error, :missing_stream_id} = LiveStreams.update_stream(%{title: "New"}, token: "tok")
    end
  end

  describe "delete_stream/2" do
    test "deletes stream and returns confirmation map" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "DELETE"
        assert conn.query_string =~ "id=str_to_delete"

        conn
        |> Plug.Conn.send_resp(204, "")
      end)

      assert {:ok, %{id: "str_to_delete", deleted: true}} =
               LiveStreams.delete_stream("str_to_delete", token: "tok")
    end

    test "returns error when ID is missing in delete" do
      assert {:error, :missing_stream_id} = LiveStreams.delete_stream("", token: "tok")
      assert {:error, :missing_stream_id} = LiveStreams.delete_stream(nil, token: "tok")
    end
  end

  describe "helpers & extractors" do
    setup do
      stream = %{
        "kind" => "youtube#liveStream",
        "id" => "str_h",
        "cdn" => %{
          "ingestionType" => "rtmp",
          "ingestionInfo" => %{
            "streamName" => "key-test-123",
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "rtmpsIngestionAddress" => "rtmps://a.rtmp.youtube.com/live2",
            "rtmpsBackupIngestionAddress" => "rtmps://b.rtmp.youtube.com/live2?backup=1"
          }
        },
        "status" => %{
          "streamStatus" => "active",
          "healthStatus" => %{
            "status" => "good",
            "configurationIssues" => []
          }
        }
      }

      {:ok, stream: stream}
    end

    test "extracts stream key and ingestion addresses", %{stream: stream} do
      assert LiveStreams.stream_key(stream) == "key-test-123"
      assert LiveStreams.ingestion_address(stream) == "rtmp://a.rtmp.youtube.com/live2"
      assert LiveStreams.backup_ingestion_address(stream) == "rtmp://b.rtmp.youtube.com/live2?backup=1"
      assert LiveStreams.rtmps_ingestion_address(stream) == "rtmps://a.rtmp.youtube.com/live2"
      assert LiveStreams.rtmps_backup_ingestion_address(stream) == "rtmps://b.rtmp.youtube.com/live2?backup=1"
    end

    test "constructs full stream URLs correctly", %{stream: stream} do
      assert LiveStreams.stream_url(stream) == "rtmp://a.rtmp.youtube.com/live2/key-test-123"
      assert LiveStreams.stream_url(stream, protocol: :rtmps) == "rtmps://a.rtmp.youtube.com/live2/key-test-123"
      assert LiveStreams.stream_url(stream, backup: true) == "rtmp://b.rtmp.youtube.com/live2/key-test-123?backup=1"
      assert LiveStreams.stream_url(stream, protocol: :rtmps, backup: true) == "rtmps://b.rtmp.youtube.com/live2/key-test-123?backup=1"
    end

    test "evaluates health and readiness predicates", %{stream: stream} do
      assert LiveStreams.stream_status(stream) == "active"
      assert LiveStreams.health_status(stream) == "good"
      assert LiveStreams.active?(stream) == true
      assert LiveStreams.ready?(stream) == true
      assert LiveStreams.error?(stream) == false

      error_stream = %{
        "status" => %{
          "streamStatus" => "error",
          "healthStatus" => %{"status" => "bad"}
        }
      }

      assert LiveStreams.active?(error_stream) == false
      assert LiveStreams.ready?(error_stream) == false
      assert LiveStreams.error?(error_stream) == true
    end

    test "handles nil inputs safely" do
      assert LiveStreams.stream_key(nil) == nil
      assert LiveStreams.ingestion_address(nil) == nil
      assert LiveStreams.stream_url(nil) == nil
      assert LiveStreams.stream_status(nil) == nil
      assert LiveStreams.health_status(nil) == nil
      assert LiveStreams.active?(nil) == false
      assert LiveStreams.ready?(nil) == false
      assert LiveStreams.error?(nil) == false
    end
  end
end
```

---

## 6. End-to-End Workflow Integration with Live Broadcasts

In Milestone 2, the complete live streaming workflow coordinates between `LiveBroadcasts` and `LiveStreams`:

```elixir
# 1. Create the Live Broadcast
{:ok, broadcast} = Lux.Integrations.YouTube.LiveBroadcasts.create_broadcast(%{
  title: "AI Autonomous Stream",
  scheduled_start_time: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
  privacy_status: "unlisted"
}, token: access_token)

# 2. Create the Live Stream Ingestion Point
{:ok, stream} = Lux.Integrations.YouTube.LiveStreams.create_stream(%{
  title: "AI Ingestion Point",
  resolution: "1080p",
  frame_rate: "60fps",
  ingestion_type: "rtmp"
}, token: access_token)

# 3. Bind the Stream to the Broadcast
{:ok, bound_broadcast} = Lux.Integrations.YouTube.LiveBroadcasts.bind_broadcast(
  broadcast["id"],
  stream["id"],
  token: access_token
)

# 4. Extract RTMP destination for encoder (e.g. OBS/FFmpeg)
rtmp_url = Lux.Integrations.YouTube.LiveStreams.stream_url(stream)
# Encoder streams to rtmp_url...

# 5. Transition Broadcast to Live
{:ok, live_broadcast} = Lux.Integrations.YouTube.LiveBroadcasts.transition_broadcast(
  broadcast["id"],
  "live",
  token: access_token
)

# 6. At conclusion, transition to complete
{:ok, finished_broadcast} = Lux.Integrations.YouTube.LiveBroadcasts.transition_broadcast(
  broadcast["id"],
  "complete",
  token: access_token
)
```

---

## 7. Actionable Implementation Checklist for Implementer

1. **`lib/lux/integrations/youtube/live_streams.ex`**:
   - Implement `Lux.Integrations.YouTube.LiveStreams` according to Section 4.
2. **`test/unit/lux/integrations/youtube/live_streams_test.exs`**:
   - Implement comprehensive unit tests using `UnitAPICase` and `Req.Test` according to Section 5.
3. **Compilation & Test Verification**:
   - `mix compile --warnings-as-errors`
   - `mix test test/unit/lux/integrations/youtube/live_streams_test.exs`
