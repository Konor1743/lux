# Milestone 2: Live Broadcast & Stream Workflow Integration, Challenger Review & Test Design

**Author**: Explorer 3 (Milestone 2)  
**Date**: 2026-08-17  
**Scope**:
1. Architecture and combined workflow design for YouTube Live Streaming (`LiveBroadcasts`, `LiveStreams`, `bind_broadcast`, lifecycle transitions).
2. Challenger 1 & 2 findings review and exact code refinements for `Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube.Errors`, and `Lux.Integrations.YouTube`.
3. Comprehensive end-to-end unit test design with `Req.Test` covering the complete Live Streaming lifecycle, edge cases, and resiliency.

---

## 1. Executive Summary

Milestone 2 expands the Lux YouTube integration from basic OAuth and generic HTTP client operations into domain-specific Live Streaming management. YouTube separates live streaming into two core decoupled entities:
- **`LiveBroadcast`**: The viewer-facing container, metadata (title, description, start time, privacy), live chat room (`liveChatId`), and public playback lifecycle.
- **`LiveStream`**: The technical encoder ingestion pipeline, containing RTMP/RTMPS endpoints (`ingestionAddress`), stream keys (`streamName`), and codec/resolution configurations.

These entities are bound together via the `POST /liveBroadcasts/bind` API and orchestrated through a 4-state lifecycle machine (`created`/`ready` $\to$ `testing` $\to$ `live` $\to$ `complete`).

Simultaneously, adversarial findings from Milestone 1 Challengers 1 & 2 revealed critical and high-severity edge cases in URL formatting, unmanaged 45s synchronous sleep in Req on 429 rate limits, gRPC multi-detail quota drop, and arithmetic float overflow. This report synthesizes the combined workflow design, provides exact code fixes for `Client` and `Errors`, and specifies a comprehensive `Req.Test` test harness.

---

## 2. Combined Live Streaming Workflow Architecture

### 2.1 Workflow Sequence Diagram

```
+---------------------------------------------------------------------------------------------------+
|                                  Lux Autonomous Agent / Workflow                                   |
+---------------------------------------------------------------------------------------------------+
       |                                      |                                    |
       | 1. create_broadcast/2                | 2. create_stream/2                 |
       v                                      v                                    |
+------------------------------+       +-----------------------------+             |
| YouTube API: liveBroadcasts  |       | YouTube API: liveStreams    |             |
| (Title, Privacy, AutoStart)  |       | (RTMP, 1080p60, Ingestion)  |             |
+------------------------------+       +-----------------------------+             |
       |                                      |                                    |
       | Returns broadcast_id                 | Returns stream_id                  |
       | & live_chat_id                       | & ingestionAddress, streamName     |
       \--------------------------------------/                                    |
                          |                                                        |
                          | 3. bind_broadcast(broadcast_id, stream_id)             |
                          v                                                        |
       +-------------------------------------------------------------+             |
       | YouTube API: liveBroadcasts/bind                            |             |
       | (Binds encoder ingestion pipe to viewer broadcast entity)   |             |
       +-------------------------------------------------------------+             |
                          |                                                        |
                          | 4. External Video Encoder / Media Pipeline             |
                          v (Transmits RTMP frames to ingestionAddress/streamName) |
       +-------------------------------------------------------------+             |
       | Ingestion Active (YouTube receives audio/video stream)      |             |
       +-------------------------------------------------------------+             |
                          |                                                        |
                          | 5. transition_broadcast(id, :testing) [Optional]        |
                          v (Enables private preview / monitor stream)             |
       +-------------------------------------------------------------+             |
       | Status: "testing"                                           |             |
       +-------------------------------------------------------------+             |
                          |                                                        |
                          | 6. transition_broadcast(id, :live)                     |
                          v (Broadcast goes live to public viewers)                |
       +-------------------------------------------------------------+             |
       | Status: "live" -> Active Live Chat via live_chat_id         | <-----------+
       +-------------------------------------------------------------+
                          |
                          | 7. transition_broadcast(id, :complete)
                          v (Terminates broadcast, archives to VOD)
       +-------------------------------------------------------------+
       | Status: "complete" (Terminal state)                         |
       +-------------------------------------------------------------+
```

---

