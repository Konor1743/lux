# Milestone 1: Explorer 2 Handoff Report

## 1. Observation
- Inspected existing integration clients:
  - `lib/lux/integrations/discord/client.ex` (lines 1-94): Uses Req pipeline `Req.new(req_opts) |> Req.request()`, injects `Application.get_env(:lux, __MODULE__, [])`, allows custom plug override via `maybe_add_plug/2`, parses 200..299, 401, and error status codes.
  - `lib/lux/integrations/telegram/client.ex` (lines 1-90): Follows identical pattern with Bot token URL prefixing and `ok` wrapper parsing.
  - `lib/lux/integrations/discord.ex` (lines 1-47): Defines `request_settings/0`, `headers/0`, `auth/0`, and `add_auth_header/1` supporting `%Lux.Lens{}` and `%Plug.Conn{}`.
  - `lib/lux/config.ex` (lines 1-142): Centralized config module accessing `:lux, :api_keys` via `get_required_key/2` and `Application.fetch_env!/2`.
  - `test/test_helper.exs` (lines 1-43): Defines `UnitAPICase` injecting `plug: {Req.Test, MockModule}` into `Application.put_env(:lux, ClientModule, ...)`.
  - `test/unit/lux/integrations/discord/client_test.exs` (lines 1-131): Uses `Req.Test.expect/2` and `Req.Test.stub/2` with `verify_on_exit!()` for testing.

## 2. Logic Chain
1. `Lux.Integrations.YouTube.Client` requires communication with `https://www.googleapis.com/youtube/v3` with support for OAuth Bearer token headers and API key parameter fallbacks.
2. Under RFC 6749 and Google OAuth 2.0 specs, access tokens expire after 3600 seconds and Google returns HTTP 401 on expired tokens. By equipping `Client.request/3` with an automatic token refresh loop (`OAuth.refresh_token/2`), when HTTP 401 is encountered and `auto_refresh: true`, the client seamlessly refreshes the access token and retries the outbound request once without exposing transient token expiry to higher-level lenses or prisms.
3. Adding Google-specific error matching for `quotaExceeded` (HTTP 403), `rateLimitExceeded` / `userRateLimitExceeded` (HTTP 403 / 429), and `:invalid_token` (HTTP 401) ensures consistent error tuple contracts (`{:error, {:quota_exceeded, details}}`, `{:error, {:rate_limited, details}}`, `{:error, :invalid_token}`) across all YouTube live streaming and chat modules.
4. Integrating `Lux.Integrations.YouTube` with standard `request_settings/0`, `headers/0`, `auth/0`, and `add_auth_header/1` maintains full compatibility with `Lux.Lens` and `Plug.Conn`.
5. Configuring `Lux.Config` with `youtube_client_id/0`, `youtube_client_secret/0`, `youtube_api_key/0`, `youtube_access_token/0`, and `youtube_refresh_token/0` establishes standard configuration ergonomics.
6. Registering `YouTubeClientMock` and `YouTubeOAuthMock` in `test/test_helper.exs` enables 100% offline, isolated ExUnit testing via `Req.Test`.

## 3. Caveats
- `Lux.Integrations.YouTube.OAuth` must be available or stubbed for `attempt_token_refresh/1` during live token rotation.
- In unit testing, tests that stub `Req.Test.expect(YouTubeClientMock, ...)` must also stub `YouTubeOAuthMock` when testing the full automatic token refresh retry flow.

## 4. Conclusion
The YouTube HTTP Client and Integration Core design is completely specified, robust, and aligned with all Lux architectural patterns. Complete proposed implementations and test matrices are documented in `.agents/explorer_m1_2/analysis.md`.

## 5. Verification Method
- Independent review of `.agents/explorer_m1_2/analysis.md`.
- Inspect proposed module structures:
  - `lib/lux/integrations/youtube/client.ex`
  - `lib/lux/integrations/youtube.ex`
  - `lib/lux/config.ex` additions
  - `test/test_helper.exs` additions
  - `test/unit/lux/integrations/youtube/client_test.exs`
  - `test/unit/lux/integrations/youtube_test.exs`
- When implemented, verify with:
  ```bash
  mix compile --warnings-as-errors
  mix test test/unit/lux/integrations/youtube/
  ```
