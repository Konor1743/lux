defmodule Lux.LLM.Router do
  @moduledoc """
  Dynamic LLM Router for selecting and invoking the optimal LLM provider and model.

  Evaluates registered providers and models from `Lux.LLM.ProviderRegistry` based on required capabilities
  (such as `:vision`, `:tools`, `:json_schema`, `:reasoning`) and selection algorithms (`:cheapest`, `:smartest`).
  """

  alias Lux.LLM.ModelConfig
  alias Lux.LLM.ProviderConfig
  alias Lux.LLM.ProviderRegistry
  alias Lux.Signal

  @type strategy :: :cheapest | :smartest | (ModelConfig.t() -> number())
  @type prompt :: Lux.LLM.Provider.prompt()
  @type tools :: Lux.LLM.Provider.tools()
  @type opts :: map() | keyword()

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

  @doc """
  Routes an LLM call to the optimal provider/model combination and executes the request.

  ## Options

  - `:strategy` - Selection algorithm: `:cheapest` (default) or `:smartest`.
  - `:capabilities` - List of required capability atoms (e.g. `[:vision, :tools]`).
  - `:estimated_prompt_tokens` - Token count used for cost estimation (default: 1000).
  - `:estimated_completion_tokens` - Token count used for cost estimation (default: 1000).
  - `:registry_name` - GenServer name of `ProviderRegistry` (default: `Lux.LLM.ProviderRegistry`).
  - `:provider_id` - Filter candidates by provider ID atom (e.g. `:openai`).
  - `:model` - Filter candidates by exact model ID string (e.g. `"gpt-4o"`).
  """
  @spec call(prompt(), tools(), opts()) :: {:ok, Signal.t()} | {:error, term()}
  def call(prompt, tools \\ [], opts \\ []) do
    opts_map = to_map(opts)

    req_caps = Map.get(opts_map, :capabilities, [])
    req_caps = if tools != [] and :tools not in req_caps, do: [:tools | req_caps], else: req_caps
    opts_with_caps = Map.put(opts_map, :capabilities, req_caps)

    case route(prompt, tools, opts_with_caps) do
      {:ok, {provider_config, model_config}} ->
        call_opts =
          opts_map
          |> Map.drop(@control_opts)
          |> Map.put(:model, model_config.id)
          |> maybe_put_new(:api_key, provider_config.api_key)
          |> maybe_put_new(:endpoint, provider_config.endpoint)

        provider_config.module.call(prompt, tools, call_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Evaluates candidates registered in `Lux.LLM.ProviderRegistry` and selects the matching `{ProviderConfig, ModelConfig}` tuple.
  """
  @spec route(prompt(), tools(), opts()) ::
          {:ok, {ProviderConfig.t(), ModelConfig.t()}} | {:error, term()}
  def route(_prompt, tools \\ [], opts \\ []) do
    opts_map = to_map(opts)
    registry_name = Map.get(opts_map, :registry_name, ProviderRegistry)

    case GenServer.whereis(registry_name) do
      nil ->
        {:error, :registry_not_running}

      _pid ->
        try do
          req_caps = Map.get(opts_map, :capabilities, [])
          req_caps = if tools != [] and :tools not in req_caps, do: [:tools | req_caps], else: req_caps

          filter_opts = [
            registry_name: registry_name,
            capabilities: req_caps,
            status: :active
          ]

          filter_opts =
            if provider_id = Map.get(opts_map, :provider_id) do
              Keyword.put(filter_opts, :provider_id, provider_id)
            else
              filter_opts
            end

          models = ProviderRegistry.list_models(filter_opts)

          models =
            if target_model = Map.get(opts_map, :model) do
              Enum.filter(models, &(&1.id == target_model))
            else
              models
            end

          case models do
            [] ->
              {:error, :no_matching_model}

            candidates ->
              strategy = Map.get(opts_map, :strategy, :cheapest)
              selected_model = select_candidate(candidates, strategy, opts_map)

              case ProviderRegistry.get_provider(selected_model.provider_id, registry_name: registry_name) do
                {:ok, provider_config} ->
                  {:ok, {provider_config, selected_model}}

                {:error, reason} ->
                  {:error, {:provider_not_found, selected_model.provider_id, reason}}
              end
          end
        catch
          :exit, {:noproc, _} ->
            {:error, :registry_not_running}

          :exit, :noproc ->
            {:error, :registry_not_running}
        end
    end
  end

  @doc """
  Calculates the total token cost for a model config given prompt and completion token counts.
  """
  @spec calculate_cost(ModelConfig.t(), non_neg_integer(), non_neg_integer()) :: float()
  def calculate_cost(%ModelConfig{} = model, prompt_tokens, completion_tokens) do
    prompt_cost = (prompt_tokens / 1000.0) * model.cost_per_1k_prompt_tokens
    completion_cost = (completion_tokens / 1000.0) * model.cost_per_1k_completion_tokens
    prompt_cost + completion_cost
  end

  # Selection algorithms

  defp select_candidate(candidates, :cheapest, opts) do
    prompt_tokens = Map.get(opts, :estimated_prompt_tokens, 1000)
    completion_tokens = Map.get(opts, :estimated_completion_tokens, 1000)

    Enum.min_by(candidates, fn model ->
      calculate_cost(model, prompt_tokens, completion_tokens)
    end)
  end

  defp select_candidate(candidates, :smartest, _opts) do
    Enum.max_by(candidates, fn model ->
      {model.context_window, model.cost_per_1k_prompt_tokens}
    end)
  end

  defp select_candidate(candidates, fun, _opts) when is_function(fun, 1) do
    Enum.min_by(candidates, fun)
  end

  defp select_candidate(candidates, _fallback, opts) do
    select_candidate(candidates, :cheapest, opts)
  end

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Enum.into(opts, %{})
  defp to_map(_), do: %{}

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)
end