### 2.2 Detailed Step-by-Step API Specification

#### Step 1: Create Broadcast (`LiveBroadcasts.create_broadcast/2`)
- **HTTP Method & Path**: `POST /youtube/v3/liveBroadcasts?part=snippet,status,contentDetails`
- **Request Headers**: `Authorization: Bearer <token>`, `Content-Type: application/json`
- **Payload Schema**:
  ```json
  {
    "snippet": {
      "title": "Autonomous Agent Livestream",
      "description": "Live streaming AI agent reasoning and task execution.",
      "scheduledStartTime": "2026-08-17T20:00:00.000Z",
      "defaultLanguage": "en"
    },
    "status": {
      "privacyStatus": "public",
      "selfDeclaredMadeForKids": false
    },
    "contentDetails": {
      "enableAutoStart": true,
      "enableAutoStop": true,
      "enableDvr": true,
      "enableContentEncryption": false,
      "enableEmbed": true,
      "recordFromStart": true,
      "latencyPreference": "low",
      "monitorStream": {
        "enableMonitorStream": false,
        "broadcastStreamDelayMs": 0
      }
    }
  }
  ```
- **Response Extracted Data**:
  - `id`: The unique broadcast ID (e.g. `"bcast_abc123"`).
  - `snippet.liveChatId`: Unique identifier for the live chat room (crucial bridge to Milestone 3 `LiveChat.Poller`).
  - `status.lifeCycleStatus`: Initial status (`"created"` or `"ready"`).

#### Step 2: Create Stream (`LiveStreams.create_stream/2`)
- **HTTP Method & Path**: `POST /youtube/v3/liveStreams?part=snippet,cdn,status,contentDetails`
- **Payload Schema**:
  ```json
  {
    "snippet": {
      "title": "Agent Ingestion Stream 1080p60",
      "description": "Primary RTMP stream ingestion"
    },
    "cdn": {
      "ingestionType": "rtmp",
      "resolution": "1080p",
      "frameRate": "60fps"
    }
  }
  ```
- **Response Extracted Data**:
  - `id`: The unique stream ID (e.g. `"stream_xyz789"`).
  - `cdn.ingestionInfo.ingestionAddress`: Primary RTMP URL (e.g. `"rtmp://a.rtmp.youtube.com/live2"`).
  - `cdn.ingestionInfo.backupIngestionAddress`: Secondary RTMP URL (e.g. `"rtmp://b.rtmp.youtube.com/live2?backup=1"`).
  - `cdn.ingestionInfo.streamName`: Secret RTMP stream key (e.g. `"xxxx-xxxx-xxxx-xxxx-xxxx"`).
  - `status.streamStatus`: Current ingestion health (`"ready"`, `"active"`, `"inactive"`).

#### Step 3: Bind Stream to Broadcast (`LiveBroadcasts.bind_broadcast/3`)
- **HTTP Method & Path**: `POST /youtube/v3/liveBroadcasts/bind?id=<broadcast_id>&streamId=<stream_id>&part=id,snippet,contentDetails,status`
- **Request Body**: Empty (`{}` or nil)
- **Response**: The updated Broadcast resource where `contentDetails.boundStreamId` matches `<stream_id>`.
- **Unbinding**: Calling `bind_broadcast(broadcast_id, nil, opts)` or omitting `streamId` unbinds the stream from the broadcast.

#### Step 4: Broadcast Lifecycle Transitions (`LiveBroadcasts.transition_broadcast/3`)
- **HTTP Method & Path**: `POST /youtube/v3/liveBroadcasts/transition?broadcastStatus=<status>&id=<broadcast_id>&part=id,snippet,contentDetails,status`
- **Supported Statuses**:
  1. `:testing` / `"testing"`: Transitions broadcast into testing mode. Preview video is routed to Studio monitor stream. Requires active RTMP ingestion.
  2. `:live` / `"live"`: Broadcast transitions to public live streaming.
  3. `:complete` / `"complete"`: Broadcast ends. Permanent state transition.
- **State Machine Rules & Error Responses**:
  - Transitioning to `:testing` or `:live` before the encoder has established RTMP ingestion results in HTTP 400 `streamInactive` or `invalidTransition`.
  - Transitioning to an already active state returns HTTP 400 `redundantTransition`.
  - Once `:complete` is reached, YouTube seals the broadcast; no further transitions are permitted.

