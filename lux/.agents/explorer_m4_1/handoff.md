# Architectural Exploration Report: Lux Lenses, Prisms & YouTube High-Level Modules (Milestone 4)

## 1. Observation

### 1.1 Lux Lens Architecture (`lib/lux/lens.ex`)
From direct inspection of `lib/lux/lens.ex` (lines 42–199):
- **Struct Definition**:
  ```elixir
  defstruct after_focus: nil,
            name: nil,
            module_name: nil,
            url: nil,
            method: :get,
            params: %{},
            headers: [],
            auth: nil,
            description: "",
            schema: %{}
  ```
- **Macro `__using__(opts)`** (lines 68–115):
  Registers `@lens_struct` and `@lens_module_name`.
  Supported `use Lux.Lens` options:
  - `:name` (String, default: module name string)
  - `:description` (String, default: `""`)
  - `:url` (String, endpoint URL)
  - `:method` (Atom, `:get`, `:post`, `:put`, `:delete`, default: `:get`)
  - `:params` (Map, default query parameters or body template)
  - `:headers` (List of `{String.t(), String.t()}` headers)
  - `:auth` (Map, authentication descriptor)
  - `:schema` (Map, JSON schema format defining expected query/body params)
- **Callbacks & Overridables**:
  - `@callback after_focus(response :: any()) :: {:ok, any()} | {:error, any()}` (optional)
  - `def before_focus(params), do: params` (overridable, default identity)
  - `def after_focus(body), do: {:ok, body}` (overridable)
- **Execution Pipeline**:
  1. `LensModule.focus(input \\ %{}, opts \\ [])` calls `__MODULE__.view()`
  2. Merges `input` into `params`: `Map.update!(:params, &Map.merge(&1, input))`
  3. Authenticates via `Lux.Lens.authenticate(lens)`: evaluates `:custom` auth function (e.g. `Lux.Integrations.YouTube.add_auth_header/1`), or `:oauth`, `:api_key`, `:basic`.
  4. Runs `before_focus(params)`: allows parameter normalization, key renaming (e.g. snake_case to camelCase), or URL manipulation.
  5. `Lux.Lens.focus/2` issues `Req.request` with `[method: method] ++ body_or_params(method, params)` where `body_or_params(:get, params)` sets `[params: params]` and other methods set `[json: params]`.
  6. On HTTP 200, calls `after_focus.(body)`. On non-200, returns `{:error, response.body}`.

### 1.2 Lux Prism Architecture (`lib/lux/prism.ex`)
From direct inspection of `lib/lux/prism.ex` (lines 42–137):
- **Struct Definition**:
  ```elixir
  defstruct [
    :id,
    :name,
    :module_name,
    :handler,
    :description,
    :examples,
    :input_schema,
    :output_schema
  ]
  ```
- **Macro `__using__(opts)`** (lines 90–137):
  Registers `@prism_config`, `@prism_struct`, `@prism_module_name`.
  Supported `use Lux.Prism` options:
  - `:name` (String, default: module name string)
  - `:description` (String, default: `""`)
  - `:input_schema` (Map in JSON Schema format or module implementing `Lux.SignalSchema`)
  - `:output_schema` (Map in JSON Schema format or module implementing `Lux.SignalSchema`)
  - `:examples` (List of String examples, default: `[]`)
  - `:id` (String UUID, auto-generated if omitted)
- **Callbacks**:
  - `@callback handler(input :: any(), context :: any()) :: {:ok, any()} | {:error, any()}`
  - Defines `def run(input, context \\ nil)` which invokes `Lux.Prism.run(__MODULE__, input, context)` -> `handler(input, context)`.
  - Defines `def view`, returning `%{@prism_struct | handler: &__MODULE__.handler/2}`.

### 1.3 YouTube Domain Modules & Helpers (M1–M3)
- `Lux.Integrations.YouTube`:
  - `base_url/0`: `"https://www.googleapis.com/youtube/v3"`
  - `headers/0`: `[{"Content-Type", "application/json"}, {"Accept", "application/json"}]`
  - `auth/0`: `%{type: :custom, auth_function: &Lux.Integrations.YouTube.add_auth_header/1}`
- `Lux.Integrations.YouTube.LiveBroadcasts`:
  - `list_broadcasts/2`, `create_broadcast/2`, `get_broadcast/2`, `update_broadcast/2`, `transition_broadcast/3`, `bind_broadcast/3`, `delete_broadcast/2`, `broadcast_url/1`, `live_chat_id/1`
- `Lux.Integrations.YouTube.LiveStreams`:
  - `list_streams/2`, `create_stream/2`, `get_stream/2`, `update_stream/2`, `delete_stream/2`, `stream_key/1`, `stream_url/2`
