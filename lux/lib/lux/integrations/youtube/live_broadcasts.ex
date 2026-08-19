defmodule Lux.Integrations.YouTube.LiveBroadcasts do
  @moduledoc """
  Manages YouTube Live Broadcasts (`liveBroadcasts` resource) via the YouTube Live Streaming API.

  Provides full lifecycle management including creating scheduled broadcasts, listing,
  retrieving, updating metadata, binding to ingestion streams, transitioning lifecycle states
  (`testing` -> `live` -> `complete`), and deleting broadcasts.

  All requests are executed through `Lux.Integrations.YouTube.Client`, providing automatic
  Bearer token authentication, token refresh on 401, quota and rate limit parsing, and
  testing support with `Req.Test`.
  """

  alias Lux.Integrations.YouTube.Client

  @default_parts "snippet,status,contentDetails"
  @default_transition_parts "status,snippet,contentDetails"
  @default_bind_parts "id,snippet,contentDetails,status"
  @valid_transitions ~w(testing live complete)

  # --- Typespecs ---

  @type broadcast_id :: String.t()
  @type stream_id :: String.t()
  @type privacy_status :: :public | :private | :unlisted | String.t()
  @type broadcast_status :: :all | :active | :completed | :upcoming | String.t()
  @type broadcast_type :: :all | :event | :persistent | String.t()
  @type transition_status :: :testing | :live | :complete | String.t()
  @type latency_preference :: :normal | :low | :ultraLow | :ultra_low | String.t()

  @type broadcast :: %{required(String.t()) => term()}
  @type broadcast_list_response :: %{
          required(String.t()) => term()
        }

  @type request_opts :: Client.request_opts() | keyword() | map()

  @type create_broadcast_params ::
          %{
            optional(:title) => String.t(),
            optional(:description) => String.t(),
            optional(:scheduled_start_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:scheduledStartTime) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:scheduled_end_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:scheduledEndTime) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:privacy_status) => privacy_status(),
            optional(:privacyStatus) => privacy_status(),
            optional(:is_default_broadcast) => boolean(),
            optional(:isDefaultBroadcast) => boolean(),
            optional(:self_declared_made_for_kids) => boolean(),
            optional(:selfDeclaredMadeForKids) => boolean(),
            optional(:enable_auto_start) => boolean(),
            optional(:enableAutoStart) => boolean(),
            optional(:enable_auto_stop) => boolean(),
            optional(:enableAutoStop) => boolean(),
            optional(:enable_dvr) => boolean(),
            optional(:enableDvr) => boolean(),
            optional(:enable_content_encryption) => boolean(),
            optional(:enableContentEncryption) => boolean(),
            optional(:enable_embed) => boolean(),
            optional(:enableEmbed) => boolean(),
            optional(:record_from_start) => boolean(),
            optional(:recordFromStart) => boolean(),
            optional(:start_with_slate) => boolean(),
            optional(:startWithSlate) => boolean(),
            optional(:enable_closed_captions) => boolean(),
            optional(:enableClosedCaptions) => boolean(),
            optional(:closed_captions_type) => String.t(),
            optional(:closedCaptionsType) => String.t(),
            optional(:enable_low_latency) => boolean(),
            optional(:enableLowLatency) => boolean(),
            optional(:latency_preference) => latency_preference(),
            optional(:latencyPreference) => latency_preference(),
            optional(:monitor_stream) => map(),
            optional(:monitorStream) => map(),
            optional(:snippet) => map(),
            optional(:status) => map(),
            optional(:contentDetails) => map(),
            optional(:content_details) => map(),
            optional(String.t()) => term()
          }
          | Keyword.t()

  @type update_broadcast_params ::
          %{
            required(:id) => String.t(),
            optional(:title) => String.t(),
            optional(:description) => String.t(),
            optional(:scheduled_start_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:scheduledStartTime) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:scheduled_end_time) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:scheduledEndTime) => String.t() | DateTime.t() | NaiveDateTime.t(),
            optional(:privacy_status) => privacy_status(),
            optional(:privacyStatus) => privacy_status(),
            optional(:self_declared_made_for_kids) => boolean(),
            optional(:selfDeclaredMadeForKids) => boolean(),
            optional(:enable_auto_start) => boolean(),
            optional(:enableAutoStart) => boolean(),
            optional(:enable_auto_stop) => boolean(),
            optional(:enableAutoStop) => boolean(),
            optional(:enable_dvr) => boolean(),
            optional(:enableDvr) => boolean(),
            optional(:enable_content_encryption) => boolean(),
            optional(:enableContentEncryption) => boolean(),
            optional(:enable_embed) => boolean(),
            optional(:enableEmbed) => boolean(),
            optional(:record_from_start) => boolean(),
            optional(:recordFromStart) => boolean(),
            optional(:enable_closed_captions) => boolean(),
            optional(:enableClosedCaptions) => boolean(),
            optional(:latency_preference) => latency_preference(),
            optional(:latencyPreference) => latency_preference(),
            optional(:snippet) => map(),
            optional(:status) => map(),
            optional(:contentDetails) => map(),
            optional(:content_details) => map(),
            optional(String.t()) => term()
          }
          | Keyword.t()

  @type list_broadcasts_params ::
          %{
            optional(:broadcast_status) => broadcast_status(),
            optional(:broadcastStatus) => broadcast_status(),
            optional(:broadcast_type) => broadcast_type(),
            optional(:broadcastType) => broadcast_type(),
            optional(:id) => String.t() | [String.t()],
            optional(:mine) => boolean(),
            optional(:max_results) => pos_integer(),
            optional(:maxResults) => pos_integer(),
            optional(:page_token) => String.t(),
            optional(:pageToken) => String.t(),
            optional(:part) => String.t() | [String.t() | atom()],
            optional(:on_behalf_of_content_owner) => String.t(),
            optional(:onBehalfOfContentOwner) => String.t(),
            optional(:on_behalf_of_content_owner_channel) => String.t(),
            optional(:onBehalfOfContentOwnerChannel) => String.t()
          }
          | Keyword.t()

  # --- Public API ---

  @doc """
  Returns the default part parameter for live broadcast requests.
  """
  @spec default_parts() :: String.t()
  def default_parts, do: @default_parts

  @doc """
  Creates a new YouTube Live Broadcast.

  ## Parameters
  - `params`: Map or keyword list of broadcast parameters (supports flat friendly keys or nested YouTube JSON structure).
  - `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3` (e.g. `:token`, `:plug`, `:part`).

  ## Returns
  - `{:ok, broadcast_map}` on success
  - `{:error, reason}` on failure
  """
  @spec create_broadcast(create_broadcast_params(), request_opts()) ::
          {:ok, broadcast()} | {:error, term()}
  def create_broadcast(params, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    part = resolve_part(params_map, opts_map, @default_parts)
    body = build_create_body(params_map)

    query_params =
      [part: part]
      |> maybe_put_query(
        :onBehalfOfContentOwner,
        params_map[:onBehalfOfContentOwner] || params_map[:on_behalf_of_content_owner] ||
          opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner]
      )
      |> maybe_put_query(
        :onBehalfOfContentOwnerChannel,
        params_map[:onBehalfOfContentOwnerChannel] || params_map[:on_behalf_of_content_owner_channel] ||
          opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel]
      )

    client_opts =
      opts_map
      |> Map.put(:params, query_params)
      |> Map.put(:json, body)

    Client.post("/liveBroadcasts", client_opts)
  end

  @doc """
  Lists live broadcasts for the authenticated channel or filtered by ID/status.

  ## Parameters
  - `params`: Query filters and pagination options (map or keyword list).
    - `:broadcast_status` / `:broadcastStatus`: `:all`, `:active`, `:completed`, `:upcoming` (automatically enables `mine: true`).
    - `:broadcast_type` / `:broadcastType`: `:all`, `:event`, `:persistent` (default `:event`).
    - `:id`: Filter by broadcast ID or list of IDs.
    - `:mine`: Boolean, defaults to `true` when querying without `:id`.
    - `:max_results` / `:maxResults`: Integer (1..50, default 25).
    - `:page_token` / `:pageToken`: Pagination cursor.
    - `:part`: Resource parts string or list (default `"snippet,status,contentDetails"`).
  - `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3`.

  ## Returns
  - `{:ok, broadcast_list_response}` on success
  - `{:error, reason}` on failure
  """
  @spec list_broadcasts(list_broadcasts_params(), request_opts()) ::
          {:ok, broadcast_list_response()} | {:error, term()}
  def list_broadcasts(params \\ %{}, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    part = resolve_part(params_map, opts_map, @default_parts)
    query_params = build_list_query_params(params_map, part)

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    Client.get("/liveBroadcasts", client_opts)
  end

  @doc """
  Retrieves a single live broadcast by ID.

  ## Parameters
  - `id`: YouTube broadcast ID string.
  - `opts`: Client options (supports `:part`, `:token`, `:plug`).

  ## Returns
  - `{:ok, broadcast_map}` if found
  - `{:error, :not_found}` if no broadcast matches the given ID
  - `{:error, :missing_broadcast_id}` if `id` is blank or invalid
  - `{:error, reason}` on API or network failure
  """
  @spec get_broadcast(broadcast_id(), request_opts()) ::
          {:ok, broadcast()} | {:error, term()}
  def get_broadcast(id, opts \\ %{})

  def get_broadcast(id, opts) when is_binary(id) and id != "" do
    opts_map = to_map(opts)
    part = resolve_part(opts_map, opts_map, @default_parts)

    query_params =
      [part: part, id: id]
      |> maybe_put_query(
        :onBehalfOfContentOwner,
        opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner]
      )
      |> maybe_put_query(
        :onBehalfOfContentOwnerChannel,
        opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel]
      )

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    case Client.get("/liveBroadcasts", client_opts) do
      {:ok, %{"items" => [broadcast | _]}} ->
        {:ok, broadcast}

      {:ok, %{"items" => []}} ->
        {:error, :not_found}

      {:ok, %{"kind" => "youtube#liveBroadcast"} = broadcast} ->
        {:ok, broadcast}

      {:ok, other} ->
        {:ok, other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_broadcast(_id, _opts), do: {:error, :missing_broadcast_id}

  @doc """
  Updates an existing YouTube live broadcast's metadata and settings.

  ## Parameters
  - `params`: Map containing `:id` and updated broadcast fields.
  - `opts`: Client options forwarded to `Lux.Integrations.YouTube.Client.request/3`.

  ## Returns
  - `{:ok, updated_broadcast_map}` on success
  - `{:error, :missing_broadcast_id}` if `:id` is not supplied
  - `{:error, reason}` on API or network failure
  """
  @spec update_broadcast(update_broadcast_params(), request_opts()) ::
          {:ok, broadcast()} | {:error, term()}
  def update_broadcast(params, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    id = params_map[:id] || params_map["id"]

    if is_nil(id) or id == "" do
      {:error, :missing_broadcast_id}
    else
      part = resolve_part(params_map, opts_map, @default_parts)
      body = build_update_body(params_map)

      query_params =
        [part: part]
        |> maybe_put_query(
          :onBehalfOfContentOwner,
          params_map[:onBehalfOfContentOwner] || params_map[:on_behalf_of_content_owner] ||
            opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner]
        )
        |> maybe_put_query(
          :onBehalfOfContentOwnerChannel,
          params_map[:onBehalfOfContentOwnerChannel] || params_map[:on_behalf_of_content_owner_channel] ||
            opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel]
        )

      client_opts =
        opts_map
        |> Map.put(:params, query_params)
        |> Map.put(:json, body)

      Client.put("/liveBroadcasts", client_opts)
    end
  end

  @doc """
  Transitions the lifecycle status of a live broadcast.

  Valid transition target statuses:
  - `:testing` / `"testing"`: Enters monitor stream testing before going live.
  - `:live` / `"live"`: Transitions to public streaming.
  - `:complete` / `"complete"`: Terminates the broadcast (irreversible).

  ## Parameters
  - `broadcast_id`: YouTube broadcast ID string.
  - `status`: Target status atom (`:testing`, `:live`, `:complete`) or string.
  - `opts`: Client options (supports `:part`, default `"status,snippet,contentDetails"`).

  ## Returns
  - `{:ok, updated_broadcast_map}` on success
  - `{:error, {:invalid_transition_status, status}}` if the status is not valid
  - `{:error, :missing_broadcast_id}` if broadcast ID is omitted
  - `{:error, reason}` on API failure
  """
  @spec transition_broadcast(broadcast_id(), transition_status(), request_opts()) ::
          {:ok, broadcast()} | {:error, term()}
  def transition_broadcast(broadcast_id, status, opts \\ %{})

  def transition_broadcast(broadcast_id, status, opts)
      when is_binary(broadcast_id) and broadcast_id != "" do
    status_str = normalize_transition_status(status)

    if status_str in @valid_transitions do
      opts_map = to_map(opts)
      part = resolve_part(opts_map, opts_map, @default_transition_parts)

      query_params =
        [broadcastStatus: status_str, id: broadcast_id, part: part]
        |> maybe_put_query(
          :onBehalfOfContentOwner,
          opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner]
        )
        |> maybe_put_query(
          :onBehalfOfContentOwnerChannel,
          opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel]
        )

      client_opts =
        opts_map
        |> Map.put(:params, query_params)

      Client.post("/liveBroadcasts/transition", client_opts)
    else
      {:error, {:invalid_transition_status, status}}
    end
  end

  def transition_broadcast(_broadcast_id, _status, _opts), do: {:error, :missing_broadcast_id}

  @doc """
  Binds a live broadcast to a live stream (ingestion point) or unbinds it.

  ## Parameters
  - `broadcast_id`: YouTube broadcast ID string.
  - `stream_id`: YouTube live stream ID string, or `nil`/`""` to unbind.
  - `opts`: Client options (supports `:part`, default `"id,snippet,contentDetails,status"`).

  ## Returns
  - `{:ok, updated_broadcast_map}` on success
  - `{:error, :missing_broadcast_id}` if broadcast ID is omitted
  - `{:error, reason}` on API failure
  """
  @spec bind_broadcast(broadcast_id(), stream_id() | nil, request_opts()) ::
          {:ok, broadcast()} | {:error, term()}
  def bind_broadcast(broadcast_id, stream_id, opts \\ %{})

  def bind_broadcast(broadcast_id, stream_id, opts)
      when is_binary(broadcast_id) and broadcast_id != "" do
    opts_map = to_map(opts)
    part = resolve_part(opts_map, opts_map, @default_bind_parts)

    query_params =
      [id: broadcast_id, part: part]
      |> maybe_put_query(:streamId, format_stream_id(stream_id))
      |> maybe_put_query(
        :onBehalfOfContentOwner,
        opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner]
      )
      |> maybe_put_query(
        :onBehalfOfContentOwnerChannel,
        opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel]
      )

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    Client.post("/liveBroadcasts/bind", client_opts)
  end

  def bind_broadcast(_broadcast_id, _stream_id, _opts), do: {:error, :missing_broadcast_id}

  @doc """
  Deletes a YouTube live broadcast by ID.

  ## Parameters
  - `broadcast_id`: YouTube broadcast ID string.
  - `opts`: Client options.

  ## Returns
  - `{:ok, %{id: id, deleted: true}}` on successful deletion (HTTP 204).
  - `{:error, :missing_broadcast_id}` if `broadcast_id` is invalid.
  - `{:error, reason}` on API or network failure.
  """
  @spec delete_broadcast(broadcast_id(), request_opts()) :: {:ok, map()} | {:error, term()}
  def delete_broadcast(broadcast_id, opts \\ %{})

  def delete_broadcast(broadcast_id, opts) when is_binary(broadcast_id) and broadcast_id != "" do
    opts_map = to_map(opts)

    query_params =
      [id: broadcast_id]
      |> maybe_put_query(
        :onBehalfOfContentOwner,
        opts_map[:onBehalfOfContentOwner] || opts_map[:on_behalf_of_content_owner]
      )
      |> maybe_put_query(
        :onBehalfOfContentOwnerChannel,
        opts_map[:onBehalfOfContentOwnerChannel] || opts_map[:on_behalf_of_content_owner_channel]
      )

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    case Client.delete("/liveBroadcasts", client_opts) do
      {:ok, _body} -> {:ok, %{id: broadcast_id, deleted: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_broadcast(_id, _opts), do: {:error, :missing_broadcast_id}

  # --- Helper Accessors ---

  @doc """
  Extracts the bound live stream ID from a live broadcast map.
  """
  @spec bound_stream_id(map() | nil) :: String.t() | nil
  def bound_stream_id(nil), do: nil
  def bound_stream_id(%{"contentDetails" => %{"boundStreamId" => id}}), do: id
  def bound_stream_id(%{contentDetails: %{boundStreamId: id}}), do: id
  def bound_stream_id(%{content_details: %{bound_stream_id: id}}), do: id
  def bound_stream_id(_), do: nil

  @doc """
  Extracts the live chat ID (`liveChatId`) from a live broadcast map.
  """
  @spec live_chat_id(map() | nil) :: String.t() | nil
  def live_chat_id(nil), do: nil
  def live_chat_id(%{"snippet" => %{"liveChatId" => id}}), do: id
  def live_chat_id(%{snippet: %{liveChatId: id}}), do: id
  def live_chat_id(%{snippet: %{live_chat_id: id}}), do: id
  def live_chat_id(_), do: nil

  @doc """
  Extracts the lifecycle status string from a live broadcast map.
  """
  @spec status(map() | nil) :: String.t() | nil
  def status(nil), do: nil
  def status(%{"status" => %{"lifeCycleStatus" => status}}), do: status
  def status(%{status: %{lifeCycleStatus: status}}), do: status
  def status(%{status: %{life_cycle_status: status}}), do: status
  def status(_), do: nil

  @doc """
  Alias for `status/1`.
  """
  @spec life_cycle_status(map() | nil) :: String.t() | nil
  def life_cycle_status(broadcast), do: status(broadcast)

  @doc """
  Returns true if the broadcast lifecycle status is `"live"`.
  """
  @spec active?(map() | nil) :: boolean()
  def active?(broadcast), do: status(broadcast) == "live"

  @doc """
  Returns true if the broadcast lifecycle status is `"testing"` or `"testStarting"`.
  """
  @spec testing?(map() | nil) :: boolean()
  def testing?(broadcast), do: status(broadcast) in ["testing", "testStarting"]

  @doc """
  Returns true if the broadcast lifecycle status is `"complete"`.
  """
  @spec complete?(map() | nil) :: boolean()
  def complete?(broadcast), do: status(broadcast) == "complete"

  @doc """
  Returns true if the broadcast lifecycle status is `"created"` or `"ready"`.
  """
  @spec upcoming?(map() | nil) :: boolean()
  def upcoming?(broadcast), do: status(broadcast) in ["created", "ready"]

  @doc """
  Returns the public YouTube watch URL for the broadcast.
  """
  @spec broadcast_url(map() | String.t() | nil) :: String.t() | nil
  def broadcast_url(nil), do: nil
  def broadcast_url(%{"id" => id}) when is_binary(id) and id != "", do: "https://www.youtube.com/watch?v=#{id}"
  def broadcast_url(%{id: id}) when is_binary(id) and id != "", do: "https://www.youtube.com/watch?v=#{id}"
  def broadcast_url(id) when is_binary(id) and id != "", do: "https://www.youtube.com/watch?v=#{id}"
  def broadcast_url(_), do: nil

  # --- Private Builders & Normalization Helpers ---

  defp build_create_body(params) do
    snippet = build_snippet(params)
    status = build_status(params)
    content_details = build_content_details(params)

    %{}
    |> Map.put("snippet", snippet)
    |> Map.put("status", status)
    |> maybe_put_map("contentDetails", content_details)
  end

  defp build_update_body(params) do
    id = params[:id] || params["id"]

    %{"id" => id}
    |> maybe_put_map("snippet", build_snippet_for_update(params))
    |> maybe_put_map("status", build_status_for_update(params))
    |> maybe_put_map("contentDetails", build_content_details_for_update(params))
  end

  defp build_snippet(params) do
    raw_snippet = params[:snippet] || params["snippet"] || %{}
    snippet_map = to_map(raw_snippet)

    title =
      params[:title] ||
        params["title"] ||
        snippet_map[:title] ||
        snippet_map["title"] ||
        "Live Broadcast #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    description =
      params[:description] ||
        params["description"] ||
        snippet_map[:description] ||
        snippet_map["description"] ||
        ""

    scheduled_start_time =
      format_datetime(
        params[:scheduled_start_time] ||
          params[:scheduledStartTime] ||
          params["scheduledStartTime"] ||
          snippet_map[:scheduled_start_time] ||
          snippet_map[:scheduledStartTime] ||
          snippet_map["scheduledStartTime"]
      )

    scheduled_end_time =
      format_datetime(
        params[:scheduled_end_time] ||
          params[:scheduledEndTime] ||
          params["scheduledEndTime"] ||
          snippet_map[:scheduled_end_time] ||
          snippet_map[:scheduledEndTime] ||
          snippet_map["scheduledEndTime"]
      )

    is_default =
      params[:is_default_broadcast] ||
        params[:isDefaultBroadcast] ||
        params["isDefaultBroadcast"] ||
        snippet_map[:is_default_broadcast] ||
        snippet_map[:isDefaultBroadcast] ||
        snippet_map["isDefaultBroadcast"] ||
        false

    %{"title" => to_string(title), "description" => to_string(description)}
    |> maybe_put("scheduledStartTime", scheduled_start_time)
    |> maybe_put("scheduledEndTime", scheduled_end_time)
    |> maybe_put("isDefaultBroadcast", is_default)
  end

  defp build_snippet_for_update(params) do
    raw_snippet = params[:snippet] || params["snippet"]

    if raw_snippet || params[:title] || params[:description] || params[:scheduled_start_time] ||
         params[:scheduledStartTime] || params[:scheduled_end_time] || params[:scheduledEndTime] do
      snippet_map = if raw_snippet, do: to_map(raw_snippet), else: %{}

      %{}
      |> maybe_put("title", params[:title] || snippet_map[:title] || snippet_map["title"])
      |> maybe_put(
        "description",
        params[:description] || snippet_map[:description] || snippet_map["description"]
      )
      |> maybe_put(
        "scheduledStartTime",
        format_datetime(
          params[:scheduled_start_time] ||
            params[:scheduledStartTime] ||
            params["scheduledStartTime"] ||
            snippet_map[:scheduled_start_time] ||
            snippet_map[:scheduledStartTime] ||
            snippet_map["scheduledStartTime"]
        )
      )
      |> maybe_put(
        "scheduledEndTime",
        format_datetime(
          params[:scheduled_end_time] ||
            params[:scheduledEndTime] ||
            params["scheduledEndTime"] ||
            snippet_map[:scheduled_end_time] ||
            snippet_map[:scheduledEndTime] ||
            snippet_map["scheduledEndTime"]
        )
      )
    else
      nil
    end
  end

  defp build_status(params) do
    raw_status = params[:status] || params["status"] || %{}
    status_map = to_map(raw_status)

    privacy =
      normalize_privacy(
        params[:privacy_status] ||
          params[:privacyStatus] ||
          params["privacyStatus"] ||
          status_map[:privacy_status] ||
          status_map[:privacyStatus] ||
          status_map["privacyStatus"] ||
          :public
      )

    made_for_kids =
      params[:self_declared_made_for_kids] ||
        params[:selfDeclaredMadeForKids] ||
        params["selfDeclaredMadeForKids"] ||
        status_map[:self_declared_made_for_kids] ||
        status_map[:selfDeclaredMadeForKids] ||
        status_map["selfDeclaredMadeForKids"] ||
        false

    %{
      "privacyStatus" => privacy,
      "selfDeclaredMadeForKids" => made_for_kids
    }
  end

  defp build_status_for_update(params) do
    raw_status = params[:status] || params["status"]

    if raw_status || params[:privacy_status] || params[:privacyStatus] ||
         Map.has_key?(params, :self_declared_made_for_kids) ||
         Map.has_key?(params, :selfDeclaredMadeForKids) do
      status_map = if raw_status, do: to_map(raw_status), else: %{}

      privacy =
        params[:privacy_status] ||
          params[:privacyStatus] ||
          params["privacyStatus"] ||
          status_map[:privacy_status] ||
          status_map[:privacyStatus] ||
          status_map["privacyStatus"]

      made_for_kids =
        params[:self_declared_made_for_kids] ||
          params[:selfDeclaredMadeForKids] ||
          params["selfDeclaredMadeForKids"] ||
          status_map[:self_declared_made_for_kids] ||
          status_map[:selfDeclaredMadeForKids] ||
          status_map["selfDeclaredMadeForKids"]

      %{}
      |> maybe_put("privacyStatus", if(privacy, do: normalize_privacy(privacy), else: nil))
      |> maybe_put("selfDeclaredMadeForKids", made_for_kids)
    else
      nil
    end
  end

  defp build_content_details(params) do
    raw_cd = params[:content_details] || params[:contentDetails] || params["contentDetails"] || %{}
    cd_map = to_map(raw_cd)

    %{}
    |> maybe_put(
      "enableAutoStart",
      get_boolean(params, cd_map, [:enable_auto_start, :enableAutoStart, "enableAutoStart"])
    )
    |> maybe_put(
      "enableAutoStop",
      get_boolean(params, cd_map, [:enable_auto_stop, :enableAutoStop, "enableAutoStop"])
    )
    |> maybe_put("enableDvr", get_boolean(params, cd_map, [:enable_dvr, :enableDvr, "enableDvr"]))
    |> maybe_put(
      "enableContentEncryption",
      get_boolean(params, cd_map, [
        :enable_content_encryption,
        :enableContentEncryption,
        "enableContentEncryption"
      ])
    )
    |> maybe_put(
      "enableEmbed",
      get_boolean(params, cd_map, [:enable_embed, :enableEmbed, "enableEmbed"])
    )
    |> maybe_put(
      "recordFromStart",
      get_boolean(params, cd_map, [:record_from_start, :recordFromStart, "recordFromStart"])
    )
    |> maybe_put(
      "startWithSlate",
      get_boolean(params, cd_map, [:start_with_slate, :startWithSlate, "startWithSlate"])
    )
    |> maybe_put(
      "enableClosedCaptions",
      get_boolean(params, cd_map, [
        :enable_closed_captions,
        :enableClosedCaptions,
        "enableClosedCaptions"
      ])
    )
    |> maybe_put(
      "closedCaptionsType",
      params[:closed_captions_type] ||
        params[:closedCaptionsType] ||
        cd_map[:closed_captions_type] ||
        cd_map[:closedCaptionsType] ||
        cd_map["closedCaptionsType"]
    )
    |> maybe_put(
      "enableLowLatency",
      get_boolean(params, cd_map, [
        :enable_low_latency,
        :enableLowLatency,
        "enableLowLatency"
      ])
    )
    |> maybe_put(
      "latencyPreference",
      normalize_latency(
        params[:latency_preference] ||
          params[:latencyPreference] ||
          cd_map[:latency_preference] ||
          cd_map[:latencyPreference] ||
          cd_map["latencyPreference"]
      )
    )
    |> maybe_put(
      "monitorStream",
      build_monitor_stream(params[:monitor_stream] || params[:monitorStream] || cd_map[:monitor_stream] || cd_map[:monitorStream] || cd_map["monitorStream"])
    )
  end

  defp build_content_details_for_update(params) do
    raw_cd = params[:content_details] || params[:contentDetails] || params["contentDetails"]

    if raw_cd || params[:enable_auto_start] || params[:enableAutoStart] ||
         params[:enable_auto_stop] || params[:enableAutoStop] ||
         params[:enable_dvr] || params[:enableDvr] ||
         params[:enable_content_encryption] || params[:enableContentEncryption] ||
         params[:enable_embed] || params[:enableEmbed] ||
         params[:record_from_start] || params[:recordFromStart] ||
         params[:latency_preference] || params[:latencyPreference] ||
         params[:monitor_stream] || params[:monitorStream] do
      build_content_details(params)
    else
      nil
    end
  end

  defp build_monitor_stream(nil), do: nil

  defp build_monitor_stream(ms) when is_map(ms) do
    ms_map = to_map(ms)

    enable =
      case Map.fetch(ms_map, :enable_monitor_stream) do
        {:ok, val} ->
          val

        :error ->
          case Map.fetch(ms_map, :enableMonitorStream) do
            {:ok, val} ->
              val

            :error ->
              case Map.fetch(ms_map, "enableMonitorStream") do
                {:ok, val} -> val
                :error -> nil
              end
          end
      end

    delay =
      ms_map[:broadcast_stream_delay_ms] ||
        ms_map[:broadcastStreamDelayMs] ||
        ms_map["broadcastStreamDelayMs"]

    %{}
    |> maybe_put("enableMonitorStream", enable)
    |> maybe_put("broadcastStreamDelayMs", delay)
  end

  defp build_monitor_stream(_), do: nil

  defp build_list_query_params(params, part) do
    id_param = format_id_param(params[:id] || params["id"])
    status_param = normalize_broadcast_status(params[:broadcast_status] || params[:broadcastStatus] || params["broadcastStatus"])
    type_param = normalize_broadcast_type(params[:broadcast_type] || params[:broadcastType] || params["broadcastType"])

    base = [part: part]

    base =
      if is_binary(id_param) and id_param != "" do
        Keyword.put(base, :id, id_param)
      else
        mine =
          case Map.fetch(params, :mine) do
            {:ok, val} -> val
            :error ->
              case Map.fetch(params, "mine") do
                {:ok, val} -> val
                :error -> true
              end
          end

        Keyword.put(base, :mine, mine)
      end

    base
    |> maybe_put_query(:broadcastStatus, status_param)
    |> maybe_put_query(:broadcastType, type_param)
    |> maybe_put_query(:maxResults, params[:max_results] || params[:maxResults] || params["maxResults"])
    |> maybe_put_query(:pageToken, params[:page_token] || params[:pageToken] || params["pageToken"])
    |> maybe_put_query(:onBehalfOfContentOwner, params[:onBehalfOfContentOwner] || params[:on_behalf_of_content_owner])
    |> maybe_put_query(:onBehalfOfContentOwnerChannel, params[:onBehalfOfContentOwnerChannel] || params[:on_behalf_of_content_owner_channel])
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"
  defp format_datetime(str) when is_binary(str), do: str
  defp format_datetime(_), do: nil

  defp normalize_privacy(:public), do: "public"
  defp normalize_privacy(:private), do: "private"
  defp normalize_privacy(:unlisted), do: "unlisted"
  defp normalize_privacy(val) when is_binary(val), do: val
  defp normalize_privacy(_), do: "public"

  defp normalize_latency(:normal), do: "normal"
  defp normalize_latency(:low), do: "low"
  defp normalize_latency(:ultraLow), do: "ultraLow"
  defp normalize_latency(:ultra_low), do: "ultraLow"
  defp normalize_latency(val) when is_binary(val), do: val
  defp normalize_latency(_), do: nil

  defp normalize_transition_status(:testing), do: "testing"
  defp normalize_transition_status(:live), do: "live"
  defp normalize_transition_status(:complete), do: "complete"
  defp normalize_transition_status(val) when is_binary(val), do: val
  defp normalize_transition_status(_), do: nil

  defp normalize_broadcast_status(:all), do: "all"
  defp normalize_broadcast_status(:active), do: "active"
  defp normalize_broadcast_status(:completed), do: "completed"
  defp normalize_broadcast_status(:upcoming), do: "upcoming"
  defp normalize_broadcast_status(val) when is_binary(val), do: val
  defp normalize_broadcast_status(_), do: nil

  defp normalize_broadcast_type(:all), do: "all"
  defp normalize_broadcast_type(:event), do: "event"
  defp normalize_broadcast_type(:persistent), do: "persistent"
  defp normalize_broadcast_type(val) when is_binary(val), do: val
  defp normalize_broadcast_type(_), do: nil

  defp format_id_param(nil), do: nil
  defp format_id_param(ids) when is_list(ids), do: Enum.map_join(ids, ",", &to_string/1)
  defp format_id_param(id) when is_binary(id), do: id
  defp format_id_param(_), do: nil

  defp format_stream_id(nil), do: nil
  defp format_stream_id(""), do: nil
  defp format_stream_id(id) when is_binary(id), do: id
  defp format_stream_id(_), do: nil

  defp resolve_part(params, opts, default) do
    case params[:part] || params["part"] || opts[:part] || opts["part"] do
      nil -> default
      parts when is_list(parts) -> Enum.map_join(parts, ",", &to_string/1)
      part when is_binary(part) -> part
      _ -> default
    end
  end

  defp get_boolean(map1, map2, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.fetch(map1, key) do
        {:ok, val} when is_boolean(val) ->
          {:halt, val}

        _ ->
          case Map.fetch(map2, key) do
            {:ok, val} when is_boolean(val) -> {:halt, val}
            _ -> {:cont, nil}
          end
      end
    end)
  end

  defp maybe_put_query(list, _key, nil), do: list
  defp maybe_put_query(list, key, value), do: Keyword.put(list, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, _key, empty_map) when map_size(empty_map) == 0, do: map
  defp maybe_put_map(map, key, submap), do: Map.put(map, key, submap)

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(_), do: %{}
end
