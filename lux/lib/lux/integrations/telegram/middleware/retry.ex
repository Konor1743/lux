defmodule Lux.Telegram.Middleware.Retry do
  @moduledoc """
  Req response step middleware for Telegram Bot API retries with exponential backoff.
  Retries on transport errors and HTTP status 5xx responses.
  """

  @doc """
  Attaches retry middleware to a Req request struct.
  """
  def attach(%Req.Request{} = req, opts \\ []) do
    opts_list = if is_map(opts), do: Map.to_list(opts), else: opts || []

    filtered_opts =
      Keyword.take(opts_list, [
        :max_retries,
        :base_backoff,
        :max_backoff,
        :backoff_factor,
        :sleep_fun
      ])

    req
    |> Req.Request.register_options([
      :max_retries,
      :base_backoff,
      :max_backoff,
      :backoff_factor,
      :sleep_fun
    ])
    |> Req.Request.merge_options(filtered_opts)
    |> Req.Request.append_response_steps(telegram_retry: &handle/1)
  end

  @doc """
  Handles response step for transport errors and HTTP 5xx responses.
  """
  def handle({request, response_or_exception}) do
    if retryable?(response_or_exception) do
      retry_count = Req.Request.get_private(request, :telegram_retry_count, 0)
      max_retries = Req.Request.get_option(request, :max_retries, 3)

      if retry_count < max_retries do
        base_backoff = Req.Request.get_option(request, :base_backoff, 100)
        max_backoff = Req.Request.get_option(request, :max_backoff, 5000)
        factor = Req.Request.get_option(request, :backoff_factor, 2)
        sleep_fun = Req.Request.get_option(request, :sleep_fun, fn ms -> Process.sleep(ms) end)

        delay = calculate_backoff(base_backoff, factor, retry_count, max_backoff)
        sleep_fun.(delay)

        request = Req.Request.put_private(request, :telegram_retry_count, retry_count + 1)
        {request, new_response_or_exception} = Req.Request.run_request(%{request | halted: false})
        Req.Request.halt(request, new_response_or_exception)
      else
        {request, response_or_exception}
      end
    else
      {request, response_or_exception}
    end
  end

  @doc """
  Determines if a response or exception should be retried.
  """
  def retryable?(%Req.Response{status: status}) when status in 500..599, do: true
  def retryable?(%Req.Response{}), do: false
  def retryable?(%Req.TransportError{}), do: true
  def retryable?(%{__exception__: true}), do: true
  def retryable?(_), do: false

  @doc """
  Calculates exponential backoff delay in milliseconds.
  """
  def calculate_backoff(base_backoff, factor, retry_count, max_backoff) do
    delay = trunc(base_backoff * :math.pow(factor, retry_count))
    min(delay, max_backoff)
  end
end
