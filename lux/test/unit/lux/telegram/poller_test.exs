defmodule Lux.Telegram.PollerUnitTest do
  use UnitAPICase, async: true

  alias Lux.Telegram.Poller

  @bot_token "test_poller_token_123"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "poll_once/1" do
    test "polls updates, dispatches signals to PID, and updates offset" do
      test_pid = self()

      plug = fn conn ->
        assert conn.request_path == "/bot#{@bot_token}/getUpdates"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["offset"] == 0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => [
            %{"update_id" => 100, "message" => %{"text" => "First"}},
            %{"update_id" => 101, "message" => %{"text" => "Second"}}
          ]
        }))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: @bot_token,
          plug: plug,
          handler: test_pid,
          autostart: false
        })

      assert Poller.get_offset(poller) == 0

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 2

      assert_receive {:telegram_update, signal1}
      assert signal1.payload["update_id"] == 100
      assert get_in(signal1.payload, ["message", "text"]) == "First"

      assert_receive {:telegram_update, signal2}
      assert signal2.payload["update_id"] == 101
      assert get_in(signal2.payload, ["message", "text"]) == "Second"

      assert Poller.get_offset(poller) == 102
    end

    test "dispatches signal to handler function" do
      test_pid = self()

      handler_fn = fn signal ->
        send(test_pid, {:custom_fn_signal, signal})
      end

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => [%{"update_id" => 50, "message" => %{"text" => "Fn test"}}]
        }))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: @bot_token,
          plug: plug,
          handler: handler_fn,
          autostart: false
        })

      assert {:ok, [signal]} = Poller.poll_once(poller)
      assert_receive {:custom_fn_signal, ^signal}
      assert signal.payload["update_id"] == 50
    end

    test "filters out invalid update payloads, drops error tuples, and advances offset" do
      test_pid = self()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => [
            # Valid update 1
            %{"update_id" => 200, "message" => %{"text" => "Valid 1"}},
            # Invalid update (missing update_id, wait - if update_id is missing it won't advance; if update_id is present but bad message type, schema error)
            %{"update_id" => 201, "message" => "invalid_string_message"},
            # Valid update 2
            %{"update_id" => 202, "message" => %{"text" => "Valid 2"}}
          ]
        }))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: @bot_token,
          plug: plug,
          handler: test_pid,
          autostart: false
        })

      assert {:ok, signals} = Poller.poll_once(poller)
      assert length(signals) == 2

      assert_receive {:telegram_update, signal1}
      assert signal1.payload["update_id"] == 200

      assert_receive {:telegram_update, signal2}
      assert signal2.payload["update_id"] == 202

      # Ensure no error tuple was dispatched
      refute_receive {:telegram_update, {:error, _}}

      # Ensure offset advanced past invalid update 201 to 203
      assert Poller.get_offset(poller) == 203
    end

    test "handles batch with only invalid updates by returning empty list and advancing offset" do
      test_pid = self()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => [
            %{"update_id" => 300, "message" => "bad_message_1"},
            %{"update_id" => 301, "message" => "bad_message_2"}
          ]
        }))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: @bot_token,
          plug: plug,
          handler: test_pid,
          autostart: false
        })

      assert {:ok, []} = Poller.poll_once(poller)
      refute_receive {:telegram_update, _}
      assert Poller.get_offset(poller) == 302
    end

    test "skips non-map items in updates array gracefully" do
      test_pid = self()

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => [
            "not-a-map",
            12345,
            %{"update_id" => 400, "message" => %{"text" => "Valid after scalars"}}
          ]
        }))
      end

      {:ok, poller} =
        Poller.start_link(%{
          token: @bot_token,
          plug: plug,
          handler: test_pid,
          autostart: false
        })

      assert {:ok, [signal]} = Poller.poll_once(poller)
      assert signal.payload["update_id"] == 400
      assert_receive {:telegram_update, ^signal}
      assert Poller.get_offset(poller) == 401
    end
  end
end