---

### 2.3 Parameter Normalization & Developer Experience

To make API calls idiomatic in Elixir while supporting standard Google JSON schemas, `LiveBroadcasts` and `LiveStreams` must support both `snake_case` atom keys and camelCase string keys.

```elixir
defmodule Lux.Integrations.YouTube.Utils do
  @doc "Recursively converts snake_case atom map keys to camelCase string keys."
  def to_camel_case(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) ->
        {camelize(Atom.to_string(k)), to_camel_case(v)}

      {k, v} when is_binary(k) ->
        {k, to_camel_case(v)}

      other ->
        other
    end)
  end

  def to_camel_case(list) when is_list(list), do: Enum.map(list, &to_camel_case/1)
  def to_camel_case(val), do: val

  defp camelize(string) do
    case String.split(string, "_") do
      [first | rest] ->
        first <> Enum.map_join(rest, &String.capitalize/1)
      [] -> ""
    end
  end
end
```

---

## 3. Challenger 1 & 2 Findings Review & Exact Refinements

A critical objective for Milestone 2 is hardening `Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube.Errors`, and `Lux.Integrations.YouTube` against the vulnerabilities identified by Challengers 1 & 2.

### Summary Matrix of Challenger Findings

| # | Finding | Severity | Source | Root Cause | Proposed Fix |
|---|---|---|---|---|---|
| 1 | URL Concatenation Bug without Leading Slash | **Critical** | Challenger 1 | `build_url/1` did `@endpoint <> path` directly. | Ensure leading slash when concatenating relative paths. |
| 2 | Req Default Synchronous Sleep on 429 `Retry-After` | **High** | Challenger 2 | Req defaults `:retry` to `:safe_transient`, sleeping 45s synchronously. | Default `:retry` to `false` in `Client.request/3`. |
| 3 | Quota Drop in Multi-Item gRPC Error Details | **High** | Challenger 1 & 2 | `extract_error_info/1` only inspected the head element of `details`. | Search entire `details` list for reason, domain, and message. |
| 4 | `RESOURCE_EXHAUSTED` Status Code Drop | **Medium-High** | Challenger 1 & 2 | `"RESOURCE_EXHAUSTED"` was missing from `@quota_reasons`. | Add `"RESOURCE_EXHAUSTED"` to `@quota_reasons`. |
| 5 | Atom-Keyed Error Map Fallback | **Medium** | Challenger 2 | `extract_error_info/1` only matched `%{"error" => ...}` string keys. | Add clauses supporting atom-keyed error structures. |
| 6 | Large HTML Error Page Leakage to LLM | **Medium** | Challenger 2 | Raw HTML 500/502 error bodies copied directly into error messages. | Sanitize/summarize HTML bodies in `classify/4`. |
| 7 | Arithmetic Overflow in `backoff_delay/2` at `attempt >= 1025` | **Low** | Challenger 1 & 2 | `:math.pow(2, attempt - 1)` exceeded 64-bit float limit. | Clamp exponent to `min(max(0, attempt - 1), 30)`. |
| 8 | Lens `headers: nil` Concatenation Crash | **Medium** | Challenger 1 | `lens.headers ++ [...]` raised when headers was `nil`. | Default `(lens.headers || []) ++ [...]`. |
| 9 | Non-Binary Scopes in `OAuth.authorize_url/1` | **Low** | Challenger 1 | `Enum.join(scopes, " ")` failed on atom list. | Use `Enum.map_join(scopes, " ", &to_string/1)`. |

---

### Exact Code Refinements

#### Refinement 1: `Lux.Integrations.YouTube.Client`
```elixir
# File: lib/lux/integrations/youtube/client.ex

# 1. Update req_options to disable Req's implicit retry by default (prevents 45s freeze on 429)
req_options =
  [
    method: method,
    url: build_url(path),
    headers: headers,
    params: params,
    json: opts_map[:json],
    retry: Map.get(opts_map, :retry, false)
  ]
  |> maybe_put_body(opts_map[:body])
  |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
  |> maybe_add_plug(opts_map[:plug])

# 2. Fix build_url/1 to safely handle paths with or without leading slash
defp build_url(path) when is_binary(path) do
  cond do
    String.starts_with?(path, "http://") or String.starts_with?(path, "https://") ->
      path

    String.starts_with?(path, "/") ->
      @endpoint <> path

    true ->
      @endpoint <> "/" <> path
  end
end
```

