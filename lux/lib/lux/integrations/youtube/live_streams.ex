defmodule Lux.Integrations.YouTube.LiveStreams do
  @moduledoc """
  Manages YouTube Live Streaming ingestion endpoints (`liveStreams` resource).

  Provides functionality to:
  - Create (`create_stream/2`) RTMP/RTMPS live stream ingestion points
  - List (`list_streams/2`) streams belonging to the authenticated channel or by ID
  - Fetch (`get_stream/2`) specific stream details
  - Update (`update_stream/2`) stream metadata and video resolution/framerate
  - Delete (`delete_stream/2`) streams
  - Extract stream keys, RTMP addresses, and evaluate stream health/status
  """

  alias Lux.Integrations.YouTube.Client

  @default_part "snippet,cdn,status,contentDetails"

  # --- Typespecs ---

  @type ingestion_type :: String.t()
  @type resolution :: String.t()
  @type frame_rate :: String.t()
  @type stream_status :: String.t()
  @type health_status_value :: String.t()

  @type stream_item :: %{
          required(String.t()) => term()
        }

  @type stream_list_response :: %{
          required(String.t()) => term()
        }

  @type client_opts :: Client.request_opts() | keyword() | map()

  @type create_stream_params ::
          %{
            optional(:title) => String.t(),
            optional(:description) => String.t(),
            optional(:ingestion_type) => ingestion_type(),
            optional(:ingestionType) => ingestion_type(),
            optional(:resolution) => resolution(),
            optional(:frame_rate) => frame_rate(),
            optional(:frameRate) => frame_rate(),
            optional(:is_reusable) => boolean(),
            optional(:isReusable) => boolean(),
            optional(:is_default_stream) => boolean(),
            optional(:isDefaultStream) => boolean(),
            optional(:snippet) => map(),
            optional(:cdn) => map(),
            optional(:contentDetails) => map(),
            optional(:content_details) => map(),
            optional(String.t()) => term()
          }
          | Keyword.t()

  @type update_stream_params ::
          %{
            required(:id) => String.t(),
            optional(:title) => String.t(),
            optional(:description) => String.t(),
            optional(:ingestion_type) => ingestion_type(),
            optional(:ingestionType) => ingestion_type(),
            optional(:resolution) => resolution(),
            optional(:frame_rate) => frame_rate(),
            optional(:frameRate) => frame_rate(),
            optional(:snippet) => map(),
            optional(:cdn) => map(),
            optional(:contentDetails) => map(),
            optional(:content_details) => map(),
            optional(String.t()) => term()
          }
          | Keyword.t()

  @type list_streams_params ::
          %{
            optional(:mine) => boolean(),
            optional(:id) => String.t() | [String.t()],
            optional(:max_results) => non_neg_integer(),
            optional(:maxResults) => non_neg_integer(),
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
  Returns the default part parameter for live stream requests.
  """
  @spec default_part() :: String.t()
  def default_part, do: @default_part

  @doc """
  Creates a new YouTube Live Stream resource.

  ## Parameters
  - `params`: Map or keyword list of stream configuration properties:
    - `:title` (string): Stream title.
    - `:description` (string, optional): Stream description.
    - `:ingestion_type` / `:ingestionType` (string): `"rtmp"`, `"dash"`, or `"hls"` (default `"rtmp"`).
    - `:resolution` (string): `"1080p"`, `"720p"`, `"variable"`, etc. (default `"variable"`).
    - `:frame_rate` / `:frameRate` (string): `"60fps"`, `"30fps"`, `"variable"` (default `"variable"`).
    - `:is_reusable` / `:isReusable` (boolean): Whether stream is reusable across broadcasts (default `true`).
    - Alternatively, a nested map with `:snippet`, `:cdn`, `:contentDetails`.
  - `opts`: Client options (`:token`, `:plug`, `:auto_refresh`, etc.).

  ## Returns
  - `{:ok, stream}` on success (including `cdn.ingestionInfo.streamName` and `ingestionAddress`).
  - `{:error, reason}` on failure.
  """
  @spec create_stream(create_stream_params(), client_opts()) ::
          {:ok, stream_item()} | {:error, term()}
  def create_stream(params, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    part = resolve_part(params_map, opts_map, @default_part)
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

    Client.post("/liveStreams", client_opts)
  end

  @doc """
  Lists live streams.

  ## Parameters
  - `params`: Filter and pagination options:
    - `:mine` (boolean): List authenticated channel's streams (default `true` if no `:id`).
    - `:id` (string or list): Filter by stream ID(s).
    - `:max_results` / `:maxResults` (integer): Results per page (1..50).
    - `:page_token` / `:pageToken` (string): Token for page navigation.
    - `:part` (string or list): Resource parts to include.
  - `opts`: Client options.

  ## Returns
  - `{:ok, stream_list_response}` with `items` and pagination metadata.
  - `{:error, reason}` on failure.
  """
  @spec list_streams(list_streams_params(), client_opts()) ::
          {:ok, stream_list_response()} | {:error, term()}
  def list_streams(params \\ %{}, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    part = resolve_part(params_map, opts_map, @default_part)
    query_params = build_list_query_params(params_map, part)

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    Client.get("/liveStreams", client_opts)
  end

  @doc """
  Gets a single live stream by its ID.

  ## Parameters
  - `id`: Unique stream ID string.
  - `opts`: Client options (can include `:part`).

  ## Returns
  - `{:ok, stream}` on success (unwrapped from items list).
  - `{:error, :not_found}` if no stream exists with the given ID.
  - `{:error, :missing_stream_id}` if ID is blank or invalid.
  - `{:error, reason}` on failure.
  """
  @spec get_stream(String.t(), client_opts()) ::
          {:ok, stream_item()} | {:error, term()}
  def get_stream(id, opts \\ %{})

  def get_stream(id, opts) when is_binary(id) and id != "" do
    opts_map = to_map(opts)
    part = resolve_part(opts_map, opts_map, @default_part)

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

    case Client.get("/liveStreams", client_opts) do
      {:ok, %{"items" => [stream | _]}} ->
        {:ok, stream}

      {:ok, %{"items" => []}} ->
        {:error, :not_found}

      {:ok, %{"kind" => "youtube#liveStream"} = stream} ->
        {:ok, stream}

      {:ok, other} ->
        {:ok, other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_stream(_id, _opts), do: {:error, :missing_stream_id}

  @doc """
  Updates an existing live stream's metadata or configuration.

  ## Parameters
  - `params`: Stream update parameters. Must contain `:id` (or `"id"`).
  - `opts`: Client options.

  ## Returns
  - `{:ok, updated_stream}` on success.
  - `{:error, :missing_stream_id}` if `id` is omitted.
  - `{:error, reason}` on failure.
  """
  @spec update_stream(update_stream_params(), client_opts()) ::
          {:ok, stream_item()} | {:error, term()}
  def update_stream(params, opts \\ %{}) do
    params_map = to_map(params)
    opts_map = to_map(opts)

    id = params_map[:id] || params_map["id"]

    if is_nil(id) or id == "" do
      {:error, :missing_stream_id}
    else
      part = resolve_part(params_map, opts_map, "snippet,cdn,contentDetails")
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

      Client.put("/liveStreams", client_opts)
    end
  end

  @doc """
  Deletes an existing live stream.

  ## Parameters
  - `id`: Stream ID to delete.
  - `opts`: Client options.

  ## Returns
  - `{:ok, %{id: id, deleted: true}}` on successful deletion (HTTP 204).
  - `{:error, :missing_stream_id}` if `id` is invalid.
  - `{:error, reason}` on failure.
  """
  @spec delete_stream(String.t(), client_opts()) :: {:ok, map()} | {:error, term()}
  def delete_stream(id, opts \\ %{})

  def delete_stream(id, opts) when is_binary(id) and id != "" do
    opts_map = to_map(opts)

    query_params =
      [id: id]
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

    case Client.delete("/liveStreams", client_opts) do
      {:ok, _body} -> {:ok, %{id: id, deleted: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  def delete_stream(_id, _opts), do: {:error, :missing_stream_id}

  # --- Stream Ingestion & Status Extractors ---

  @doc """
  Extracts the stream key (`streamName`) from a stream resource or `cdn` map.
  """
  @spec stream_key(map() | nil) :: String.t() | nil
  def stream_key(nil), do: nil
  def stream_key(%{"cdn" => %{"ingestionInfo" => %{"streamName" => key}}}), do: key
  def stream_key(%{cdn: %{ingestionInfo: %{streamName: key}}}), do: key
  def stream_key(%{cdn: %{ingestion_info: %{stream_name: key}}}), do: key
  def stream_key(%{"ingestionInfo" => %{"streamName" => key}}), do: key
  def stream_key(%{ingestionInfo: %{streamName: key}}), do: key
  def stream_key(%{ingestion_info: %{stream_name: key}}), do: key
  def stream_key(_), do: nil

  @doc """
  Extracts the primary RTMP ingestion address from a stream resource.
  """
  @spec ingestion_address(map() | nil) :: String.t() | nil
  def ingestion_address(nil), do: nil
  def ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"ingestionAddress" => addr}}}), do: addr
  def ingestion_address(%{cdn: %{ingestionInfo: %{ingestionAddress: addr}}}), do: addr
  def ingestion_address(%{cdn: %{ingestion_info: %{ingestion_address: addr}}}), do: addr
  def ingestion_address(%{"ingestionInfo" => %{"ingestionAddress" => addr}}), do: addr
  def ingestion_address(%{ingestionInfo: %{ingestionAddress: addr}}), do: addr
  def ingestion_address(%{ingestion_info: %{ingestion_address: addr}}), do: addr
  def ingestion_address(_), do: nil

  @doc """
  Extracts the backup RTMP ingestion address from a stream resource.
  """
  @spec backup_ingestion_address(map() | nil) :: String.t() | nil
  def backup_ingestion_address(nil), do: nil
  def backup_ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"backupIngestionAddress" => addr}}}), do: addr
  def backup_ingestion_address(%{cdn: %{ingestionInfo: %{backupIngestionAddress: addr}}}), do: addr
  def backup_ingestion_address(%{cdn: %{ingestion_info: %{backup_ingestion_address: addr}}}), do: addr
  def backup_ingestion_address(%{"ingestionInfo" => %{"backupIngestionAddress" => addr}}), do: addr
  def backup_ingestion_address(%{ingestionInfo: %{backupIngestionAddress: addr}}), do: addr
  def backup_ingestion_address(%{ingestion_info: %{backup_ingestion_address: addr}}), do: addr
  def backup_ingestion_address(_), do: nil

  @doc """
  Extracts the secure primary RTMPS ingestion address from a stream resource.
  """
  @spec rtmps_ingestion_address(map() | nil) :: String.t() | nil
  def rtmps_ingestion_address(nil), do: nil
  def rtmps_ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"rtmpsIngestionAddress" => addr}}}), do: addr
  def rtmps_ingestion_address(%{cdn: %{ingestionInfo: %{rtmpsIngestionAddress: addr}}}), do: addr
  def rtmps_ingestion_address(%{cdn: %{ingestion_info: %{rtmps_ingestion_address: addr}}}), do: addr
  def rtmps_ingestion_address(%{"ingestionInfo" => %{"rtmpsIngestionAddress" => addr}}), do: addr
  def rtmps_ingestion_address(%{ingestionInfo: %{rtmpsIngestionAddress: addr}}), do: addr
  def rtmps_ingestion_address(%{ingestion_info: %{rtmps_ingestion_address: addr}}), do: addr
  def rtmps_ingestion_address(_), do: nil

  @doc """
  Extracts the secure backup RTMPS ingestion address from a stream resource.
  """
  @spec rtmps_backup_ingestion_address(map() | nil) :: String.t() | nil
  def rtmps_backup_ingestion_address(nil), do: nil
  def rtmps_backup_ingestion_address(%{"cdn" => %{"ingestionInfo" => %{"rtmpsBackupIngestionAddress" => addr}}}), do: addr
  def rtmps_backup_ingestion_address(%{cdn: %{ingestionInfo: %{rtmpsBackupIngestionAddress: addr}}}), do: addr
  def rtmps_backup_ingestion_address(%{cdn: %{ingestion_info: %{rtmps_backup_ingestion_address: addr}}}), do: addr
  def rtmps_backup_ingestion_address(%{"ingestionInfo" => %{"rtmpsBackupIngestionAddress" => addr}}), do: addr
  def rtmps_backup_ingestion_address(%{ingestionInfo: %{rtmpsBackupIngestionAddress: addr}}), do: addr
  def rtmps_backup_ingestion_address(%{ingestion_info: %{rtmps_backup_ingestion_address: addr}}), do: addr
  def rtmps_backup_ingestion_address(_), do: nil

  @doc """
  Constructs the full RTMP/RTMPS stream URL by combining the ingestion address and stream key.

  ## Options
  - `:protocol`: `:rtmp` (default) or `:rtmps`
  - `:backup`: boolean (default `false`)
  """
  @spec stream_url(map() | nil, keyword() | map()) :: String.t() | nil
  def stream_url(stream, opts \\ [])
  def stream_url(nil, _opts), do: nil

  def stream_url(stream, opts) do
    opts_map = to_map(opts)
    protocol = Map.get(opts_map, :protocol, :rtmp)
    backup = Map.get(opts_map, :backup, false)

    key = stream_key(stream)

    addr =
      case {protocol, backup} do
        {:rtmps, true} -> rtmps_backup_ingestion_address(stream)
        {:rtmps, false} -> rtmps_ingestion_address(stream) || ingestion_address(stream)
        {_rtmp, true} -> backup_ingestion_address(stream)
        {_rtmp, false} -> ingestion_address(stream)
      end

    if is_binary(addr) and is_binary(key) and addr != "" and key != "" do
      base = String.trim_trailing(addr, "/")

      if String.contains?(base, "?") do
        [path, query] = String.split(base, "?", parts: 2)
        "#{path}/#{key}?#{query}"
      else
        "#{base}/#{key}"
      end
    else
      nil
    end
  end

  @doc """
  Extracts the streamStatus from a live stream (`"active"`, `"created"`, `"error"`, `"inactive"`, `"ready"`).
  """
  @spec stream_status(map() | nil) :: String.t() | nil
  def stream_status(nil), do: nil
  def stream_status(%{"status" => %{"streamStatus" => status}}), do: status
  def stream_status(%{status: %{streamStatus: status}}), do: status
  def stream_status(%{status: %{stream_status: status}}), do: status
  def stream_status(_), do: nil

  @doc """
  Extracts the stream health status (`"good"`, `"ok"`, `"bad"`, `"noData"`).
  """
  @spec health_status(map() | nil) :: String.t() | nil
  def health_status(nil), do: nil
  def health_status(%{"status" => %{"healthStatus" => %{"status" => status}}}), do: status
  def health_status(%{status: %{healthStatus: %{status: status}}}), do: status
  def health_status(%{status: %{health_status: %{status: status}}}), do: status
  def health_status(_), do: nil

  @doc """
  Returns true if the stream is currently actively transmitting data.
  """
  @spec active?(map() | nil) :: boolean()
  def active?(stream), do: stream_status(stream) == "active"

  @doc """
  Returns true if the stream is ready to receive data or actively receiving data.
  """
  @spec ready?(map() | nil) :: boolean()
  def ready?(stream), do: stream_status(stream) in ["ready", "active"]

  @doc """
  Returns true if the stream status is `"error"` or health status is `"bad"`.
  """
  @spec error?(map() | nil) :: boolean()
  def error?(stream), do: stream_status(stream) == "error" or health_status(stream) == "bad"

  # --- Private Builders & Normalization Helpers ---

  defp build_create_body(params) do
    snippet = build_snippet(params)
    cdn = build_cdn(params)
    content_details = build_content_details(params)

    %{}
    |> Map.put("snippet", snippet)
    |> Map.put("cdn", cdn)
    |> maybe_put_map("contentDetails", content_details)
  end

  defp build_update_body(params) do
    id = params[:id] || params["id"]

    %{"id" => id}
    |> maybe_put_map("snippet", build_snippet_for_update(params))
    |> maybe_put_map("cdn", build_cdn_for_update(params))
    |> maybe_put_map("contentDetails", build_content_details(params))
  end

  defp build_snippet(params) do
    raw_snippet = params[:snippet] || params["snippet"] || %{}
    snippet_map = to_map(raw_snippet)

    title =
      params[:title] ||
        params["title"] ||
        snippet_map[:title] ||
        snippet_map["title"] ||
        "Live Stream #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    description =
      params[:description] ||
        params["description"] ||
        snippet_map[:description] ||
        snippet_map["description"] ||
        ""

    is_default =
      params[:is_default_stream] ||
        params[:isDefaultStream] ||
        params["isDefaultStream"] ||
        snippet_map[:is_default_stream] ||
        snippet_map[:isDefaultStream] ||
        snippet_map["isDefaultStream"] ||
        false

    %{
      "title" => to_string(title),
      "description" => to_string(description),
      "isDefaultStream" => is_default
    }
  end

  defp build_snippet_for_update(params) do
    raw_snippet = params[:snippet] || params["snippet"]

    if raw_snippet || params[:title] || params[:description] do
      snippet_map = if raw_snippet, do: to_map(raw_snippet), else: %{}

      %{}
      |> maybe_put("title", params[:title] || snippet_map[:title] || snippet_map["title"])
      |> maybe_put(
        "description",
        params[:description] || snippet_map[:description] || snippet_map["description"]
      )
    else
      nil
    end
  end

  defp build_cdn(params) do
    raw_cdn = params[:cdn] || params["cdn"] || %{}
    cdn_map = to_map(raw_cdn)

    ingestion_type =
      params[:ingestion_type] ||
        params[:ingestionType] ||
        params["ingestionType"] ||
        cdn_map[:ingestion_type] ||
        cdn_map[:ingestionType] ||
        cdn_map["ingestionType"] ||
        "rtmp"

    resolution =
      params[:resolution] ||
        params["resolution"] ||
        cdn_map[:resolution] ||
        cdn_map["resolution"] ||
        "variable"

    frame_rate =
      params[:frame_rate] ||
        params[:frameRate] ||
        params["frameRate"] ||
        cdn_map[:frame_rate] ||
        cdn_map[:frameRate] ||
        cdn_map["frameRate"] ||
        "variable"

    %{
      "ingestionType" => to_string(ingestion_type),
      "resolution" => to_string(resolution),
      "frameRate" => to_string(frame_rate)
    }
  end

  defp build_cdn_for_update(params) do
    raw_cdn = params[:cdn] || params["cdn"]

    if raw_cdn || params[:resolution] || params[:frame_rate] || params[:frameRate] ||
         params[:ingestion_type] || params[:ingestionType] do
      cdn_map = if raw_cdn, do: to_map(raw_cdn), else: %{}

      %{}
      |> maybe_put(
        "ingestionType",
        params[:ingestion_type] || params[:ingestionType] || cdn_map[:ingestion_type] ||
          cdn_map[:ingestionType] || cdn_map["ingestionType"]
      )
      |> maybe_put("resolution", params[:resolution] || cdn_map[:resolution] || cdn_map["resolution"])
      |> maybe_put(
        "frameRate",
        params[:frame_rate] || params[:frameRate] || cdn_map[:frame_rate] ||
          cdn_map[:frameRate] || cdn_map["frameRate"]
      )
    else
      nil
    end
  end

  defp build_content_details(params) do
    raw_cd = params[:content_details] || params[:contentDetails] || params["contentDetails"]

    if raw_cd || Map.has_key?(params, :is_reusable) || Map.has_key?(params, :isReusable) do
      cd_map = if raw_cd, do: to_map(raw_cd), else: %{}

      is_reusable =
        cond do
          Map.has_key?(params, :is_reusable) -> params[:is_reusable]
          Map.has_key?(params, :isReusable) -> params[:isReusable]
          Map.has_key?(cd_map, :is_reusable) -> cd_map[:is_reusable]
          Map.has_key?(cd_map, :isReusable) -> cd_map[:isReusable]
          Map.has_key?(cd_map, "isReusable") -> cd_map["isReusable"]
          true -> true
        end

      %{"isReusable" => is_reusable}
    else
      %{"isReusable" => true}
    end
  end

  defp build_list_query_params(params, part) do
    id_param = format_id_param(params[:id] || params["id"])

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
    |> maybe_put_query(:maxResults, params[:max_results] || params[:maxResults] || params["maxResults"])
    |> maybe_put_query(:pageToken, params[:page_token] || params[:pageToken] || params["pageToken"])
    |> maybe_put_query(
      :onBehalfOfContentOwner,
      params[:onBehalfOfContentOwner] || params[:on_behalf_of_content_owner]
    )
    |> maybe_put_query(
      :onBehalfOfContentOwnerChannel,
      params[:onBehalfOfContentOwnerChannel] || params[:on_behalf_of_content_owner_channel]
    )
  end

  defp format_id_param(nil), do: nil
  defp format_id_param(ids) when is_list(ids), do: Enum.map_join(ids, ",", &to_string/1)
  defp format_id_param(id) when is_binary(id), do: id
  defp format_id_param(_), do: nil

  defp resolve_part(params, opts, default) do
    case params[:part] || params["part"] || opts[:part] || opts["part"] do
      nil -> default
      parts when is_list(parts) -> Enum.map_join(parts, ",", &to_string/1)
      part when is_binary(part) -> part
      _ -> default
    end
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
