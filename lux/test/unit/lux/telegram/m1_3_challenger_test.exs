defmodule Lux.Telegram.M13ChallengerTest do
  use UnitAPICase, async: false

  alias Lux.Telegram.Client
  alias Lux.Telegram.Media
  alias Lux.Integrations.Telegram.Client, as: IntegrationClient

  @bot_token "challenger_bot_token_77777"

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "1. Network Isolation & :plug Preservation in download_file/2" do
    test "download_file with file_id preserves :plug for BOTH getFile and file download requests" do
      get_file_called = :counters.new(1, [:atomics])
      download_called = :counters.new(1, [:atomics])

      plug_fn = fn conn ->
        case conn.request_path do
          "/bot" <> rest ->
            assert rest == "#{@bot_token}/getFile"
            assert conn.method == "POST"
            :counters.add(get_file_called, 1, 1)

            {:ok, body, _conn} = Plug.Conn.read_body(conn)
            json = Jason.decode!(body)
            assert json["file_id"] == "fid_challenger_001"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "ok" => true,
              "result" => %{
                "file_id" => "fid_challenger_001",
                "file_path" => "photos/challenger_image.png",
                "file_size" => 42_000
              }
            }))

          "/file/bot" <> rest ->
            assert rest == "#{@bot_token}/photos/challenger_image.png"
            assert conn.method == "GET"
            :counters.add(download_called, 1, 1)

            conn
            |> Plug.Conn.put_resp_content_type("image/png")
            |> Plug.Conn.send_resp(200, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>)
        end
      end

      # Test with map options
      assert {:ok, binary_data} =
               Media.download_file("fid_challenger_001", %{token: @bot_token, plug: plug_fn})

      assert binary_data == <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
      assert :counters.get(get_file_called, 1) == 1
      assert :counters.get(download_called, 1) == 1

      # Test with keyword list options
      assert {:ok, binary_data2} =
               Media.download_file("fid_challenger_001", token: @bot_token, plug: plug_fn)

      assert binary_data2 == <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
      assert :counters.get(get_file_called, 1) == 2
      assert :counters.get(download_called, 1) == 2
    end

    test "download_file with direct file_path (contains slash or dot) bypasses getFile and uses :plug" do
      download_called = :counters.new(1, [:atomics])

      plug_fn = fn conn ->
        assert conn.request_path == "/file/bot#{@bot_token}/documents/archive.bin"
        assert conn.method == "GET"
        :counters.add(download_called, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, "RAW_BINARY_DATA")
      end

      # Contains slash
      assert {:ok, "RAW_BINARY_DATA"} =
               Media.download_file("documents/archive.bin", token: @bot_token, plug: plug_fn)

      # Contains dot only (treated as file_path)
      plug_dot = fn conn ->
        assert conn.request_path == "/file/bot#{@bot_token}/archive.bin"
        assert conn.method == "GET"
        :counters.add(download_called, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, "RAW_BINARY_DATA")
      end

      assert {:ok, "RAW_BINARY_DATA"} =
               Media.download_file("archive.bin", token: @bot_token, plug: plug_dot)

      assert :counters.get(download_called, 1) == 2
    end

    test "Client.download_file and IntegrationClient.download_file preserve plug" do
      plug_fn = fn conn ->
        assert conn.request_path == "/file/bot#{@bot_token}/voice/note.ogg"

        conn
        |> Plug.Conn.put_resp_content_type("audio/ogg")
        |> Plug.Conn.send_resp(200, "OGG_AUDIO_BYTES")
      end

      # Via Lux.Telegram.Client struct with req_options plug
      client = Client.new(token: @bot_token, req_options: [plug: plug_fn])
      assert {:ok, "OGG_AUDIO_BYTES"} = Client.download_file(client, "voice/note.ogg")

      # Via Lux.Integrations.Telegram.Client
      assert {:ok, "OGG_AUDIO_BYTES"} =
               IntegrationClient.download_file("voice/note.ogg", token: @bot_token, plug: plug_fn)
    end
  end

  describe "2. Error Handling & Failure Modes in download_file/2 and resolve_file_path" do
    test "get_file 404 Not Found returns {:error, {404, message}} without calling download" do
      download_attempted = :counters.new(1, [:atomics])

      plug_fn = fn conn ->
        case conn.request_path do
          "/bot" <> _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(404, Jason.encode!(%{
              "ok" => false,
              "error_code" => 404,
              "description" => "Not Found: file not found"
            }))

          _ ->
            :counters.add(download_attempted, 1, 1)
            Plug.Conn.send_resp(conn, 200, "SHOULD_NOT_BE_REACHED")
        end
      end

      assert {:error, {404, "Not Found: file not found"}} =
               Media.download_file("non_existent_fid", token: @bot_token, plug: plug_fn)

      assert :counters.get(download_attempted, 1) == 0
    end

    test "get_file 401 Unauthorized returns {:error, :invalid_token}" do
      plug_fn = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, Jason.encode!(%{
          "ok" => false,
          "error_code" => 401,
          "description" => "Unauthorized"
        }))
      end

      assert {:error, :invalid_token} =
               Media.download_file("fid_unauth", token: "bad_token", plug: plug_fn)
    end

    test "get_file 500 Internal Server Error returns {:error, {500, message}}" do
      plug_fn = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{
          "ok" => false,
          "error_code" => 500,
          "description" => "Internal Server Error: Telegram crashed"
        }))
      end

      assert {:error, {500, "Internal Server Error: Telegram crashed"}} =
               Media.download_file("fid_500", token: @bot_token, plug: plug_fn)
    end

    test "get_file 429 Rate Limit returns {:error, {429, body}}" do
      plug_fn = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{
          "ok" => false,
          "error_code" => 429,
          "description" => "Too Many Requests: retry after 10",
          "parameters" => %{"retry_after" => 10}
        }))
      end

      assert {:error, {429, body}} =
               Media.download_file("fid_429", token: @bot_token, plug: plug_fn, max_rate_limit_retries: 0)

      assert body["parameters"]["retry_after"] == 10
    end

    test "get_file network/transport error returns {:error, reason}" do
      plug_fn = fn conn ->
        Plug.Conn.send_resp(conn, 500, "Plain error")
      end

      assert {:error, {500, "Plain error"}} =
               Media.download_file("fid_transport", token: @bot_token, plug: plug_fn)
    end

    test "get_file returns unexpected JSON shape without file_path -> {:error, {:unexpected_response, ...}}" do
      plug_fn = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{
          "ok" => true,
          "result" => %{"file_id" => "fid_no_path", "file_size" => 100}
        }))
      end

      assert {:error, {:unexpected_response, %{"ok" => true, "result" => %{"file_id" => "fid_no_path"}}}} =
               Media.download_file("fid_no_path", token: @bot_token, plug: plug_fn)
    end

    test "file download failure (404, 401, 500, 429) returns proper error" do
      # 1. 404 on file download
      plug_404 = fn conn ->
        case conn.request_path do
          "/bot" <> _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "ok" => true,
              "result" => %{"file_id" => "f1", "file_path" => "photos/expired.png"}
            }))

          "/file/bot" <> _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(404, Jason.encode!(%{
              "ok" => false,
              "error_code" => 404,
              "description" => "File expired or not found"
            }))
        end
      end

      assert {:error, {404, "File expired or not found"}} =
               Media.download_file("f1", token: @bot_token, plug: plug_404)

      # 2. 401 on file download
      plug_401 = fn conn ->
        case conn.request_path do
          "/bot" <> _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "ok" => true,
              "result" => %{"file_id" => "f2", "file_path" => "photos/p.png"}
            }))

          "/file/bot" <> _ ->
            Plug.Conn.send_resp(conn, 401, "Unauthorized")
        end
      end

      assert {:error, :invalid_token} =
               Media.download_file("f2", token: @bot_token, plug: plug_401)

      # 3. 429 on file download
      plug_429 = fn conn ->
        case conn.request_path do
          "/bot" <> _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{
              "ok" => true,
              "result" => %{"file_id" => "f3", "file_path" => "photos/p.png"}
            }))

          "/file/bot" <> _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(429, Jason.encode!(%{
              "ok" => false,
              "parameters" => %{"retry_after" => 7}
            }))
        end
      end

      assert {:error, {429, body}} =
               Media.download_file("f3", token: @bot_token, plug: plug_429, max_rate_limit_retries: 0)

      assert body["parameters"]["retry_after"] == 7
    end
  end

  describe "3. Option Precedence: Custom :plug vs Client Struct vs Application Env" do
    test "explicit :plug in opts overrides Client struct req_options plug" do
      client_plug_called = :counters.new(1, [:atomics])
      override_plug_called = :counters.new(1, [:atomics])

      client_plug = fn conn ->
        :counters.add(client_plug_called, 1, 1)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"source" => "client"}}))
      end

      override_plug = fn conn ->
        :counters.add(override_plug_called, 1, 1)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"source" => "override"}}))
      end

      client = Client.new(token: @bot_token, req_options: [plug: client_plug])

      assert {:ok, resp} = Client.request(client, :get, "/getMe", plug: override_plug)
      assert resp["result"]["source"] == "override"
      assert :counters.get(override_plug_called, 1) == 1
      assert :counters.get(client_plug_called, 1) == 0
    end

    test "Client struct req_options plug is used when opts does not specify :plug" do
      client_plug_called = :counters.new(1, [:atomics])

      client_plug = fn conn ->
        :counters.add(client_plug_called, 1, 1)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"source" => "client_struct"}}))
      end

      client = Client.new(token: @bot_token, req_options: [plug: client_plug])

      assert {:ok, resp} = Client.request(client, :get, "/getMe", [])
      assert resp["result"]["source"] == "client_struct"
      assert :counters.get(client_plug_called, 1) == 1
    end

    test "Application env :plug is used when neither client struct nor opts specify :plug" do
      app_env_plug_called = :counters.new(1, [:atomics])

      app_env_plug = fn conn ->
        :counters.add(app_env_plug_called, 1, 1)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => %{"source" => "app_env"}}))
      end

      prev_env_client = Application.get_env(:lux, Lux.Telegram.Client)
      prev_env_integ = Application.get_env(:lux, Lux.Integrations.Telegram.Client)

      Application.put_env(:lux, Lux.Telegram.Client, plug: app_env_plug)
      Application.put_env(:lux, Lux.Integrations.Telegram.Client, plug: app_env_plug)

      try do
        client = Client.new(@bot_token)
        assert {:ok, resp} = Client.request(client, :get, "/getMe")
        assert resp["result"]["source"] == "app_env"
        assert :counters.get(app_env_plug_called, 1) == 1
      after
        if prev_env_client, do: Application.put_env(:lux, Lux.Telegram.Client, prev_env_client), else: Application.delete_env(:lux, Lux.Telegram.Client)
        if prev_env_integ, do: Application.put_env(:lux, Lux.Integrations.Telegram.Client, prev_env_integ), else: Application.delete_env(:lux, Lux.Integrations.Telegram.Client)
      end
    end

    test "in download_file/2, explicit :plug in opts overrides Application env" do
      app_env_plug_called = :counters.new(1, [:atomics])
      opts_plug_called = :counters.new(1, [:atomics])

      app_env_plug = fn conn ->
        :counters.add(app_env_plug_called, 1, 1)
        Plug.Conn.send_resp(conn, 200, "APP_ENV_DOWNLOAD")
      end

      opts_plug = fn conn ->
        :counters.add(opts_plug_called, 1, 1)
        Plug.Conn.send_resp(conn, 200, "OPTS_DOWNLOAD")
      end

      prev_env_client = Application.get_env(:lux, Lux.Telegram.Client)
      prev_env_integ = Application.get_env(:lux, Lux.Integrations.Telegram.Client)

      Application.put_env(:lux, Lux.Telegram.Client, plug: app_env_plug)
      Application.put_env(:lux, Lux.Integrations.Telegram.Client, plug: app_env_plug)

      try do
        assert {:ok, "OPTS_DOWNLOAD"} =
                 Media.download_file("file/test.png", token: @bot_token, plug: opts_plug)

        assert :counters.get(opts_plug_called, 1) == 1
        assert :counters.get(app_env_plug_called, 1) == 0
      after
        if prev_env_client, do: Application.put_env(:lux, Lux.Telegram.Client, prev_env_client), else: Application.delete_env(:lux, Lux.Telegram.Client)
        if prev_env_integ, do: Application.put_env(:lux, Lux.Integrations.Telegram.Client, prev_env_integ), else: Application.delete_env(:lux, Lux.Integrations.Telegram.Client)
      end
    end
  end

  describe "4. Adversarial & Edge Case Stress Testing" do
    test "concurrent downloads under load do not cross-talk or leak connections" do
      total_downloads = 50

      results =
        1..total_downloads
        |> Task.async_stream(
          fn i ->
            plug = fn conn ->
              assert conn.request_path == "/file/bot#{@bot_token}/photos/img_#{i}.png"
              Plug.Conn.send_resp(conn, 200, "IMG_PAYLOAD_#{i}")
            end

            Media.download_file("photos/img_#{i}.png", token: @bot_token, plug: plug)
          end,
          max_concurrency: 10
        )
        |> Enum.to_list()

      for {{:ok, {:ok, payload}}, i} <- Enum.with_index(results, 1) do
        assert payload == "IMG_PAYLOAD_#{i}"
      end
    end

    test "download_file handles large payloads safely" do
      large_binary = :crypto.strong_rand_bytes(1024 * 1024) # 1 MB

      plug = fn conn ->
        assert conn.request_path == "/file/bot#{@bot_token}/documents/large.bin"
        Plug.Conn.send_resp(conn, 200, large_binary)
      end

      assert {:ok, downloaded} =
               Media.download_file("documents/large.bin", token: @bot_token, plug: plug)

      assert byte_size(downloaded) == 1024 * 1024
      assert downloaded == large_binary
    end
  end
end
