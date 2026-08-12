defmodule Lux.Integrations.RateLimitMiddlewareTest do
  use UnitAPICase, async: true

  alias Lux.Telegram.Middleware.RateLimit
  alias Lux.Telegram.Middleware.Retry

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "Lux.Telegram.Middleware.RateLimit" do
    test "extracts retry_after from response body" do
      response = %Req.Response{
        status: 429,
        body: %{"parameters" => %{"retry_after" => 5}}
      }

      assert RateLimit.extract_retry_after(response) == 5
    end

    test "extracts retry_after from Retry-After header" do
      response = %Req.Response{
        status: 429,
        headers: %{"retry-after" => ["12"]},
        body: %{}
      }

      assert RateLimit.extract_retry_after(response) == 12
    end

    test "retries request on HTTP 429 status code up to max_rate_limit_retries" do
      test_process = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.expect(TelegramClientMock, 2, fn conn ->
        send(test_process, :attempt)
        count = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

        if count > 1 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => "success"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(429, Jason.encode!(%{
            "ok" => false,
            "error_code" => 429,
            "parameters" => %{"retry_after" => 1}
          }))
        end
      end)

      {:ok, response} =
        Lux.Integrations.Telegram.Client.request(:get, "/getMe", %{
          token: "test_token",
          sleep_fun: fn _ms -> :ok end,
          max_rate_limit_retries: 2
        })

      assert response["ok"] == true
      assert response["result"] == "success"
      assert_receive :attempt
      assert_receive :attempt
    end
  end

  describe "Lux.Telegram.Middleware.Retry" do
    test "identifies retryable responses and errors" do
      assert Retry.retryable?(%Req.Response{status: 500}) == true
      assert Retry.retryable?(%Req.Response{status: 502}) == true
      assert Retry.retryable?(%Req.Response{status: 503}) == true
      assert Retry.retryable?(%Req.Response{status: 200}) == false
      assert Retry.retryable?(%Req.Response{status: 404}) == false
      assert Retry.retryable?(%Req.TransportError{reason: :econnrefused}) == true
    end

    test "calculates exponential backoff delay correctly" do
      assert Retry.calculate_backoff(100, 2, 0, 5000) == 100
      assert Retry.calculate_backoff(100, 2, 1, 5000) == 200
      assert Retry.calculate_backoff(100, 2, 2, 5000) == 400
      assert Retry.calculate_backoff(100, 2, 10, 5000) == 5000
    end

    test "retries request on HTTP 5xx status code with exponential backoff" do
      test_process = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.expect(TelegramClientMock, 2, fn conn ->
        send(test_process, :attempt)
        count = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

        if count > 1 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => "recovered"}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(502, Jason.encode!(%{
            "ok" => false,
            "description" => "Bad Gateway"
          }))
        end
      end)

      {:ok, response} =
        Lux.Integrations.Telegram.Client.request(:get, "/getMe", %{
          token: "test_token",
          sleep_fun: fn _ms -> :ok end,
          max_retries: 2
        })

      assert response["ok"] == true
      assert response["result"] == "recovered"
      assert_receive :attempt
      assert_receive :attempt
    end
  end
end