#### Refinement 2: `Lux.Integrations.YouTube.Errors`
```elixir
# File: lib/lux/integrations/youtube/errors.ex

# 1. Expand @quota_reasons to include gRPC RESOURCE_EXHAUSTED
@quota_reasons [
  "quotaExceeded",
  "dailyLimitExceeded",
  "QUOTA_EXCEEDED",
  "RESOURCE_EXHAUSTED_QUOTA",
  "RESOURCE_EXHAUSTED"
]

# 2. Fix backoff_delay/2 to prevent ArithmeticError on large attempts
def backoff_delay(attempt, opts \\ []) do
  base = Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms)
  max_delay = Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
  min_delay = Keyword.get(opts, :min_backoff_ms, 50)

  clamped_exp = min(max(0, attempt - 1), 30)
  temp_delay = min(max_delay, trunc(base * :math.pow(2, clamped_exp)))
  jitter_factor = :rand.uniform()
  max(min_delay, trunc(jitter_factor * temp_delay))
end

# 3. Enhance extract_error_info to search all details and support atom keys
defp extract_error_info(%{"error" => %{} = error_map}) do
  first_error =
    case error_map["errors"] do
      [first | _] when is_map(first) -> first
      _ -> %{}
    end

  {detail_reason, detail_domain, detail_msg} = extract_from_details_list(error_map["details"])

  reason =
    first_error["reason"] ||
      detail_reason ||
      error_map["reason"] ||
      error_map["status"]

  domain = first_error["domain"] || detail_domain
  message = error_map["message"] || first_error["message"] || detail_msg

  %{reason: reason, domain: domain, message: message, error_description: nil}
end

defp extract_error_info(%{error: %{} = error_map}) do
  first_error =
    case error_map[:errors] || error_map["errors"] do
      [first | _] when is_map(first) -> first
      _ -> %{}
    end

  details = error_map[:details] || error_map["details"]
  {detail_reason, detail_domain, detail_msg} = extract_from_details_list(details)

  reason =
    first_error[:reason] || first_error["reason"] ||
      detail_reason ||
      error_map[:reason] || error_map["reason"] ||
      error_map[:status] || error_map["status"]

  domain = first_error[:domain] || first_error["domain"] || detail_domain
  message = error_map[:message] || error_map["message"] || first_error[:message] || first_error["message"] || detail_msg

  %{reason: reason, domain: domain, message: message, error_description: nil}
end

defp extract_from_details_list(details) when is_list(details) do
  reason =
    Enum.find_value(details, fn
      %{"reason" => r} when is_binary(r) and r != "" -> r
      %{reason: r} when is_binary(r) and r != "" -> r
      _ -> nil
    end)

  domain =
    Enum.find_value(details, fn
      %{"domain" => d} when is_binary(d) and d != "" -> d
      %{domain: d} when is_binary(d) and d != "" -> d
      _ -> nil
    end)

  msg =
    Enum.find_value(details, fn
      %{"message" => m} when is_binary(m) and m != "" -> m
      %{message: m} when is_binary(m) and m != "" -> m
      _ -> nil
    end)

  {reason, domain, msg}
end
defp extract_from_details_list(_), do: {nil, nil, nil}

# 4. Add HTML payload summarization to prevent prompt pollution
defp sanitize_message(status, message) when is_binary(message) do
  trimmed = String.trim(message)
  cond do
    String.starts_with?(trimmed, "<!DOCTYPE") or String.starts_with?(trimmed, "<html") ->
      "<HTML Error Page: #{status} #{default_message_for_status(status)}>"

    byte_size(trimmed) > 1000 ->
      String.slice(trimmed, 0, 997) <> "..."

    true ->
      trimmed
  end
end
defp sanitize_message(status, _), do: default_message_for_status(status)
```

