defmodule Lux.Integrations.YouTube.AdversarialChallengeGen5Test do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.{Client, Errors, LiveChat}
  alias Lux.Integrations.YouTube.LiveChat.Poller

  # Helper functions
  defp build_chat_item(id, text, author \\ "Tester", overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "youtube#liveChatMessage",
        "id" => id,
        "snippet" => %{
          "type" => "textMessageEvent",
          "liveChatId" => "adv_chat_1",
          "authorChannelId" => "UC_adv_author",
          "publishedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "displayMessage" => text,
          "textMessageDetails" => %{
            "messageText" => text
          }
        },
        "authorDetails" => %{
          "channelId" => "UC_adv_author",
          "displayName" => author,
          "profileImageUrl" => "https://example.com/avatar.jpg",
          "isVerified" => true,
          "isChatOwner" => false,
          "isChatSponsor" => true,
          "isChatModerator" => false
        }
      },
      overrides
    )
  end

  defp build_list_resp(items, next_tok, interval_ms), do: build_list_resp(items, next_tok, interval_ms, nil)

  defp build_list_resp(items, next_tok, interval_ms, offline_at) do
    %{
      "kind" => "youtube#liveChatMessageListResponse",
      "nextPageToken" => next_tok,
      "pollingIntervalMillis" => interval_ms,
      "offlineAt" => offline_at,
      "items" => items
    }
  end

  # ============================================================================
  # CATEGORY 1: Poller Concurrency, Mock Isolation, and Crash Resilience
  # ============================================================================
  describe "Category 1: Poller Concurrency, Mock Isolation, and Crash Resilience" do
    test "High-concurrency Poller spawning and isolated poll execution (50 concurrent pollers)" do
      num_pollers = 50

      # Use isolated plug per poller
      pollers =
        Enum.map(1..num_pollers, fn i ->
          chat_id = "conc_chat_#{i}"
          plug_fn = fn conn ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(build_list_resp([build_chat_item("msg_#{i}", "Hello from #{i}")], "tok_#{i}", 3000))
            )
          end

          {:ok, poller} =
            Poller.start_link(
              live_chat_id: chat_id,
              token: "tok_#{i}",
              auto_start: false,
              client_opts: %{plug: plug_fn}
            )

          {i, chat_id, poller}
        end)

      # Concurrently step all 50 pollers
      tasks =
        Enum.map(pollers, fn {i, chat_id, poller} ->
          Task.async(fn ->
            {:ok, messages} = Poller.poll_once(poller)
            assert length(messages) == 1
            [msg] = messages
            assert msg.id == "msg_#{i}"
            assert msg.message_text == "Hello from #{i}"

            status = Poller.get_status(poller)
            assert status.live_chat_id == chat_id
            assert status.message_count == 1
            assert status.poll_count == 1
            assert status.page_token == "tok_#{i}"
            :ok
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert Enum.all?(results, &(&1 == :ok))

      for {_i, _chat_id, poller} <- pollers, do: Poller.stop(poller)
    end

    test "Massive subscriber registration, abrupt termination and isolation" do
      plug_fn = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(build_list_resp([build_chat_item("sub_msg_1", "Testing subscriber blast")], "tok_sub", 4000))
        )
      end

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "subscriber_blast_chat",
          token: "tok",
          auto_start: false,
          client_opts: %{plug: plug_fn}
        )

      test_pid = self()
      subscriber_count = 100

      # Spawn 100 subscribers
      subscribers =
        for i <- 1..subscriber_count do
          spawn_link(fn ->
            receive do
              {:live_chat_messages, _id, msgs} ->
                send(test_pid, {:received, i, msgs})
              :stop ->
                :ok
            end
          end)
        end

      # Subscribe all
      Enum.each(subscribers, fn pid ->
        assert :ok = Poller.subscribe(poller, pid)
      end)

      assert Poller.get_status(poller).subscribers_count == 100

      # Abruptly kill 90 of them
      {to_kill, surviving} = Enum.split(subscribers, 90)
      Enum.each(to_kill, fn pid ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end)

      # Give GenServer time to receive DOWN signals
      Process.sleep(60)

      status = Poller.get_status(poller)
      assert status.subscribers_count == 10
      assert length(surviving) == 10
      assert Process.alive?(poller)

      # Poll once and verify remaining 10 receive the message
      {:ok, [msg]} = Poller.poll_once(poller)
      assert msg.id == "sub_msg_1"

      surviving_indices =
        Enum.map(91..100, fn expected_idx ->
          assert_receive {:received, ^expected_idx, [received_msg]}, 2000
          assert received_msg.id == "sub_msg_1"
          expected_idx
        end)

      assert length(surviving_indices) == 10

      Poller.stop(poller)
    end

    test "Hostile and crashing callback handlers (raising exceptions) do not crash the Poller" do
      # 1. Handler that raises runtime exception
      plug_fn = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(build_list_resp([build_chat_item("crash_1", "Boom")], "tok_c1", 3000))
        )
      end

      {:ok, poller1} =
        Poller.start_link(
          live_chat_id: "crash_handler_chat_1",
          auto_start: false,
          handler_fn: fn _msgs -> raise "CRASH IN HANDLER!" end,
          client_opts: %{plug: plug_fn}
        )

      assert {:ok, [_]} = Poller.poll_once(poller1)
      assert Process.alive?(poller1)
      Poller.stop(poller1)

      # 2. Handler that raises argument error in arity-2 function
      {:ok, poller2} =
        Poller.start_link(
          live_chat_id: "crash_handler_chat_2",
          auto_start: false,
          handler_fn: fn _chat_id, _msgs -> raise ArgumentError, "Arity 2 crash!" end,
          client_opts: %{plug: plug_fn}
        )

      assert {:ok, [_]} = Poller.poll_once(poller2)
      assert Process.alive?(poller2)
      Poller.stop(poller2)

      # 3. Handler MFA that calls nonexistent module/function
      {:ok, poller3} =
        Poller.start_link(
          live_chat_id: "crash_handler_chat_3",
          auto_start: false,
          handler_fn: {NonExistentAdversarialModule, :does_not_exist, [123]},
          client_opts: %{plug: plug_fn}
        )

      assert {:ok, [_]} = Poller.poll_once(poller3)
      assert Process.alive?(poller3)
      Poller.stop(poller3)
    end

    test "Concurrently hammering Poller lifecycle calls (pause, resume, set_interval, poll_once)" do
      plug_fn = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(build_list_resp([build_chat_item("lifecycle_msg", "Lifecycle Test")], "tok_life", 2000))
        )
      end

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "hammer_lifecycle_chat",
          auto_start: false,
          default_interval_ms: 3000,
          client_opts: %{plug: plug_fn}
        )

      tasks =
        Enum.map(1..40, fn i ->
          Task.async(fn ->
            case rem(i, 4) do
              0 -> Poller.pause(poller)
              1 -> Poller.resume(poller)
              2 -> Poller.set_interval(poller, 1000 + i * 100)
              3 -> Poller.get_status(poller)
            end
          end)
        end)

      Task.await_many(tasks, 10_000)
      assert Process.alive?(poller)

      # Verify poller still works properly after hammering
      {:ok, [msg]} = Poller.poll_once(poller)
      assert msg.id == "lifecycle_msg"

      Poller.stop(poller)
    end
  end

  # ============================================================================
  # CATEGORY 2: Dynamic Polling Interval Adjustments under Rate Limits/Throttling
  # ============================================================================
  describe "Category 2: Dynamic Polling Interval Adjustments under Rate Limits/Throttling" do
    test "Dynamic interval respects min_interval_ms and max_interval_ms boundaries" do
      # Test 1: Suggested interval is below min_interval_ms -> clamped to min_interval_ms
      plug_low = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_list_resp([], "tok_low", 200)))
      end

      {:ok, poller_low} =
        Poller.start_link(
          live_chat_id: "interval_clamping_low",
          auto_start: false,
          min_interval_ms: 1500,
          max_interval_ms: 10_000,
          default_interval_ms: 5000,
          client_opts: %{plug: plug_low}
        )

      {:ok, []} = Poller.poll_once(poller_low)
      assert Poller.get_status(poller_low).interval_ms == 1500
      Poller.stop(poller_low)

      # Test 2: Suggested interval is above max_interval_ms -> clamped to max_interval_ms
      plug_high = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_list_resp([], "tok_high", 50_000)))
      end

      {:ok, poller_high} =
        Poller.start_link(
          live_chat_id: "interval_clamping_high",
          auto_start: false,
          min_interval_ms: 1000,
          max_interval_ms: 8_000,
          default_interval_ms: 5000,
          client_opts: %{plug: plug_high}
        )

      {:ok, []} = Poller.poll_once(poller_high)
      assert Poller.get_status(poller_high).interval_ms == 8000
      Poller.stop(poller_high)

      # Test 3: Suggested interval within range -> exact value used
      plug_mid = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(build_list_resp([], "tok_mid", 4500)))
      end

      {:ok, poller_mid} =
        Poller.start_link(
          live_chat_id: "interval_mid",
          auto_start: false,
          min_interval_ms: 1000,
          max_interval_ms: 8000,
          default_interval_ms: 5000,
          client_opts: %{plug: plug_mid}
        )

      {:ok, []} = Poller.poll_once(poller_mid)
      assert Poller.get_status(poller_mid).interval_ms == 4500
      Poller.stop(poller_mid)
    end

    test "Corrupted/non-integer pollingIntervalMillis falls back safely to default_interval_ms or API default" do
      # Responses with negative, string, and float interval
      invalid_intervals = [-500, "fast", 3.14159, %{"millis" => 1000}]

      Enum.each(invalid_intervals, fn bad_interval ->
        plug = fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "kind" => "youtube#liveChatMessageListResponse",
              "nextPageToken" => "tok_bad",
              "pollingIntervalMillis" => bad_interval,
              "items" => []
            })
          )
        end

        {:ok, poller} =
          Poller.start_link(
            live_chat_id: "bad_interval_chat",
            auto_start: false,
            default_interval_ms: 4200,
            client_opts: %{plug: plug}
          )

        {:ok, []} = Poller.poll_once(poller)
        assert Poller.get_status(poller).interval_ms == 4200
        Poller.stop(poller)
      end)
    end

    test "Poller rate limit error backoff increment and recovery" do
      counter = :counters.new(1, [:atomics])

      plug_flaky = fn conn ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if count < 2 do
          # First 2 requests (count = 0, 1) return 429 Rate Limit
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            429,
            Jason.encode!(%{
              "error" => %{
                "code" => 429,
                "message" => "Rate limit exceeded. Slow down.",
                "errors" => [%{"reason" => "rateLimitExceeded"}]
              }
            })
          )
        else
          # 3rd request (count >= 2) succeeds
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(build_list_resp([build_chat_item("rec_msg", "Recovered!")], "tok_rec", 3000))
          )
        end
      end

      {:ok, poller} =
        Poller.start_link(
          live_chat_id: "rate_limit_recovery_chat",
          auto_start: false,
          subscriber: self(),
          client_opts: %{plug: plug_flaky}
        )

      # First poll -> rate limit error
      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      status1 = Poller.get_status(poller)
      assert status1.consecutive_errors == 1
      assert_receive {:live_chat_error, "rate_limit_recovery_chat", {:rate_limited, _}}

      # Second poll -> second error
      assert {:error, {:rate_limited, _}} = Poller.poll_once(poller)
      status2 = Poller.get_status(poller)
      assert status2.consecutive_errors == 2
      assert_receive {:live_chat_error, "rate_limit_recovery_chat", {:rate_limited, _}}

      # Third poll -> recovered!
      assert {:ok, [msg]} = Poller.poll_once(poller)
      assert msg.id == "rec_msg"
      status3 = Poller.get_status(poller)
      assert status3.consecutive_errors == 0
      assert status3.last_error == nil
      assert status3.message_count == 1
      assert_receive {:live_chat_messages, "rate_limit_recovery_chat", [_]}

      Poller.stop(poller)
    end
  end

  # ============================================================================
  # CATEGORY 3: 401 Token Refresh Loop Boundaries and Multi-Process Mock Sharing
  # ============================================================================
  describe "Category 3: 401 Token Refresh Loop Boundaries and Multi-Process Mock Sharing" do
    test "Successful token refresh on 401 and subsequent request with updated token" do
      client_counter = :counters.new(1, [:atomics])

      plug_oauth = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "rt_valid_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "fresh_access_token_abc",
            "expires_in" => 3600,
            "token_type" => "Bearer"
          })
        )
      end

      plug_client = fn conn ->
        count = :counters.get(client_counter, 1)
        :counters.add(client_counter, 1, 1)

        if count == 0 do
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer expired_token"]
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Token expired"}}))
        else
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh_access_token_abc"]
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => [%{"id" => "success_item"}]}))
        end
      end

      # Run Client.get with isolated plugs
      Req.Test.stub(YouTubeOAuthMock, plug_oauth)
      Req.Test.stub(YouTubeClientMock, plug_client)

      opts = %{
        token: "expired_token",
        refresh_token: "rt_valid_123",
        client_id: "cid",
        client_secret: "sec",
        auto_refresh: true
      }

      assert {:ok, %{"items" => [%{"id" => "success_item"}]}} = Client.get("/liveBroadcasts", opts)
    end

    test "401 loop boundary strictly prevents infinite recursion on persistent 401" do
      client_counter = :counters.new(1, [:atomics])

      plug_oauth = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"access_token" => "second_bad_token", "expires_in" => 3600})
        )
      end

      plug_client = fn conn ->
        :counters.add(client_counter, 1, 1)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid credentials"}}))
      end

      Req.Test.stub(YouTubeOAuthMock, plug_oauth)
      Req.Test.stub(YouTubeClientMock, plug_client)

      opts = %{
        token: "bad_token_1",
        refresh_token: "rt_valid",
        client_id: "cid",
        client_secret: "sec",
        auto_refresh: true
      }

      # Must return {:error, :invalid_token} and exactly 2 client calls (original + 1 retry)
      assert {:error, :invalid_token} = Client.get("/liveBroadcasts", opts)
      assert :counters.get(client_counter, 1) == 2
    end

    test "401 with failing OAuth refresh endpoint returns error cleanly without crashing" do
      plug_oauth = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => "invalid_grant", "error_description" => "Token has been expired or revoked."})
        )
      end

      plug_client = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Unauthorized"}}))
      end

      Req.Test.stub(YouTubeOAuthMock, plug_oauth)
      Req.Test.stub(YouTubeClientMock, plug_client)

      opts = %{
        token: "bad_tok",
        refresh_token: "revoked_rt",
        client_id: "cid",
        client_secret: "sec",
        auto_refresh: true
      }

      assert {:error, :invalid_token} = Client.get("/liveBroadcasts", opts)
    end

    test "Concurrent multi-process 401 refresh with mock isolation" do
      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            combined_plug = fn conn ->
              path = conn.request_path
              cond do
                String.contains?(path, "oauth2") or String.contains?(path, "token") ->
                  # OAuth refresh request
                  conn
                  |> Plug.Conn.put_resp_content_type("application/json")
                  |> Plug.Conn.send_resp(
                    200,
                    Jason.encode!(%{"access_token" => "refreshed_tok_#{i}", "expires_in" => 3600})
                  )

                true ->
                  # YouTube API client request
                  auth_header = Plug.Conn.get_req_header(conn, "authorization")
                  if auth_header == ["Bearer init_expired_#{i}"] do
                    conn
                    |> Plug.Conn.put_resp_content_type("application/json")
                    |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Expired"}}))
                  else
                    assert auth_header == ["Bearer refreshed_tok_#{i}"]
                    conn
                    |> Plug.Conn.put_resp_content_type("application/json")
                    |> Plug.Conn.send_resp(200, Jason.encode!(%{"worker" => i}))
                  end
              end
            end

            opts = %{
              token: "init_expired_#{i}",
              refresh_token: "rt_#{i}",
              client_id: "cid_#{i}",
              client_secret: "sec_#{i}",
              auto_refresh: true,
              plug: combined_plug
            }

            assert {:ok, %{"worker" => ^i}} = Client.get("/liveBroadcasts", opts)
            :ok
          end)
        end)

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  # ============================================================================
  # CATEGORY 4: Malformed API Payloads, Corrupt Error Bodies & Edge Cases
  # ============================================================================
  describe "Category 4: Malformed API Payloads, Corrupt Error Bodies & Edge Cases" do
    test "Errors.parse handles non-JSON, HTML, empty, binary, and weird error bodies" do
      # 1. HTML 502/503 Cloudflare/Nginx gateway page returns raw string
      html_body = "<html><head><title>502 Bad Gateway</title></head><body>502 Bad Gateway</body></html>"
      assert {:error, {502, ^html_body}} = Errors.parse(502, html_body, [])

      # 2. 500 Internal Error with raw string
      assert {:error, {500, "Internal Crash"}} = Errors.parse(500, "Internal Crash", [])

      # 3. 403 Forbidden with plain text
      assert {:error, {403, "Access Denied by WAF"}} = Errors.parse(403, "Access Denied by WAF", [])

      # 4. 400 Bad Request with nil body
      assert {:error, {400, "Bad Request"}} = Errors.parse(400, nil, [])

      # 5. 429 Rate Limit with unparseable corrupt string
      assert {:error, {:rate_limited, info}} = Errors.parse(429, "<<unparseable>>", [{"retry-after", "15"}])
      assert info.status == 429
      assert info.retry_after == 15

      # 6. 403 Quota Exceeded with Google nested JSON
      google_quota_json = %{
        "error" => %{
          "code" => 403,
          "message" => "The request cannot be completed because you have exceeded your quota.",
          "errors" => [
            %{
              "domain" => "youtube.quota",
              "reason" => "quotaExceeded",
              "message" => "The request cannot be completed because you have exceeded your quota."
            }
          ]
        }
      }
      assert {:error, {:quota_exceeded, q_info}} = Errors.parse(403, google_quota_json, [])
      assert q_info.reason == "quotaExceeded"
      assert q_info.domain == "youtube.quota"
      assert Errors.quota_exceeded?({:error, {:quota_exceeded, q_info}})
    end

    test "LiveChat.normalize_message resilience against deeply broken and unusual payloads" do
      # 1. Completely empty map
      norm1 = LiveChat.normalize_message(%{})
      assert norm1.id == nil
      assert norm1.is_verified == false
      assert norm1.is_chat_owner == false
      assert norm1.super_chat_details == nil

      # 2. Map with nil values for snippet and authorDetails
      norm2 = LiveChat.normalize_message(%{"id" => "n2", "snippet" => nil, "authorDetails" => nil})
      assert norm2.id == "n2"
      assert norm2.message_text == nil
      assert norm2.author_display_name == nil

      # 3. Super chat with non-numeric amountMicros
      raw_sc_broken = %{
        "id" => "sc_broken",
        "snippet" => %{
          "type" => "superChatEvent",
          "liveChatId" => "c_sc",
          "superChatDetails" => %{
            "amountMicros" => "not_a_number",
            "currency" => "USD",
            "amountDisplayString" => "$5.00"
          }
        }
      }
      norm_sc = LiveChat.normalize_message(raw_sc_broken)
      assert norm_sc.id == "sc_broken"
      assert norm_sc.super_chat_details.currency == "USD"
      # amount_micros should safely parse to nil without crashing
      assert norm_sc.super_chat_details.amount_micros == nil

      # 4. Message with author badges missing
      raw_badges = %{
        "id" => "badge_test",
        "authorDetails" => %{
          "displayName" => "CoolUser",
          "isVerified" => "truthy_string",
          "isChatOwner" => true
        }
      }
      norm_b = LiveChat.normalize_message(raw_badges)
      assert norm_b.author_display_name == "CoolUser"
      assert norm_b.is_chat_owner == true
    end

    test "LiveChat.list_messages parses malformed top-level responses gracefully" do
      # 1. Response without nextPageToken
      plug_no_token = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "items" => []
          })
        )
      end

      assert {:ok, resp} = LiveChat.list_messages("c1", plug: plug_no_token)
      assert resp.next_page_token == nil
      assert resp.messages == []
      assert resp.polling_interval_ms == 5000

      # 2. Response with offlineAt signal
      plug_offline = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "kind" => "youtube#liveChatMessageListResponse",
            "offlineAt" => "2026-08-18T19:00:00Z",
            "items" => []
          })
        )
      end

      assert {:ok, resp_off} = LiveChat.list_messages("c1", plug: plug_offline)
      assert resp_off.offline_at == "2026-08-18T19:00:00Z"
    end
  end
end
