# Milestone 3 Synthesis Report

## Consensus & Architecture for Milestone 3 (Live Chat Reading & Poller)

### 1. `Lux.Integrations.YouTube.LiveChat`
- **Module Path**: `lib/lux/integrations/youtube/live_chat.ex`
- **Functions**:
  - `list_messages(live_chat_id, opts \\ %{}) :: {:ok, map()} | {:error, term()}`
    - Query params: `liveChatId`, `part` (default `"snippet,authorDetails"`), `pageToken`, `maxResults`, `hl`, `profileImageSize`.
    - Returns normalized map: `%{messages: list_of_parsed_messages, next_page_token: string, polling_interval_ms: integer, page_info: map, offline_at: string | nil, raw: map}`.
  - `insert_message(live_chat_id, message_text, opts \\ %{}) :: {:ok, map()} | {:error, term()}`
    - Builds request body: `%{snippet: %{liveChatId: live_chat_id, type: "textMessageEvent", textMessageDetails: %{messageText: message_text}}}`.
    - Path: `"liveChat/messages"`, method: `:post`, part: `"snippet"`.
  - `get_live_chat_id_for_broadcast(broadcast_id, opts \\ %{}) :: {:ok, String.t()} | {:error, term()}`
    - Helper using `Lux.Integrations.YouTube.LiveBroadcasts.get_broadcast/2` to extract `snippet.liveChatId`.
  - `start_poller(opts) :: {:ok, pid()} | {:error, term()}`
    - Convenience delegate to `Lux.Integrations.YouTube.LiveChat.Poller.start_link/1`.

### 2. `Lux.Integrations.YouTube.LiveChat.Poller`
- **Module Path**: `lib/lux/integrations/youtube/live_chat/poller.ex`
- **GenServer API**:
  - `start_link(opts)` / `start(opts)`
    - Options: `:live_chat_id` (required), `:token` / `:client_opts`, `:subscribers` / `:subscriber` (pid or list of pids), `:handler_fn` (optional callback), `:initial_page_token` (optional), `:default_interval_ms` (default 5000), `:name` (optional).
  - `stop(poller_pid_or_name, reason \\ :normal)`
  - `pause(poller_pid_or_name)`
  - `resume(poller_pid_or_name)`
  - `get_status(poller_pid_or_name) :: %{status: atom, page_token: string, interval_ms: integer, message_count: integer}`
  - `poll_once(poller_pid_or_name)` (manual trigger for synchronous/step testing)
- **GenServer Implementation Details**:
  - Uses `Process.send_after(self(), :poll, interval_ms)` to avoid blocking GenServer loop.
  - Keeps track of `timer_ref` to cancel/reschedule safely during `pause` / `resume` / `poll_once`.
  - Normalizes and extracts incoming messages. When new messages arrive, broadcasts to all subscribers via `send(pid, {:live_chat_messages, live_chat_id, messages})` and executes `handler_fn` if present.
  - Updates `page_token` to `next_page_token` to guarantee no duplicated message processing.
  - Adapts `polling_interval_ms` to `pollingIntervalMillis` returned from YouTube API.
  - On error (e.g. rate limit, network failure): applies exponential backoff, notifies subscribers with `{:live_chat_error, live_chat_id, error}`, and retries without crashing the process unless fatal.

### 3. Unit Tests & Mocks
- `test/unit/lux/integrations/youtube/live_chat_test.exs`:
  - Verify `list_messages` with various parts, pageTokens, maxResults.
  - Verify message normalization (authorDetails, textMessageDetails, timestamps, boolean badges).
  - Verify `insert_message` payload structure and response.
  - Verify error handling (403 quotaExceeded, 404 liveChatNotFound, 429 rateLimit).
- `test/unit/lux/integrations/youtube/poller_test.exs`:
  - Multi-cycle pagination simulation using stateful `Req.Test` plug mock.
  - Dynamic `pollingIntervalMillis` adjustment verification.
  - `pause` / `resume` state transitions and message halting.
  - Subscriber message delivery and `handler_fn` execution.
  - Error backoff and retry behavior.
  - Graceful termination on stop and when broadcast ends.