#### Refinement 3: `Lux.Integrations.YouTube`
```elixir
# File: lib/lux/integrations/youtube.ex

def add_auth_header(%Lux.Lens{} = lens) do
  token =
    try do
      Lux.Config.youtube_access_token()
    rescue
      _ -> nil
    end

  if token && token != "" do
    existing_headers = lens.headers || []
    %{lens | headers: existing_headers ++ [{"Authorization", "Bearer #{token}"}]}
  else
    # ...
  end
end
```

---

## 4. `LiveBroadcasts` & `LiveStreams` Module Interface Contracts

### 4.1 `Lux.Integrations.YouTube.LiveBroadcasts`

```elixir
defmodule Lux.Integrations.YouTube.LiveBroadcasts do
  @moduledoc """
  Manages YouTube Live Broadcasts (events, metadata, lifecycle transitions, and stream binding).
  """

  alias Lux.Integrations.YouTube.Client

  @type broadcast_id :: String.t()
  @type stream_id :: String.t()
  @type lifecycle_status :: :testing | :live | :complete | String.t()
  @type broadcast_status :: :all | :active | :completed | :upcoming | String.t()
  @type broadcast_type :: :all | :event | :persistent | String.t()

  @doc "Creates a new live broadcast."
  @spec create_broadcast(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def create_broadcast(params, opts \\ %{})

  @doc "Retrieves a single broadcast by ID."
  @spec get_broadcast(broadcast_id(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def get_broadcast(id, opts \\ %{})

  @doc "Lists broadcasts filtered by broadcastStatus or broadcastType."
  @spec list_broadcasts(map() | keyword(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def list_broadcasts(params \\ %{}, opts \\ %{})

  @doc "Updates an existing broadcast's metadata."
  @spec update_broadcast(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def update_broadcast(params, opts \\ %{})

  @doc "Binds a live stream to a live broadcast."
  @spec bind_broadcast(broadcast_id(), stream_id() | nil, keyword() | map()) :: {:ok, map()} | {:error, term()}
  def bind_broadcast(broadcast_id, stream_id, opts \\ %{})

  @doc "Transitions a broadcast's lifecycle status (testing, live, complete)."
  @spec transition_broadcast(broadcast_id(), lifecycle_status(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def transition_broadcast(broadcast_id, status, opts \\ %{})

  @doc "Deletes a broadcast."
  @spec delete_broadcast(broadcast_id(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def delete_broadcast(id, opts \\ %{})
end
```

### 4.2 `Lux.Integrations.YouTube.LiveStreams`

```elixir
defmodule Lux.Integrations.YouTube.LiveStreams do
  @moduledoc """
  Manages YouTube Live Streams (RTMP ingestion points, CDN settings, and stream keys).
  """

  alias Lux.Integrations.YouTube.Client

  @type stream_id :: String.t()

  @doc "Creates a new live stream (ingestion point)."
  @spec create_stream(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def create_stream(params, opts \\ %{})

  @doc "Retrieves a single live stream by ID."
  @spec get_stream(stream_id(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def get_stream(id, opts \\ %{})

  @doc "Lists live streams belonging to the authenticated channel."
  @spec list_streams(map() | keyword(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def list_streams(params \\ %{}, opts \\ %{})

  @doc "Updates a live stream's metadata or CDN configuration."
  @spec update_stream(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def update_stream(params, opts \\ %{})

  @doc "Deletes a live stream."
  @spec delete_stream(stream_id(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def delete_stream(id, opts \\ %{})
end
```

---

## 5. End-to-End Unit Test Suite Design (`Req.Test`)

To ensure complete coverage and verify the live streaming workflow and hardening fixes, the test suite is structured into 4 comprehensive test files:
1. `test/unit/lux/integrations/youtube/live_broadcasts_test.exs`
2. `test/unit/lux/integrations/youtube/live_streams_test.exs`
3. `test/unit/lux/integrations/youtube/live_workflow_test.exs` (Full E2E setup pipeline)
4. Updated `client_test.exs` and `errors_test.exs` (verifying all challenger mitigations).

### 5.1 Complete Workflow Test Scenario (`live_workflow_test.exs`)

