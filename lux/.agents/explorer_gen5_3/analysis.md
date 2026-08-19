# Comprehensive LiveChat Coverage Analysis & Remediation Plan

**Explorer**: Explorer 3 (Milestone 5 Generation 5)  
**Target Module**: `lib/lux/integrations/youtube/live_chat.ex`  
**Test File**: `test/unit/lux/integrations/youtube/live_chat_test.exs`  
**Initial Coverage**: 81.2% (155 relevant SLOC, 126 hits, 29 missed)  
**Target Coverage**: >95% (Projected: 100.0% / 155 hits, 0 missed)

---

## 1. Executive Summary

The victory audit failed the test coverage threshold on `lib/lux/integrations/youtube/live_chat.ex` (81.2% vs >90% requirement). An automated extraction of coverage misses from `cover/excoveralls.html` isolated exactly **29 unexecuted lines**.

The gaps fall into 4 major categories:
1. **`get_live_chat_id/2` and `get_live_chat_id_for_broadcast/2` map branches & defaults**:
   - `get_live_chat_id` was only ever tested with binary IDs; passing a broadcast map (with string or atom keys) was completely untested.
   - Calling `get_live_chat_id_for_broadcast` with default options (1 arity) was untested.
   - API error propagation when fetching a broadcast by ID was untested.
2. **`message_text/1`, `author_name/1`, `author_channel_id/1`, `published_at/1` pattern matches**:
   - Fallback clauses for atom-keyed maps (`%{snippet: %{...}}`), camelCase vs snake_case atom maps, and snippet-level author channel IDs were omitted.
3. **Badge predicates (`chat_owner?`, `chat_moderator?`, `chat_sponsor?`) & Super Chat accessors**:
   - Atom-keyed map branches (`%{authorDetails: ...}` and `%{author_details: ...}`) and boolean `false` checks were missed.
   - `super_chat?/1` with non-empty map and `super_chat_amount/1` with atom-keyed snippet were unexecuted.
4. **`normalize_super_chat/1`, `resolve_part/2`, and `to_map/1` error/fallback branches**:
   - String `amountMicros` non-integer parsing failure (`_ -> nil`).
   - `resolve_part` fallback (`_ -> default`) for invalid/empty part options.
   - `to_map` fallback (`defp to_map(_), do: %{}`) for non-map/non-list options.
   - `normalize_message` fallback for non-map arguments.

---

## 2. Line-by-Line Inventory of 29 Missed Lines

From `cover/excoveralls.html`:

