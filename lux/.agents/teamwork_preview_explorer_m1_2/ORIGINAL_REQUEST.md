## 2026-08-10T00:12:53Z
You are Explorer 2 investigating Requirement R2 for PR #99.

Working directory: /home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2
Project root: /home/Konor1743/Operacion Dolar/lux/lux

Your objective:
1. Investigate how `Router.call/3` (or relevant functions in `Lux.LLM.Router`) passes options to LLM providers.
2. Specifically analyze R2: Filter router-exclusive control options (such as `:strategy`, `:capabilities`, `:registry_name`, `:estimated_prompt_tokens`, `:primary`, `:fallbacks`) so they are NOT passed down to strict provider configurations.
3. Identify where providers raise `KeyError` when unexpected options are received, and determine the exact set of control options to filter or how providers should take allowed options (`Map.take/2` or keyword filtering).
4. Examine existing tests for `Router` and `Fallback`.
5. Plan the tests for Acceptance Criterion 2: "Las pruebas usan proveedores integrados reales a través de `Router` y `Fallback` (no solo simulaciones permisivas) para garantizar que no haya `KeyError` por opciones de control."
6. Write your detailed findings and recommendations in `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/analysis.md` and write your handoff report to `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/handoff.md`.
7. Notify the orchestrator via send_message when done. Do NOT edit source code files.
