defmodule Lux.Integrations.YouTube.LiveChatTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.LiveChat

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  defp message_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "etag" => "\"etag_msg_123\"",
        "id" => "msg_test_001",
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "chat_test_123",
          "authorChannelId" => "UC_author_456",
          "publishedAt" => "2026-08-17T20:15:30.123Z",
          "hasDisplayContent" => true,
          "displayMessage" => "Hello Lux community!",
          "textMessageDetails" => %{
            "messageText" => "Hello Lux community!"
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_author_456",
          "channelUrl" => "http://www.youtube.com/channel/UC_author_456",
          "displayName" => "TestUser",
          "profileImageUrl" => "https://yt3.ggpht.com/avatar.jpg",
          "isVerified" => true,
          "isChatOwner" => false,
          "isChatSponsor" => true,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  defp superchat_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "etag" => "\"etag_sc_789\"",
        "id" => "msg_sc_002",
        "snippet" => %{
          "type" => "superChatEvent",
          "liveChatId" => "chat_test_123",
          "authorChannelId" => "UC_donor_789",
          "publishedAt" => "2026-08-17T20:16:00.000Z",
          "hasDisplayContent" => true,
          "displayMessage" => "Keep up the great work with Lux agents!",
          "superChatDetails" => %{
            "amountMicros" => 10_000_000,
            "currency" => "USD",
            "amountDisplayString" => "$10.00",
            "userComment" => "Keep up the great work with Lux agents!",
            "tier" => 3
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_donor_789",
          "displayName" => "GenerousSupporter",
          "profileImageUrl" => "https://yt3.ggpht.com/donor.jpg",
          "isVerified" => false,
          "isChatOwner" => false,
          "isChatSponsor" => true,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  defp list_response_fixture(items \\ [message_fixture()], overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessageListResponse",
        "etag" => "\"etag_list_resp\"",
        "nextPageToken" => "token_page_2",
        "pollingIntervalMillis" => 6000,
        "offlineAt" => nil,
        "pageInfo" => %{
          "totalResults" => length(items),
          "resultsPerPage" => 200
        },
        "items" => items
      },
      overrides
    )
  end

  describe "list_messages/2" do
    test "fetches messages with default parts and returns normalized response" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "liveChatId=chat_test_123"
        assert conn.query_string =~ "part=snippet%2CauthorDetails"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response_fixture()))
      end)

      assert {:ok, resp} = LiveChat.list_messages("chat_test_123", token: "test_token")
      assert resp.next_page_token == "token_page_2"
      assert resp.polling_interval_ms == 6000
      assert length(resp.messages) == 1

      [first_msg] = resp.messages
      assert first_msg.id == "msg_test_001"
      assert first_msg.live_chat_id == "chat_test_123"
      assert first_msg.author_channel_id == "UC_author_456"
      assert first_msg.author_display_name == "TestUser"
      assert first_msg.author_profile_image_url == "https://yt3.ggpht.com/avatar.jpg"
      assert first_msg.is_verified == true
      assert first_msg.is_chat_owner == false
      assert first_msg.is_chat_sponsor == true
      assert first_msg.is_chat_moderator == false
      assert first_msg.published_at == "2026-08-17T20:15:30.123Z"
      assert first_msg.type == "textMessageEvent"
      assert first_msg.display_message == "Hello Lux community!"
      assert first_msg.message_text == "Hello Lux community!"
      assert first_msg.super_chat_details == nil
      assert is_map(first_msg.raw)
    end

    test "handles pagination, maxResults, language, and profileImageSize options" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "liveChatId=chat_xyz"
        assert conn.query_string =~ "pageToken=cursor_prev"
        assert conn.query_string =~ "maxResults=50"
        assert conn.query_string =~ "hl=es"
        assert conn.query_string =~ "profileImageSize=64"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response_fixture([], %{"nextPageToken" => "cursor_next"}))
        )
      end)

      opts = %{
        page_token: "cursor_prev",
        max_results: 50,
        hl: "es",
        profile_image_size: 64,
        token: "test_token"
      }

      assert {:ok, resp} = LiveChat.list_messages("chat_xyz", opts)
      assert resp.next_page_token == "cursor_next"
      assert resp.messages == []
    end

    test "supports custom part parameter as string and list of atoms" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.query_string =~ "part=snippet%2CauthorDetails%2Cid"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response_fixture()))
      end)

      assert {:ok, _} =
               LiveChat.list_messages("chat_123",
                 part: [:snippet, :authorDetails, :id],
                 token: "test_token"
               )
    end

    test "parses Super Chat event messages correctly" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(list_response_fixture([superchat_fixture()]))
        )
      end)

      assert {:ok, resp} = LiveChat.list_messages("chat_test_123", token: "test_token")
      [sc_msg] = resp.messages

      assert sc_msg.id == "msg_sc_002"
      assert sc_msg.type == "superChatEvent"
      assert sc_msg.author_display_name == "GenerousSupporter"
      assert sc_msg.message_text == "Keep up the great work with Lux agents!"
      assert is_map(sc_msg.super_chat_details)
      assert sc_msg.super_chat_details.amount_micros == 10_000_000
      assert sc_msg.super_chat_details.currency == "USD"
      assert sc_msg.super_chat_details.amount_display_string == "$10.00"
      assert sc_msg.super_chat_details.user_comment == "Keep up the great work with Lux agents!"
    end

    test "parses offlineAt timestamp when stream is finished" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            list_response_fixture([], %{
              "offlineAt" => "2026-08-17T22:00:00.000Z"
            })
          )
        )
      end)

      assert {:ok, resp} = LiveChat.list_messages("chat_ended", token: "test_token")
      assert resp.offline_at == "2026-08-17T22:00:00.000Z"
      assert resp.messages == []
    end

    test "returns {:error, :missing_live_chat_id} when live_chat_id is blank or nil" do
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages("", token: "test_token")
      assert {:error, :missing_live_chat_id} = LiveChat.list_messages(nil, token: "test_token")
    end

    test "propagates API errors such as quotaExceeded, rateLimit, and notFound" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "errors" => [%{"reason" => "quotaExceeded", "message" => "Quota exceeded"}]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} =
               LiveChat.list_messages("chat_123", token: "test_token")

      assert details.reason == "quotaExceeded"

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{
            "error" => %{
              "code" => 404,
              "message" => "Live chat not found"
            }
          })
        )
      end)

      assert {:error, {404, "Live chat not found"}} =
               LiveChat.list_messages("chat_123", token: "test_token")
    end

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
  end

  describe "insert_message/3" do
    test "posts text message with snippet payload and part=snippet" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert conn.method == "POST"
        assert conn.request_path == "/youtube/v3/liveChat/messages"
        assert conn.query_string =~ "part=snippet"
        assert decoded["snippet"]["liveChatId"] == "chat_insert_123"
        assert decoded["snippet"]["type"] == "textMessageEvent"
        assert decoded["snippet"]["textMessageDetails"]["messageText"] == "Autonomous hello from Lux!"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(
            message_fixture(%{
              "id" => "msg_inserted_999",
              "snippet" => %{
                "liveChatId" => "chat_insert_123",
                "type" => "textMessageEvent",
                "displayMessage" => "Autonomous hello from Lux!",
                "textMessageDetails" => %{
                  "messageText" => "Autonomous hello from Lux!"
                }
              }
            })
          )
        )
      end)

      assert {:ok, msg} =
               LiveChat.insert_message(
                 "chat_insert_123",
                 "Autonomous hello from Lux!",
                 token: "test_token"
               )

      assert msg["id"] == "msg_inserted_999"
    end

    test "validates parameters before sending request" do
      assert {:error, :missing_live_chat_id} =
               LiveChat.insert_message("", "Hello", token: "test_token")

      assert {:error, :missing_live_chat_id} =
               LiveChat.insert_message(nil, "Hello", token: "test_token")

      assert {:error, :empty_message_text} =
               LiveChat.insert_message("chat_123", "", token: "test_token")

      assert {:error, :empty_message_text} =
               LiveChat.insert_message("chat_123", nil, token: "test_token")
    end

    test "propagates API errors on insertion failure" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "errors" => [%{"reason" => "liveChatDisabled", "message" => "Live chat is disabled"}]
            }
          })
        )
      end)

      assert {:error, {403, "Live chat is disabled"}} =
               LiveChat.insert_message("chat_123", "Hello", token: "test_token")
    end

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
               LiveChat.insert_message("chat_custom_str", "Message", %{
                 "snippet" => %{"type" => "stringKeyType"}
               })
    end

    test "validates non-binary live_chat_id and message_text" do
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message(12345, "Hello")
      assert {:error, :missing_live_chat_id} = LiveChat.insert_message(:an_atom, "Hello")
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", 12345)
      assert {:error, :empty_message_text} = LiveChat.insert_message("chat_123", :an_atom)
    end
  end

  describe "get_live_chat_id/2 and get_live_chat_id_for_broadcast/2" do
    test "extracts liveChatId when broadcast exists and has active chat" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/youtube/v3/liveBroadcasts"
        assert conn.query_string =~ "id=bcast_with_chat"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [
              %{
                "id" => "bcast_with_chat",
                "snippet" => %{
                  "title" => "Broadcast Title",
                  "liveChatId" => "active_chat_id_999"
                }
              }
            ]
          })
        )
      end)

      assert {:ok, "active_chat_id_999"} =
               LiveChat.get_live_chat_id("bcast_with_chat", token: "test_token")

      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveBroadcastListResponse",
            "items" => [
              %{
                "id" => "bcast_with_chat_2",
                "snippet" => %{
                  "liveChatId" => "active_chat_id_888"
                }
              }
            ]
          })
        )
      end)

      assert {:ok, "active_chat_id_888"} =
               LiveChat.get_live_chat_id_for_broadcast("bcast_with_chat_2", token: "test_token")
    end

    test "returns {:error, :no_live_chat_id} when broadcast has no live chat id" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "bcast_no_chat",
                "snippet" => %{"title" => "Chat Disabled"}
              }
            ]
          })
        )
      end)

      assert {:error, :no_live_chat_id} =
               LiveChat.get_live_chat_id("bcast_no_chat", token: "test_token")
    end

    test "returns {:error, :not_found} when broadcast does not exist" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end)

      assert {:error, :not_found} =
               LiveChat.get_live_chat_id("nonexistent_bcast", token: "test_token")
    end

    test "validates broadcast_id parameter" do
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id("", token: "test_token")
      assert {:error, :missing_broadcast_id} = LiveChat.get_live_chat_id(nil, token: "test_token")
    end

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
  end

  describe "helper accessors and normalization functions" do
    setup do
      raw_msg = message_fixture()
      raw_sc = superchat_fixture()
      norm_msg = LiveChat.normalize_message(raw_msg)
      norm_sc = LiveChat.normalize_message(raw_sc)

      {:ok, raw_msg: raw_msg, raw_sc: raw_sc, norm_msg: norm_msg, norm_sc: norm_sc}
    end

    test "message_text/1 extracts text from both normalized and raw structures", %{
      raw_msg: raw_msg,
      raw_sc: raw_sc,
      norm_msg: norm_msg,
      norm_sc: norm_sc
    } do
      assert LiveChat.message_text(norm_msg) == "Hello Lux community!"
      assert LiveChat.message_text(raw_msg) == "Hello Lux community!"
      assert LiveChat.message_text(norm_sc) == "Keep up the great work with Lux agents!"
      assert LiveChat.message_text(raw_sc) == "Keep up the great work with Lux agents!"
      assert LiveChat.message_text(nil) == nil
      assert LiveChat.message_text(%{}) == nil
    end

    test "author_name/1 and author_channel_id/1 extract info", %{
      raw_msg: raw_msg,
      norm_msg: norm_msg
    } do
      assert LiveChat.author_name(norm_msg) == "TestUser"
      assert LiveChat.author_name(raw_msg) == "TestUser"
      assert LiveChat.author_name(nil) == nil

      assert LiveChat.author_channel_id(norm_msg) == "UC_author_456"
      assert LiveChat.author_channel_id(raw_msg) == "UC_author_456"
      assert LiveChat.author_channel_id(nil) == nil
    end

    test "published_at/1 extracts timestamps", %{raw_msg: raw_msg, norm_msg: norm_msg} do
      assert LiveChat.published_at(norm_msg) == "2026-08-17T20:15:30.123Z"
      assert LiveChat.published_at(raw_msg) == "2026-08-17T20:15:30.123Z"
      assert LiveChat.published_at(nil) == nil
    end

    test "badge predicates (chat_owner?, chat_moderator?, chat_sponsor?)", %{
      raw_msg: raw_msg,
      norm_msg: norm_msg
    } do
      assert LiveChat.chat_sponsor?(norm_msg) == true
      assert LiveChat.chat_sponsor?(raw_msg) == true
      assert LiveChat.chat_owner?(norm_msg) == false
      assert LiveChat.chat_owner?(raw_msg) == false
      assert LiveChat.chat_moderator?(norm_msg) == false
      assert LiveChat.chat_moderator?(raw_msg) == false

      mod_msg =
        message_fixture(%{
          "authorDetails" => %{
            "isChatOwner" => true,
            "isChatModerator" => true,
            "isChatSponsor" => true
          }
        })
        |> LiveChat.normalize_message()

      assert LiveChat.chat_owner?(mod_msg) == true
      assert LiveChat.chat_moderator?(mod_msg) == true
      assert LiveChat.chat_sponsor?(mod_msg) == true
    end

    test "super_chat? and super_chat_amount helpers", %{
      raw_msg: raw_msg,
      norm_msg: norm_msg,
      raw_sc: raw_sc,
      norm_sc: norm_sc
    } do
      assert LiveChat.super_chat?(norm_sc) == true
      assert LiveChat.super_chat?(raw_sc) == true
      assert LiveChat.super_chat?(norm_msg) == false
      assert LiveChat.super_chat?(raw_msg) == false
      assert LiveChat.super_chat?(nil) == false

      assert LiveChat.super_chat_amount(norm_sc) == "$10.00"
      assert LiveChat.super_chat_amount(raw_sc) == "$10.00"
      assert LiveChat.super_chat_amount(norm_msg) == nil
      assert LiveChat.super_chat_amount(nil) == nil
    end

    test "default_parts returns expected string" do
      assert LiveChat.default_parts() == "snippet,authorDetails"
    end

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
      assert norm.super_chat_details.user_comment == "String micros comment"
      assert norm.message_text == "SuperChat with string micros"

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
  end

  describe "start_poller/1 delegate" do
    test "starts poller GenServer linked and can poll" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(list_response_fixture([])))
      end)

      assert {:ok, poller} =
               LiveChat.start_poller(
                 live_chat_id: "chat_delegate_1",
                 token: "tok",
                 auto_start: false
               )

      Req.Test.allow(YouTubeClientMock, self(), poller)
      assert is_pid(poller)
      assert Process.alive?(poller)
      assert {:ok, []} = Lux.Integrations.YouTube.LiveChat.Poller.poll_once(poller)
      GenServer.stop(poller)
    end
  end
end
