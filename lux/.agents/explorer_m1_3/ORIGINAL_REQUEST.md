## 2026-08-17T17:49:20Z
You are Explorer 3 for Milestone 1: YouTube API Error Handling & Resiliency.
Your working directory is: /home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_3
Read:
- /home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/ORIGINAL_REQUEST.md
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/discord/client.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/telegram/client.ex

Your task:
1. Investigate YouTube API error responses:
   - Quota limit exceeded (HTTP 403, error reason `quotaExceeded`)
   - Rate limit exceeded (HTTP 403, error reason `rateLimitExceeded` / `userRateLimitExceeded`, or HTTP 429)
   - Authentication errors (HTTP 401, error reason `authError`, `invalid_token`)
   - Invalid request / not found / forbidden (400, 404, other 403s)
   - Server errors (500, 503)
2. Design error structures/modules `Lux.Integrations.YouTube.Errors` or error parsing in `Client`:
   - `{:error, {:quota_exceeded, %{reason: ..., message: ..., status: 403}}}`
   - `{:error, {:rate_limited, %{reason: ..., message: ..., status: ...}}}`
   - `{:error, :invalid_token}`
   - `{:error, {status, message}}`
3. Design retry strategy and test fixtures with `Req.Test` for verifying quota and rate limit parsing.
4. Write your comprehensive analysis report to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_3/analysis.md` and a summary `handoff.md`. Send a message when complete.
