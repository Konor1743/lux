defmodule Lux.Integrations.YouTube.LiveChat.Poller do
  @moduledoc """
  GenServer that continuously polls YouTube Live Chat messages for an active live stream.

  ## Key Features
  - **Dynamic Polling Interval**: Adjusts polling cadence dynamically using `pollingIntervalMillis` returned by YouTube API.
  - **Subscriber Broadcasts**: Dispatches incoming message batches to subscriber processes via `{:live_chat_messages, live_chat_id, messages}`.
  - **Callback Execution**: Executes optional `:handler_fn` on each batch of new messages.
  - **Resilient Error Handling**: Applies exponential backoff with jitter on transient errors and rate limits, broadcasting `{:live_chat_error, live_chat_id, error}`.
  - **Deduplication**: Maintains `page_token` cursor across polling iterations to avoid duplicate message delivery.
  - **Lifecycle Control**: Supports `pause/1`, `resume/1`, `poll_once/1` (synchronous step testing), and `stop/2`.
  - **Stream Termination Detection**: Detects `offlineAt` / broadcast termination signals and notifies subscribers with `{:live_chat_ended, live_chat_id, details}`.
  """

  use GenServer
  require Logger

  alias Lux.Integrations.YouTube.Errors
  alias Lux.Integrations.YouTube.LiveChat

  @default_interval_ms 5000
  @default_min_interval_ms 1000
  @default_max_interval_ms 60_000
  @default_backoff_base_ms 1000
  @default_max_backoff_ms 30_000

  # --- Typespecs ---

  @type server_ref :: GenServer.server()
  @type live_chat_id :: String.t()

  @type handler_fn ::
          (list() -> any())
          | (live_chat_id(), list() -> any())
          | {module(), atom(), list()}

  @type poller_status :: :running | :paused | :stopped | :error | :ended

  @type state :: %{
          live_chat_id: live_chat_id(),
          client_opts: map(),
          subscribers: MapSet.t(pid()),
          monitors: %{pid() => reference()},
          handler_fn: handler_fn() | nil,
          page_token: String.t() | nil,
          interval_ms: non_neg_integer(),
          default_interval_ms: non_neg_integer(),
          min_interval_ms: non_neg_integer(),
          max_interval_ms: non_neg_integer(),
          status: poller_status(),
          timer_ref: reference() | nil,
          message_count: non_neg_integer(),
          poll_count: non_neg_integer(),
          consecutive_errors: non_neg_integer(),
          last_error: term() | nil,
          last_poll_at: DateTime.t() | nil,
          offline_at: String.t() | nil,
          part: String.t(),
          max_results: integer() | nil,
          backoff_base_ms: non_neg_integer(),
          max_backoff_ms: non_neg_integer()
        }

  @type status_summary :: %{
          status: poller_status(),
          live_chat_id: live_chat_id(),
          page_token: String.t() | nil,
          interval_ms: non_neg_integer(),
          message_count: non_neg_integer(),
          poll_count: non_neg_integer(),
          subscribers_count: non_neg_integer(),
          consecutive_errors: non_neg_integer(),
          last_error: term() | nil,
          last_poll_at: DateTime.t() | nil,
          offline_at: String.t() | nil
        }

  # --- Client API ---

  @doc """
  Starts the Live Chat Poller linked to the calling process.

  ## Options
  - `:live_chat_id` (required): YouTube Live Chat ID string.
  - `:token`: OAuth 2.0 access token string.
  - `:client_opts`: Extra client options passed to `LiveChat.list_messages/2`.
  - `:subscriber` / `:subscribers`: Process PID or list of PIDs to receive message signals.
  - `:handler_fn`: Optional callback invoked with new messages: `fn messages -> ... end` or `fn chat_id, msgs -> ... end`.
  - `:initial_page_token` / `:page_token`: Starting pagination token.
  - `:default_interval_ms` / `:interval_ms`: Default polling interval in ms (default: 5000).
  - `:min_interval_ms`: Minimum allowed polling interval in ms (default: 1000).
  - `:max_interval_ms`: Maximum allowed polling interval in ms (default: 60000).
  - `:auto_start`: Boolean flag whether to start polling immediately (default: true).
  - `:part`: Resource parts string (default: `"snippet,authorDetails"`).
  - `:max_results`: Max results per page (default: nil/API default).
  - `:name`: GenServer registration name.
  """
  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(opts \\ %{}) do
    opts_map = to_map(opts)

    case validate_init_opts(opts_map) do
      :ok ->
        genserver_opts = extract_genserver_opts(opts_map)
        GenServer.start_link(__MODULE__, opts_map, genserver_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts the Live Chat Poller unlinked.
  """
  @spec start(keyword() | map()) :: GenServer.on_start()
  def start(opts \\ %{}) do
    opts_map = to_map(opts)

    case validate_init_opts(opts_map) do
      :ok ->
        genserver_opts = extract_genserver_opts(opts_map)
        GenServer.start(__MODULE__, opts_map, genserver_opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops the poller process.
  """
  @spec stop(server_ref(), term()) :: :ok
  def stop(poller, reason \\ :normal) do
    GenServer.stop(poller, reason)
  end

  @doc """
  Pauses the poller, canceling any active polling timers.
  """
  @spec pause(server_ref()) :: :ok
  def pause(poller) do
    GenServer.call(poller, :pause)
  end

  @doc """
  Resumes the poller if paused, scheduling an immediate poll.
  """
  @spec resume(server_ref()) :: :ok
  def resume(poller) do
    GenServer.call(poller, :resume)
  end

  @doc """
  Retrieves the current status and metrics of the poller.
  """
  @spec get_status(server_ref()) :: status_summary()
  def get_status(poller) do
    GenServer.call(poller, :get_status)
  end

  @doc """
  Synchronously executes a single poll iteration.
  Useful for deterministic tests and manual stepping.
  """
  @spec poll_once(server_ref()) :: {:ok, [map()]} | {:error, term()}
  def poll_once(poller) do
    GenServer.call(poller, :poll_once)
  end

  @doc """
  Subscribes a PID to receive live chat message notifications and error events.
  """
  @spec subscribe(server_ref(), pid()) :: :ok
  def subscribe(poller, subscriber_pid \\ self()) do
    GenServer.call(poller, {:subscribe, subscriber_pid})
  end

  @doc """
  Unsubscribes a PID from notifications.
  """
  @spec unsubscribe(server_ref(), pid()) :: :ok
  def unsubscribe(poller, subscriber_pid \\ self()) do
    GenServer.call(poller, {:unsubscribe, subscriber_pid})
  end

  @doc """
  Sets the default polling interval in milliseconds.
  """
  @spec set_interval(server_ref(), pos_integer()) :: :ok
  def set_interval(poller, interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    GenServer.call(poller, {:set_interval, interval_ms})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    case validate_init_opts(opts) do
      :ok ->
        live_chat_id = opts[:live_chat_id] || opts["live_chat_id"]
      default_interval =
        opts[:default_interval_ms] || opts[:interval_ms] || opts[:interval] ||
          opts["default_interval_ms"] || opts["interval_ms"] || opts["interval"] ||
          @default_interval_ms

      min_interval =
        opts[:min_interval_ms] || opts["min_interval_ms"] || @default_min_interval_ms

      max_interval =
        opts[:max_interval_ms] || opts["max_interval_ms"] || @default_max_interval_ms

      backoff_base =
        opts[:backoff_base_ms] || opts["backoff_base_ms"] || @default_backoff_base_ms

      max_backoff =
        opts[:max_backoff_ms] || opts["max_backoff_ms"] || @default_max_backoff_ms

      initial_token =
        opts[:initial_page_token] || opts[:page_token] || opts["initial_page_token"] ||
          opts["page_token"]

      handler_fn = opts[:handler_fn] || opts["handler_fn"]
      part = opts[:part] || opts["part"] || LiveChat.default_parts()
      max_results = opts[:max_results] || opts["max_results"]
      auto_start = Map.get(opts, :auto_start, Map.get(opts, "auto_start", true))

      client_opts = build_client_opts(opts)

      # Process subscribers
      raw_subs =
        List.wrap(
          opts[:subscribers] || opts[:subscriber] || opts["subscribers"] || opts["subscriber"] || []
        )

      {subscribers, monitors} = setup_subscribers(raw_subs)

      initial_state = %{
        live_chat_id: to_string(live_chat_id),
        client_opts: client_opts,
        subscribers: subscribers,
        monitors: monitors,
        handler_fn: handler_fn,
        page_token: initial_token,
        interval_ms: default_interval,
        default_interval_ms: default_interval,
        min_interval_ms: min_interval,
        max_interval_ms: max_interval,
        status: if(auto_start, do: :running, else: :paused),
        timer_ref: nil,
        message_count: 0,
        poll_count: 0,
        consecutive_errors: 0,
        last_error: nil,
        last_poll_at: nil,
        offline_at: nil,
        part: part,
        max_results: max_results,
        backoff_base_ms: backoff_base,
        max_backoff_ms: max_backoff
      }

      state =
        if auto_start do
          schedule_poll(initial_state, 0)
        else
          initial_state
        end

      {:ok, state}

    {:error, reason} ->
      {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    summary = %{
      status: state.status,
      live_chat_id: state.live_chat_id,
      page_token: state.page_token,
      interval_ms: state.interval_ms,
      message_count: state.message_count,
      poll_count: state.poll_count,
      subscribers_count: MapSet.size(state.subscribers),
      consecutive_errors: state.consecutive_errors,
      last_error: state.last_error,
      last_poll_at: state.last_poll_at,
      offline_at: state.offline_at
    }

    {:reply, summary, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    state = cancel_timer(state)
    {:reply, :ok, %{state | status: :paused}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    state = cancel_timer(state)
    state = %{state | status: :running}
    state = schedule_poll(state, 0)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:poll_once, _from, state) do
    {result, new_state} = execute_poll(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    if MapSet.member?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      mon_ref = Process.monitor(pid)
      new_subs = MapSet.put(state.subscribers, pid)
      new_mons = Map.put(state.monitors, pid, mon_ref)
      {:reply, :ok, %{state | subscribers: new_subs, monitors: new_mons}}
    end
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) when is_pid(pid) do
    case Map.pop(state.monitors, pid) do
      {nil, _} ->
        new_subs = MapSet.delete(state.subscribers, pid)
        {:reply, :ok, %{state | subscribers: new_subs}}

      {mon_ref, new_mons} ->
        Process.demonitor(mon_ref, [:flush])
        new_subs = MapSet.delete(state.subscribers, pid)
        {:reply, :ok, %{state | subscribers: new_subs, monitors: new_mons}}
    end
  end

  @impl true
  def handle_call({:set_interval, interval_ms}, _from, state) do
    {:reply, :ok, %{state | default_interval_ms: interval_ms, interval_ms: interval_ms}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | timer_ref: nil}

    if state.status == :running do
      {_result, new_state} = execute_poll(state)

      final_state =
        if new_state.status == :running and is_nil(new_state.timer_ref) do
          schedule_poll(new_state, new_state.interval_ms)
        else
          new_state
        end

      {:noreply, final_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    new_mons =
      Enum.reject(state.monitors, fn {p, r} -> p == pid or r == ref end)
      |> Map.new()

    new_subs = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subs, monitors: new_mons}}
  end

  @impl true
  def handle_info(_other, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state)
    :ok
  end

  # --- Internal Polling & Dispatch Logic ---

  defp execute_poll(state) do
    query_opts =
      state.client_opts
      |> Map.put(:part, state.part)
      |> maybe_put_opt(:page_token, state.page_token)
      |> maybe_put_opt(:max_results, state.max_results)

    case LiveChat.list_messages(state.live_chat_id, query_opts) do
      {:ok, response} ->
        messages = response.messages || []
        next_token = response.next_page_token
        suggested_interval = response.polling_interval_ms
        offline_at = response.offline_at

        # Broadcast new messages to subscribers
        if length(messages) > 0 do
          broadcast(state.subscribers, {:live_chat_messages, state.live_chat_id, messages})
          invoke_handler(state.handler_fn, state.live_chat_id, messages)
        end

        # Dynamic interval adjustment clamped to configured limits
        interval_ms = calculate_interval(suggested_interval, state)

        # Check if chat is ended/offline
        {new_status, new_offline_at} =
          if is_binary(offline_at) and offline_at != "" do
            broadcast(state.subscribers, {:live_chat_ended, state.live_chat_id, %{offline_at: offline_at}})
            {:ended, offline_at}
          else
            {state.status, state.offline_at}
          end

        new_state = %{
          state
          | page_token: next_token || state.page_token,
            interval_ms: interval_ms,
            message_count: state.message_count + length(messages),
            poll_count: state.poll_count + 1,
            consecutive_errors: 0,
            last_error: nil,
            last_poll_at: DateTime.utc_now(),
            offline_at: new_offline_at,
            status: new_status
        }

        {{:ok, messages}, new_state}

      {:error, reason} = error ->
        consecutive_errors = state.consecutive_errors + 1
        broadcast(state.subscribers, {:live_chat_error, state.live_chat_id, reason})

        # Check for chat ended / not found
        {new_status, backoff_ms} =
          case reason do
            {404, _} ->
              broadcast(state.subscribers, {:live_chat_ended, state.live_chat_id, reason})
              {:ended, nil}

            {:quota_exceeded, _} ->
              # Quota exhaustion: long backoff
              backoff = calculate_backoff(consecutive_errors, state.backoff_base_ms, state.max_backoff_ms)
              {state.status, backoff}

            _ ->
              backoff = calculate_backoff(consecutive_errors, state.backoff_base_ms, state.max_backoff_ms)
              {state.status, backoff}
          end

        new_state = %{
          state
          | consecutive_errors: consecutive_errors,
            last_error: reason,
            last_poll_at: DateTime.utc_now(),
            status: new_status
        }

        # If backoff delay is calculated and poller is still running, schedule retry
        new_state =
          if new_status == :running and is_integer(backoff_ms) and backoff_ms > 0 do
            schedule_poll(new_state, backoff_ms)
          else
            new_state
          end

        {error, new_state}
    end
  end

  defp calculate_interval(suggested_interval, state) when is_integer(suggested_interval) and suggested_interval > 0 do
    suggested_interval
    |> max(state.min_interval_ms)
    |> min(state.max_interval_ms)
  end

  defp calculate_interval(_invalid, state), do: state.default_interval_ms

  defp calculate_backoff(attempt, base_ms, max_ms) do
    Errors.backoff_delay(attempt, base_backoff_ms: base_ms, max_backoff_ms: max_ms, min_backoff_ms: 100)
  end

  defp schedule_poll(state, delay_ms) do
    state = cancel_timer(state)
    timer_ref = Process.send_after(self(), :poll, delay_ms)
    %{state | timer_ref: timer_ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp broadcast(subscribers, message) do
    for pid <- subscribers, is_pid(pid) and Process.alive?(pid) do
      send(pid, message)
    end
    :ok
  end

  defp invoke_handler(nil, _chat_id, _messages), do: :ok

  defp invoke_handler(fun, _chat_id, messages) when is_function(fun, 1) do
    fun.(messages)
  rescue
    e ->
      Logger.warning("LiveChat.Poller handler_fn/1 raised exception: #{inspect(e)}")
      :error
  end

  defp invoke_handler(fun, chat_id, messages) when is_function(fun, 2) do
    fun.(chat_id, messages)
  rescue
    e ->
      Logger.warning("LiveChat.Poller handler_fn/2 raised exception: #{inspect(e)}")
      :error
  end

  defp invoke_handler({mod, fun, extra_args}, _chat_id, messages)
       when is_atom(mod) and is_atom(fun) and is_list(extra_args) do
    apply(mod, fun, [messages | extra_args])
  rescue
    e ->
      Logger.warning("LiveChat.Poller handler MFA raised exception: #{inspect(e)}")
      :error
  end

  defp invoke_handler(_other, _chat_id, _messages), do: :ok

  defp setup_subscribers(subs) do
    valid_pids =
      subs
      |> Enum.filter(&is_pid/1)
      |> Enum.filter(&Process.alive?/1)

    monitors =
      Enum.reduce(valid_pids, %{}, fn pid, acc ->
        Map.put(acc, pid, Process.monitor(pid))
      end)

    {MapSet.new(valid_pids), monitors}
  end

  defp build_client_opts(opts) do
    raw_client = opts[:client_opts] || opts["client_opts"] || %{}
    client_map = to_map(raw_client)

    client_map
    |> maybe_put_opt(:token, opts[:token] || opts["token"])
    |> maybe_put_opt(:api_key, opts[:api_key] || opts["api_key"])
    |> maybe_put_opt(:plug, opts[:plug] || opts["plug"])
    |> maybe_put_opt(:auto_refresh, opts[:auto_refresh] || opts["auto_refresh"])
  end

  defp validate_init_opts(opts) do
    live_chat_id = opts[:live_chat_id] || opts["live_chat_id"]

    if is_binary(live_chat_id) and live_chat_id != "" do
      :ok
    else
      {:error, :missing_live_chat_id}
    end
  end

  defp extract_genserver_opts(opts) do
    name = opts[:name] || opts["name"]

    if name do
      [name: name]
    else
      []
    end
  end

  defp maybe_put_opt(map, _key, nil), do: map
  defp maybe_put_opt(map, key, val), do: Map.put(map, key, val)

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(_), do: %{}
end