| Line # | Source Code Snippet | Root Cause of Coverage Miss |
|---|---|---|
| **189** | `def get_live_chat_id(broadcast_or_id, opts \\ %{})` | Calling `get_live_chat_id(map)` with 1 argument (default `opts`) |
| **192** | `case LiveBroadcasts.live_chat_id(broadcast_map) do` | Passing a map into `get_live_chat_id/2` |
| **193** | `id when is_binary(id) and id != "" ->` | Direct extraction of `liveChatId` from broadcast map |
| **197** | `id = broadcast_map["id"] || broadcast_map[:id]` | Fallback to broadcast ID in map when `liveChatId` missing |
| **199** | `if is_binary(id) and id != "" do` | Checking if extracted ID is valid binary |
| **200** | `get_live_chat_id(id, opts)` | Delegating map's ID to `get_live_chat_id/2` for API fetch |
| **234** | `def get_live_chat_id_for_broadcast(broadcast_id, opts \\ %{})` | Calling `get_live_chat_id_for_broadcast` with 1 argument |
| **309** | `def message_text(%{display_message: text}) when is_binary(text), do: text` | Calling `message_text` with map having `:display_message` but no `:message_text` |
| **312** | `def message_text(%{"snippet" => %{"superChatDetails" => %{"userComment" => comment}}}), do: comment` | Extracting message text from raw Super Chat userComment |
| **313** | `def message_text(%{snippet: %{textMessageDetails: %{messageText: text}}}), do: text` | Extracting message text from atom camelCase snippet |
| **314** | `def message_text(%{snippet: %{displayMessage: text}}), do: text` | Extracting message text from atom snippet displayMessage |
| **324** | `def author_name(%{authorDetails: %{displayName: name}}), do: name` | Extracting author name from atom camelCase `authorDetails` |
| **325** | `def author_name(%{author_details: %{display_name: name}}), do: name` | Extracting author name from atom snake_case `author_details` |
| **335** | `def author_channel_id(%{authorDetails: %{channelId: id}}), do: id` | Extracting author channel ID from atom camelCase `authorDetails` |
| **336** | `def author_channel_id(%{"snippet" => %{"authorChannelId" => id}}), do: id` | Extracting channel ID from raw string snippet `authorChannelId` |
| **337** | `def author_channel_id(%{snippet: %{authorChannelId: id}}), do: id` | Extracting channel ID from atom snippet `authorChannelId` |
| **347** | `def published_at(%{snippet: %{publishedAt: ts}}), do: ts` | Extracting timestamp from atom snippet `publishedAt` |
| **357** | `def chat_owner?(%{authorDetails: %{isChatOwner: bool}}), do: bool == true` | Predicate for atom camelCase `authorDetails.isChatOwner` |
| **358** | `def chat_owner?(%{author_details: %{is_chat_owner: bool}}), do: bool == true` | Predicate for atom snake_case `author_details.is_chat_owner` |
| **368** | `def chat_moderator?(%{authorDetails: %{isChatModerator: bool}}), do: bool == true` | Predicate for atom camelCase `authorDetails.isChatModerator` |
| **369** | `def chat_moderator?(%{author_details: %{is_chat_moderator: bool}}), do: bool == true` | Predicate for atom snake_case `author_details.is_chat_moderator` |
| **379** | `def chat_sponsor?(%{authorDetails: %{isChatSponsor: bool}}), do: bool == true` | Predicate for atom camelCase `authorDetails.isChatSponsor` |
| **380** | `def chat_sponsor?(%{author_details: %{is_chat_sponsor: bool}}), do: bool == true` | Predicate for atom snake_case `author_details.is_chat_sponsor` |
| **389** | `def super_chat?(%{super_chat_details: details}) when is_map(details) and map_size(details) > 0, do: true` | Predicate for normalized message with `super_chat_details` map |
| **391** | `def super_chat?(%{"snippet" => %{"superChatDetails" => details}}) when is_map(details), do: true` | Predicate for raw string snippet with `superChatDetails` map |
| **401** | `def super_chat_amount(%{snippet: %{superChatDetails: %{amountDisplayString: str}}}), do: str` | Super chat amount extraction from atom snippet `superChatDetails` |
| **464** | `_ -> nil` in `Integer.parse(str)` within `normalize_super_chat/1` | Handling unparseable string `amountMicros` (e.g. `"invalid"`) |
| **491** | `_ -> default` in `resolve_part/2` | Fallback when `:part` option is empty string `""` or invalid type |
| **500** | `defp to_map(_), do: %{}` | Fallback when `opts` is not a map or keyword list (e.g. atom/int) |

---

## 3. Recommended Unit Tests for `live_chat_test.exs`

The following test blocks should be appended or merged into `test/unit/lux/integrations/youtube/live_chat_test.exs`.

