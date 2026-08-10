# Original User Request

## 2026-08-10T00:11:39Z

Resolución de los 3 defectos bloqueantes del PR #99 (Universal LLM Provider Abstraction) reportados en la revisión de código, asegurando que el enrutamiento central funcione correctamente sin errores de llaves ni sobrescritura de credenciales.

Working directory: /home/Konor1743/Operacion Dolar/lux/lux
Integrity mode: development

## Requirements

### R1. Corregir propagación de credenciales nulas en el Router
Modificar `Router.call/3` para que solo inyecte propiedades de configuración (`api_key`, `endpoint`, etc.) provenientes del registro si estas NO son nulas. Esto evitará que un valor nulo del registro sobrescriba las credenciales configuradas a nivel de aplicación del usuario.

### R2. Filtrar opciones de control en el Router
Evitar que `Router.call/3` pase opciones de control exclusivas del enrutador (como `:strategy`, `:capabilities`, `:registry_name`, `:estimated_prompt_tokens`, `:primary`, `:fallbacks`) hacia las configuraciones estrictas de los proveedores. Los proveedores deben recibir solo las opciones que les competen (o hacer un `Map.take/2` explícito) para evitar excepciones `KeyError`.

### R3. Respetar el `endpoint` configurado en el proveedor OpenAI
Modificar `Lux.LLM.OpenAI` para que construya sus peticiones HTTP utilizando el valor dinámico `config.endpoint` en lugar de una constante estática de módulo (`@endpoint`), permitiendo usar proxies o endpoints compatibles con OpenAI configurados por el usuario.

## Acceptance Criteria

### Verificación y Pruebas
- [ ] Existe una prueba automatizada que verifica que una llave (`api_key`) configurada a nivel de aplicación no se pierde ni sobrescribe al usar el registro por defecto.
- [ ] Las pruebas usan proveedores integrados reales a través de `Router` y `Fallback` (no solo simulaciones permisivas) para garantizar que no haya `KeyError` por opciones de control.
- [ ] Existe una prueba que intercepta la petición HTTP de OpenAI y afirma (assert) que la URL destino corresponde al `endpoint` sobreescrito en la configuración.
- [ ] La suite de pruebas completa (`mix test`) pasa exitosamente localmente.
