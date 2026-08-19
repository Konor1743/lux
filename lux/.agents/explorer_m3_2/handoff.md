# Milestone 3 Explorer 2 Handoff: Architecture & Design of `Lux.Integrations.YouTube.LiveChat.Poller`

## 1. Observation

### 1.1 Existing Codebase & Infrastructure
- **`Lux.Integrations.YouTube.Client` (`lib/lux/integrations/youtube/client.ex:64-120`)**:
  - Implements Req-based HTTP pipeline for YouTube Data API v3 (`https://www.googleapis.com/youtube/v3`).
  - Supports Bearer token authorization, automatic 401 token refresh retry, test plug injection via `:plug`, and structured error delegation.
- **`Lux.Integrations.YouTube.Errors` (`lib/lux/integrations/youtube/errors.ex:60-128, 380-434`)**:
  - Classifies API responses into:
    - `{:error, {:quota_exceeded, details}}` (403 daily quota exceeded)
    - `{:error, {:rate_limited, details}}` (429 or 403 userRateLimitExceeded with optional `retry_after`)
    - `{:error, :invalid_token}` (401 unauthorized)
    - `{:error, {status, message}}`
  - Provides `backoff_delay(attempt, opts)` calculating exponential backoff with full jitter and `retryable?(error)`.
- **`Lux.Integrations.YouTube.LiveBroadcasts` (`lib/lux/integrations/youtube/live_broadcasts.ex:478-487`)**:
  - Extracts `liveChatId` from broadcast resources via `live_chat_id(broadcast)` (`snippet.liveChatId`).
- **`Lux.Signal.Router.Local` (`lib/lux/signal/router/local.ex:1-237`)**:
  - Demonstrates Lux OTP GenServer pub/sub patterns, subscriber management via `MapSet`, process monitoring, and safe process message dispatching.
- **Project Requirements (`PROJECT.md:28, 56-60`)**:
  - Milestone 3 specifies `Lux.Integrations.YouTube.LiveChat` and `Lux.Integrations.YouTube.LiveChat.Poller`.
  - Required API contracts:
    - `list_messages(live_chat_id, opts \\ %{}) :: {:ok, %{messages: list(), next_page_token: String.t(), polling_interval_ms: integer()}} | {:error, term()}`
    - `insert_message(live_chat_id, message_text, opts \\ %{}) :: {:ok, map()} | {:error, term()}`
    - `start_poller(opts) :: {:ok, pid()} | {:error, term()}`

---

## 2. Logic Chain

1. **YouTube Live Chat Polling Semantics**:
   - `GET /youtube/v3/liveChat/messages?liveChatId={id}&part=id,snippet,authorDetails` returns a list of `items`, a `nextPageToken`, and `pollingIntervalMillis`.
   - YouTube's API terms mandate that clients must not poll more frequently than the returned `pollingIntervalMillis`.
   - Initial call without `pageToken` retrieves the latest chat backlog and provides the first `nextPageToken`.
   - Subsequent calls passing `pageToken: nextPageToken` only retrieve messages created after that cursor.
2. **GenServer & Process Model**:
   - Polling is inherently stateful (maintaining `live_chat_id`, cursor `page_token`, dynamic polling interval, timer reference, subscriber pids, and consecutive error counter).
   - An OTP GenServer process scheduling polls with `Process.send_after(self(), :poll, interval)` is the standard BEAM design pattern for rate-controlled event streaming.
3. **Resilience & Backoff**:
   - Transient network errors (timeouts, 5xx) and rate limits (429, 403 `rateLimitExceeded`) must trigger exponential backoff using `Errors.backoff_delay/2` instead of crashing or tight-looping.
   - Non-retryable terminal errors such as `quotaExceeded` (403 daily exhaustion) or `liveChatEnded` / `liveChatNotActive` / `offlineAt` must cleanly halt polling, notify subscribers with structured tuples (`{:live_chat_ended, live_chat_id, reason}` or `{:live_chat_error, live_chat_id, error}`), and avoid pointless retries.
4. **Deduplication & Delivery Guarantees**:
   - Although `pageToken` prevents duplicates during standard operation, network timeouts or retried requests could return overlapping items.
   - Maintaining a bounded FIFO ring buffer + `MapSet` of recently seen message IDs guarantees strict at-most-once delivery to subscribers.
