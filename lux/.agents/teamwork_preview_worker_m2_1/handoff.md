# Handoff Report — PR #99 Fixes for R1, R2, R3 and Acceptance Tests

## 1. Observation

- **R1 Defect (Null Credential Propagation)**:
  - **File**: `lib/lux/llm/router.ex` (lines 45-46 prior to fix).
  - **Issue**: `Router.call/3` constructed `call_opts` using `Map.put_new(:api_key, provider_config.api_key)` and `Map.put_new(:endpoint, provider_config.endpoint)`. When providers were registered via `ProviderRegistry` defaults (where `api_key: nil` and `endpoint: nil`), `call_opts` was populated with `:api_key => nil` and `:endpoint => nil`. In `Lux.LLM.OpenAI.call/3`, merging `call_opts` over default application config caused `Application.get_env(:lux, :api_keys)[:openai]` to be overwritten by `nil`.

- **R2 Defect (Control Options Filtering)**:
  - **File**: `lib/lux/llm/router.ex` (lines 42-48 prior to fix).
  - **Issue**: Router and Fallback control options (`:strategy`, `:capabilities`, `:registry_name`, `:estimated_prompt_tokens`, `:estimated_completion_tokens`, `:provider_id`, `:primary`, `:fallbacks`, `:fallback_on_all_errors`) were passed directly in `call_opts` to `provider_config.module.call/3`. Provider modules enforcing configuration schemas with `struct!/2` raised `KeyError` on unknown control keys.

- **R3 Defect (Dynamic OpenAI Endpoint)**:
  - **File**: `lib/lux/llm/open_ai.ex` (line 134 prior to fix).
  - **Issue**: `OpenAI.call/3` hardcoded `url: @endpoint` (`"https://api.openai.com/v1/chat/completions"`), ignoring any custom `endpoint` specified in `config.endpoint`.

- **Verification Executed**:
  - `mix compile`: 0 compilation errors.
  - `mix test --only unit test/unit/lux/llm/router_test.exs test/unit/lux/llm/open_ai_test.exs test/unit/lux/llm/fallback_test.exs`: 32 tests, 0 failures.
  - `mix test`: 1373 tests, 0 failures.

---

## 2. Logic Chain

1. **R1 Fix**:
   - Defined helper function `maybe_put_new/3`:
     ```elixir
     defp maybe_put_new(map, _key, nil), do: map
     defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)
     ```
   - Updated `call_opts` construction in `Router.call/3`:
     ```elixir
     call_opts =
       opts_map
       |> Map.drop(@control_opts)
       |> Map.put(:model, model_config.id)
       |> maybe_put_new(:api_key, provider_config.api_key)
       |> maybe_put_new(:endpoint, provider_config.endpoint)
     ```
   - When `provider_config.api_key` or `provider_config.endpoint` is `nil`, `maybe_put_new/3` leaves `opts_map` unchanged, omitting `nil` keys. Downstream providers (e.g. `Lux.LLM.OpenAI`) then successfully fall back to application-level configuration or struct defaults.

2. **R2 Fix**:
   - Defined module attribute `@control_opts`:
     ```elixir
     @control_opts [
       :strategy,
       :capabilities,
       :registry_name,
       :estimated_prompt_tokens,
       :estimated_completion_tokens,
       :provider_id,
       :primary,
       :fallbacks,
       :fallback_on_all_errors
     ]
     ```
   - Applied `Map.drop(opts_map, @control_opts)` in `Router.call/3` prior to invoking `provider_config.module.call/3`. Control parameters used by `Router` or `Fallback` are stripped from provider options, preventing `KeyError` exceptions when providers validate options via `struct!/2`.

3. **R3 Fix**:
   - Updated `url` parameter in `Lux.LLM.OpenAI.call/3`:
     ```elixir
     url: Lux.Config.resolve(config.endpoint || @endpoint),
     ```
   - This resolves `config.endpoint` dynamically via `Lux.Config.resolve/1`, falling back to `@endpoint` when `config.endpoint` is nil or unset.

4. **Automated Acceptance Tests**:
   - **AC1 Test** (`test/unit/lux/llm/router_test.exs`): Set application env `api_keys: [openai: "test-app-level-key"]`, called `Router.call/3` against a default registry with `api_key: nil`, and verified via `Req.Test.expect` that `"Authorization"` header preserves `"Bearer test-app-level-key"`.
   - **AC2 Tests** (`test/unit/lux/llm/router_test.exs` & `test/unit/lux/llm/fallback_test.exs`): Defined `StrictProvider` using `struct!(StrictConfig, opts)`. Passed full `@control_opts` set through `Router.call/3` and `Fallback.call/3` with both `StrictProvider` and `Lux.LLM.OpenAI`. Verified no `KeyError` was raised and responses returned successfully.
   - **AC3 Test** (`test/unit/lux/llm/open_ai_test.exs`): Called `OpenAI.call/3` with custom endpoint `"http://localhost:4000/custom/v1/chat/completions"`. Intercepted request with `Req.Test.expect` and asserted `scheme == :http`, `host == "localhost"`, `port == 4000`, and `request_path == "/custom/v1/chat/completions"`.
   - **AC4 Verification**: Ran full test suite `mix test`, confirming 0 test failures.

---

## 3. Caveats

- `maybe_put_new/3` strictly checks for `nil`. If explicit non-nil values are specified in `provider_config`, they will be inserted into `call_opts` unless already present.
- `@control_opts` filtering takes place inside `Router.call/3`. Direct provider module invocations outside the router handle options per their module logic.

---

## 4. Conclusion

All requested defects (R1, R2, R3) are resolved with genuine implementations, minimal code changes, and clean compilation. Automated acceptance tests AC1, AC2, and AC3 cover all edge cases, and AC4 verification confirms that 100% of the project test suite passes with 0 failures.

---

## 5. Verification Method

To independently verify the implementation and test coverage:

1. **Compile the project**:
   ```bash
   mix compile
   ```
   *Expected output*: Compiles cleanly with 0 errors.

2. **Run targeted LLM unit tests (AC1, AC2, AC3)**:
   ```bash
   mix test --only unit test/unit/lux/llm/router_test.exs test/unit/lux/llm/open_ai_test.exs test/unit/lux/llm/fallback_test.exs
   ```
   *Expected output*: 32 tests, 0 failures.

3. **Run full project test suite (AC4)**:
   ```bash
   mix test
   ```
   *Expected output*: All tests pass with 0 failures.
