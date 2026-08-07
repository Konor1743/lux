# Context

## Project Constraints
- Framework: Spectral-Finance/lux (Elixir)
- Working directory: `/home/Konor1743/Operacion Dolar/lux/lux`
- Directives: Follow Lux Lens & Prism architecture recycled from Binance implementation.
- Required directory structure:
  - `lib/lux/coinbase/`
  - `lib/lux/prisms/coinbase/`
  - `lib/lux/lenses/coinbase/`
  - `test/lux/coinbase/`
- Verification commands to be run by workers:
  - `mix compile --warnings-as-errors`
  - `mix format --check-formatted`
  - `mix test test/lux/coinbase/`