- `Lux.Integrations.YouTube.LiveChat`:
  - `list_messages/2`, `insert_message/3`, `get_live_chat_id/2`, `normalize_message/1`
- `Lux.Integrations.YouTube.Errors`:
  - `quota_exceeded?/1`, `rate_limited?/1`, `retryable?/1`, `with_retry/2`, `backoff_delay/2`

### 1.4 Compilation Defect Noted in `poller.ex`
Running `mix test` revealed that `lib/lux/integrations/youtube/live_chat/poller.ex` (lines 102, 119, 198) calls `validate_init_opts/1`, but the private function `validate_init_opts/1` definition was missing from the module.

---

## 2. Logic Chain

1. **Lens Execution Semantics for YouTube**:
   - Lenses are pure HTTP data-fetching queries.
   - For YouTube Data API v3 GET endpoints, lenses configure `url: "#{Lux.Integrations.YouTube.base_url()}/<endpoint>"`, `method: :get`, `headers: Lux.Integrations.YouTube.headers()`, and `auth: Lux.Integrations.YouTube.auth()`.
   - `before_focus/1` converts idiomatic Elixir snake_case input keys (e.g. `:broadcast_status`, `:page_token`, `:max_results`, `:live_chat_id`) to YouTube camelCase query parameters (`:broadcastStatus`, `:pageToken`, `:maxResults`, `:liveChatId`) and ensures appropriate default `:part` parameters.
   - `after_focus/1` unpacks HTTP 200 response bodies, normalizing data structures (such as calling `LiveChat.normalize_message/1` or extracting `items`).

2. **Prism Execution Semantics for YouTube**:
   - Prisms encapsulate domain actions/mutations executed by Agents and workflows.
   - In `handler(input, context)`, the prism validates input parameters, delegates execution to domain modules (`Lux.Integrations.YouTube.LiveBroadcasts.create_broadcast/2`, `Lux.Integrations.YouTube.LiveChat.insert_message/3`), maps outputs into structured maps matching `output_schema`, and returns `{:ok, result}` or `{:error, reason}`.

3. **Proposed Specifications for YouTube Lenses**:

   - **`Lux.Lenses.YouTube.ListBroadcasts` (`lib/lux/lenses/youtube/list_broadcasts.ex`)**:
     - `use Lux.Lens, name: "List YouTube Broadcasts", description: "Lists live broadcasts for the authenticated channel or filtered by status", url: "#{Lux.Integrations.YouTube.base_url()}/liveBroadcasts", method: :get, headers: Lux.Integrations.YouTube.headers(), auth: Lux.Integrations.YouTube.auth()`
     - Schema: `broadcast_status` (enum: all, active, completed, upcoming), `broadcast_type` (enum: all, event, persistent), `mine` (boolean), `max_results` (integer, 1..50), `page_token` (string), `part` (string).
     - `before_focus(params)`: maps snake_case keys to camelCase, sets default `part: "snippet,status,contentDetails"`, ensures `mine: true` if not filtering by ID.
     - `after_focus(response)`: extracts `items`, `next_page_token`, `page_info`.

   - **`Lux.Lenses.YouTube.GetChatMessages` (`lib/lux/lenses/youtube/get_chat_messages.ex`)**:
     - `use Lux.Lens, name: "Get YouTube Live Chat Messages", description: "Fetches live chat messages for an active broadcast chat", url: "#{Lux.Integrations.YouTube.base_url()}/liveChat/messages", method: :get, headers: Lux.Integrations.YouTube.headers(), auth: Lux.Integrations.YouTube.auth()`
     - Schema: `live_chat_id` (string, required), `page_token` (string), `max_results` (integer, 1..2000), `part` (string), `hl` (string), `profile_image_size` (integer).
     - `before_focus(params)`: maps `live_chat_id` to `liveChatId`, `page_token` to `pageToken`, `max_results` to `maxResults`, default `part: "snippet,authorDetails"`.
     - `after_focus(response)`: normalizes messages using `Lux.Integrations.YouTube.LiveChat.normalize_message/1`, returning `{:ok, %{messages: normalized_messages, next_page_token: ..., polling_interval_ms: ...}}`.

   - **`Lux.Lenses.YouTube.GetStream` (`lib/lux/lenses/youtube/get_stream.ex`)**:
     - `use Lux.Lens, name: "Get YouTube Live Stream", description: "Fetches live stream ingestion point details by stream ID", url: "#{Lux.Integrations.YouTube.base_url()}/liveStreams", method: :get, headers: Lux.Integrations.YouTube.headers(), auth: Lux.Integrations.YouTube.auth()`
     - Schema: `id` (string, required), `part` (string).
     - `before_focus(params)`: sets `id: params[:id]` and default `part: "snippet,cdn,status,contentDetails"`.
     - `after_focus(response)`: extracts first item from `items`, returning `{:ok, stream}` or `{:error, :not_found}` if items list is empty.

