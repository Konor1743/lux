# Original User Request

## 2026-08-02T18:51:11Z

<USER_REQUEST>
Implementación de una Capa Universal de Abstracción para Proveedores LLM (`Lux.LLM.Provider`, `Lux.LLM.ProviderRegistry` y enrutamiento dinámico) en Elixir para **Spectral-Finance/lux** (Bounty #99 - $600 USD), incorporando selección automática de modelos, smart fallbacks ante errores y monitoreo unificado de costos/latencia con pruebas ExUnit.

Working directory: /home/Konor1743/Operacion Dolar/lux/lux
Integrity mode: development

## Requirements

### R1. Interfaz Universal y Registro Central de Proveedores (`ProviderRegistry`)
Diseñar e implementar una interfaz común para proveedores LLM (OpenAI, Gemini, Anthropic, OpenRouter) y un sistema de registro (`ProviderRegistry`) que permita registrar, consultar y gestionar proveedores disponibles de forma dinámica.

### R2. Lógica de Selección Automática de Modelos (Routing)
Implementar algoritmos de selección automática de modelos basados en preferencias o restricciones (ej. enrutamiento por costo `:cheapest`, rendimiento `:smartest` o compatibilidad de capacidades).

### R3. Smart Fallback Handling (Resiliencia ante fallos)
Agregar manejo inteligente de fallbacks: ante errores de red, límite de tasa (429 Rate Limit) o indisponibilidad (503 Service Unavailable) del proveedor primario, el sistema debe redirigir la consulta al siguiente modelo/proveedor de respaldo de forma automática y transparente.

### R4. Cost Tracking, Telemetría y Optimización
Implementar seguimiento y monitoreo de costos y rendimiento (latencia, `prompt_tokens`, `completion_tokens`, costo acumulado), normalizados en las estructuras de señal de Lux.

### R5. Suite de Pruebas ExUnit y Documentación
Crear pruebas unitarias completas en `test/unit/lux/llm/` para verificar el registro de proveedores (`ProviderRegistry`), la selección de modelos y la conmutación por error (fallback), sin llamadas de red ni API keys reales (usando mocks HTTP).

## Acceptance Criteria

### Compilación y Calidad del Monorepo
- [ ] El código compila sin advertencias con `mix compile`.
- [ ] Los módulos se ubican correctamente dentro del paquete `lux/lux/lib/lux/llm/` y `lux/lux/test/unit/lux/llm/` respetando la regla #005 del monorepo.

### Funcionalidad y Cobertura de Pruebas
- [ ] Todas las pruebas de `mix test` para los nuevos módulos se ejecutan en verde al 100%.
- [ ] Se verifica con un test de ExUnit que el registro (`ProviderRegistry`) permite agregar y recuperar proveedores.
- [ ] Se verifica que un fallo simulado (429/503) activa el fallback secundario devolviendo un resultado etiquetado válido (`{:ok, response}`).
- [ ] Se incluye documentación en @moduledoc y @doc con ejemplos claros de uso.
</USER_REQUEST>
