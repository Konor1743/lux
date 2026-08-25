defmodule Lux.Telegram.AdversarialStressTest do
  use UnitAPICase, async: false
  require Logger

  alias Lux.Telegram.WebhookPlug
  alias Lux.Telegram.Poller

  @secret_token "V3ry_S3cur3_T0k3n_#2026!"

  defmodule CrashModuleHandler do
    def handle_signal(_signal), do: raise("Crash in handle_signal/1")
  end

  defmodule LegacyUpdateModuleHandler do
    def handle_update(signal) do
      send(signal.sender || self(), {:legacy_handled, signal})
      :ok
    end
  end

  defmodule NonHandlerModule do
    def other_function, do: :ok
  end

  # ============================================================================
  # 1. WEBHOOK ADVERSARIAL STRESS TESTS
  # ============================================================================

  describe "Webhook: Malformed JSON syntax stress test" do
    @malformed_bodies [
      {"truncated json", "{\"update_id\": 100, \"message\": {"},
      {"unbalanced closing braces", "{\"update_id\": 100}}"},
      {"unbalanced array brackets", "[{\"update_id\": 100}"},
      {"illegal escape character", "{\"text\": \"illegal \\x escape\"}"},
      {"binary garbage 1", <<0, 255, 128, 64>>},
      {"binary garbage 2", <<0x80, 0x81, 0x82, 0xFF>>},
      {"trailing comma", "{\"update_id\": 100,}"},
      {"single-quoted json", "{'update_id': 100}"},
      {"unquoted keys", "{update_id: 100}"},
      {"truncated string", "{\"update_id\": 100, \"text\": \"unclosed string"},
      {"double colon", "{\"update_id\":: 100}"},
      {"null byte injection in body", "{\"update_id\": 100\0, \"text\": \"null\"}"}
    ]

    for {label, body} <- @malformed_bodies do
      @tag label: label
      test "rejects malformed JSON (#{label}) with HTTP 400 and halts" do
        opts = WebhookPlug.init(handler: self())

        conn =
          :post
          |> Plug.Test.conn("/webhook", unquote(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> WebhookPlug.call(opts)

        assert conn.status == 400, "Expected 400 for #{unquote(label)}, got #{conn.status}"
        assert conn.halted
        assert Jason.decode!(conn.resp_body) == %{"error" => "Malformed JSON", "status" => "error"}
        refute_receive {:telegram_update, _}
      end
    end
  end

  describe "Webhook: Empty and whitespace body stress test" do
    @empty_or_whitespace_bodies [
      {"empty string", ""},
      {"single space", " "},
      {"multiple spaces", "     "},
      {"newlines and tabs", "\n\t\r\n \t  "},
      {"mixed whitespace", "   \r\n \t \n  "}
    ]

    for {label, body} <- @empty_or_whitespace_bodies do
      test "rejects empty/whitespace body (#{label}) with HTTP 400 and halts" do
        opts = WebhookPlug.init(handler: self())

        conn =
          :post
          |> Plug.Test.conn("/webhook", unquote(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> WebhookPlug.call(opts)

        assert conn.status == 400
        assert conn.halted
        decoded = Jason.decode!(conn.resp_body)
        assert decoded["status"] == "error"
        assert decoded["error"] in ["Empty request body", "Malformed JSON"]
        refute_receive {:telegram_update, _}
      end
    end
  end

  describe "Webhook: Non-map JSON root types stress test" do
    @non_map_roots [
      {"empty array", Jason.encode!([])},
      {"array of integers", Jason.encode!([1, 2, 3])},
      {"array of valid update maps", Jason.encode!([%{"update_id" => 100}])},
      {"primitive positive integer", Jason.encode!(12345)},
      {"primitive zero", Jason.encode!(0)},
      {"primitive negative integer", Jason.encode!(-42)},
      {"primitive float", Jason.encode!(3.14159)},
      {"primitive string", Jason.encode!("hello world")},
      {"primitive empty string", Jason.encode!("")},
      {"primitive boolean true", Jason.encode!(true)},
      {"primitive boolean false", Jason.encode!(false)},
      {"primitive null", Jason.encode!(nil)},
      {"empty object map", Jason.encode!(%{})}
    ]

    for {label, body} <- @non_map_roots do
      test "rejects non-map/empty JSON root (#{label}) with HTTP 400 and halts" do
        opts = WebhookPlug.init(handler: self())

        conn =
          :post
          |> Plug.Test.conn("/webhook", unquote(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> WebhookPlug.call(opts)

        assert conn.status == 400
        assert conn.halted
        assert Jason.decode!(conn.resp_body) == %{"error" => "Invalid payload", "status" => "error"}
        refute_receive {:telegram_update, _}
      end
    end
  end

  describe "Webhook: Invalid update schema maps stress test" do
    @invalid_schema_payloads [
      {"missing update_id (only message)", %{"message" => %{"text" => "hi"}}},
      {"missing update_id (empty fields)", %{"unrelated" => "value"}},
      {"update_id is string", %{"update_id" => "100"}},
      {"update_id is float", %{"update_id" => 100.5}},
      {"update_id is nil", %{"update_id" => nil}},
      {"update_id is boolean true", %{"update_id" => true}},
      {"update_id is boolean false", %{"update_id" => false}},
      {"update_id is list", %{"update_id" => [100]}},
      {"update_id is map", %{"update_id" => %{"id" => 100}}},
      {"message is string instead of object", %{"update_id" => 101, "message" => "not_an_object"}},
      {"message is integer instead of object", %{"update_id" => 102, "message" => 12345}},
      {"message is list instead of object", %{"update_id" => 103, "message" => [%{"text" => "hi"}]}},
      {"callback_query is integer", %{"update_id" => 104, "callback_query" => 999}},
      {"chat_member is boolean", %{"update_id" => 105, "chat_member" => true}},
      {"poll is string", %{"update_id" => 106, "poll" => "invalid_poll"}}
    ]

    for {label, payload} <- @invalid_schema_payloads do
      test "rejects invalid update schema (#{label}) with HTTP 400 and halts" do
        opts = WebhookPlug.init(handler: self())

        conn =
          :post
          |> Plug.Test.conn("/webhook", Jason.encode!(unquote(Macro.escape(payload))))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> WebhookPlug.call(opts)

        assert conn.status == 400
        assert conn.halted
        assert Jason.decode!(conn.resp_body) == %{"error" => "Invalid update payload", "status" => "error"}
        refute_receive {:telegram_update, _}
      end
    end
  end

  describe "Webhook: Secret token authentication bypass attempts" do
    @auth_bypass_cases [
      {"missing header", nil},
      {"empty header value", ""},
      {"wrong secret token", "Wrong_Secret_Token_999"},
      {"secret with trailing space", "#{@secret_token} "},
      {"secret with leading space", " #{@secret_token}"},
      {"secret with trailing newline", "#{@secret_token}\n"},
      {"lowercase variation", String.downcase(@secret_token)},
      {"uppercase variation", String.upcase(@secret_token)},
      {"prefix match attempt", "#{@secret_token}_extra"},
      {"suffix match attempt", "pre_#{@secret_token}"},
      {"null byte appended", "#{@secret_token}\0"},
      {"sql-injection like token", "#{@secret_token}' OR '1'='1"}
    ]

    for {label, header_val} <- @auth_bypass_cases do
      test "rejects secret token bypass attempt (#{label}) with HTTP 401 and halts" do
        opts = WebhookPlug.init(secret_token: @secret_token, handler: self())

        conn =
          :post
          |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 200, "message" => %{"text" => "hello"}}))
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> then(fn c ->
            if unquote(header_val) do
              Plug.Conn.put_req_header(c, "x-telegram-bot-api-secret-token", unquote(header_val))
            else
              c
            end
          end)
          |> WebhookPlug.call(opts)

        assert conn.status == 401
        assert conn.halted
        assert Jason.decode!(conn.resp_body) == %{"error" => "Unauthorized", "status" => "error"}
        refute_receive {:telegram_update, _}
      end
    end

    test "accepts request when secret token matches exactly" do
      opts = WebhookPlug.init(secret_token: @secret_token, handler: self())

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 201, "message" => %{"text" => "authorized"}}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", @secret_token)
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      refute conn.halted
      assert_receive {:telegram_update, signal}
      assert signal.payload["update_id"] == 201
    end

    test "accepts request with unicode / multibyte secret token" do
      unicode_token = "🔑_töken_2026_🔐"
      opts = WebhookPlug.init(secret_token: unicode_token, handler: self())

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 202, "message" => %{"text" => "unicode auth"}}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-telegram-bot-api-secret-token", unicode_token)
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:telegram_update, signal}
      assert signal.payload["update_id"] == 202
    end
  end

  describe "Webhook: Handler fault tolerance and dispatch types" do
    test "survives handler throwing an exception" do
      crashing_handler = fn _signal -> raise RuntimeError, "Boom! Handler exploded" end
      opts = WebhookPlug.init(handler: crashing_handler)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 301}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
    end

    test "survives handler throwing an atom/term" do
      throwing_handler = fn _signal -> throw(:unexpected_throw) end
      opts = WebhookPlug.init(handler: throwing_handler)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 302}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
    end

    test "survives handler calling exit(:shutdown)" do
      exiting_handler = fn _signal -> exit(:shutdown) end
      opts = WebhookPlug.init(handler: exiting_handler)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 303}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
    end

    test "survives module handler that crashes" do
      opts = WebhookPlug.init(handler: CrashModuleHandler)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 304}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
    end

    test "dispatches to module handler with handle_update/1" do
      opts = WebhookPlug.init(handler: LegacyUpdateModuleHandler)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 305}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
      assert_receive {:legacy_handled, signal}
      assert signal.payload["update_id"] == 305
    end

    test "ignores module handler that does not implement handler callbacks" do
      opts = WebhookPlug.init(handler: NonHandlerModule)

      conn =
        :post
        |> Plug.Test.conn("/webhook", Jason.encode!(%{"update_id" => 306}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> WebhookPlug.call(opts)

      assert conn.status == 200
    end
  end

  # ============================================================================
  # 2. POLLER ADVERSARIAL STRESS TESTS
  # ============================================================================

  describe "Poller: process_updates/3 adversarial inputs" do
    test "drops all non-map items in updates list and preserves valid signals" do
      test_pid = self()
      non_map_items = [
        :atom_item,
        nil,
        true,
        false,
        "string_item",
        "",
        <<0, 255, 128>>,
        12345,
        -999,
        0,
        3.14159,
        [],
        [1, 2, 3],
        [%{"update_id" => 500}],
        {:tuple, :not, :allowed}
      ]

      valid_update_1 = %{"update_id" => 10, "message" => %{"text" => "First"}}
      valid_update_2 = %{"update_id" => 20, "message" => %{"text" => "Second"}}

      corrupted_updates = [valid_update_1 | non_map_items] ++ [valid_update_2]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => Enum.filter(corrupted_updates, &is_map/1)
        }))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "dummy_tok",
          plug: plug,
          handler: test_pid,
          autostart: false,
          offset: 0
        })

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 2
      assert Enum.map(signals, & &1.payload["update_id"]) == [10, 20]
      assert Poller.get_offset(poller) == 21

      assert_receive {:telegram_update, sig1}
      assert sig1.payload["update_id"] == 10
      assert_receive {:telegram_update, sig2}
      assert sig2.payload["update_id"] == 20
      refute_receive {:telegram_update, _}

      Poller.stop(poller)
    end

    test "handles malformed update_id variations and advances offset correctly for non-negative IDs" do
      test_pid = self()

      raw_updates = [
        # missing update_id
        %{"message" => %{"text" => "no_id"}},
        # string update_id with invalid format
        %{"update_id" => "invalid_string_id", "message" => %{"text" => "bad_str"}},
        # negative string update_id
        %{"update_id" => "-50", "message" => %{"text" => "neg_str"}},
        # float update_id
        %{"update_id" => 99.9, "message" => %{"text" => "float_id"}},
        # nil update_id
        %{"update_id" => nil, "message" => %{"text" => "nil_id"}},
        # boolean update_id
        %{"update_id" => true, "message" => %{"text" => "bool_id"}},
        # list update_id
        %{"update_id" => [100], "message" => %{"text" => "list_id"}},
        # valid update 1
        %{"update_id" => 100, "message" => %{"text" => "Valid 100"}},
        # corrupt schema with valid update_id 105
        %{"update_id" => 105, "message" => "invalid_message_string"},
        # valid update 2
        %{"update_id" => 110, "message" => %{"text" => "Valid 110"}}
      ]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => raw_updates}))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "dummy_tok",
          plug: plug,
          handler: test_pid,
          autostart: false,
          offset: 50
        })

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 2
      assert Enum.map(signals, & &1.payload["update_id"]) == [100, 110]

      # Offset must be max(50, 100+1, 105+1, 110+1) == 111
      assert Poller.get_offset(poller) == 111

      assert_receive {:telegram_update, s1}
      assert s1.payload["update_id"] == 100
      assert_receive {:telegram_update, s2}
      assert s2.payload["update_id"] == 110

      # Assert NO error tuples were ever sent to handler
      refute_receive {:telegram_update, {:error, _}}
      refute_receive {:telegram_update, _}

      Poller.stop(poller)
    end

    test "negative update_id does not advance offset" do
      test_pid = self()

      raw_updates = [
        %{"update_id" => -10, "message" => %{"text" => "neg_int"}}
      ]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => raw_updates}))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "dummy_tok",
          plug: plug,
          handler: test_pid,
          autostart: false,
          offset: 50
        })

      assert {:ok, [signal]} = Poller.poll_once(poller)
      assert signal.payload["update_id"] == -10
      # Offset should remain 50 because update_id was negative
      assert Poller.get_offset(poller) == 50

      Poller.stop(poller)
    end

    test "handles out-of-order batches and maintains monotonically increasing offset" do
      test_pid = self()

      out_of_order_updates = [
        %{"update_id" => 750, "message" => %{"text" => "750"}},
        %{"update_id" => 700, "message" => %{"text" => "700"}},
        %{"update_id" => 800, "message" => %{"text" => "800"}},
        %{"update_id" => 720, "message" => %{"text" => "720"}}
      ]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => out_of_order_updates}))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "dummy_tok",
          plug: plug,
          handler: test_pid,
          autostart: false,
          offset: 600
        })

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 4
      assert Poller.get_offset(poller) == 801

      Poller.stop(poller)
    end

    test "preserves current offset when batch updates are older than current offset" do
      test_pid = self()

      older_updates = [
        %{"update_id" => 100, "message" => %{"text" => "100"}},
        %{"update_id" => 200, "message" => %{"text" => "200"}}
      ]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => older_updates}))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "dummy_tok",
          plug: plug,
          handler: test_pid,
          autostart: false,
          offset: 1000
        })

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 2
      # Offset should remain 1000 because 1000 > 200 + 1
      assert Poller.get_offset(poller) == 1000

      Poller.stop(poller)
    end

    test "handles completely empty batch without changing offset" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => []}))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "dummy_tok",
          plug: plug,
          handler: self(),
          autostart: false,
          offset: 42
        })

      assert {:ok, []} = Poller.poll_once(poller)
      assert Poller.get_offset(poller) == 42
      refute_receive {:telegram_update, _}

      Poller.stop(poller)
    end

    test "survives Poller handler exceptions without crashing or stopping offset progression" do
      test_pid = self()

      crashing_handler = fn signal ->
        if signal.payload["update_id"] == 500 do
          raise "Crash on 500"
        else
          send(test_pid, {:handled, signal.payload["update_id"]})
        end
      end

      updates = [
        %{"update_id" => 500, "message" => %{"text" => "Will crash handler"}},
        %{"update_id" => 501, "message" => %{"text" => "Will succeed"}}
      ]

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => updates}))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: "dummy_tok",
          plug: plug,
          handler: crashing_handler,
          autostart: false,
          offset: 400
        })

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 2
      assert Poller.get_offset(poller) == 502
      assert_receive {:handled, 501}

      Poller.stop(poller)
    end

    test "generative randomized batch property test (50 iterations)" do
      for batch_idx <- 1..50 do
        initial_offset = :rand.uniform(10_000)

        item_count = :rand.uniform(20)
        items =
          Enum.map(1..item_count, fn i ->
            case :rand.uniform(6) do
              1 ->
                # Valid update
                %{"update_id" => initial_offset + i * 2, "message" => %{"text" => "msg_#{i}"}}

              2 ->
                # Non-map item
                case :rand.uniform(4) do
                  1 -> "corrupt_string_#{i}"
                  2 -> :rand.uniform(1000)
                  3 -> nil
                  4 -> ["nested", "list"]
                end

              3 ->
                # Missing update_id
                %{"message" => %{"text" => "no_update_id_#{i}"}}

              4 ->
                # Corrupt schema with valid update_id
                %{"update_id" => initial_offset + i * 2 + 1, "message" => 12345}

              5 ->
                # Invalid update_id format
                %{"update_id" => "not_int", "message" => %{"text" => "bad_id"}}

              6 ->
                # Negative update_id
                %{"update_id" => -:rand.uniform(100), "message" => %{"text" => "negative"}}
            end
          end)

        valid_maps = Enum.filter(items, &is_map/1)

        plug = fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => valid_maps}))
        end

        {:ok, poller} =
          Poller.start_link(%{
            token: "dummy_tok_#{batch_idx}",
            plug: plug,
            handler: self(),
            autostart: false,
            offset: initial_offset
          })

        assert {:ok, signals} = Poller.poll_once(poller)

        # Invariant 1: All returned items are valid Lux.Signal structs
        for sig <- signals do
          assert %Lux.Signal{} = sig
          assert is_integer(sig.payload["update_id"])
        end

        # Invariant 2: Offset is monotonically non-decreasing
        new_offset = Poller.get_offset(poller)
        assert new_offset >= initial_offset, "Offset decreased from #{initial_offset} to #{new_offset}"

        # Clean up any received messages and stop poller
        flush_messages()
        Poller.stop(poller)
      end
    end
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
