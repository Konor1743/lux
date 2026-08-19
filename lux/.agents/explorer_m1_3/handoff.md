# Handoff Report — Explorer 3: YouTube API Error Handling & Resiliency

## 1. Observation
- **`PROJECT.md:40-43`**: Client contract explicitly specifies:
  > `request(method, path, opts \\ %{}) :: {:ok, map()} | {:error, term()}`
  > Returns decoded JSON body on 2xx, or structured error tuples on failure (`{:error, {:quota_exceeded, details}}`, `{:error, {:rate_limited, details}}`, `{:error, :invalid_token}`, `{:error, {status, message}}`).
- **`PROJECT.md:16-18, 70`**: Code layout explicitly specifies:
  > `lib/lux/integrations/youtube/errors.ex` — Quota, rate limit, and domain errors
  > Explicit parsing and error mapping for HTTP 403 `quotaExceeded` / `rateLimitExceeded` and HTTP 429.
- **`lib/lux/integrations/discord/client.ex:69-82`**: Discord client error patterns:
  > `{:ok, %{status: status} = response} when status in 200..299 -> {:ok, response.body}`
  > `{:ok, %{status: 401}} -> {:error, :invalid_token}`
  > `{:ok, %{status: status, body: %{"message" => message}}} -> {:error, {status, message}}`
- **`lib/lux/integrations/telegram/client.ex:67-85`**: Telegram client error patterns:
  > `{:ok, %{status: 401}} -> {:error, :invalid_token}`
  > `{:ok, %{status: status, body: %{"description" => message}}} -> {:error, {status, message}}`
- **`test/test_helper.exs:25-27`**:
  > `Application.put_env(:lux, DiscordClient, plug: {Req.Test, DiscordClientMock})`
  > `Application.put_env(:lux, TelegramClient, plug: {Req.Test, TelegramClientMock})`
- **`mix.exs:69`**: Req dependency is `{:req, "~> 0.5.0"}` with built-in `Req.Test`.
- **Google API v3 error payloads**: Google wraps errors in `%{"error" => %{"code" => integer(), "message" => String.t(), "errors" => [%{"domain" => ..., "reason" => ...}]}}`.

## 2. Logic Chain
1. *From Obs 1 & 7*: Google API error bodies use nested maps with `error.errors` lists containing `reason` and `domain`. Standard Discord/Telegram client matching (`%{"message" => message}`) would fail to extract the real reason/message for YouTube API errors without dedicated parsing.
2. *From Obs 1 & 2*: YouTube API returns HTTP 403 for both `quotaExceeded` (daily project quota) and `userRateLimitExceeded` / `rateLimitExceeded` (per-user/burst limits).
3. *From Step 2*: Because `quotaExceeded` resets only at 00:00 PT, retrying it is useless and must immediately return `{:error, {:quota_exceeded, details}}`. Conversely, `rateLimitExceeded` / `userRateLimitExceeded` / HTTP 429 are transient and can be retried with exponential backoff and jitter, returning `{:error, {:rate_limited, details}}`.
4. *From Obs 1, 3, 4*: HTTP 401 should trigger automatic token refresh if `:refresh_token` is present and `:auto_refresh` is true. If refresh fails or is not configured, returning `{:error, :invalid_token}` maintains consistency with Discord and Telegram integrations.
5. *From Obs 5 & 6*: `Req.Test` allows deterministic stubbing of all 10+ error response types via `{Req.Test, MockModule}` and plug passing without any external HTTP calls.

## 3. Caveats
- Google Cloud API Gateway occasionally formats errors using gRPC-style `details` lists (e.g. `ErrorInfo` objects with `reason: "RATE_LIMIT_EXCEEDED"`) rather than the v3 `errors` list. The designed `Errors.parse/3` module defends against both formats.
- Some edge case HTTP 502/503 proxies return raw HTML bodies (e.g. `<html>502 Bad Gateway</html>`). Defensive parsing falls back to `{status, default_message}` instead of crashing.

## 4. Conclusion
- The dedicated `Lux.Integrations.YouTube.Errors` module cleanly addresses all requirements for Milestone 1 and downstream milestones (Live Chat Poller and Prisms).
- `Errors.parse/3` accurately classifies:
  1. `{:error, {:quota_exceeded, %{reason: "quotaExceeded", message: ..., status: 403, domain: ..., details: ...}}}`
  2. `{:error, {:rate_limited, %{reason: ..., message: ..., status: 403 | 429, retry_after: ..., details: ...}}}`
  3. `{:error, :invalid_token}` for 401 / unauthenticated responses
  4. `{:error, {status, message}}` for 400, 404, 500, 503, and non-quota 403s
- Full design specifications, JSON fixtures, exponential backoff utility, and `Req.Test` unit test suites are delivered in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_3/analysis.md`.

## 5. Verification Method
- Review `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_3/analysis.md` for complete code listings and test assertions.
- Verify that error categorizations match Google API v3 specifications.
- When implemented in Worker phase:
  - Run `mix test test/unit/lux/integrations/youtube/errors_test.exs`
  - Run `mix test test/unit/lux/integrations/youtube/client_test.exs`
  - Run `mix compile --warnings-as-errors`
