defmodule Lux.Integrations.YouTube.LiveChat do
  @moduledoc """
  Manages YouTube Live Chat messages (`liveChatMessages` resource) via the YouTube Data API v3.

  Provides functionality to:
  - List live chat messages with pagination, internationalization, and profile image options (`list_messages/2`)
  - Normalize incoming raw message items into structured maps (`normalize_message/1`)
  - Insert new chat messages (`insert_message/3`)
  - Retrieve the active live chat ID for a broadcast (`get_live_chat_id/2`, `get_live_chat_id_for_broadcast/2`)
  - Start continuous polling processes via `Lux.Integrations.YouTube.LiveChat.Poller` (`start_poller/1`)
  - Helper functions for extracting message text, author details, badges, and super chat metadata

  All requests are executed through `Lux.Integrations.YouTube.Client`, providing automatic
  Bearer token authentication, token refresh on 401, quota/rate-limit parsing, and
  offline testing support with `Req.Test`.
  """

  alias Lux.Integrations.YouTube.Client
  alias Lux.Integrations.YouTube.LiveBroadcasts

  @default_parts "snippet,authorDetails"
  @default_insert_part "snippet"

  # --- Typespecs ---

  @type live_chat_id :: String.t()
  @type broadcast_id :: String.t()
  @type message_id :: String.t()

  @type super_chat_details :: %{
          optional(:amount_micros) => non_neg_integer(),
          optional(:currency) => String.t(),
          optional(:amount_display_string) => String.t(),
          optional(:user_comment) => String.t()
        }

  @type normalized_message :: %{
          id: message_id(),
          live_chat_id: live_chat_id(),
          author_channel_id: String.t() | nil,
          author_display_name: String.t() | nil,
          author_profile_image_url: String.t() | nil,
          is_verified: boolean(),
          is_chat_owner: boolean(),
          is_chat_sponsor: boolean(),
          is_chat_moderator: boolean(),
          published_at: String.t() | nil,
          type: String.t(),
          display_message: String.t() | nil,
          message_text: String.t() | nil,
          super_chat_details: super_chat_details() | nil,
          raw: map()
        }

  @type list_messages_response :: %{
          messages: [normalized_message()],
          items: [map()],
          next_page_token: String.t() | nil,
          polling_interval_ms: non_neg_integer(),
          page_info: map() | nil,
          offline_at: String.t() | nil,
          raw: map()
        }

  @type client_opts :: Client.request_opts() | keyword() | map()

  @type list_messages_opts ::
          %{
            optional(:part) => String.t() | [String.t() | atom()],
            optional(:page_token) => String.t(),
            optional(:pageToken) => String.t(),
            optional(:max_results) => pos_integer(),
            optional(:maxResults) => pos_integer(),
            optional(:hl) => String.t(),
            optional(:profile_image_size) => pos_integer(),
            optional(:profileImageSize) => pos_integer(),
            optional(:token) => String.t(),
            optional(:plug) => term()
          }
          | Keyword.t()

  # --- Public API ---

  @doc """
  Returns the default part parameter for listing live chat messages.
  """
  @spec default_parts() :: String.t()
  def default_parts, do: @default_parts

  @doc """
  Lists messages from a YouTube Live Chat stream.

  ## Parameters
  - `live_chat_id`: Unique live chat ID string (from broadcast's `snippet.liveChatId`).
  - `opts`: Query and client options (map or keyword list):
    - `:part`: Resource parts (default: `"snippet,authorDetails"`).
    - `:page_token` / `:pageToken`: Pagination token from previous request.
    - `:max_results` / `:maxResults`: Maximum messages to return (1..2000).
    - `:hl`: BCP-47 language tag for localized messages (e.g. `"en"`, `"es"`).
    - `:profile_image_size` / `:profileImageSize`: Image resolution for author avatar (16..720).
    - Client options (`:token`, `:plug`, `:auto_refresh`, etc.).

  ## Returns
  - `{:ok, list_messages_response}` containing normalized `:messages`, `:next_page_token`, `:polling_interval_ms`, etc.
  - `{:error, :missing_live_chat_id}` if `live_chat_id` is empty or invalid.
  - `{:error, reason}` on API or network failure.
  """
  @spec list_messages(live_chat_id(), list_messages_opts()) ::
          {:ok, list_messages_response()} | {:error, term()}
  def list_messages(live_chat_id, opts \\ %{})

  def list_messages(live_chat_id, opts) when is_binary(live_chat_id) and live_chat_id != "" do
    opts_map = to_map(opts)
    part = resolve_part(opts_map, @default_parts)
    query_params = build_list_query_params(live_chat_id, opts_map, part)

    client_opts =
      opts_map
      |> Map.put(:params, query_params)

    case Client.get("/liveChat/messages", client_opts) do
      {:ok, %{} = body} ->
        {:ok, parse_list_response(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_messages(_live_chat_id, _opts), do: {:error, :missing_live_chat_id}

  @doc """
  Inserts (posts) a new text message into a YouTube Live Chat stream.

  ## Parameters
  - `live_chat_id`: YouTube Live Chat ID string.
  - `message_text`: The text content of the message to send.
  - `opts`: Additional options or client overrides (supports custom snippet details, `:token`, `:plug`).

  ## Returns
  - `{:ok, message_map}` with the created message item.
  - `{:error, :missing_live_chat_id}` if `live_chat_id` is blank.
  - `{:error, :empty_message_text}` if `message_text` is blank.
  - `{:error, reason}` on API or network failure.
  """
  @spec insert_message(live_chat_id(), String.t(), client_opts()) ::
          {:ok, map()} | {:error, term()}
  def insert_message(live_chat_id, message_text, opts \\ %{})

  def insert_message(live_chat_id, _message_text, _opts)
      when not is_binary(live_chat_id) or live_chat_id == "" do
    {:error, :missing_live_chat_id}
  end

  def insert_message(_live_chat_id, message_text, _opts)
      when not is_binary(message_text) or message_text == "" do
    {:error, :empty_message_text}
  end

  def insert_message(live_chat_id, message_text, opts) do
    opts_map = to_map(opts)
    part = resolve_part(opts_map, @default_insert_part)
    body = build_insert_body(live_chat_id, message_text, opts_map)

    client_opts =
      opts_map
      |> Map.put(:params, [part: part])
      |> Map.put(:json, body)

    Client.post("/liveChat/messages", client_opts)
  end

  @doc """
  Retrieves the `liveChatId` associated with a YouTube Live Broadcast.

  Accepts either a broadcast ID string or a broadcast map.

  ## Parameters
  - `broadcast_or_id`: YouTube broadcast ID string or broadcast struct/map.
  - `opts`: Client options forwarded to `LiveBroadcasts.get_broadcast/2`.

  ## Returns
  - `{:ok, live_chat_id}` if the broadcast has an active live chat ID.
  - `{:error, :no_live_chat_id}` if the broadcast exists but chat is disabled or unavailable.
  - `{:error, :not_found}` if no broadcast matches the given ID.
  - `{:error, reason}` on API or network failure.
  """
  @spec get_live_chat_id(broadcast_id() | map(), client_opts()) ::
          {:ok, live_chat_id()} | {:error, term()}
  def get_live_chat_id(broadcast_or_id, opts \\ %{})

  def get_live_chat_id(broadcast_map, opts) when is_map(broadcast_map) do
    case LiveBroadcasts.live_chat_id(broadcast_map) do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        id = broadcast_map["id"] || broadcast_map[:id]

        if is_binary(id) and id != "" do
          get_live_chat_id(id, opts)
        else
          {:error, :missing_broadcast_id}
        end
    end
  end

  def get_live_chat_id(broadcast_id, opts) when is_binary(broadcast_id) and broadcast_id != "" do
    opts_map = to_map(opts)
    # Ensure snippet part is requested so liveChatId is present
    part_opts = Map.put(opts_map, :part, "snippet")

    case LiveBroadcasts.get_broadcast(broadcast_id, part_opts) do
      {:ok, broadcast} ->
        case LiveBroadcasts.live_chat_id(broadcast) do
          id when is_binary(id) and id != "" ->
            {:ok, id}

          _ ->
            {:error, :no_live_chat_id}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_live_chat_id(_broadcast_id, _opts), do: {:error, :missing_broadcast_id}

  @doc """
  Alias for `get_live_chat_id/2`.
  """
  @spec get_live_chat_id_for_broadcast(broadcast_id(), client_opts()) ::
          {:ok, live_chat_id()} | {:error, term()}
  def get_live_chat_id_for_broadcast(broadcast_id, opts \\ %{}),
    do: get_live_chat_id(broadcast_id, opts)

  @doc """
  Starts a continuous Live Chat Poller GenServer.

  Delegates directly to `Lux.Integrations.YouTube.LiveChat.Poller.start_link/1`.

  ## Parameters
  - `opts`: Poller configuration options (must include `:live_chat_id`).

  ## Returns
  - `{:ok, pid}` on successful start.
  - `{:error, reason}` on failure.
  """
  @spec start_poller(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_poller(opts) do
    Lux.Integrations.YouTube.LiveChat.Poller.start_link(opts)
  end

  # --- Normalization & Message Extractors ---

  @doc """
  Normalizes a raw YouTube live chat message item map into a structured map with standardized keys.
  """
  @spec normalize_message(map()) :: normalized_message()
  def normalize_message(%{} = item) do
    snippet = item["snippet"] || item[:snippet] || %{}
    author = item["authorDetails"] || item[:authorDetails] || item[:author_details] || %{}
    text_details = snippet["textMessageDetails"] || snippet[:textMessageDetails] || snippet[:text_message_details] || %{}
    super_chat = snippet["superChatDetails"] || snippet[:superChatDetails] || snippet[:super_chat_details]

    display_msg = snippet["displayMessage"] || snippet[:displayMessage] || snippet[:display_message]

    msg_text =
      text_details["messageText"] ||
        text_details[:messageText] ||
        text_details[:message_text] ||
        display_msg ||
        (super_chat && (super_chat["userComment"] || super_chat[:userComment] || super_chat[:user_comment]))

    %{
      id: item["id"] || item[:id],
      live_chat_id: snippet["liveChatId"] || snippet[:liveChatId] || snippet[:live_chat_id],
      author_channel_id:
        author["channelId"] || author[:channelId] || author[:channel_id] || snippet["authorChannelId"] ||
          snippet[:authorChannelId] || snippet[:author_channel_id],
      author_display_name: author["displayName"] || author[:displayName] || author[:display_name],
      author_profile_image_url:
        author["profileImageUrl"] || author[:profileImageUrl] || author[:profile_image_url],
      is_verified:
        get_bool(author, ["isVerified", :isVerified, :is_verified], false),
      is_chat_owner:
        get_bool(author, ["isChatOwner", :isChatOwner, :is_chat_owner], false),
      is_chat_sponsor:
        get_bool(author, ["isChatSponsor", :isChatSponsor, :is_chat_sponsor], false),
      is_chat_moderator:
        get_bool(author, ["isChatModerator", :isChatModerator, :is_chat_moderator], false),
      published_at: snippet["publishedAt"] || snippet[:publishedAt] || snippet[:published_at],
      type: snippet["type"] || snippet[:type] || "textMessageEvent",
      display_message: display_msg,
      message_text: msg_text,
      super_chat_details: normalize_super_chat(super_chat),
      raw: item
    }
  end

  def normalize_message(_), do: %{}

  @doc """
  Extracts the message text string from a normalized message map or raw item map.
  """
  @spec message_text(map() | nil) :: String.t() | nil
  def message_text(nil), do: nil
  def message_text(%{message_text: text}) when is_binary(text), do: text
  def message_text(%{display_message: text}) when is_binary(text), do: text
  def message_text(%{"snippet" => %{"textMessageDetails" => %{"messageText" => text}}}), do: text
  def message_text(%{"snippet" => %{"displayMessage" => text}}), do: text
  def message_text(%{"snippet" => %{"superChatDetails" => %{"userComment" => comment}}}), do: comment
  def message_text(%{snippet: %{textMessageDetails: %{messageText: text}}}), do: text
  def message_text(%{snippet: %{displayMessage: text}}), do: text
  def message_text(_), do: nil

  @doc """
  Extracts author display name from a message map.
  """
  @spec author_name(map() | nil) :: String.t() | nil
  def author_name(nil), do: nil
  def author_name(%{author_display_name: name}) when is_binary(name), do: name
  def author_name(%{"authorDetails" => %{"displayName" => name}}), do: name
  def author_name(%{authorDetails: %{displayName: name}}), do: name
  def author_name(%{author_details: %{display_name: name}}), do: name
  def author_name(_), do: nil

  @doc """
  Extracts author channel ID from a message map.
  """
  @spec author_channel_id(map() | nil) :: String.t() | nil
  def author_channel_id(nil), do: nil
  def author_channel_id(%{author_channel_id: id}) when is_binary(id), do: id
  def author_channel_id(%{"authorDetails" => %{"channelId" => id}}), do: id
  def author_channel_id(%{authorDetails: %{channelId: id}}), do: id
  def author_channel_id(%{"snippet" => %{"authorChannelId" => id}}), do: id
  def author_channel_id(%{snippet: %{authorChannelId: id}}), do: id
  def author_channel_id(_), do: nil

  @doc """
  Extracts published timestamp from a message map.
  """
  @spec published_at(map() | nil) :: String.t() | nil
  def published_at(nil), do: nil
  def published_at(%{published_at: ts}) when is_binary(ts), do: ts
  def published_at(%{"snippet" => %{"publishedAt" => ts}}), do: ts
  def published_at(%{snippet: %{publishedAt: ts}}), do: ts
  def published_at(_), do: nil

  @doc """
  Returns true if the author is the chat / channel owner.
  """
  @spec chat_owner?(map() | nil) :: boolean()
  def chat_owner?(nil), do: false
  def chat_owner?(%{is_chat_owner: bool}), do: bool == true
  def chat_owner?(%{"authorDetails" => %{"isChatOwner" => bool}}), do: bool == true
  def chat_owner?(%{authorDetails: %{isChatOwner: bool}}), do: bool == true
  def chat_owner?(%{author_details: %{is_chat_owner: bool}}), do: bool == true
  def chat_owner?(_), do: false

  @doc """
  Returns true if the author is a chat moderator.
  """
  @spec chat_moderator?(map() | nil) :: boolean()
  def chat_moderator?(nil), do: false
  def chat_moderator?(%{is_chat_moderator: bool}), do: bool == true
  def chat_moderator?(%{"authorDetails" => %{"isChatModerator" => bool}}), do: bool == true
  def chat_moderator?(%{authorDetails: %{isChatModerator: bool}}), do: bool == true
  def chat_moderator?(%{author_details: %{is_chat_moderator: bool}}), do: bool == true
  def chat_moderator?(_), do: false

  @doc """
  Returns true if the author is a channel sponsor / member.
  """
  @spec chat_sponsor?(map() | nil) :: boolean()
  def chat_sponsor?(nil), do: false
  def chat_sponsor?(%{is_chat_sponsor: bool}), do: bool == true
  def chat_sponsor?(%{"authorDetails" => %{"isChatSponsor" => bool}}), do: bool == true
  def chat_sponsor?(%{authorDetails: %{isChatSponsor: bool}}), do: bool == true
  def chat_sponsor?(%{author_details: %{is_chat_sponsor: bool}}), do: bool == true
  def chat_sponsor?(_), do: false

  @doc """
  Returns true if the message is a Super Chat event.
  """
  @spec super_chat?(map() | nil) :: boolean()
  def super_chat?(nil), do: false
  def super_chat?(%{type: "superChatEvent"}), do: true
  def super_chat?(%{super_chat_details: details}) when is_map(details) and map_size(details) > 0, do: true
  def super_chat?(%{"snippet" => %{"type" => "superChatEvent"}}), do: true
  def super_chat?(%{"snippet" => %{"superChatDetails" => details}}) when is_map(details), do: true
  def super_chat?(_), do: false

  @doc """
  Extracts the Super Chat formatted amount string (e.g. `"$5.00"`).
  """
  @spec super_chat_amount(map() | nil) :: String.t() | nil
  def super_chat_amount(nil), do: nil
  def super_chat_amount(%{super_chat_details: %{amount_display_string: str}}), do: str
  def super_chat_amount(%{"snippet" => %{"superChatDetails" => %{"amountDisplayString" => str}}}), do: str
  def super_chat_amount(%{snippet: %{superChatDetails: %{amountDisplayString: str}}}), do: str
  def super_chat_amount(_), do: nil

  # --- Private Builders & Response Parsers ---

  defp parse_list_response(%{} = body) do
    raw_items = body["items"] || body[:items] || []
    normalized_items = Enum.map(raw_items, &normalize_message/1)

    next_page_token = body["nextPageToken"] || body[:nextPageToken] || body[:next_page_token]
    polling_interval = body["pollingIntervalMillis"] || body[:pollingIntervalMillis] || body[:polling_interval_ms] || 5000
    offline_at = body["offlineAt"] || body[:offlineAt] || body[:offline_at]
    page_info = body["pageInfo"] || body[:pageInfo] || body[:page_info]

    %{
      messages: normalized_items,
      items: raw_items,
      next_page_token: next_page_token,
      polling_interval_ms: polling_interval,
      page_info: page_info,
      offline_at: offline_at,
      raw: body
    }
  end

  defp build_list_query_params(live_chat_id, opts_map, part) do
    [liveChatId: live_chat_id, part: part]
    |> maybe_put_query(:pageToken, opts_map[:page_token] || opts_map[:pageToken] || opts_map["pageToken"])
    |> maybe_put_query(:maxResults, opts_map[:max_results] || opts_map[:maxResults] || opts_map["maxResults"])
    |> maybe_put_query(:hl, opts_map[:hl] || opts_map["hl"])
    |> maybe_put_query(
      :profileImageSize,
      opts_map[:profile_image_size] || opts_map[:profileImageSize] || opts_map["profileImageSize"]
    )
  end

  defp build_insert_body(live_chat_id, message_text, opts_map) do
    raw_snippet = opts_map[:snippet] || opts_map["snippet"] || %{}
    snippet_map = to_map(raw_snippet)

    type = snippet_map[:type] || snippet_map["type"] || "textMessageEvent"

    snippet =
      %{
        "liveChatId" => live_chat_id,
        "type" => type,
        "textMessageDetails" => %{
          "messageText" => message_text
        }
      }

    %{"snippet" => snippet}
  end

  defp normalize_super_chat(%{} = sc) do
    amount_micros =
      case sc["amountMicros"] || sc[:amountMicros] || sc[:amount_micros] do
        int when is_integer(int) -> int
        str when is_binary(str) ->
          case Integer.parse(str) do
            {num, ""} -> num
            _ -> nil
          end
        _ -> nil
      end

    %{
      amount_micros: amount_micros,
      currency: sc["currency"] || sc[:currency],
      amount_display_string: sc["amountDisplayString"] || sc[:amountDisplayString] || sc[:amount_display_string],
      user_comment: sc["userComment"] || sc[:userComment] || sc[:user_comment]
    }
  end

  defp normalize_super_chat(_), do: nil

  defp get_bool(map, keys, default) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, val} when is_boolean(val) -> val
        _ -> nil
      end
    end) || default
  end

  defp resolve_part(opts_map, default) do
    case opts_map[:part] || opts_map["part"] do
      nil -> default
      parts when is_list(parts) -> Enum.map_join(parts, ",", &to_string/1)
      part when is_binary(part) and part != "" -> part
      _ -> default
    end
  end

  defp maybe_put_query(list, _key, nil), do: list
  defp maybe_put_query(list, key, value), do: Keyword.put(list, key, value)

  defp to_map(opts) when is_map(opts), do: opts
  defp to_map(opts) when is_list(opts), do: Map.new(opts)
  defp to_map(_), do: %{}
end
