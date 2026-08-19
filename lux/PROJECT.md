# Project: YouTube Core API Integration and Live Streaming for Lux Framework

## Architecture
Lux is an Elixir framework for building and orchestrating LLM-powered agent workflows using Agents, Lenses, Prisms, Beams, and Integrations.
The YouTube integration provides:
1. **Low-level Client & Auth (`Lux.Integrations.YouTube.*`)**:
   - `Lux.Integrations.YouTube.OAuth`: Handles OAuth 2.0 URL generation, authorization code exchange for tokens, and refresh token rotation/handling.
   - `Lux.Integrations.YouTube.Client`: Req-based HTTP client communicating with Google APIs (`https://www.googleapis.com/youtube/v3`), managing headers (`Authorization: Bearer <token>`), query params, JSON bodies, mock plug injection, error parsing, and auto-refresh on 401.
   - `Lux.Integrations.YouTube`: High-level module providing shared settings, headers, auth functions for Lenses/Prisms, and API helper functions.
2. **Live Streaming Domain (`Lux.Integrations.YouTube.LiveStreaming.*` / `LiveBroadcasts`, `LiveStreams`)**:
   - `Lux.Integrations.YouTube.LiveBroadcasts`: Create, list, update, transition (e.g. testing, live, complete), and bind live broadcasts.
   - `Lux.Integrations.YouTube.LiveStreams`: Create, list, and manage live streams (RTMP ingestion points, stream status).
3. **Live Chat Domain (`Lux.Integrations.YouTube.LiveChat.*`)**:
   - `Lux.Integrations.YouTube.LiveChat`: Fetch live chat messages by `liveChatId`, parse page tokens, polling intervals, author details, and message text/snippets.
   - `Lux.Integrations.YouTube.LiveChat.Poller`: GenServer / Stream-based poller that continuously polls active chat messages respecting `pollingIntervalMillis`, emitting signals/messages or streaming to agents.
4. **Resiliency & Quota / Rate Limiting**:
   - Explicit parsing and error mapping for HTTP 403 `quotaExceeded` / `rateLimitExceeded` and HTTP 429.
   - Exponential backoff / retry utilities where appropriate.
5. **Lenses & Prisms**:
   - `Lux.Lenses.YouTube.*` for data-fetching lenses (e.g. `ListBroadcasts`, `GetChatMessages`, `GetStream`).
   - `Lux.Prisms.YouTube.*` for actionable agent prisms (e.g. `CreateBroadcastPrism`, `SendMessagePrism`).

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | OAuth 2.0 & YouTube API Client | `Lux.Integrations.YouTube.OAuth`, `Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube`, `Lux.Config` additions, unit tests | none | DONE |
| 2 | Live Streaming Management | `Lux.Integrations.YouTube.LiveBroadcasts`, `Lux.Integrations.YouTube.LiveStreams`, unit tests | M1 | DONE |
| 3 | Live Chat Reading & Poller | `Lux.Integrations.YouTube.LiveChat`, `Lux.Integrations.YouTube.LiveChat.Poller`, unit tests | M1 | DONE |
| 4 | Resiliency & High-Level Lenses/Prisms | `Lux.Lenses.YouTube.*`, `Lux.Prisms.YouTube.*`, Resiliency error types, unit tests | M1, M2, M3 | DONE |
| 5 | E2E Testing Suite & Hardening | Comprehensive test suite across Tiers 1-4 with Req.Test mocks, Tier 5 adversarial tests, >90% coverage check, `mix compile --warnings-as-errors` check | M1, M2, M3, M4 | DONE |

## Interface Contracts

### OAuth 2.0 (`Lux.Integrations.YouTube.OAuth`) [DONE]
- `authorize_url(opts \\ %{}) :: String.t()`
- `exchange_code(code, opts \\ %{}) :: {:ok, token_map} | {:error, term()}`
- `refresh_token(refresh_token, opts \\ %{}) :: {:ok, token_map} | {:error, term()}`

