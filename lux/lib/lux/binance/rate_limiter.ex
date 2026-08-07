defmodule Lux.Binance.RateLimiter do
  @moduledoc """
  Rate Limiter GenServer and Req middleware for Binance API limits.

  Tracks weight usage (`x-mbx-used-weight-1m`, `x-fapi-used-weight-1m`)
  and backoff windows triggered by 429 (Rate Limit Exceeded) or 418 (Teapot / Ban) status codes.
  """

  use GenServer
  require Logger

  @table :lux_binance_rate_limiter

  defstruct spot_weight: 0,
            futures_weight: 0,
            spot_backoff_until: 0,
            futures_backoff_until: 0

  # API

  @doc """
  Starts the RateLimiter GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks if the specified market type is currently rate limited.
  Returns `:ok` or `{:error, {:rate_limited, wait_ms}}`.
  """
  @spec check_rate_limit(atom()) :: :ok | {:error, {:rate_limited, integer()}}
  def check_rate_limit(market_type \\ :spot) do
    now = System.system_time(:millisecond)
    backoff_until = get_backoff_until(market_type)

    if now < backoff_until do
      {:error, {:rate_limited, backoff_until - now}}
    else
      :ok
    end
  end

  @doc """
  Records response status code and headers to update weight tracking and backoff state.
  """
  @spec record_response(list() | map(), integer(), atom()) :: :ok
  def record_response(headers, status_code, market_type \\ :spot) do
    headers_map = normalize_headers(headers)
    now = System.system_time(:millisecond)

    if status_code in [429, 418] do
      retry_after_sec = parse_header_int(headers_map, "retry-after", 60)
      backoff_until = now + retry_after_sec * 1000
      set_backoff_until(market_type, backoff_until)
      Logger.warning("Binance #{market_type} API rate limit hit (HTTP #{status_code}). Backoff until #{backoff_until} (#{retry_after_sec}s)")
    end

    weight_header =
      if market_type == :futures, do: "x-fapi-used-weight-1m", else: "x-mbx-used-weight-1m"

    if weight_str = Map.get(headers_map, weight_header) do
      case Integer.parse(weight_str) do
        {weight, _} -> set_used_weight(market_type, weight)
        :error -> :ok
      end
    end

    :ok
  end

  @doc """
  Gets the last recorded used weight for a market type.
  """
  @spec get_used_weight(atom()) :: integer()
  def get_used_weight(market_type \\ :spot) do
    key = weight_key(market_type)
    get_ets_value(key, 0)
  end

  @doc """
  Gets the backoff_until timestamp (ms) for a market type.
  """
  @spec get_backoff_until(atom()) :: integer()
  def get_backoff_until(market_type \\ :spot) do
    key = backoff_key(market_type)
    get_ets_value(key, 0)
  end

  @doc """
  Resets the rate limiter state (useful for tests).
  """
  def reset do
    if ets_exists?() do
      :ets.insert(@table, {:spot_weight, 0})
      :ets.insert(@table, {:futures_weight, 0})
      :ets.insert(@table, {:spot_backoff_until, 0})
      :ets.insert(@table, {:futures_backoff_until, 0})
    end
    :ok
  end

  @doc """
  Attaches rate limiting middleware steps to a `Req.Request`.
  """
  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = request) do
    request
    |> Req.Request.register_options([:binance_market_type, :binance_auto_backoff, :retry_delay_multiplier])
    |> Req.Request.append_request_steps(binance_rate_limit_check: &pre_request_step/1)
    |> Req.Request.append_response_steps(binance_rate_limit_record: &post_response_step/1)
  end

  # Middleware steps

  defp pre_request_step(%Req.Request{} = request) do
    market_type = request.options[:binance_market_type] || :spot
    auto_backoff = request.options[:binance_auto_backoff] != false

    case check_rate_limit(market_type) do
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
            body: %{"code" => -1003, "msg" => "Rate limit backoff active", "wait_ms" => wait_ms}
          }

          Req.Request.halt(request, resp)
        end
    end
  end

  defp post_response_step({request, response}) do
    market_type = request.options[:binance_market_type] || :spot
    record_response(response.headers, response.status, market_type)
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
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      :ets.insert(@table, {:spot_weight, 0})
      :ets.insert(@table, {:futures_weight, 0})
      :ets.insert(@table, {:spot_backoff_until, 0})
      :ets.insert(@table, {:futures_backoff_until, 0})
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

  defp set_backoff_until(market_type, timestamp) do
    create_table_if_not_exists()
    :ets.insert(@table, {backoff_key(market_type), timestamp})
  end

  defp set_used_weight(market_type, weight) do
    create_table_if_not_exists()
    :ets.insert(@table, {weight_key(market_type), weight})
  end

  defp weight_key(:futures), do: :futures_weight
  defp weight_key(_), do: :spot_weight

  defp backoff_key(:futures), do: :futures_backoff_until
  defp backoff_key(_), do: :spot_backoff_until

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    |> Map.new()
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.map(fn {k, v} ->
      val = if is_list(v), do: Enum.join(v, ", "), else: to_string(v)
      {String.downcase(to_string(k)), val}
    end)
    |> Map.new()
  end

  defp parse_header_int(headers_map, header_name, default) do
    case Map.get(headers_map, header_name) do
      nil -> default
      val ->
        case Integer.parse(to_string(val)) do
          {int_val, _} -> int_val
          :error -> default
        end
    end
  end
end
