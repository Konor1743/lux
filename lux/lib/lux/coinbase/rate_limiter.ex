defmodule Lux.Coinbase.RateLimiter do
  @moduledoc """
  Rate Limiter GenServer and Req middleware for Coinbase API limits.

  Tracks quota metrics (`cb-ratelimit-limit`, `cb-ratelimit-remaining`, `cb-ratelimit-reset`)
  and backoff windows triggered by 429 (Rate Limit Exceeded) status codes with exponential backoff.
  """

  use GenServer
  require Logger

  @table :lux_coinbase_rate_limiter

  defstruct limit: 0,
            remaining: 0,
            reset: 0,
            backoff_until: 0,
            consecutive_429s: 0

  # API

  @doc """
  Starts the RateLimiter GenServer process.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks if the Coinbase API is currently rate limited.
  Returns `:ok` or `{:error, {:rate_limited, wait_ms}}`.
  """
  @spec check_rate_limit() :: :ok | {:error, {:rate_limited, integer()}}
  def check_rate_limit do
    now = System.system_time(:millisecond)
    backoff_until = get_backoff_until()

    if now < backoff_until do
      {:error, {:rate_limited, backoff_until - now}}
    else
      :ok
    end
  end

  @doc """
  Records response status code and headers to update quota metrics and backoff state.
  """
  @spec record_response(list() | map(), integer()) :: :ok
  def record_response(headers, status_code) do
    headers_map = normalize_headers(headers)
    now = System.system_time(:millisecond)

    if status_code == 429 do
      retry_after_sec = parse_header_int(headers_map, "retry-after", nil)
      consecutive = get_ets_value(:consecutive_429s, 0) + 1
      set_ets_value(:consecutive_429s, consecutive)

      delay_sec =
        if retry_after_sec && retry_after_sec > 0 do
          multiplier = :math.pow(2, consecutive - 1) |> round()
          retry_after_sec * multiplier
        else
          :math.pow(2, consecutive - 1) |> round()
        end

      backoff_until = now + delay_sec * 1000
      set_backoff_until(backoff_until)

      Logger.warning(
        "Coinbase API rate limit hit (HTTP 429, attempt #{consecutive}). Backoff until #{backoff_until} (#{delay_sec}s)"
      )
    else
      if status_code in 200..299 do
        set_ets_value(:consecutive_429s, 0)
      end
    end

    if limit_str = Map.get(headers_map, "cb-ratelimit-limit") do
      case Integer.parse(limit_str) do
        {limit, _} -> set_ets_value(:cb_ratelimit_limit, limit)
        :error -> :ok
      end
    end

    if remaining_str = Map.get(headers_map, "cb-ratelimit-remaining") do
      case Integer.parse(remaining_str) do
        {remaining, _} -> set_ets_value(:cb_ratelimit_remaining, remaining)
        :error -> :ok
      end
    end

    if reset_str = Map.get(headers_map, "cb-ratelimit-reset") do
      case Integer.parse(reset_str) do
        {reset_val, _} -> set_ets_value(:cb_ratelimit_reset, reset_val)
        :error -> :ok
      end
    end

    :ok
  end

  @doc """
  Gets the last recorded rate limit quota limit.
  """
  @spec get_limit() :: integer()
  def get_limit do
    get_ets_value(:cb_ratelimit_limit, 0)
  end

  @doc """
  Gets the last recorded remaining rate limit quota.
  """
  @spec get_remaining_quota() :: integer()
  def get_remaining_quota do
    get_ets_value(:cb_ratelimit_remaining, 0)
  end

  @doc """
  Gets the last recorded reset timestamp in seconds.
  """
  @spec get_reset_timestamp() :: integer()
  def get_reset_timestamp do
    get_ets_value(:cb_ratelimit_reset, 0)
  end

  @doc """
  Gets the backoff_until timestamp in milliseconds.
  """
  @spec get_backoff_until() :: integer()
  def get_backoff_until do
    get_ets_value(:backoff_until, 0)
  end

  @doc """
  Gets the current count of consecutive 429 errors.
  """
  @spec get_consecutive_429s() :: integer()
  def get_consecutive_429s do
    get_ets_value(:consecutive_429s, 0)
  end

  @doc """
  Resets the rate limiter state stored in ETS.
  """
  def reset do
    create_table_if_not_exists()
    :ets.insert(@table, {:cb_ratelimit_limit, 0})
    :ets.insert(@table, {:cb_ratelimit_remaining, 0})
    :ets.insert(@table, {:cb_ratelimit_reset, 0})
    :ets.insert(@table, {:backoff_until, 0})
    :ets.insert(@table, {:consecutive_429s, 0})
    :ok
  end

  @doc """
  Attaches rate limiting middleware steps to a `Req.Request`.
  """
  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = request) do
    request
    |> Req.Request.register_options([:coinbase_auto_backoff, :retry_delay_multiplier])
    |> Req.Request.append_request_steps(coinbase_rate_limit_check: &pre_request_step/1)
    |> Req.Request.append_response_steps(coinbase_rate_limit_record: &post_response_step/1)
  end

  # Middleware steps

  defp pre_request_step(%Req.Request{} = request) do
    auto_backoff = request.options[:coinbase_auto_backoff] != false

    case check_rate_limit() do
      :ok ->
        request

      {:error, {:rate_limited, wait_ms}} ->
        if auto_backoff and wait_ms > 0 do
          delay_mult = request.options[:retry_delay_multiplier] || 1.0
          actual_sleep = round(wait_ms * delay_mult)

          if actual_sleep > 0 do
            Process.sleep(actual_sleep)
          end

          request
        else
          resp = %Req.Response{
            status: 429,
            body: %{"message" => "Rate limit backoff active", "wait_ms" => wait_ms}
          }

          Req.Request.halt(request, resp)
        end
    end
  end

  defp post_response_step({request, response}) do
    record_response(response.headers, response.status)
    {request, response}
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    create_table_if_not_exists()
    {:ok, %__MODULE__{}}
  end

  # Helper functions for ETS operations

  defp create_table_if_not_exists do
    unless ets_exists?() do
      try do
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ets.insert(@table, {:cb_ratelimit_limit, 0})
        :ets.insert(@table, {:cb_ratelimit_remaining, 0})
        :ets.insert(@table, {:cb_ratelimit_reset, 0})
        :ets.insert(@table, {:backoff_until, 0})
        :ets.insert(@table, {:consecutive_429s, 0})
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp ets_exists? do
    :ets.whereis(@table) != :undefined
  end

  defp get_ets_value(key, default) do
    create_table_if_not_exists()

    case :ets.lookup(@table, key) do
      [{^key, val}] -> val
      [] -> default
    end
  rescue
    _ -> default
  end

  defp set_ets_value(key, value) do
    create_table_if_not_exists()
    :ets.insert(@table, {key, value})
  end

  defp set_backoff_until(timestamp) do
    set_ets_value(:backoff_until, timestamp)
  end

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {k, v} ->
      val =
        case v do
          list when is_list(list) -> Enum.join(list, ", ")
          other -> to_string(other)
        end

      {String.downcase(to_string(k)), val}
    end)
    |> Map.new()
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.map(fn {k, v} ->
      val =
        case v do
          list when is_list(list) -> Enum.join(list, ", ")
          other -> to_string(other)
        end

      {String.downcase(to_string(k)), val}
    end)
    |> Map.new()
  end

  defp normalize_headers(_), do: %{}

  defp parse_header_int(headers_map, header_name, default) do
    case Map.get(headers_map, header_name) do
      nil ->
        default

      val ->
        case Integer.parse(to_string(val)) do
          {int_val, _} -> int_val
          :error -> default
        end
    end
  end
end