### Client (`Lux.Integrations.YouTube.Client`) [DONE]
- `request(method, path, opts \\ %{}) :: {:ok, map()} | {:error, term()}`
  - Options: `:token`, `:refresh_token`, `:client_id`, `:client_secret`, `:params`, `:json`, `:headers`, `:plug`, `:auto_refresh` (boolean, default true)
  - Returns decoded JSON body on 2xx, or structured error tuples on failure (`{:error, {:quota_exceeded, details}}`, `{:error, {:rate_limited, details}}`, `{:error, :invalid_token}`, `{:error, {status, message}}`).

### Live Broadcasts & Streams (`Lux.Integrations.YouTube.LiveBroadcasts`, `LiveStreams`) [M2]
- `create_broadcast(params, opts \\ %{}) :: {:ok, broadcast} | {:error, term()}`
- `list_broadcasts(params, opts \\ %{}) :: {:ok, list_result} | {:error, term()}`
- `get_broadcast(id, opts \\ %{}) :: {:ok, broadcast} | {:error, term()}`
- `update_broadcast(params, opts \\ %{}) :: {:ok, broadcast} | {:error, term()}`
- `transition_broadcast(broadcast_id, status, opts \\ %{}) :: {:ok, broadcast} | {:error, term()}`
- `bind_broadcast(broadcast_id, stream_id, opts \\ %{}) :: {:ok, broadcast} | {:error, term()}`
- `create_stream(params, opts \\ %{}) :: {:ok, stream} | {:error, term()}`
- `list_streams(params, opts \\ %{}) :: {:ok, list_result} | {:error, term()}`
- `get_stream(id, opts \\ %{}) :: {:ok, stream} | {:error, term()}`
- `delete_stream(id, opts \\ %{}) :: {:ok, map()} | {:error, term()}`

### Live Chat (`Lux.Integrations.YouTube.LiveChat`, `Poller`) [M3]
- `list_messages(live_chat_id, opts \\ %{}) :: {:ok, %{messages: list(), next_page_token: String.t(), polling_interval_ms: integer()}} | {:error, term()}`
- `insert_message(live_chat_id, message_text, opts \\ %{}) :: {:ok, map()} | {:error, term()}`
- `start_poller(opts) :: {:ok, pid()} | {:error, term()}`

## Code Layout
```
lib/
├── lux/
│   ├── config.ex                       # Added youtube helper configs
│   ├── integrations/
│   │   ├── youtube/
│   │   │   ├── oauth.ex                # OAuth 2.0 URL, exchange, refresh [DONE]
│   │   │   ├── client.ex               # HTTP client with Req, auto-refresh, error handling [DONE]
│   │   │   ├── live_broadcasts.ex      # Broadcast lifecycle & CRUD [M2]
│   │   │   ├── live_streams.ex         # Stream ingestion & CRUD [M2]
│   │   │   ├── live_chat.ex            # Live chat message fetching [M3]
│   │   │   ├── live_chat/
│   │   │   │   └── poller.ex           # GenServer/Poller for chat streams [M3]
│   │   │   └── errors.ex               # Quota, rate limit, and domain errors [DONE]
│   │   └── youtube.ex                  # Integration helper & auth settings [DONE]
│   ├── lenses/
│   │   └── youtube/
│   │       ├── list_broadcasts.ex
│   │       ├── get_chat_messages.ex
│   │       └── get_stream.ex
│   └── prisms/
│       └── youtube/
│           ├── create_broadcast.ex
│           └── send_chat_message.ex
test/
├── unit/
│   └── lux/
│       ├── integrations/
│       │   └── youtube/
│       │       ├── oauth_test.exs       [DONE]
│       │       ├── client_test.exs      [DONE]
│       │       ├── errors_test.exs      [DONE]
│       │       ├── live_broadcasts_test.exs [M2]
│       │       ├── live_streams_test.exs    [M2]
│       │       ├── live_chat_test.exs       [M3]
│       │       └── poller_test.exs          [M3]
│       ├── lenses/
│       │   └── youtube_lenses_test.exs
│       └── prisms/
│           └── youtube_prisms_test.exs
└── e2e/
    └── youtube_integration_e2e_test.exs
```

## Verification Standards
1. Zero compiler warnings: `mix compile --warnings-as-errors`
2. Test coverage >90% across YouTube modules
3. All ExUnit tests pass with `Req.Test` mocks
4. Zero cheating / full forensic audit verification
