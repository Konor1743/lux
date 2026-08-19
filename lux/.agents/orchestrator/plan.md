# Project Plan: YouTube Core API Integration and Live Streaming (Issue #68)

## Objectives
Implement a complete, production-grade YouTube Core API and Live Streaming integration for the Lux Elixir framework, covering:
1. **OAuth 2.0 & API Client**: Authorization URL generation, token exchange, token refresh, request pipeline with automatic token refresh on expiry/401, quota and rate limit parsing.
2. **Live Streaming Management**: Creating broadcasts, creating live streams, binding streams to broadcasts, updating status/metadata, transitioning broadcast lifecycle (testing, live, complete), listing streams/broadcasts.
3. **Live Chat Reading & Poller**: Fetching live chat messages for active broadcasts, handling page tokens, polling intervals (`pollingIntervalMillis`), message stream/GenServer or stream consumer.
4. **Resiliency & Error Handling**: HTTP 403 `quotaExceeded` detection, HTTP 429 rate limit backoff, exponential backoff/jitter, informative error tuples.
5. **High-Level Lenses & Prisms**: Exposing YouTube features through Lux native primitives (`Lux.Lens` and `Lux.Prism` or `Lux.Integrations.YouTube`).
6. **Testing & Coverage**: Unit tests with `Req.Test` mocking, live chat polling simulation with page tokens, >90% test coverage, clean compilation (`mix compile --warnings-as-errors`).

## Milestones Decomposition
- **Milestone 1**: OAuth 2.0 & YouTube API Client
  - Modules: `Lux.Integrations.YouTube.OAuth`, `Lux.Integrations.YouTube.Client`, `Lux.Integrations.YouTube`
  - Unit tests: OAuth flows, client request formatting, token refresh, error handling
- **Milestone 2**: YouTube Live Streaming Management
  - Modules: `Lux.Integrations.YouTube.LiveBroadcasts`, `Lux.Integrations.YouTube.LiveStreams`, related Lenses/Prisms
  - Unit tests: Broadcast CRUD, Stream CRUD, Bind, Transition
- **Milestone 3**: YouTube Live Chat Reading & Poller
  - Modules: `Lux.Integrations.YouTube.LiveChat`, `Lux.Integrations.YouTube.LiveChat.Poller` (or Stream/GenServer)
  - Unit tests: Paginated polling simulation, message decoding, rate limit handling
- **Milestone 4**: High-Level Lux Lenses, Prisms & Resiliency Integration
  - Modules: Lenses and Prisms for YouTube actions, Config integration (`Lux.Config.youtube_*`), Error structures
  - Unit tests: Lenses focus/after_focus, Prisms handler, Config lookup
- **Milestone 5 (Final Milestone)**: End-to-End Test Suite & Hardening
  - E2E Test suite across Tiers 1-4 with `Req.Test` mocks
  - Adversarial hardening (Tier 5)
  - Verification of compiler warnings (`mix compile --warnings-as-errors`) and test coverage (>90%)

## Orchestration Workflow
For each milestone:
1. Dispatch 3 Explorers to analyze codebase patterns, contracts, schemas, and requirements.
2. Synthesize findings into actionable implementation guidance.
3. Dispatch 1 Worker to implement the code and unit tests.
4. Dispatch 2 Reviewers independently to verify code correctness and test coverage.
5. Dispatch 2 Challengers to test edge cases, error conditions, and corner scenarios.
6. Dispatch 1 Forensic Auditor (`teamwork_preview_auditor`) to verify zero cheating, clean implementation.
7. Gate check: pass all criteria -> advance milestone.