5. **Subscriber & Dispatch Architecture**:
   - The poller must support multiple subscriber pids, process monitoring (clearing dead pids on `{:DOWN, ...}`), optional callback functions, and optional `Lux.Signal` emission for integration into the Lux Agent Hub.

---

## 3. Caveats

- **No Active Network Calls**: In accordance with the `CODE_ONLY` constraint, all analysis is based on local codebase review and official Google YouTube Live Streaming API specifications.
- **Dependency on `LiveChat` Module**: The Poller relies on `Lux.Integrations.YouTube.LiveChat.list_messages/2` (or injected mock module via `:live_chat_module` option) for parsing raw API payloads.

---

## 4. Conclusion: Detailed Architectural Design for `Lux.Integrations.YouTube.LiveChat.Poller`

### 4.1 Module Location & Structure
- **Target File**: `lib/lux/integrations/youtube/live_chat/poller.ex`
- **Module**: `Lux.Integrations.YouTube.LiveChat.Poller`

### 4.2 State Definition & Typespecs

```elixir
defmodule Lux.Integrations.YouTube.LiveChat.Poller do
  @moduledoc """
  GenServer poller for continuous reading and streaming of YouTube Live Chat messages.

  Maintains cursor pagination (`nextPageToken`), dynamically adjusts polling cadence
  respecting YouTube's `pollingIntervalMillis`, handles rate limits with exponential backoff,
  and dispatches new messages to subscribers or callback functions.
  """

  use GenServer
  require Logger

  alias Lux.Integrations.YouTube.Errors
  alias Lux.Integrations.YouTube.LiveChat

  @default_interval_ms 5_000
  @min_interval_ms 1_000
  @max_interval_ms 60_000
  @default_backoff_base_ms 2_000
  @default_max_consecutive_errors 10
  @default_seen_cache_size 1_000

  @type status :: :running | :paused | :stopped | :ended | :backing_off | :quota_exhausted

  @type subscriber :: pid() | {module(), atom(), [term()]} | (([map()]) -> any())

  @type poller_opt ::
          {:live_chat_id, String.t()}
          | {:subscriber, pid() | subscriber()}
          | {:subscribers, [pid() | subscriber()]}
          | {:callback, (([map()], t()) -> any()) | (([map()]) -> any())}
          | {:client_opts, map() | keyword()}
          | {:live_chat_module, module()}
          | {:auto_start, boolean()}
          | {:initial_page_token, String.t() | nil}
          | {:min_interval_ms, non_neg_integer()}
          | {:default_interval_ms, non_neg_integer()}
          | {:max_interval_ms, non_neg_integer()}
          | {:backoff_base_ms, non_neg_integer()}
          | {:max_consecutive_errors, non_neg_integer()}
          | {:skip_initial_messages, boolean()}
          | {:max_seen_cache_size, non_neg_integer()}
          | {:emit_signals, boolean()}
          | {:name, GenServer.name()}

  @type poller_opts :: [poller_opt()] | %{optional(atom()) => term()}

  @type t :: %__MODULE__{
          live_chat_id: String.t(),
          status: status(),
          page_token: String.t() | nil,
          subscribers: MapSet.t(pid()),
          monitors: %{reference() => pid()},
          callback: term() | nil,
          client_opts: map(),
          live_chat_module: module(),
          current_interval_ms: non_neg_integer(),
          min_interval_ms: non_neg_integer(),
          default_interval_ms: non_neg_integer(),
          max_interval_ms: non_neg_integer(),
          backoff_base_ms: non_neg_integer(),
          max_consecutive_errors: non_neg_integer(),
          error_count: non_neg_integer(),
          last_error: term() | nil,
          last_polled_at: DateTime.t() | nil,
          messages_received_count: non_neg_integer(),
          timer_ref: reference() | nil,
          skip_initial_messages: boolean(),
          is_first_poll: boolean(),
          seen_message_ids: MapSet.t(String.t()),
          seen_message_order: :queue.queue(String.t()),
          max_seen_cache_size: non_neg_integer(),
          emit_signals: boolean()
        }

  defstruct [
    :live_chat_id,
    :status,
    :page_token,
    :subscribers,
    :monitors,
    :callback,
    :client_opts,
    :live_chat_module,
    :current_interval_ms,
    :min_interval_ms,
    :default_interval_ms,
    :max_interval_ms,
    :backoff_base_ms,
    :max_consecutive_errors,
    :error_count,
    :last_error,
    :last_polled_at,
    :messages_received_count,
    :timer_ref,
    :skip_initial_messages,
    :is_first_poll,
    :seen_message_ids,
    :seen_message_order,
    :max_seen_cache_size,
    :emit_signals
  ]
```

