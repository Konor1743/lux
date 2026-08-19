## 2026-08-17T17:49:19Z

You are Explorer 1 for Milestone 1: YouTube OAuth 2.0 and API Client.
Your working directory is: /home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_1
Read:
- /home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/ORIGINAL_REQUEST.md
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/discord.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/discord/client.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/allora.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/config.ex

Your task:
1. Deeply investigate how Google OAuth 2.0 flow should be structured in Elixir for the YouTube API.
2. Determine exact endpoints:
   - Authorization URL endpoint: `https://accounts.google.com/o/oauth2/v2/auth`
   - Token endpoint: `https://oauth2.googleapis.com/token`
   - Scopes needed for YouTube Live Streaming API: `https://www.googleapis.com/auth/youtube`, `https://www.googleapis.com/auth/youtube.force-ssl`, `https://www.googleapis.com/auth/youtube.readonly`
3. Design module `Lux.Integrations.YouTube.OAuth`:
   - `authorize_url(opts)`: query params (`client_id`, `redirect_uri`, `scope`, `response_type=code`, `access_type=offline`, `prompt=consent`, `state`)
   - `exchange_code(code, opts)`: POST to token endpoint with `client_id`, `client_secret`, `redirect_uri`, `grant_type=authorization_code`, `code`. Return `{:ok, %{"access_token" => ..., "refresh_token" => ..., "expires_in" => ...}}` or `{:error, term()}`.
   - `refresh_token(refresh_token, opts)`: POST to token endpoint with `client_id`, `client_secret`, `grant_type=refresh_token`, `refresh_token`. Return `{:ok, %{"access_token" => ..., "expires_in" => ...}}` or `{:error, term()}`.
4. Provide concrete code signatures, specs, test strategies with `Req.Test`, and implementation guidelines.
5. Write your comprehensive analysis report to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_1/analysis.md` and a summary `handoff.md`. Send a message when complete.
