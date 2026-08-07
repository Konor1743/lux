# Original User Request

## Initial Request — 2026-08-07T21:02:25Z

Implementación de la Integración de **Coinbase Exchange** en Elixir para el framework **Spectral-Finance/lux** (Bounty #83 - $750 USD). Incluye conexión a la API Advanced Trade REST y WebSockets para el mercado Spot. Se debe reciclar la misma arquitectura de abstracción que usamos recientemente para Binance (Lenses, Prisms).

Working directory: /home/Konor1743/Operacion Dolar/lux/lux
Integrity mode: development

## Requirements

### R1. Cliente REST API Advanced Trade
Implementar el cliente HTTP autenticado (`Lux.Coinbase.Client`) para interactuar con la API REST de Coinbase Advanced Trade, utilizando HMAC-SHA256 para la autenticación de peticiones privadas según la documentación oficial de Coinbase.

### R2. WebSockets & Market Data (Spot)
Crear Lenses (`CoinbaseTickerPriceLens`, `CoinbaseExchangeInfoLens`) utilizando WebSockex para capturar flujos de datos en tiempo real de Coinbase. Garantizar la conexión y reconexión automática.

### R3. Sistemas de Trading (Prisms para Spot)
Implementar abstracciones nativas de Lux (Prisms) siguiendo fielmente el modelo que hicimos para Binance:
- `CoinbaseSpotAccountPrism`
- `CoinbaseSpotOrderPrism`
- `CoinbaseSpotCancelOrderPrism`
- `CoinbaseSpotOpenOrdersPrism`

### R4. Manejo Estricto de Rate Limiting
Desarrollar middleware (`Lux.Coinbase.RateLimiter`) que intercepte respuestas `429 Too Many Requests` de Coinbase, utilizando el patrón de backoff y pausando las peticiones de los agentes antes de fallar.

### R5. Pruebas Automatizadas ExUnit
Asegurar que cada componente (Auth, Rate Limiter, WebSockets, Prisms) tenga tests unitarios y de integración usando *mocks* y `Req.Test` para evitar usar la red real ni claves en el servidor de CI.

## Acceptance Criteria

### Integridad del Código y Arquitectura
- [ ] El código compila al 100% sin advertencias (`mix compile --warnings-as-errors`).
- [ ] El formato de los archivos sigue los estándares (`mix format`).

### Verificación Funcional
- [ ] Las pruebas pasan localmente (`mix test test/lux/coinbase/`).
- [ ] La estructura de directorios coincide con el estándar del proyecto (`lib/lux/coinbase/`, `lib/lux/prisms/coinbase/`, `lib/lux/lenses/coinbase/`).
