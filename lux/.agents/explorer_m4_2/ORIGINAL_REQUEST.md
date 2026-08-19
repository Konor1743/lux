## 2026-08-17T23:33:47Z
You are Explorer 2 for Milestone 4 (Resiliency, Quota/Rate Limits & High-Level Lenses/Prisms).
Your working directory is: `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m4_2`
Project root is: `/home/Konor1743/Operacion Dolar/lux/lux`
Scope document: `/home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md`

Your task:
1. Design the YouTube Lenses and Prisms:
   - `Lux.Lenses.YouTube.ListBroadcasts`: fetches broadcasts list matching broadcastStatus / mine / options.
   - `Lux.Lenses.YouTube.GetChatMessages`: fetches messages from live chat.
   - `Lux.Lenses.YouTube.GetStream`: fetches live stream info.
   - `Lux.Prisms.YouTube.CreateBroadcast`: creates live broadcast.
   - `Lux.Prisms.YouTube.SendChatMessage`: sends chat message to live chat.
2. Define their schema declarations, parameter validation, integration with `Lux.Integrations.YouTube.*`, return tuples, and error wrapping.
3. Write your module specifications to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m4_2/handoff.md` and send a message back.
