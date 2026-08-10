# Explorer 1 Handoff Report: Requirement R1 (Credential Merging in Router)

## 1. Observation

- **`lib/lux/llm/router.ex:42-47`**:
  ```elixir
  call_opts =
    opts_map
    |> Map.put(:model, model_config.id)
    |> Map.put_new(:api_key, provider_config.api_key)
    |> Map.put_new(:endpoint, provider_config.endpoint)
  ```
  `Map.put_new/3` inserts `:api_key => nil` and `:endpoint => nil` into `call_opts` whenever `provider_config.api_key` or `provider_config.endpoint` is `nil` and key `:api_key`/`:endpoint` is missing from `opts_map`.

- **`lib/lux/llm/provider_registry.ex:48-55`**:
  Providers registered via module atom (the default in `ProviderRegistry`) produce a `%ProviderConfig{}` struct with `api_key: nil` and `endpoint: nil`.

- **`lib/lux/llm/open_ai.ex:107-116`** (and Anthropic, OpenRouter, Gemini, TogetherAI):
  ```elixir
  config =
    struct(
      Config,
      Map.merge(
        %{
          model: Application.get_env(:lux, :open_ai_models)[:default] || "gpt-4",
          api_key: Application.get_env(:lux, :api_keys)[:openai]
        },
        opts_map
      )
    )
  ```
  `Map.merge/2` takes `opts_map` (`call_opts`) and overrides the application default `%{:api_key => "sk-app-key"}` with `%{api_key: nil}`, losing the application-configured key.

- **`test/unit/lux/llm/router_test.exs`**:
  11 unit tests present, all passing when run with `mix test test/unit/lux/llm/router_test.exs --include unit`.
  Currently no test verifies `Application.get_env(:lux, :api_keys)` preservation during `Router.call/3`.

---

## 2. Logic Chain

1. In `ProviderRegistry`, registered providers default `api_key` and `endpoint` to `nil`.
2. When a user invokes `Router.call(prompt, tools, opts)`, if `:api_key` is omitted in `opts`, `opts_map` has no `:api_key` key.
3. `Router.call/3` uses `Map.put_new(opts_map, :api_key, provider_config.api_key)`. Because `:api_key` is not in `opts_map`, `Map.put_new` adds `:api_key => nil` to `call_opts`.
4. `call_opts` (`%{api_key: nil}`) is passed to `provider_module.call(prompt, tools, call_opts)`.
5. The provider module calls `Map.merge(%{api_key: Application.get_env(...)}, call_opts)`, replacing `"sk-app-key"` with `nil`.
6. Therefore, `Router.call/3` must be modified to only inject `api_key` and `endpoint` into `call_opts` if their values in `provider_config` are NOT `nil`.
7. This can be achieved cleanly with a helper function:
   ```elixir
   defp maybe_put_new(map, _key, nil), do: map
   defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)
   ```
   and updating `call_opts` pipeline in `Router.call/3`:
   ```elixir
   call_opts =
     opts_map
     |> Map.put(:model, model_config.id)
     |> maybe_put_new(:api_key, provider_config.api_key)
     |> maybe_put_new(:endpoint, provider_config.endpoint)
   ```

---

## 3. Caveats

- **Existing Registry Behavior**: If a provider in `ProviderRegistry` is explicitly registered with a non-nil `api_key: "sk-reg-key"`, `maybe_put_new` will inject `"sk-reg-key"` into `call_opts`, overriding the application config. This is the intended behavior (registry override).
- **Codebase Read-only Constraint**: Explorer 1 did not modify any source files (`lib/lux/llm/router.ex` or `test/unit/lux/llm/router_test.exs`), adhering strictly to read-only investigation rules. Implementation must be carried out by Implementer agent.

---

## 4. Conclusion

- **Root Cause Confirmed**: `Map.put_new` in `Router.call/3` unconditionally sets `:api_key => nil` and `:endpoint => nil` when `provider_config` values are `nil`, overwriting `Application.get_env(:lux, :api_keys)` during provider option merging.
- **Solution Specified**: Replace direct `Map.put_new` calls in `Router.call/3` with conditional `maybe_put_new/3` calls that ignore `nil` values.
- **Test Plan Formulated for AC1**: A new test block in `test/unit/lux/llm/router_test.exs` using `AppKeyTestProvider` will set `Application.put_env(:lux, :api_keys, ...)`, register a default provider without API key, invoke `Router.call/3`, and verify the application API key is preserved in the resulting signal payload.

---

## 5. Verification Method

To verify the issue and solution:
1. Run existing router test suite:
   ```bash
   mix test test/unit/lux/llm/router_test.exs --include unit
   ```
2. Inspect `lib/lux/llm/router.ex` lines 41-48 to confirm the target code location.
3. Review `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_1/analysis.md` for full implementation patch and test design.
