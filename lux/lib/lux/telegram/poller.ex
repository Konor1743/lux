defmodule Lux.Telegram.Poller do
  @moduledoc """
  GenServer implementation for long-polling Telegram Bot API updates.
  Tracks update `offset` and dispatches `Lux.Signals.TelegramUpdate` signals.
  """

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [
      :token,
      :offset,
      :handler,
      :timeout,
      :poll_interval,
      :allowed_updates,
      :plug,
      :client,
      :autostart
    ]
  end

  @doc """
  Starts the Telegram updates Poller GenServer.

  ## Options
    * `:token` - Telegram bot API token
    * `:offset` - Starting update offset (default 0)
    * `:handler` - Callback function `(signal -> term)`, PID, or module to receive updates
    * `:timeout` - Long polling timeout in seconds (default 30)
    * `:poll_interval` - Delay between poll requests in ms (default 1000)
    * `:allowed_updates` - Optional list of allowed update types
    * `:plug` - Req plug for testing
    * `:autostart` - Boolean indicating whether polling loop starts automatically (default true)
    * `:name` - GenServer process registration name
  """
  def start_link(opts \\ %{}) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts || %{}
    gen_opts = if name = opts_map[:name], do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts_map, gen_opts)
  end

  @doc """
  Triggers a single poll operation synchronously. Returns `{:ok, signals}` or `{:error, reason}`.
  """
  def poll_once(pid_or_name) do
    GenServer.call(pid_or_name, :poll_once)
  end

  @doc """
  Retrieves the current update offset.
  """
  def get_offset(pid_or_name) do
    GenServer.call(pid_or_name, :get_offset)
  end

  @doc """
  Stops the poller process.
  """
  def stop(pid_or_name) do
    GenServer.stop(pid_or_name)
  end

  @impl true
  def init(opts_map) do
    token = Lux.Integrations.Telegram.fetch_token(opts_map)
    offset = Map.get(opts_map, :offset, 0)
    handler = Map.get(opts_map, :handler)
    timeout = Map.get(opts_map, :timeout, 30)
    poll_interval = Map.get(opts_map, :poll_interval, 1000)
    allowed_updates = Map.get(opts_map, :allowed_updates)
    plug = Map.get(opts_map, :plug)
    client = Map.get(opts_map, :client, Lux.Telegram.Client)
    autostart = Map.get(opts_map, :autostart, true)

    state = %State{
      token: token,
      offset: offset,
      handler: handler,
      timeout: timeout,
      poll_interval: poll_interval,
      allowed_updates: allowed_updates,
      plug: plug,
      client: client,
      autostart: autostart
    }

    if autostart do
      send(self(), :poll)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:poll_once, _from, state) do
    case do_poll(state) do
      {:ok, signals, new_state} ->
        {:reply, {:ok, signals}, new_state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_offset, _from, state) do
    {:reply, state.offset, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case do_poll(state) do
      {:ok, _signals, new_state} ->
        schedule_poll(new_state)
        {:noreply, new_state}

      {:error, _reason, state} ->
        schedule_poll(state)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_poll(%State{autostart: true, poll_interval: interval}) when is_integer(interval) and interval >= 0 do
    Process.send_after(self(), :poll, interval)
  end

  defp schedule_poll(_state), do: :ok

  defp do_poll(state) do
    client_opts = %{token: state.token}
    client_opts = if state.plug, do: Map.put(client_opts, :plug, state.plug), else: client_opts

    json = %{offset: state.offset, timeout: state.timeout}
    json = if state.allowed_updates, do: Map.put(json, :allowed_updates, state.allowed_updates), else: json

    case state.client.request(:post, "/getUpdates", Map.put(client_opts, :json, json)) do
      {:ok, %{"ok" => true, "result" => updates}} when is_list(updates) ->
        {signals, new_offset} = process_updates(updates, state.offset, state.handler)
        {:ok, signals, %{state | offset: new_offset}}

      {:ok, %{"ok" => false} = body} ->
        {:error, body, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp process_updates(updates, current_offset, handler) do
    Enum.reduce(updates, {[], current_offset}, fn update, {signals_acc, max_offset} ->
      update_id = update["update_id"] || update[:update_id] || 0
      next_offset = max(max_offset, update_id + 1)

      signal =
        case Lux.Signals.TelegramUpdate.new(update) do
          {:ok, sig} -> sig
          sig -> sig
        end

      dispatch_signal(signal, handler)
      {[signal | signals_acc], next_offset}
    end)
    |> then(fn {signals, final_offset} -> {Enum.reverse(signals), final_offset} end)
  end

  defp dispatch_signal(signal, handler) do
    cond do
      is_function(handler, 1) ->
        try do
          handler.(signal)
        rescue
          e -> Logger.error("Poller handler error: #{inspect(e)}")
        end

      is_pid(handler) ->
        send(handler, {:telegram_update, signal})

      is_atom(handler) and handler != nil ->
        if Code.ensure_loaded?(handler) and function_exported?(handler, :handle_signal, 1) do
          handler.handle_signal(signal)
        else
          :ok
        end

      true ->
        :ok
    end
  end
end
