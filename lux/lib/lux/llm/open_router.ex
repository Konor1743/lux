defmodule Lux.LLM.OpenRouter do
  @moduledoc """
  OpenRouter LLM implementation that supports passing Beams, Prisms, and Lenses as tools.

  OpenRouter provides an OpenAI-compatible interface with custom headers for site
  attribution (`HTTP-Referer` and `X-OpenRouter-Title`). It acts as a unified
  gateway supporting hundreds of models from different providers (OpenAI,
  Anthropic, Meta, Google, etc.) through a single API.

  ## Differences from `Lux.LLM.OpenAI`

  - **`json_response` defaults to `false`**: OpenRouter is a multi-model gateway,
    and many models do not support `response_format`. Users should explicitly set
    `json_response: true` when using models that support structured output.

  - **Plain-text content handling**: Unlike the OpenAI provider, `parse_content/1`
    wraps non-JSON text responses in `%{"text" => content}` instead of returning
    an error. This is intentional since OpenRouter routes to models that
    frequently return plain-text responses.

  - **Site attribution headers**: Supports optional `HTTP-Referer` and
    `X-OpenRouter-Title` headers for app identification on OpenRouter leaderboards.
    Configure via `site_url`/`site_name` or `http_referer`/`openrouter_title` keys.
  """

  @behaviour Lux.LLM

  alias Lux.Beam
  alias Lux.Lens
  alias Lux.LLM.ResponseSignal
  alias Lux.Prism

  require Beam
  require Lens
  require Logger

  @default_endpoint "https://openrouter.ai/api/v1/chat/completions"

  defmodule Config do
    @moduledoc """
    Configuration module for OpenRouter.
    """
    @type t :: %__MODULE__{
            endpoint: String.t(),
            model: String.t() | nil,
            api_key: String.t() | nil,
            site_url: String.t() | nil,
            site_name: String.t() | nil,
            http_referer: String.t() | nil,
            openrouter_title: String.t() | nil,
            temperature: float(),
            frequency_penalty: float(),
            receive_timeout: integer(),
            seed: integer() | nil,
            n: integer(),
            json_response: boolean(),
            json_schema: map() | atom() | nil,
            max_tokens: integer() | nil,
            tool_choice: map() | String.t() | atom() | nil,
            user: String.t() | nil,
            messages: [map()]
          }

    defstruct endpoint: "https://openrouter.ai/api/v1/chat/completions",
              model: nil,
              api_key: nil,
              site_url: nil,
              site_name: nil,
              http_referer: nil,
              openrouter_title: nil,
              temperature: 0.7,
              frequency_penalty: 0.0,
              receive_timeout: 60_000,
              seed: nil,
              n: 1,
              # Defaults to false because OpenRouter is a multi-model gateway
              # and many models do not support response_format.
              json_response: false,
              json_schema: nil,
              max_tokens: nil,
              tool_choice: nil,
              user: nil,
              messages: []
  end

  @impl true

  def call(prompt, tools, config) when is_map(config) do
    default_model =
      case Application.get_env(:lux, :open_router_models) do
        models when is_list(models) -> models[:default]
        _ -> "openai/gpt-4o-mini"
      end || "openai/gpt-4o-mini"

    default_api_key =
      case Application.get_env(:lux, :api_keys) do
        keys when is_list(keys) -> keys[:openrouter]
        _ -> nil
      end

    config =
      struct(
        Config,
        Map.merge(
          %{
            model: default_model,
            api_key: default_api_key
          },
          config
        )
      )

    messages = config.messages ++ build_messages(prompt)
    tools_config = build_tools_config(tools)

    resolved_model = Lux.Config.resolve(config.model)

    body =
      %{
        model: resolved_model,
        messages: messages,
        temperature: config.temperature,
        frequency_penalty: config.frequency_penalty
      }
      |> maybe_add_max_tokens(config.max_tokens)
      |> maybe_add_tools(tools_config, config.tool_choice)
      |> maybe_add_response_format(config)
      |> maybe_add_user(config.user)
      |> maybe_add_n(config.n)

    headers = build_headers(config)

    [
      url: Lux.Config.resolve(config.endpoint || @default_endpoint),
      json: body,
      headers: headers,
      receive_timeout: config.receive_timeout
    ]
    |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
    |> Req.new()
    |> Req.post()
    |> case do
      {:ok, %{status: 200} = response} ->
        handle_response(response, config)

      {:ok, %{status: 401}} ->
        {:error, :invalid_api_key}

      {:ok, %{status: status, body: %{"error" => %{"message" => message}}}} ->
        {:error, {status, message}}

      {:ok, %{status: status, body: %{"error" => message}}} when is_binary(message) ->
        {:error, {status, message}}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, inspect(body)}}

      {:error, error} ->
        handle_error(error)
    end
  end

  defp build_messages(prompt) when is_binary(prompt) do
    [%{role: "user", content: prompt}]
  end

  defp build_tools_config([]), do: []
  defp build_tools_config(tools), do: Enum.map(tools, &tool_to_function/1)

  defp maybe_add_tools(body, [], _tool_choice), do: body

  defp maybe_add_tools(body, tools, tool_choice) do
    body
    |> Map.put(:tools, tools)
    |> Map.put(:tool_choice, format_tool_choice(tool_choice))
  end

  defp format_tool_choice(:none), do: "none"
  defp format_tool_choice(:auto), do: "auto"

  defp format_tool_choice(name) when is_binary(name) do
    %{"type" => "function", "function" => %{"name" => String.replace(name, ".", "_")}}
  end

  defp format_tool_choice(choice) when is_map(choice), do: choice
  defp format_tool_choice(_), do: "auto"

  defp maybe_add_max_tokens(body, nil), do: body
  defp maybe_add_max_tokens(body, max_tokens), do: Map.put(body, :max_tokens, max_tokens)

  defp maybe_add_user(body, nil), do: body
  defp maybe_add_user(body, user), do: Map.put(body, :user, user)

  defp maybe_add_n(body, nil), do: body
  defp maybe_add_n(body, 1), do: body
  defp maybe_add_n(body, n), do: Map.put(body, :n, n)

  defp maybe_add_response_format(body, %Config{json_response: false}), do: body

  defp maybe_add_response_format(body, %Config{json_response: true, json_schema: schema})
       when is_map(schema) and map_size(schema) > 0 do
    Map.put(body, :response_format, %{
      type: "json_schema",
      json_schema: schema
    })
  end

  defp maybe_add_response_format(body, %Config{json_response: true, json_schema: schema})
       when is_atom(schema) and not is_nil(schema) do
    Map.put(body, :response_format, %{
      type: "json_schema",
      json_schema: %{name: schema.name(), schema: schema.schema()}
    })
  end

  defp maybe_add_response_format(body, %Config{json_response: true, json_schema: nil}) do
    Map.put(
      %{
        body
        | messages:
            Enum.map(body.messages, fn
              %{role: "user", content: content} = msg ->
                %{msg | content: content <> "\n Reply in json format"}

              msg ->
                msg
            end)
      },
      :response_format,
      %{type: "json_object"}
    )
  end

  defp maybe_add_response_format(body, _), do: body

  defp build_headers(config) do
    resolved_api_key = Lux.Config.resolve(config.api_key)

    site_url =
      cond do
        is_binary(config.http_referer) and config.http_referer != "" -> Lux.Config.resolve(config.http_referer)
        is_binary(config.site_url) and config.site_url != "" -> Lux.Config.resolve(config.site_url)
        true -> nil
      end

    site_name =
      cond do
        is_binary(config.openrouter_title) and config.openrouter_title != "" -> Lux.Config.resolve(config.openrouter_title)
        is_binary(config.site_name) and config.site_name != "" -> Lux.Config.resolve(config.site_name)
        true -> nil
      end

    headers = [
      {"Authorization", "Bearer #{resolved_api_key}"},
      {"Content-Type", "application/json"}
    ]

    headers =
      if is_binary(site_url) and site_url != "" do
        headers ++ [{"HTTP-Referer", site_url}]
      else
        headers
      end

    headers =
      if is_binary(site_name) and site_name != "" do
        headers ++ [{"X-OpenRouter-Title", site_name}]
      else
        headers
      end

    headers
  end

  def tool_to_function({:python, path}) do
    path
    |> Prism.view()
    |> tool_to_function()
  end

  def tool_to_function(tool_module) when is_atom(tool_module) and not is_nil(tool_module) do
    cond do
      Lux.prism?(tool_module) ->
        tool_to_function(tool_module.view())

      Lux.beam?(tool_module) ->
        tool_to_function(tool_module.view())

      Lux.lens?(tool_module) ->
        tool_to_function(tool_module.view())

      true ->
        raise "Unsupported tool type: #{inspect(tool_module)}"
    end
  end

  def tool_to_function(%Beam{module_name: name, description: description, input_schema: input_schema}) do
    %{
      type: "function",
      function: %{
        # OpenRouter function names must be [a-zA-Z0-9_-]
        name: String.replace(name, ".", "_"),
        description: description || "",
        parameters: input_schema
      }
    }
  end

  def tool_to_function(%Prism{module_name: name, description: description, input_schema: input_schema}) do
    %{
      type: "function",
      function: %{
        # OpenRouter function names must be [a-zA-Z0-9_-]
        name: String.replace(name, ".", "_"),
        description: description || "",
        parameters: input_schema
      }
    }
  end

  def tool_to_function(%Lens{module_name: name, description: description, schema: schema}) do
    %{
      type: "function",
      function: %{
        name: String.replace(name, ".", "_"),
        description: description || "",
        parameters: schema
      }
    }
  end

  defp handle_response(%{body: body}, _config) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> handle_response(%{body: decoded}, _config)
      {:error, _} -> {:error, "Failed to decode response body: #{inspect(body)}"}
    end
  end

  defp handle_response(%{body: body}, _config) when is_map(body) do
    with %{"choices" => [choice | _]} <- body,
         %{"message" => message} <- choice do
      finish_reason = Map.get(choice, "finish_reason") || "stop"

      with {:ok, content} <- parse_content(message["content"]),
           {:ok, tool_calls_results} <- execute_tool_calls(message["tool_calls"]) do
        payload = %{
          content: content,
          model: body["model"],
          finish_reason: finish_reason,
          tool_calls: message["tool_calls"],
          tool_calls_results: tool_calls_results
        }

        usage =
          case body["usage"] do
            %{} = u -> u
            _ -> %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
          end

        metadata = %{
          id: body["id"],
          created: body["created"],
          usage: usage,
          system_fingerprint: body["system_fingerprint"]
        }

        %{
          schema_id: ResponseSignal,
          payload: payload,
          metadata: metadata
        }
        |> Lux.Signal.new()
        |> ResponseSignal.validate()
      end
    else
      _ -> {:error, "Invalid response payload from OpenRouter"}
    end
  end

  def parse_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, structured_output} when is_map(structured_output) ->
        {:ok, structured_output}

      {:error, _} ->
        {:ok, %{"text" => content}}

      {:ok, other} ->
        {:ok, %{"text" => inspect(other)}}
    end
  end

  def parse_content(nil), do: {:ok, nil}
  def parse_content(other), do: {:ok, other}

  def execute_tool_calls(tool_calls) when is_list(tool_calls) do
    results = Enum.map(tool_calls, &execute_tool_call/1)

    if Enum.all?(results, fn
         {:ok, _} -> true
         {:ok, _, _} -> true
         _ -> false
       end) do
      unwrapped =
        Enum.map(results, fn
          {:ok, res, _log} -> res
          {:ok, res} -> res
        end)

      {:ok, unwrapped}
    else
      error = Enum.find(results, &match?({:error, _}, &1)) || {:error, "Tool call execution failed"}
      error
    end
  end

  def execute_tool_calls(nil), do: {:ok, nil}

  def execute_tool_call(%{"function" => %{"name" => tool_name, "arguments" => args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded_args} ->
        try do
          execute_tool(tool_name, decoded_args, nil)
        rescue
          e -> {:error, "Error executing tool #{tool_name}: #{inspect(e)}"}
        end

      {:error, error} ->
        {:error, "Failed to decode arguments for tool #{tool_name}: #{inspect(error)}"}
    end
  end

  def execute_tool_call(%{"function" => %{"name" => tool_name, "arguments" => args}}) when is_map(args) do
    try do
      execute_tool(tool_name, args, nil)
    rescue
      e -> {:error, "Error executing tool #{tool_name}: #{inspect(e)}"}
    end
  end

  def execute_tool_call(%{"function" => %{"name" => tool_name}}) do
    {:error, "Missing arguments for tool #{tool_name}"}
  end

  def execute_tool_call(other) do
    {:error, "Invalid tool call format: #{inspect(other)}"}
  end

  def execute_tool(tool_name, args, ctx \\ nil)

  def execute_tool(tool_name, args, ctx) when is_binary(tool_name) do
    tool_name
    |> String.replace("_", ".")
    |> List.wrap()
    |> Module.concat()
    |> Code.ensure_loaded()
    |> case do
      {:module, module_name} ->
        execute_tool(module_name, args, ctx)

      {:error, :nofile} ->
        {:error,
         "Failed to load tool module #{tool_name}: It doesn't seems to be implemented or reacheable"}

      {:error, error} ->
        {:error, "Failed to load tool module #{tool_name}: #{inspect(error)}"}
    end
  end

  def execute_tool(tool_module, args, ctx) when is_atom(tool_module) do
    cond do
      Lux.prism?(tool_module) ->
        tool_module.handler(args, ctx)

      Lux.beam?(tool_module) ->
        tool_module.run(args, ctx)

      Lux.lens?(tool_module) ->
        tool_module.focus(args)

      true ->
        {:error,
         """
         Tool #{tool_module} does not seem to be a valid Beam or Prism
         as it does not have a registered `handler` or `run` function.
         """}
    end
  end

  defp handle_error(error) do
    Logger.error("OpenRouter API error: #{inspect(error)}")
    {:error, "OpenRouter API error: #{inspect(error)}"}
  end
end