4. **Proposed Specifications for YouTube Prisms**:

   - **`Lux.Prisms.YouTube.CreateBroadcast` (`lib/lux/prisms/youtube/create_broadcast.ex`)**:
     - `use Lux.Prism, name: "Create YouTube Live Broadcast", description: "Creates and schedules a new YouTube Live Broadcast"`
     - `input_schema`: JSON Schema requiring `title`, optional `scheduled_start_time`, `privacy_status`, `description`, `enable_auto_start`, `enable_auto_stop`, `enable_dvr`, `latency_preference`.
     - `output_schema`: JSON Schema defining `id`, `title`, `status`, `watch_url`, `live_chat_id`, `broadcast`.
     - `handler(input, _context)`: calls `Lux.Integrations.YouTube.LiveBroadcasts.create_broadcast(input)`.

   - **`Lux.Prisms.YouTube.SendChatMessage` (`lib/lux/prisms/youtube/send_chat_message.ex`)**:
     - `use Lux.Prism, name: "Send YouTube Live Chat Message", description: "Sends/inserts a message into a live broadcast chat"`
     - `input_schema`: JSON Schema requiring `live_chat_id` and `message_text`.
     - `output_schema`: JSON Schema defining `sent`, `message_id`, `live_chat_id`, `message_text`, `published_at`, `message`.
     - `handler(input, _context)`: calls `Lux.Integrations.YouTube.LiveChat.insert_message(live_chat_id, message_text)`.

---

## 3. Caveats

1. **Lens Testing Mock Target**:
   - `Lux.Lens.focus/2` invokes `Req.request` directly. When unit testing `Lux.Lens` modules, tests must stub `Lux.Lens` via `Req.Test.stub(Lux.Lens, fn conn -> ... end)` or `Req.Test.expect(Lux.Lens, fn conn -> ... end)`.
2. **Prism Testing Mock Target**:
   - Prisms call domain modules (`LiveBroadcasts`, `LiveChat`), which use `Lux.Integrations.YouTube.Client`. Tests can stub `Lux.Integrations.YouTube.Client` or pass `opts[:plug]`.
3. **HTTP 200 Constraint on `Lux.Lens`**:
   - In `Lux.Lens.focus/2`, only HTTP 200 responses are routed to `after_focus/1`. Non-200 responses (including 201 Created or 204 No Content) produce `{:error, response.body}`. For that reason, create/insert operations belong in Prisms, while GET queries belong in Lenses.
4. **Pre-existing Poller Fix Required**:
   - `lib/lux/integrations/youtube/live_chat/poller.ex` requires adding:
     ```elixir
     defp validate_init_opts(opts) do
       live_chat_id = opts[:live_chat_id] || opts["live_chat_id"]

       cond do
         is_nil(live_chat_id) or live_chat_id == "" ->
           {:error, :missing_live_chat_id}

         not is_binary(live_chat_id) ->
           {:error, :invalid_live_chat_id}

         true ->
           :ok
       end
     end
     ```

---

## 4. Conclusion

The standard syntax and macro patterns for Milestone 4 lenses and prisms are established.

### File Plan for Implementation:
- Lenses:
  - `lib/lux/lenses/youtube/list_broadcasts.ex`
  - `lib/lux/lenses/youtube/get_chat_messages.ex`
  - `lib/lux/lenses/youtube/get_stream.ex`
- Prisms:
  - `lib/lux/prisms/youtube/create_broadcast.ex`
  - `lib/lux/prisms/youtube/send_chat_message.ex`
- Tests:
  - `test/unit/lux/lenses/youtube_lenses_test.exs`
  - `test/unit/lux/prisms/youtube_prisms_test.exs`
- Bugfix:
  - Add missing `validate_init_opts/1` in `lib/lux/integrations/youtube/live_chat/poller.ex`.

---

## 5. Verification Method

1. **Verify compilation**:
   ```bash
   mix compile --warnings-as-errors
   ```
2. **Verify unit tests**:
   ```bash
   mix test --only unit test/unit/lux/lens_test.exs test/unit/lux/prism_test.exs
   mix test --only unit test/unit/lux/integrations/youtube/
   mix test --only unit test/unit/lux/lenses/youtube_lenses_test.exs
   mix test --only unit test/unit/lux/prisms/youtube_prisms_test.exs
   ```
3. **Verify files**:
   - `lib/lux/lens.ex` lines 68–115
   - `lib/lux/prism.ex` lines 90–137
