defmodule Lux.Telegram.Middleware.RateLimit do
  @moduledoc """
  Req response step middleware for Telegram Bot API rate limiting (HTTP 429).
  """

  @doc """
  Attaches rate limit middleware to a Req request struct.
  """
  def attach(%Req.Request{} = req, opts \\ []) do
    opts_list = if is_map(opts), do: Map.to_list(opts), else: opts || []
    filtered_opts = Keyword.take(opts_list, [:max_rate_limit_retries, :sleep_fun])

    req
    |> Req.Request.register_options([:max_rate_limit_retries, :sleep_fun])
    |> Req.Request.merge_options(filtered_opts)
    |> Req.Request.append_response_steps(telegram_rate_limit: &handle/1)
  end

  @doc """
  Handles response step for HTTP status 429 backoff and retry.
  """
  def handle({request, %Req.Response{status: 429} = response}) do
    retry_count = Req.Request.get_private(request, :telegram_rate_limit_retry_count, 0)
    max_retries = Req.Request.get_option(request, :max_rate_limit_retries, 3)

    if retry_count < max_retries do
      retry_after = extract_retry_after(response)
      sleep_fun = Req.Request.get_option(request, :sleep_fun, fn ms -> Process.sleep(ms) end)

      sleep_fun.(retry_after * 1000)

      request = Req.Request.put_private(request, :telegram_rate_limit_retry_count, retry_count + 1)
      {request, new_response} = Req.Request.run_request(%{request | halted: false})
      Req.Request.halt(request, new_response)
    else
      {request, response}
    end
  end

  def handle({request, response_or_exception}) do
    {request, response_or_exception}
  end

  @doc """
  Extracts `retry_after` (in seconds) from Telegram response JSON or Retry-After header.
  """
  def extract_retry_after(%Req.Response{} = response) do
    cond do
      seconds = get_in_json(response.body, ["parameters", "retry_after"]) ->
        to_integer(seconds)

      seconds = get_header(response, "retry-after") ->
        to_integer(seconds)

      true ->
        1
    end
  end

  defp get_in_json(body, keys) when is_map(body) do
    get_in(body, keys)
  end
  defp get_in_json(_body, _keys), do: nil

  defp get_header(response, header_name) do
    case Req.Response.get_header(response, header_name) do
      [val | _] ->
        val

      _ ->
        if is_list(response.headers) do
          Enum.find_value(response.headers, fn {k, v} ->
            if String.downcase(to_string(k)) == String.downcase(header_name), do: v
          end)
        else
          nil
        end
    end
  end

  defp to_integer(val) when is_integer(val), do: val
  defp to_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> 1
    end
  end
  defp to_integer(_), do: 1
end
