# Handoff Report: Explorer 1 (Milestone 1 — YouTube OAuth 2.0)

## 1. Observation
- Inspected existing integration clients in `lib/lux/integrations/discord/client.ex`, `lib/lux/integrations/telegram/client.ex`, `lib/lux/integrations/allora.ex`, and `lib/lux/lens.ex`.
- Directly observed that client modules use `Req.new() |> Req.request()` or `Req.post()`, merging config from `Application.get_env(:lux, __MODULE__, [])` and supporting `:plug` overrides (`opts[:plug]`) for `Req.Test` mocking (`test/unit/lux/integrations/discord/client_test.exs`).
- Inspected `lib/lux/config.ex` (lines 1-142) and `config/runtime.exs` (lines 1-72), confirming central configuration via `get_required_key(:api_keys, key)` and `Dotenvy.env!`.
- Verified Google OAuth 2.0 endpoints and YouTube scopes:
  - Auth Endpoint: `https://accounts.google.com/o/oauth2/v2/auth`
  - Token Endpoint: `https://oauth2.googleapis.com/token`
  - Scopes: `https://www.googleapis.com/auth/youtube`, `https://www.googleapis.com/auth/youtube.force-ssl`, `https://www.googleapis.com/auth/youtube.readonly`
  - Default URL params: `access_type=offline`, `prompt=consent`, `response_type=code`
  - Token exchange/refresh payloads: `application/x-www-form-urlencoded` encoded form bodies with `grant_type=authorization_code` and `grant_type=refresh_token`.

## 2. Logic Chain
1. *Observation*: Google OAuth 2.0 requires `access_type=offline` and `prompt=consent` during the authorization code request to return a `refresh_token` upon code exchange.
   *Inference*: `OAuth.authorize_url/1` must default `access_type` to `"offline"` and `prompt` to `"consent"`.
2. *Observation*: Scopes in Google OAuth 2.0 requests are space-delimited strings (`Enum.join(scopes, " ")`).
   *Inference*: `OAuth.authorize_url/1` should accept either a list of scope binaries or a single string and format them appropriately.
3. *Observation*: The Token endpoint expects `application/x-www-form-urlencoded` POST bodies (`form: %{...}` in `Req`).
   *Inference*: `OAuth.exchange_code/2` and `OAuth.refresh_token/2` should use Req's built-in `form:` option to execute requests against `@token_endpoint`.
4. *Observation*: Codebase tests utilize `UnitAPICase` with `Req.Test` plugs.
   *Inference*: `OAuth` must support `maybe_add_plug(options, opts[:plug])` and `Application.get_env(:lux, __MODULE__, [])` so unit tests can intercept token exchange/refresh calls without external network dependencies.
5. *Observation*: `Lux.Config` centralizes credentials and provides typed helpers.
   *Inference*: `Lux.Config` needs additions for `youtube_client_id/0`, `youtube_client_secret/0`, `youtube_redirect_uri/0`, `youtube_refresh_token/0`, `youtube_api_key/0`.

## 3. Caveats
- No live network requests were executed (operating in CODE_ONLY mode).
- PKCE (Proof Key for Code Exchange with `code_challenge` and `code_verifier`) was omitted as standard Google Web Server App OAuth flow uses `client_secret`, though PKCE can easily be added as optional parameters in `opts` if needed.
- Invalidation condition: If Google deprecates or changes their OAuth 2.0 endpoints or response payload structures.

## 4. Conclusion
The architectural design and exact code specifications for `Lux.Integrations.YouTube.OAuth`, configuration extensions in `Lux.Config` and `config/runtime.exs`, and test suites using `Req.Test` are fully designed and documented in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_1/analysis.md`. The implementer can directly execute code creation following these specifications.

## 5. Verification Method
1. Inspect design in `.agents/explorer_m1_1/analysis.md`.
2. Once implementer writes `lib/lux/integrations/youtube/oauth.ex` and `test/unit/lux/integrations/youtube/oauth_test.exs`, run:
   ```bash
   mix compile --warnings-as-errors
   mix test test/unit/lux/integrations/youtube/oauth_test.exs
   ```