### 3.1 Gaps in `list_messages/2`
```elixir
    test "fetches messages with default opts (1 argument)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "liveChatId=chat_default_opts"
        assert conn.query_string =~ "part=snippet%2CauthorDetails"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response_fixture()))
      end)

      assert {:ok, resp} = LiveChat.list_messages("chat_default_opts")
      assert is_list(resp.messages)
    end

    test "handles string keys in opts map" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "pageToken=tok_str_1"
        assert conn.query_string =~ "maxResults=100"
        assert conn.query_string =~ "hl=fr"
        assert conn.query_string =~ "profileImageSize=128"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response_fixture()))
      end)

      opts = %{
        "pageToken" => "tok_str_1",
        "maxResults" => 100,
        "hl" => "fr",
        "profileImageSize" => 128
      }

      assert {:ok, _} = LiveChat.list_messages("chat_str_opts", opts)
    end

    test "falls back to default parts when part option is empty or invalid" do
      Req.Test.expect(YouTubeClientMock, 2, fn conn ->
        assert conn.query_string =~ "part=snippet%2CauthorDetails"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response_fixture()))
      end)

      assert {:ok, _} = LiveChat.list_messages("chat_1", part: "")
      assert {:ok, _} = LiveChat.list_messages("chat_2", part: 12345)
    end

    test "handles non-map and non-list opts gracefully" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "liveChatId=chat_non_map"
        assert conn.query_string =~ "part=snippet%2CauthorDetails"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response_fixture()))
      end)

      assert {:ok, _} = LiveChat.list_messages("chat_non_map", :invalid_opts)
    end

    test "returns {:error, :missing_live_chat_id} when live_chat_id is non-binary" do
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(12345)
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(:an_atom)
    end

    test "parses response when body uses atom keys and handles missing pollingIntervalMillis" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [],
            "nextPageToken" => "tok_atom",
            "offlineAt" => "2026-08-18T10:00:00Z",
            "pageInfo" => %{"totalResults" => 0}
          })
        )
      end)

      assert {:ok, resp} = LiveChat.list_messages("chat_defaults", token: "tok")
      assert resp.polling_interval_ms == 5000
      assert resp.next_page_token == "tok_atom"
      assert resp.offline_at == "2026-08-18T10:00:00Z"
      assert resp.page_info == %{"totalResults" => 0}
    end
```

### 3.2 Gaps in `insert_message/3`
```elixir
    test "inserts message with default opts (2 arguments)" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "part=snippet"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(message_fixture()))
      end)

      assert {:ok, _} = LiveChat.insert_message("chat_default", "Hello world!")
    end

    test "supports custom snippet options and custom part parameter" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.query_string =~ "part=snippet%2Cid"
        assert decoded["snippet"]["type"] == "fanFundingEvent"
        assert decoded["snippet"]["liveChatId"] == "chat_custom"
        assert decoded["snippet"]["textMessageDetails"]["messageText"] == "Custom event payload"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(message_fixture()))
      end)

      assert {:ok, _} =
               LiveChat.insert_message("chat_custom", "Custom event payload",
                 part: "snippet,id",
                 snippet: %{type: "fanFundingEvent"}
               )
    end

    test "supports custom snippet with string keys" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["snippet"]["type"] == "stringKeyType"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(message_fixture()))
      end)

      assert {:ok, _} =
               LiveChat.insert_message("chat_custom_str", "Message",
                 "snippet" => %{"type" => "stringKeyType"}
               )
    end

    test "validates non-binary live_chat_id and message_text" do
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message(12345, "Hello")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message(:an_atom, "Hello")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", 12345)
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", :an_atom)
    end
```

