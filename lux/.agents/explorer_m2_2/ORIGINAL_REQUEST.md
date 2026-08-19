## 2026-08-17T18:41:07Z
You are Explorer 2 for Milestone 2: YouTube Live Streams Management.
Your working directory is: /home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m2_2
Read:
- /home/Konor1743/Operacion Dolar/lux/lux/PROJECT.md
- /home/Konor1743/Operacion Dolar/lux/lux/.agents/ORIGINAL_REQUEST.md
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/youtube/client.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/youtube/errors.ex
- /home/Konor1743/Operacion Dolar/lux/lux/lib/lux/integrations/youtube.ex

Your task:
1. Deeply investigate the YouTube Live Streaming API for Live Streams (`liveStreams` resource).
2. Endpoints and methods to design in `Lux.Integrations.YouTube.LiveStreams`:
   - `create_stream/2` (`POST /liveStreams?part=snippet,cdn,status,contentDetails`): title, description, `cdn` configuration (`ingestionType` like `"rtmp"`, `resolution` like `"1080p"`, `"720p"`, `"variable"`, `frameRate` like `"60fps"`, `"30fps"`, `"variable"`). Response includes `cdn.ingestionInfo.ingestionAddress`, `cdn.ingestionInfo.streamName` (stream key), and backup ingestion address.
   - `list_streams/2` (`GET /liveStreams?part=snippet,cdn,status,contentDetails`): `mine=true`, `id`, `maxResults`, `pageToken`.
   - `get_stream/2` (`GET /liveStreams?part=snippet,cdn,status,contentDetails&id=...`).
   - `update_stream/2` (`PUT /liveStreams?part=snippet,cdn,status,contentDetails`).
   - `delete_stream/2` (`DELETE /liveStreams?id=...`).
3. Provide exact typespecs, function signatures, default `part` parameters, options handling, error propagation via `Client.request/3`, and `Req.Test` mock fixtures.
4. Write your comprehensive analysis report to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m2_2/analysis.md` and handoff report to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/explorer_m2_2/handoff.md`. Send a message when done.
