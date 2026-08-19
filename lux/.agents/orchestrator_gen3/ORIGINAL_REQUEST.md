# Original User Request

## 2026-08-17T23:30:55Z

# Teamwork Project Prompt — Draft

> Status: Launched
> Goal: Wait for the teamwork_preview agents to complete the implementation

Implement YouTube Core API Integration and Live Streaming capabilities (Issue #68) for the Lux framework.

[NOTE: This task was previously interrupted by a quota limit error. Milestones 1 & 2 (OAuth, API Client, Errors, Live Broadcasts & Live Streams) are FULLY COMPLETE and their code is already in the working directory passing 219 tests with >90% coverage. Please analyze the repository state, verify the current test coverage, and then proceed directly to Milestone 3 (Live Chat Poller) and beyond to finalize the integration.]

Working directory: /home/Konor1743/Operacion Dolar/lux/lux
Integrity mode: development

## Requirements

### R1. Authentication & API Client
Implement a robust YouTube API client using OAuth 2.0. It must support the full OAuth flow (authorization, token exchange, and automatic token refresh) to manage live streams.

### R2. Live Streaming Management
Implement functionality to create, update, and manage Live Broadcasts and Live Streams via the YouTube Live Streaming API.

### R3. Live Chat Reading
Implement a mechanism to read Live Chat messages from an active broadcast using REST API polling (fetching live chat messages via page tokens).

### R4. Resiliency & Error Handling
Implement robust error handling for YouTube API quota limits (HTTP 403 quotaExceeded) and rate limits.

## Acceptance Criteria

### Automated Verification
- [ ] ExUnit tests use `Req.Test` (or equivalent mock) to intercept outbound YouTube API calls, verifying OAuth headers and payload structures without live network requests.
- [ ] The live chat polling mechanism is explicitly tested by simulating the paginated response loop.
- [ ] Test coverage for the new YouTube integration modules exceeds 90%.
- [ ] The code compiles without warnings (`mix compile --warnings-as-errors`).
