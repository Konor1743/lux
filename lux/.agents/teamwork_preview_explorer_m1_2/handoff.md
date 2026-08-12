# Handoff Report — Explorer 2 (Requirement R2 Investigation)

## 1. Observation

1. **Option Flow in `Router.call/3`**:
   In `lib/lux/llm/router.ex` (lines 33–53):
   ```elixir
   def call(prompt, tools \\ [], opts \\ []) do
     opts_map = to_map(opts)

     req_caps = Map.get(opts_map, :capabilities, [])
     req_caps = if tools != [] and :tools not in req_caps, do: [:tools | req_caps], else: req_caps
     opts_with_caps = Map.put(opts_map, :capabilities, req_caps)

     case route(prompt, tools, opts_with_caps) do
       {:ok, {provider_config, model_config}} ->
         call_opts =
           opts_map
           |> Map.put(:model, model_config.id)
           |> Map.put_new(:api_key, provider_config.api_key)
           |> Map.put_new(:endpoint, provider_config.endpoint)

         provider_config.module.call(prompt, tools, call_opts)

       {:error, reason} ->
         {:error, reason}
     end
   end
   ```
   `call_opts` takes `opts_map` directly and only appends `:model`, `:api_key`, and `:endpoint`. Router-exclusive and fallback-exclusive control options remain in `call_opts` when sent to `provider_config.module.call/3`.

2. **Control Options Identification**:
   - Router options: `:strategy`, `:capabilities`, `:registry_name`, `:estimated_prompt_tokens`, `:estimated_completion_tokens`, `:provider_id`.
   - Fallback options: `:primary`, `:fallbacks`, `:fallback_on_all_errors`.
   - Combined set: `[:strategy, :capabilities, :registry_name, :estimated_prompt_tokens, :estimated_completion_tokens, :provider_id, :primary, :fallbacks, :fallback_on_all_errors]`.

3. **`KeyError` Mechanics in Elixir**:
   - In Elixir, `struct!(Module, map)` raises `KeyError` if any key in `map` is not a struct field of `Module`.
   - Passing functions (e.g. `strategy: fn model -> ... end`) into `call_opts` causes inspection/serialization failures if provider adapters log or JSON-encode options.

4. **Existing Tests**:
   - `test/unit/lux/llm/router_test.exs` uses `MockProvider` which accesses `opts[:model]` via `Map.get(opts, :model)` and does not enforce struct options, masking option leakage defects.
   - `test/unit/lux/llm/fallback_test.exs` uses anonymous functions for primary and fallback specs.

---

## 2. Logic Chain

1. **Observation 1** demonstrates that `Router.call/3` passes `opts_map` containing all caller options to `provider_config.module.call/3` without removing control options.
2. **Observation 2** establishes the precise list of control options (`@control_opts`) that are relevant only to routing and fallback mechanisms and are not part of any provider configuration.
3. **Observation 3** shows that when strict provider adapters (or custom provider modules using `struct!(ConfigModule, opts)`) receive these unstripped control options, Elixir raises a `KeyError`.
4. **Observation 4** explains why existing unit tests currently pass: `MockProvider` is permissive and uses `Map.get/2`, masking the control option leakage.
5. Therefore, adding `Map.drop(opts_map, @control_opts)` in `Router.call/3` before delegating to `provider_config.module.call/3` cleanly prevents `KeyError` in strict providers while preserving all valid provider parameters.
6. Implementing automated tests with a `StrictProvider` (using `struct!/2`) and real built-in providers (e.g. `Lux.LLM.OpenAI` with `Req.Test` HTTP mocks) satisfies Acceptance Criterion 2.

---

## 3. Caveats

- Built-in providers (`Lux.LLM.OpenAI`, `Lux.LLM.Anthropic`, `Lux.LLM.Gemini`, `Lux.LLM.OpenRouter`, `Lux.LLM.TogetherAI`, `Lux.LLM.Mira`) currently use standard `struct(Config, map)` which quietly drops unknown keys, so `KeyError` manifests primarily with strict provider adapters, custom providers using `struct!/2`, or functions passed in `:strategy`.
- The option `:model` is used as a filter option in `Router.route/3` as well as a provider parameter. `:model` must NOT be included in `@control_opts` because `Router.call/3` sets `call_opts` `:model` to `model_config.id`.

---

## 4. Conclusion

Requirement R2 requires filtering the exact set of 9 control options:
`[:strategy, :capabilities, :registry_name, :estimated_prompt_tokens, :estimated_completion_tokens, :provider_id, :primary, :fallbacks, :fallback_on_all_errors]` in `Router.call/3` using `Map.drop/2`.

This fix is scoped to `lib/lux/llm/router.ex` and requires unit test additions in `test/unit/lux/llm/router_test.exs` and `test/unit/lux/llm/fallback_test.exs` using strict providers and real built-in provider adapters (`Lux.LLM.OpenAI`) with `Req.Test` HTTP mocks.

---

## 5. Verification Method

1. Inspect detailed investigation findings in:
   `/home/Konor1743/Operacion Dolar/lux/lux/.agents/teamwork_preview_explorer_m1_2/analysis.md`
2. Once implemented in Milestone 2, verify by running:
   ```bash
   mix test test/unit/lux/llm/router_test.exs test/unit/lux/llm/fallback_test.exs
   ```
3. Confirm 0 compiler warnings and 100% passing tests.
