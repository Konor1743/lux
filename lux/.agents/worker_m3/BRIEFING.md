# BRIEFING — 2026-08-17T23:33:30Z

## Mission
Implement YouTube Live Chat integration (`Lux.Integrations.YouTube.LiveChat`) and continuous polling GenServer (`Lux.Integrations.YouTube.LiveChat.Poller`) with comprehensive unit, simulation, and resiliency tests.

## 🔒 My Identity
- Archetype: worker_m3
- Roles: implementer, qa, specialist
- Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_m3
- Original parent: 8f7058a5-a15e-4824-90bb-75287a1858e6
- Milestone: Milestone 3 (Live Chat Reading & Poller)

## 🔒 Key Constraints
- Genuine implementation only (no dummy/facade implementations, no hardcoded test shortcuts).
- `mix compile --warnings-as-errors` must pass with zero warnings.
- `mix test` and coverage >90% for YouTube modules.
- Strict layout compliance: source in `lib/lux/integrations/youtube/`, tests in `test/unit/lux/integrations/youtube/`, agent metadata only in `.agents/worker_m3/`.

## Current Parent
- Conversation ID: 8f7058a5-a15e-4824-90bb-75287a1858e6
- Updated: 2026-08-17T23:33:30Z

## Task Summary
- **What to build**:
  1. `Lux.Integrations.YouTube.LiveChat` (`lib/lux/integrations/youtube/live_chat.ex`):
     - `list_messages/2` (part, liveChatId, pageToken, maxResults, hl, profileImageSize, parses message items, timestamps, author details, nextPageToken, pollingIntervalMillis, offlineAt).
     - `insert_message/3` (snippet: %{liveChatId, type: "textMessageEvent", textMessageDetails: %{messageText}}).
     - `get_live_chat_id/2` / `get_live_chat_id_for_broadcast/2` (fetches broadcast liveChatId).
     - `start_poller/1` (starts poller GenServer).
  2. `Lux.Integrations.YouTube.LiveChat.Poller` (`lib/lux/integrations/youtube/live_chat/poller.ex`):
     - GenServer with `start_link/1`, `start/1`, `stop/2`, `pause/1`, `resume/1`, `get_status/1`, `poll_once/1`.
     - Subscriber notification `{:live_chat_messages, live_chat_id, messages}` and optional `handler_fn`.
     - Error dispatch `{:live_chat_error, live_chat_id, error}`.
     - Exponential backoff on errors, dynamic `pollingIntervalMillis` pacing, deduplication via page tokens.
  3. Comprehensive unit & simulation test suite:
     - `test/unit/lux/integrations/youtube/live_chat_test.exs`
     - `test/unit/lux/integrations/youtube/poller_test.exs`
- **Success criteria**: All tests pass, 0 warnings, >90% coverage, self-contained handoff report.
- **Interface contracts**: `PROJECT.md` § Milestone 3 & `.agents/orchestrator_gen3/m3_synthesis.md`
- **Code layout**: `lib/lux/integrations/youtube/live_chat.ex`, `lib/lux/integrations/youtube/live_chat/poller.ex`, `test/unit/lux/integrations/youtube/live_chat_test.exs`, `test/unit/lux/integrations/youtube/poller_test.exs`.

## Change Tracker
- **Files modified**: none yet
- **Build status**: clean (tests pass)
- **Pending issues**: none

## Quality Status
- **Build/test result**: pending implementation
- **Lint status**: clean
- **Tests added/modified**: pending

## Loaded Skills
- None required

## Key Decisions Made
- Use `Lux.Integrations.YouTube.Client` for all HTTP calls to benefit from automatic OAuth refresh, error classification, and Req.Test plug compatibility.
- Ensure `LiveChat.Poller` handles subscriber management (accepts single pid or list, allows adding subscribers if needed or subscribing self), maintains timer state, pause/resume states, backoff counts, and processes both string and atom keys gracefully.
- Normalizes live chat messages to provide structured access (author name, channel ID, badges, message text, timestamps, display message, superchat details if present).

## Artifact Index
- `.agents/worker_m3/ORIGINAL_REQUEST.md` — Original request record
- `.agents/worker_m3/BRIEFING.md` — Active briefing and state
- `.agents/worker_m3/progress.md` — Heartbeat and step tracking