### 4.3 Public Client API Contract

```elixir
  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the LiveChat Poller GenServer.

  ## Options
  - `:live_chat_id` (required): YouTube Live Chat ID string.
  - `:subscriber`: Process PID or callback receiving messages (defaults to caller `self()`).
  - `:subscribers`: List of PIDs to receive messages.
  - `:callback`: Function `(messages -> term)` or `(messages, state -> term)` called on new messages.
  - `:client_opts`: Options forwarded to `Lux.Integrations.YouTube.Client` (e.g. `:token`, `:plug`).
  - `:live_chat_module`: LiveChat implementation module (defaults to `Lux.Integrations.YouTube.LiveChat`).
  - `:auto_start`: Boolean flag indicating if polling starts immediately on init (default `true`).
  - `:initial_page_token`: Optional page token to resume from.
  - `:min_interval_ms`: Minimum polling interval clamp in ms (default `1000`).
  - `:default_interval_ms`: Fallback interval if API returns none (default `5000`).
  - `:max_interval_ms`: Maximum backoff ceiling in ms (default `60000`).
  - `:backoff_base_ms`: Base backoff step in ms (default `2000`).
  - `:max_consecutive_errors`: Maximum retries before halting or notifying (default `10`).
  - `:skip_initial_messages`: If `true`, does not dispatch messages from the first poll (default `false`).
  - `:max_seen_cache_size`: Ring buffer size for deduplication (default `1000`).
  - `:emit_signals`: Whether to emit `Lux.Signal` structs (default `false`).
  - `:name`: GenServer name registration.
  """
  @spec start_link(poller_opts()) :: GenServer.on_start()
  def start_link(opts)

  @doc """
  Stops the poller process gracefully.
  """
  @spec stop(GenServer.server(), term(), timeout()) :: :ok
  def stop(poller, reason \\ :normal, timeout \\ 5000)

  @doc """
  Pauses automatic polling cycles.
  """
  @spec pause(GenServer.server()) :: :ok
  def pause(poller)

  @doc """
  Resumes polling cycles after being paused.
  """
  @spec resume(GenServer.server()) :: :ok
  def resume(poller)

  @doc """
  Returns the current operational status and metrics of the poller.
  """
  @spec get_status(GenServer.server()) :: map()
  def get_status(poller)

  @doc """
  Performs an immediate synchronous poll cycle and returns received messages.
  """
  @spec poll_once(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def poll_once(poller)

  @doc """
  Subscribes a process PID to live chat events.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(poller, subscriber_pid \\ self())

  @doc """
  Unsubscribes a process PID from live chat events.
  """
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(poller, subscriber_pid \\ self())

  @doc """
  Dynamically updates client options (e.g., refreshed tokens or plug configs).
  """
  @spec set_client_opts(GenServer.server(), map() | keyword()) :: :ok
  def set_client_opts(poller, client_opts)
```

### 4.4 GenServer Callbacks & Implementation Logic

#### 1. Initialization (`init/1`):
- Validates that `:live_chat_id` is present and non-empty. Returns `{:stop, :missing_live_chat_id}` otherwise.
- Populates state defaults:
  - `subscribers`: initial set from `:subscriber` / `:subscribers` (or `[caller_pid]` if none specified).
  - Monitors all subscriber PIDs via `Process.monitor/1` and stores refs in `monitors`.
  - `seen_message_ids`: `MapSet.new()`, `seen_message_order`: `:queue.new()`.
  - `status`: `:running` if `auto_start: true` else `:paused`.
- If `auto_start: true`, schedules immediate first poll: `timer_ref = Process.send_after(self(), :poll, 0)`.

