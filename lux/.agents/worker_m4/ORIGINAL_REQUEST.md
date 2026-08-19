## 2026-08-17T23:34:05Z
You are Worker M4 for Milestone 4 (Resiliency, Quota/Rate Limits & High-Level Lenses/Prisms).
Your working directory is: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/worker_m4`
Project root is: `/home/Konor1743/Operacion Dolar/lux/lux`
Scope document: `/home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md`
Synthesis design: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/orchestrator_gen3/m4_synthesis.md`

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Your task:
1. Review existing code and architectural patterns for Lenses (`lib/lux/lens.ex`, `lib/lux/lenses/`) and Prisms (`lib/lux/prism.ex`, `lib/lux/prisms/`).
2. Implement YouTube Lenses:
   - `lib/lux/lenses/youtube/list_broadcasts.ex` (`Lux.Lenses.YouTube.ListBroadcasts`)
   - `lib/lux/lenses/youtube/get_chat_messages.ex` (`Lux.Lenses.YouTube.GetChatMessages`)
   - `lib/lux/lenses/youtube/get_stream.ex` (`Lux.Lenses.YouTube.GetStream`)
3. Implement YouTube Prisms:
   - `lib/lux/prisms/youtube/create_broadcast.ex` (`Lux.Prisms.YouTube.CreateBroadcast`)
   - `lib/lux/prisms/youtube/send_chat_message.ex` (`Lux.Prisms.YouTube.SendChatMessage`)
4. Enhance resiliency / backoff utilities if needed in `lib/lux/integrations/youtube/errors.ex` or `lib/lux/integrations/youtube/client.ex` (e.g. exponential backoff retry helper).
5. Implement unit tests:
   - `test/unit/lux/lenses/youtube_lenses_test.exs`
   - `test/unit/lux/prisms/youtube_prisms_test.exs`
   - Using offline `Req.Test` plugs.
6. Run builds and tests:
   - `mix compile --warnings-as-errors`
   - `mix test`
   - `mix coveralls` to ensure coverage >90%.
7. Send your completion message with test results.
