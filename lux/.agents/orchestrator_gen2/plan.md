# Orchestrator Gen 2 Plan

## Objectives
Complete YouTube Core API Integration and Live Streaming capabilities (Issue #68) for Lux framework across Milestones 1 to 5.

## Roadmap & Milestones

### Milestone 1: OAuth 2.0 & YouTube API Client [DONE]
- Implemented and verified in Gen 1.

### Milestone 2: YouTube Live Streaming Management [VERIFYING]
- Worker 2 completed implementation (`live_broadcasts.ex`, `live_streams.ex`, unit tests, 219 tests pass, 0 warnings, >90% coverage).
- Step 1: Dispatch 2 Reviewers, 2 Challengers, and 1 Forensic Auditor.
- Step 2: Gate evaluation (reviewers approval, challenger stress tests, clean forensic audit).
- Step 3: Mark Milestone 2 DONE.

### Milestone 3: Live Chat Reading & Poller [PENDING]
- Step 1: Dispatch 3 Explorers (`live_chat.ex`, `live_chat/poller.ex`, GenServer streaming, Req.Test mock architecture).
- Step 2: Dispatch 1 Worker to implement `live_chat.ex`, `live_chat/poller.ex`, unit tests, ensuring >90% coverage and 0 warnings.
- Step 3: Dispatch 2 Reviewers, 2 Challengers, and 1 Forensic Auditor.
- Step 4: Gate evaluation.
- Step 5: Mark Milestone 3 DONE.

### Milestone 4: Resiliency, Quota/Rate Limits & High-Level Lenses/Prisms [PENDING]
- Step 1: Dispatch 3 Explorers (Error mapping, retry/backoff, Lens & Prism definitions for YouTube).
- Step 2: Dispatch 1 Worker to implement Lenses (`ListBroadcasts`, `GetChatMessages`, `GetStream`), Prisms (`CreateBroadcastPrism`, `SendChatMessagePrism`), resiliency utilities, unit tests.
- Step 3: Dispatch 2 Reviewers, 2 Challengers, and 1 Forensic Auditor.
- Step 4: Gate evaluation.
- Step 5: Mark Milestone 4 DONE.

### Milestone 5: Full E2E Test Suite Pass (Tiers 1-4) & Adversarial Coverage Hardening (Tier 5) [PENDING]
- Step 1: Dispatch Worker for E2E Test Suite (`test/e2e/youtube_integration_e2e_test.exs` covering all Tiers 1-4).
- Step 2: Dispatch 2 Challengers for Tier 5 adversarial stress testing.
- Step 3: Dispatch 2 Reviewers.
- Step 4: Dispatch 1 Final Forensic Auditor.
- Step 5: Final verification and victory handoff to Sentinel.