#### 2. Polling Loop (`handle_info(:poll, state)`):
1. **Status Verification**:
   - If `state.status` not in `[:running, :backing_off]`, ignore and return `{:noreply, %{state | timer_ref: nil}}`.
2. **Execute API Call**:
   - Prepares request options:
     ```elixir
     opts =
       state.client_opts
       |> Map.new()
       |> maybe_put_opt(:page_token, state.page_token)
     ```
   - Invokes `state.live_chat_module.list_messages(state.live_chat_id, opts)`.
3. **Handle Success (`{:ok, response}`)**:
   - Parse response:
     - `messages = response[:messages] || response["messages"] || response["items"] || []`
     - `next_token = response[:next_page_token] || response["nextPageToken"] || state.page_token`
     - `interval_ms = response[:polling_interval_ms] || response["pollingIntervalMillis"] || state.default_interval_ms`
     - `offline_at = response[:offline_at] || response["offlineAt"]`
   - **Deduplication & Filtering**:
     - Filter out any message whose ID is in `state.seen_message_ids`.
     - Check if `state.is_first_poll and state.skip_initial_messages`:
       - If true, do not dispatch to subscribers.
     - Else, dispatch new messages to all `state.subscribers` (`{:live_chat_messages, state.live_chat_id, new_messages}`) and invoke `callback` if set.
   - **Update Deduplication Cache**:
     - Insert newly seen IDs into `seen_message_ids` MapSet and push to `seen_message_order` queue.
     - Prune excess if queue exceeds `max_seen_cache_size`.
   - **Evaluate End Conditions**:
     - If `offline_at != nil` or chat contains a `chatEndedEvent`:
       - Notify subscribers `{:live_chat_ended, state.live_chat_id, :offline}`.
       - Set `status: :ended, timer_ref: nil`.
     - Else:
       - Compute next delay: `effective_interval = max(interval_ms, state.min_interval_ms)`.
       - Schedule next poll: `timer_ref = Process.send_after(self(), :poll, effective_interval)`.
       - Update state:
         - `status: :running`
         - `page_token: next_token`
         - `current_interval_ms: effective_interval`
         - `error_count: 0`
         - `last_error: nil`
         - `last_polled_at: DateTime.utc_now()`
         - `messages_received_count: state.messages_received_count + length(new_messages)`
         - `is_first_poll: false`
4. **Handle Errors (`{:error, error_reason}`)**:
   - **Quota Exhausted (`{:error, {:quota_exceeded, details}}`)**:
     - Log error: `Logger.error("YouTube Live Chat quota exceeded: #{inspect(details)}")`
     - Notify subscribers: `dispatch_event(state, {:live_chat_error, state.live_chat_id, {:quota_exceeded, details}})`
     - Update state: `status: :quota_exhausted, timer_ref: nil`.
   - **Live Chat Ended (`{:error, {403, msg}}` when msg contains `"liveChatEnded"`)**:
     - Log info: `Logger.info("YouTube Live Chat has ended for #{state.live_chat_id}")`
     - Notify subscribers: `dispatch_event(state, {:live_chat_ended, state.live_chat_id, :live_chat_ended})`
     - Update state: `status: :ended, timer_ref: nil`.
   - **Rate Limited (`{:error, {:rate_limited, details}}` or `{429, _}`)**:
     - Extract `retry_after`: if given in seconds, `delay = retry_after * 1000`, else calculate exponential backoff with jitter via `Errors.backoff_delay(state.error_count + 1, base_backoff_ms: state.backoff_base_ms, max_backoff_ms: state.max_interval_ms)`.
     - Schedule next poll: `timer_ref = Process.send_after(self(), :poll, delay)`.
     - Update state: `status: :backing_off, error_count: state.error_count + 1, last_error: error_reason`.
   - **Transient Server / Transport Errors (5xx, timeouts)**:
     - Increment `error_count = state.error_count + 1`.
     - If `error_count >= state.max_consecutive_errors`:
       - Notify subscribers: `dispatch_event(state, {:live_chat_error, state.live_chat_id, {:max_errors_exceeded, error_reason}})`
       - Set `status: :paused, timer_ref: nil`.
     - Else:
       - Calculate jittered backoff delay: `delay = Errors.backoff_delay(error_count, base_backoff_ms: state.backoff_base_ms, max_backoff_ms: state.max_interval_ms)`.
       - Schedule next poll: `timer_ref = Process.send_after(self(), :poll, delay)`.
       - Update state: `status: :backing_off, error_count: error_count, last_error: error_reason`.
   - **Auth Error (`:invalid_token`)**:
     - Notify subscribers: `dispatch_event(state, {:live_chat_error, state.live_chat_id, :invalid_token})`.
     - Set `status: :paused, timer_ref: nil`.

