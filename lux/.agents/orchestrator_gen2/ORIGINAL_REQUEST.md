# Original User Request

## 2026-08-17T17:47:26Z

# Teamwork Project Prompt — Draft

> Status: Launched
> Goal: Wait for the teamwork_preview agents to complete the implementation

Implement YouTube Core API Integration and Live Streaming capabilities (Issue #68) for the Lux framework.

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

## 2026-08-17T19:06:10Z

Resuming as Project Orchestrator (Generation 2).
Predecessor state preserved. Milestone 1 completed. Milestone 2 implemented by Worker 2.
Driving Milestones 2-5 to full completion.