```elixir
defmodule Lux.Integrations.YouTube.LiveWorkflowTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{LiveBroadcasts, LiveStreams}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "executes complete 4-step live stream setup and lifecycle management" do
    # Step 1: Mock create_broadcast
    Req.Test.expect(YouTubeClientMock, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/youtube/v3/liveBroadcasts"
      assert conn.query_string =~ "part=snippet%2Cstatus%2CcontentDetails" or conn.query_string =~ "part="
      
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["snippet"]["title"] == "Autonomous Agent Stream"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{
        "kind" => "youtube#liveBroadcast",
        "id" => "bcast_12345",
        "snippet" => %{
          "title" => "Autonomous Agent Stream",
          "liveChatId" => "chat_abc_999"
        },
        "status" => %{"lifeCycleStatus" => "ready"},
        "contentDetails" => %{"boundStreamId" => nil}
      }))
    end)

    # Step 2: Mock create_stream
    Req.Test.expect(YouTubeClientMock, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/youtube/v3/liveStreams"
      
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["cdn"]["ingestionType"] == "rtmp"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{
        "kind" => "youtube#liveStream",
        "id" => "stream_67890",
        "cdn" => %{
          "ingestionInfo" => %{
            "ingestionAddress" => "rtmp://a.rtmp.youtube.com/live2",
            "backupIngestionAddress" => "rtmp://b.rtmp.youtube.com/live2?backup=1",
            "streamName" => "key_live_secret"
          }
        },
        "status" => %{"streamStatus" => "ready"}
      }))
    end)

    # Step 3: Mock bind_broadcast
    Req.Test.expect(YouTubeClientMock, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/youtube/v3/liveBroadcasts/bind"
      assert conn.query_string =~ "id=bcast_12345"
      assert conn.query_string =~ "streamId=stream_67890"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{
        "kind" => "youtube#liveBroadcast",
        "id" => "bcast_12345",
        "contentDetails" => %{"boundStreamId" => "stream_67890"}
      }))
    end)

    # Step 4a: Mock transition to testing
    Req.Test.expect(YouTubeClientMock, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
      assert conn.query_string =~ "broadcastStatus=testing"
      assert conn.query_string =~ "id=bcast_12345"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{
        "kind" => "youtube#liveBroadcast",
        "id" => "bcast_12345",
        "status" => %{"lifeCycleStatus" => "testing"}
      }))
    end)

    # Step 4b: Mock transition to live
    Req.Test.expect(YouTubeClientMock, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
      assert conn.query_string =~ "broadcastStatus=live"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{
        "kind" => "youtube#liveBroadcast",
        "id" => "bcast_12345",
        "status" => %{"lifeCycleStatus" => "live"}
      }))
    end)

    # Step 4c: Mock transition to complete
    Req.Test.expect(YouTubeClientMock, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/youtube/v3/liveBroadcasts/transition"
      assert conn.query_string =~ "broadcastStatus=complete"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{
        "kind" => "youtube#liveBroadcast",
        "id" => "bcast_12345",
        "status" => %{"lifeCycleStatus" => "complete"}
      }))
    end)

    opts = [token: "test_oauth_token"]

    # 1. Create Broadcast
    assert {:ok, broadcast} = LiveBroadcasts.create_broadcast(%{
      snippet: %{title: "Autonomous Agent Stream", scheduledStartTime: "2026-08-17T20:00:00Z"},
      status: %{privacyStatus: "public"}
    }, opts)
    assert broadcast["id"] == "bcast_12345"
    assert broadcast["snippet"]["liveChatId"] == "chat_abc_999"

    # 2. Create Stream
    assert {:ok, stream} = LiveStreams.create_stream(%{
      snippet: %{title: "Agent Stream"},
      cdn: %{ingestionType: "rtmp", resolution: "1080p", frameRate: "60fps"}
    }, opts)
    assert stream["id"] == "stream_67890"
    assert stream["cdn"]["ingestionInfo"]["streamName"] == "key_live_secret"

    # 3. Bind
    assert {:ok, bound} = LiveBroadcasts.bind_broadcast(broadcast["id"], stream["id"], opts)
    assert bound["contentDetails"]["boundStreamId"] == "stream_67890"

    # 4. Lifecycle Transitions
    assert {:ok, testing_bcast} = LiveBroadcasts.transition_broadcast(broadcast["id"], :testing, opts)
    assert testing_bcast["status"]["lifeCycleStatus"] == "testing"

    assert {:ok, live_bcast} = LiveBroadcasts.transition_broadcast(broadcast["id"], :live, opts)
    assert live_bcast["status"]["lifeCycleStatus"] == "live"

    assert {:ok, completed_bcast} = LiveBroadcasts.transition_broadcast(broadcast["id"], :complete, opts)
    assert completed_bcast["status"]["lifeCycleStatus"] == "complete"
  end
end
```