#### 3. Control Calls (`handle_call/3`):
- `{:pause}`:
  - Cancels timer: `cancel_timer(state.timer_ref)`.
  - Sets `status: :paused, timer_ref: nil`.
  - Returns `{:reply, :ok, new_state}`.
- `{:resume}`:
  - If already `:running`, returns `{:reply, :ok, state}`.
  - Else cancels timer, schedules immediate poll `Process.send_after(self(), :poll, 0)`, sets `status: :running`.
  - Returns `{:reply, :ok, new_state}`.
- `{:poll_once}`:
  - Executes single poll cycle synchronously.
  - Updates cursor and caches.
  - If running, reschedules subsequent timer from now.
  - Returns `{:reply, {:ok, messages} | {:error, reason}, new_state}`.
- `{:get_status}`:
  - Returns summary map containing `live_chat_id`, `status`, `page_token`, `current_interval_ms`, `messages_received_count`, `error_count`, `last_polled_at`, `last_error`, `subscribers_count`.
- `{:subscribe, pid}`:
  - Adds `pid` to `subscribers`, monitors process with `Process.monitor(pid)`, stores monitor ref in `monitors`.
- `{:unsubscribe, pid}`:
  - Removes `pid` from `subscribers` and demonitors matching ref.
- `{:set_client_opts, opts}`:
  - Merges `opts` into `state.client_opts`.

#### 4. Subscriber Process Monitoring (`handle_info({:DOWN, ref, :process, pid, _reason}, state)`):
- Cleans up dead subscriber PID from `state.subscribers` and removes `ref` from `state.monitors`.

---

## 5. Verification Method

To verify the implementation of `Lux.Integrations.YouTube.LiveChat.Poller`:

### 5.1 Unit Tests Verification
Run the dedicated test suite:
```bash
mix test test/unit/lux/integrations/youtube/poller_test.exs
```

### 5.2 Test Scenarios to Validate
1. **Lifecycle & Control**:
   - `start_link/1` initializes with correct defaults and starts in `:running` state.
   - `pause/1` cancels timer and changes status to `:paused`.
   - `resume/1` restarts polling and fires immediate poll.
   - `get_status/1` returns accurate snapshot of counters and state.
   - `stop/1` cleans up timer and terminates cleanly.
2. **Sequential Pagination & Token Progression**:
   - Sequential poll cycles with dynamic `pollingIntervalMillis` responses (e.g. cycle 1 returns token `T1`, cycle 2 sends `pageToken=T1` and returns `T2`).
   - Verifies subscriber receives distinct message batches in order.
3. **Deduplication Verification**:
   - Simulates overlapping message IDs returned by API mock; verifies subscriber receives each unique message ID exactly once.
4. **Resilience & Backoff**:
   - Simulates HTTP 429 rate limits with `Retry-After: 3`; verifies poller delays next request by 3000ms.
   - Simulates transient 500 errors; verifies exponential backoff and error recovery when server returns 200 on subsequent try.
   - Simulates 403 `quotaExceeded`; verifies immediate halt and notification of `{:live_chat_error, id, {:quota_exceeded, details}}`.
   - Simulates 403 `liveChatEnded`; verifies clean transition to `:ended` status and notification of `{:live_chat_ended, id, reason}`.
5. **Subscriber Management & Monitoring**:
   - Tests `subscribe/2` and `unsubscribe/2`.
   - Tests subscriber crash (`Process.exit(sub, :kill)`) and ensures poller handles `{:DOWN, ...}` without crashing.

### 5.3 Compilation & Warning Checks
```bash
mix compile --warnings-as-errors
```
Must compile with 0 warnings.
