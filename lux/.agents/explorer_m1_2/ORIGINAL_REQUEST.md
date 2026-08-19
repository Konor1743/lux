## 2026-08-17T17:49:20Z
You are Explorer 2 for Milestone 1: YouTube HTTP Client and Integration Core.
Your working directory is: /home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_2
Read:
- /home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/ORIGINAL_REQUEST.md
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/discord/client.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/telegram/client.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/config.ex
- /home/Konor1743/Operacion Dolar/lux/lux/test/test_helper.exs
- /home/Konor1743/Operacion Dolar/lux/lux/test/unit/lux/integrations/discord/client_test.exs

Your task:
1. Deeply investigate how HTTP clients are structured across the Lux codebase (using `Req`, plug mocking, headers, auth functions).
2. Design `Lux.Integrations.YouTube.Client` and `Lux.Integrations.YouTube`:
   - Base endpoint: `https://www.googleapis.com/youtube/v3`
   - `request(method, path, opts)` supporting `:token`, `:params`, `:json`, `:headers`, `:plug`, and `:auto_refresh` (if token expired or 401 returned, automatically refresh via refresh_token if provided and retry once).
   - Integration into `Lux.Config` (e.g. `youtube_client_id()`, `youtube_client_secret()`, `youtube_api_key()`, `youtube_access_token()`, `youtube_refresh_token()`).
   - Module `Lux.Integrations.YouTube` with standard `request_settings/0`, `headers/0`, `auth/0`, `add_auth_header/1` for `Lux.Lens` and `Plug.Conn`.
3. Detail how `Req.Test` should be integrated in `test_helper.exs` or test modules for unit testing.
4. Write your comprehensive analysis report to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m1_2/analysis.md` and a summary `handoff.md`. Send a message when complete.
