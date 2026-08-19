## 2026-08-17T17:51:46Z

You are Worker 1 for Milestone 1: YouTube OAuth 2.0 & API Client.
Your working directory is: /home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_m1

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Scope and Instructions:
Implement Milestone 1 per the specifications in:
- /home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_1/analysis.md
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_2/analysis.md
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_3/analysis.md

Files to implement/update:
1. `lib/lux/integrations/youtube/oauth.ex`:
   - Full OAuth 2.0 authorization URL builder, code exchange, and token refresh with Req.
2. `lib/lux/integrations/youtube/errors.ex`:
   - Parsing Google API error payloads, mapping quotaExceeded (403), rate limits (403/429), auth errors (401), domain errors, and backoff utility.
3. `lib/lux/integrations/youtube/client.ex`:
   - Core Req HTTP client for YouTube Data API v3, managing auth headers, query parameters, json bodies, automatic token refresh retry loop on 401, and error parsing.
4. `lib/lux/integrations/youtube.ex`:
   - Standard integration module with request_settings/0, headers/0, auth/0, add_auth_header/1 for Lux.Lens and Plug.Conn.
5. `lib/lux/config.ex` & `config/runtime.exs`:
   - Add YouTube config accessors (`youtube_client_id`, `youtube_client_secret`, `youtube_redirect_uri`, `youtube_api_key`, `youtube_access_token`, `youtube_refresh_token`). Ensure defaults in dev/test so missing env vars don't crash when not configured.
6. `test/test_helper.exs`:
   - Register YouTubeClientMock and YouTubeOAuthMock in `UnitAPICase` setup.
7. Unit tests:
   - `test/unit/lux/integrations/youtube/oauth_test.exs`
   - `test/unit/lux/integrations/youtube/errors_test.exs`
   - `test/unit/lux/integrations/youtube/client_test.exs`
   - `test/unit/lux/integrations/youtube_test.exs`

Verification:
- Run `mix compile --warnings-as-errors`
- Run `mix test test/unit/lux/integrations/youtube/`
- Run existing unit tests `mix test --exclude integration --exclude skip`
- Ensure 100% passing tests and >90% coverage on new modules.
- Write your completion report to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_m1/handoff.md`.
- Send a message when complete.