### 3.3 Gaps in `get_live_chat_id/2` and `get_live_chat_id_for_broadcast/2`
```elixir
    test "extracts liveChatId directly from broadcast map with string keys without network call" do
      bcast = %{
        "id" => "bcast_map_1",
        "snippet" => %{
          "title" => "Direct Broadcast",
          "liveChatId" => "chat_direct_string_123"
        }
      }

      assert {:ok, "chat_direct_string_123"} = LiveChat.get_live_chat_id(bcast)
    end

    test "extracts liveChatId directly from broadcast map with atom keys without network call" do
      bcast_camel = %{
        id: "bcast_map_2",
        snippet: %{
          title: "Camel Broadcast",
          liveChatId: "chat_direct_camel_456"
        }
      }

      bcast_snake = %{
        id: "bcast_map_3",
        snippet: %{
          title: "Snake Broadcast",
          live_chat_id: "chat_direct_snake_789"
        }
      }

      assert {:ok, "chat_direct_camel_456"} = LiveChat.get_live_chat_id(bcast_camel)
      assert {:ok, "chat_direct_snake_789"} = LiveChat.get_live_chat_id(bcast_snake)
    end

    test "fetches broadcast from API when map lacks liveChatId but contains string id" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_fetch_str"
        assert conn.query_string =~ "part=snippet"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "bcast_fetch_str",
                "snippet" => %{"liveChatId" => "chat_fetched_from_api_1"}
              }
            ]
          })
        )
      end)

      bcast_map = %{"id" => "bcast_fetch_str", "snippet" => %{"title" => "No chat in map"}}
      assert {:ok, "chat_fetched_from_api_1"} = LiveChat.get_live_chat_id(bcast_map, token: "tok")
    end

    test "fetches broadcast from API when map lacks liveChatId but contains atom id" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_fetch_atom"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "bcast_fetch_atom",
                "snippet" => %{"liveChatId" => "chat_fetched_from_api_2"}
              }
            ]
          })
        )
      end)

      bcast_map = %{id: "bcast_fetch_atom", title: "Only atom ID"}
      assert {:ok, "chat_fetched_from_api_2"} = LiveChat.get_live_chat_id(bcast_map, token: "tok")
    end

    test "returns {:error, :missing_broadcast_id} when map has no liveChatId and no ID" do
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(%{})
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(%{"snippet" => %{"title" => "No ID"}})
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(%{snippet: %{title: "No ID"}})
    end

    test "propagates API errors when fetching broadcast by ID" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"code" => 500, "message" => "Internal Server Error"}}))
      end)

      assert {:error, {500, "Internal Server Error"}} = LiveChat.get_live_chat_id("bcast_500", token: "tok")
    end

    test "get_live_chat_id_for_broadcast supports default opts and map arguments" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [%{"id" => "bcast_alias", "snippet" => %{"liveChatId" => "chat_alias_123"}}]
          })
        )
      end)

      assert {:ok, "chat_alias_123"} = LiveChat.get_live_chat_id_for_broadcast("bcast_alias")

      map_bcast = %{"snippet" => %{"liveChatId" => "chat_alias_map"}}
      assert {:ok, "chat_alias_map"} = LiveChat.get_live_chat_id_for_broadcast(map_bcast)
    end

    test "returns {:error, :missing_broadcast_id} for invalid broadcast argument types" do
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(12345)
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(:not_a_bcast)
    end
```