---

### 5.2 Adversarial & Edge Case Test Matrix for Milestone 2

| # | Test Module | Test Case Description | Injected Condition | Expected Result |
|---|---|---|---|---|
| 1 | `LiveBroadcastsTest` | `create_broadcast` relative path without leading slash | Path `"liveBroadcasts"` | Correct URL `/youtube/v3/liveBroadcasts` without 404. |
| 2 | `LiveBroadcastsTest` | `bind_broadcast` with non-existent stream ID | Mock returns 404 `streamNotFound` | Returns `{:error, {404, message}}`. |
| 3 | `LiveBroadcastsTest` | `transition_broadcast` redundant transition | Mock returns 400 `redundantTransition` | Returns `{:error, {400, "redundantTransition"}}`. |
| 4 | `LiveBroadcastsTest` | `transition_broadcast` invalid lifecycle jump | Mock returns 400 `invalidTransition` | Returns `{:error, {400, "invalidTransition"}}`. |
| 5 | `LiveBroadcastsTest` | `list_broadcasts` with status filter `:active` | Query `broadcastStatus=active` | Returns list of active broadcasts. |
| 6 | `LiveStreamsTest` | `create_stream` with snake_case atoms | `%{cdn: %{ingestion_type: "rtmp"}}` | Transformed to `ingestionType: "rtmp"`. |
| 7 | `LiveStreamsTest` | `get_stream` 404 stream not found | Mock returns 404 | Returns `{:error, {404, message}}`. |
| 8 | `LiveWorkflowTest` | Token expired during step 3 (`bind_broadcast`) | Mock returns 401, refresh mock returns 200 | Auto-refreshes token and completes bind. |
| 9 | `LiveWorkflowTest` | 403 quotaExceeded during `create_broadcast` | Multi-item gRPC quotaExceeded | Returns `{:error, {:quota_exceeded, details}}`. |
| 10 | `LiveWorkflowTest` | 429 rate limit during stream polling | Mock returns 429 `Retry-After: 30` | Returns `{:error, {:rate_limited, details}}` without freezing Req process. |

---

## 6. Implementation Plan for Milestone 2

1. **Step 1: Apply Core Refinements to `Client.ex`, `Errors.ex`, and `YouTube.ex`**:
   - Fix leading slash in `Client.build_url/1`.
   - Set `retry: false` default in `Client.request/3`.
   - Update `Errors.extract_error_info/1` for multi-item details and atom keys.
   - Add `"RESOURCE_EXHAUSTED"` to `@quota_reasons`.
   - Clamp attempt exponent in `Errors.backoff_delay/2`.
   - Sanitize HTML error messages in `Errors.classify/4`.
   - Fix `(lens.headers || [])` in `YouTube.add_auth_header/1`.
2. **Step 2: Implement `LiveBroadcasts` (`lib/lux/integrations/youtube/live_broadcasts.ex`)**:
   - Full CRUD: `create_broadcast`, `get_broadcast`, `list_broadcasts`, `update_broadcast`, `delete_broadcast`.
   - Lifecycle operations: `bind_broadcast`, `transition_broadcast`.
   - Support snake_case to camelCase parameter transformation.
3. **Step 3: Implement `LiveStreams` (`lib/lux/integrations/youtube/live_streams.ex`)**:
   - Full CRUD: `create_stream`, `get_stream`, `list_streams`, `update_stream`, `delete_stream`.
   - CDN settings mapping and ingestion info extraction.
4. **Step 4: Create Comprehensive Unit & E2E Test Suite**:
   - `test/unit/lux/integrations/youtube/live_broadcasts_test.exs`
   - `test/unit/lux/integrations/youtube/live_streams_test.exs`
   - `test/unit/lux/integrations/youtube/live_workflow_test.exs`
5. **Step 5: Run Full Verification**:
   - `mix compile --warnings-as-errors`
   - `mix test test/unit/lux/integrations/youtube/`