### 3.4 Gaps in Normalization and Helpers
```elixir
    test "normalize_message/1 returns %{} for non-map inputs" do
      assert LiveChat.normalize_message(nil) == %{}
      assert LiveChat.normalize_message("invalid_string") == %{}
      assert LiveChat.normalize_message(12345) == %{}
      assert LiveChat.normalize_message([]) == %{}
    end

    test "normalize_message/1 normalizes atom-keyed maps" do
      atom_camel = %{
        id: "msg_atom_1",
        snippet: %{
          liveChatId: "chat_atom_1",
          authorChannelId: "UC_atom_1",
          publishedAt: "2026-08-18T10:00:00Z",
          type: "textMessageEvent",
          displayMessage: "Atom display msg",
          textMessageDetails: %{messageText: "Atom msg text"}
        },
        authorDetails: %{
          channelId: "UC_atom_1",
          displayName: "AtomUser",
          profileImageUrl: "https://avatar.png",
          isVerified: true,
          isChatOwner: true,
          isChatSponsor: true,
          isChatModerator: true
        }
      }

      norm = LiveChat.normalize_message(atom_camel)
      assert norm.id == "msg_atom_1"
      assert norm.live_chat_id == "chat_atom_1"
      assert norm.author_channel_id == "UC_atom_1"
      assert norm.author_display_name == "AtomUser"
      assert norm.is_verified == true
      assert norm.is_chat_owner == true
      assert norm.is_chat_sponsor == true
      assert norm.is_chat_moderator == true
      assert norm.message_text == "Atom msg text"
      assert norm.display_message == "Atom display msg"

      atom_snake = %{
        id: "msg_atom_2",
        snippet: %{
          live_chat_id: "chat_atom_2",
          author_channel_id: "UC_atom_2",
          published_at: "2026-08-18T11:00:00Z",
          display_message: "Snake display msg",
          text_message_details: %{message_text: "Snake msg text"}
        },
        author_details: %{
          channel_id: "UC_atom_2",
          display_name: "SnakeUser",
          profile_image_url: "https://avatar2.png",
          is_verified: false,
          is_chat_owner: false,
          is_chat_sponsor: false,
          is_chat_moderator: false
        }
      }

      norm2 = LiveChat.normalize_message(atom_snake)
      assert norm2.id == "msg_atom_2"
      assert norm2.live_chat_id == "chat_atom_2"
      assert norm2.author_channel_id == "UC_atom_2"
      assert norm2.author_display_name == "SnakeUser"
      assert norm2.is_verified == false
      assert norm2.is_chat_owner == false
      assert norm2.is_chat_sponsor == false
      assert norm2.is_chat_moderator == false
    end

    test "normalizes super chat details with string amountMicros, invalid amounts, and nil" do
      msg_str_micros =
        superchat_fixture(%{
          "snippet" => %{
            "type" => "superChatEvent",
            "liveChatId" => "chat_1",
            "displayMessage" => "SuperChat with string micros",
            "superChatDetails" => %{
              "amountMicros" => "15000000",
              "currency" => "USD",
              "amountDisplayString" => "$15.00",
              "userComment" => "String micros comment"
            }
          }
        })

      norm = LiveChat.normalize_message(msg_str_micros)
      assert norm.super_chat_details.amount_micros == 15_000_000
      assert norm.super_chat_details.currency == "USD"
      assert norm.super_chat_details.amount_display_string == "$15.00"
      assert norm.message_text == "String micros comment"

      msg_bad_micros =
        superchat_fixture(%{
          "snippet" => %{
            "type" => "superChatEvent",
            "liveChatId" => "chat_1",
            "displayMessage" => "SuperChat bad micros",
            "superChatDetails" => %{
              "amountMicros" => "invalid_number",
              "currency" => "EUR",
              "amountDisplayString" => "€10.00",
              "userComment" => "Bad micros comment"
            }
          }
        })

      norm_bad = LiveChat.normalize_message(msg_bad_micros)
      assert norm_bad.super_chat_details.amount_micros == nil
      assert norm_bad.super_chat_details.currency == "EUR"
    end

    test "message_text/1 comprehensive branch coverage" do
      assert LiveChat.message_text(%{display_message: "Display only"}) == "Display only"
      assert LiveChat.message_text(%{"snippet" => %{"displayMessage" => "Raw display"}}) == "Raw display"
      assert LiveChat.message_text(%{"snippet" => %{"superChatDetails" => %{"userComment" => "SC comment"}}}) == "SC comment"
      assert LiveChat.message_text(%{snippet: %{textMessageDetails: %{messageText: "Atom text"}}}) == "Atom text"
      assert LiveChat.message_text(%{snippet: %{displayMessage: "Atom display"}}) == "Atom display"
      assert LiveChat.message_text("not_a_map") == nil
      assert LiveChat.message_text(123) == nil
    end

    test "author_name/1 comprehensive branch coverage" do
      assert LiveChat.author_name(%{authorDetails: %{displayName: "CamelName"}}) == "CamelName"
      assert LiveChat.author_name(%{author_details: %{display_name: "SnakeName"}}) == "SnakeName"
      assert LiveChat.author_name(%{}) == nil
      assert LiveChat.author_name("invalid") == nil
    end

    test "author_channel_id/1 comprehensive branch coverage" do
      assert LiveChat.author_channel_id(%{authorDetails: %{channelId: "UC_camel_id"}}) == "UC_camel_id"
      assert LiveChat.author_channel_id(%{"snippet" => %{"authorChannelId" => "UC_snippet_str_id"}}) == "UC_snippet_str_id"
      assert LiveChat.author_channel_id(%{snippet: %{authorChannelId: "UC_snippet_atom_id"}}) == "UC_snippet_atom_id"
      assert LiveChat.author_channel_id(%{}) == nil
      assert LiveChat.author_channel_id(123) == nil
    end

    test "published_at/1 comprehensive branch coverage" do
      assert LiveChat.published_at(%{snippet: %{publishedAt: "2026-08-18T12:00:00Z"}}) == "2026-08-18T12:00:00Z"
      assert LiveChat.published_at(%{}) == nil
      assert LiveChat.published_at("invalid") == nil
    end

    test "badge predicates comprehensive branch coverage" do
      # chat_owner?
      assert LiveChat.chat_owner?(%{authorDetails: %{isChatOwner: true}}) == true
      assert LiveChat.chat_owner?(%{authorDetails: %{isChatOwner: false}}) == false
      assert LiveChat.chat_owner?(%{author_details: %{is_chat_owner: true}}) == true
      assert LiveChat.chat_owner?(%{author_details: %{is_chat_owner: false}}) == false
      assert LiveChat.chat_owner?(%{}) == false
      assert LiveChat.chat_owner?("invalid") == false

      # chat_moderator?
      assert LiveChat.chat_moderator?(%{authorDetails: %{isChatModerator: true}}) == true
      assert LiveChat.chat_moderator?(%{authorDetails: %{isChatModerator: false}}) == false
      assert LiveChat.chat_moderator?(%{author_details: %{is_chat_moderator: true}}) == true
      assert LiveChat.chat_moderator?(%{author_details: %{is_chat_moderator: false}}) == false
      assert LiveChat.chat_moderator?(%{}) == false
      assert LiveChat.chat_moderator?("invalid") == false

      # chat_sponsor?
      assert LiveChat.chat_sponsor?(%{authorDetails: %{isChatSponsor: true}}) == true
      assert LiveChat.chat_sponsor?(%{authorDetails: %{isChatSponsor: false}}) == false
      assert LiveChat.chat_sponsor?(%{author_details: %{is_chat_sponsor: true}}) == true
      assert LiveChat.chat_sponsor?(%{author_details: %{is_chat_sponsor: false}}) == false
      assert LiveChat.chat_sponsor?(%{}) == false
      assert LiveChat.chat_sponsor?("invalid") == false
    end

    test "super_chat? and super_chat_amount comprehensive branch coverage" do
      # super_chat?
      assert LiveChat.super_chat?(%{super_chat_details: %{amount_micros: 5_000_000}}) == true
      assert LiveChat.super_chat?(%{super_chat_details: %{}}) == false
      assert LiveChat.super_chat?(%{"snippet" => %{"superChatDetails" => %{"amountMicros" => 5_000_000}}}) == true
      assert LiveChat.super_chat?(%{type: "textMessageEvent", super_chat_details: nil}) == false
      assert LiveChat.super_chat?(%{}) == false
      assert LiveChat.super_chat?("invalid") == false

      # super_chat_amount
      assert LiveChat.super_chat_amount(%{snippet: %{superChatDetails: %{amountDisplayString: "$50.00"}}}) == "$50.00"
      assert LiveChat.super_chat_amount(%{}) == nil
      assert LiveChat.super_chat_amount("invalid") == nil
    end
```

---

## 4. Verification Method

To verify these tests:
1. Incorporate the test additions into `test/unit/lux/integrations/youtube/live_chat_test.exs`.
2. Run `mix test test/unit/lux/integrations/youtube/live_chat_test.exs`.
3. Run `MIX_ENV=test mix coveralls.html --include unit` or `mix coveralls.detail --include unit` and verify that:
   - Line hits for `lib/lux/integrations/youtube/live_chat.ex` reach 155/155 (100.0%).
   - Misses drop from 29 to 0.
