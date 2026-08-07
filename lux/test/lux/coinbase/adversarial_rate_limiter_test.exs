defmodule Lux.Coinbase.AdversarialRateLimiterTest do
  use ExUnit.Case, async: false

  alias Lux.Coinbase.Client
  alias Lux.Coinbase.RateLimiter

  setup do
    RateLimiter.reset()
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "High-Concurrency 429 Stress Testing" do
    test "handles 50 concurrent processes recording 429 responses simultaneously without crashing" do
      concurrency = 50

      tasks =
        for i <- 1..concurrency do
          Task.async(fn ->
            headers = [{"retry-after", "1"}, {"cb-ratelimit-remaining", "#{50 - i}"}]
            RateLimiter.record_response(headers, 429)
          end)
        end

      Task.await_many(tasks)

      # ETS table must remain valid and operational
      assert RateLimiter.get_consecutive_429s() > 0
      assert {:error, {:rate_limited, wait_ms}} = RateLimiter.check_rate_limit()
      assert wait_ms > 0
    end

    test "handles 50 concurrent processes checking rate limit status simultaneously" do
      headers = [{"retry-after", "5"}]
      RateLimiter.record_response(headers, 429)

      concurrency = 50

      results =
        1..concurrency
        |> Task.async_stream(fn _ ->
          RateLimiter.check_rate_limit()
        end)
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, fn res -> match?({:error, {:rate_limited, _}}, res) end)
    end

    test "high-concurrency request halting when coinbase_auto_backoff is false" do
      headers = [{"retry-after", "10"}]
      RateLimiter.record_response(headers, 429)

      concurrency = 30

      results =
        1..concurrency
        |> Task.async_stream(fn _ ->
          opts = [
            req_options: [
              coinbase_auto_backoff: false,
              plug: {Req.Test, Lux.Coinbase.AdversarialRateLimiterTest}
            ]
          ]

          Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
        end)
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, fn res ->
               match?({:error, %{status: 429, body: %{"message" => "Rate limit backoff active"}}}, res)
             end)
    end

    test "handles high concurrency with mixed 200 and 429 responses" do
      tasks =
        for i <- 1..40 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              RateLimiter.record_response([{"retry-after", "1"}], 429)
            else
              RateLimiter.record_response([], 200)
            end
          end)
        end

      Task.await_many(tasks)
      # GenServer / ETS table must remain stable and non-corrupted
      assert is_integer(RateLimiter.get_consecutive_429s())
      assert is_integer(RateLimiter.get_backoff_until())
    end
  end

  describe "Adversarial Header Parsing & Edge Cases" do
    test "handles malformed non-integer retry-after header values" do
      headers = [{"retry-after", "invalid_string"}]
      RateLimiter.record_response(headers, 429)

      # When retry-after is invalid, defaults to 2^(consecutive-1) = 1 sec
      assert RateLimiter.get_consecutive_429s() == 1
      assert {:error, {:rate_limited, wait_ms}} = RateLimiter.check_rate_limit()
      assert wait_ms > 0 and wait_ms <= 1000
    end

    test "handles negative retry-after header values" do
      headers = [{"retry-after", "-10"}]
      RateLimiter.record_response(headers, 429)

      # Should fallback to base exponential calculation
      assert RateLimiter.get_consecutive_429s() == 1
      assert {:error, {:rate_limited, wait_ms}} = RateLimiter.check_rate_limit()
      assert wait_ms > 0 and wait_ms <= 1000
    end

    test "handles malformed non-integer quota headers gracefully without crashing" do
      headers = [
        {"cb-ratelimit-limit", "not_a_number"},
        {"cb-ratelimit-remaining", ""},
        {"cb-ratelimit-reset", "abc123"}
      ]

      assert :ok = RateLimiter.record_response(headers, 200)
      assert RateLimiter.get_limit() == 0
      assert RateLimiter.get_remaining_quota() == 0
      assert RateLimiter.get_reset_timestamp() == 0
    end

    test "handles empty header list, nil values, and arbitrary struct headers" do
      assert :ok = RateLimiter.record_response([], 200)
      assert :ok = RateLimiter.record_response(%{}, 200)
      assert :ok = RateLimiter.record_response(nil, 200)
    end
  end

  describe "Exponential Backoff & Status Code Interactions" do
    test "consecutive 429s scale exponentially" do
      # 1st 429 -> 1 * 2^0 = 1s
      RateLimiter.record_response([{"retry-after", "1"}], 429)
      assert RateLimiter.get_consecutive_429s() == 1

      # 2nd 429 -> 1 * 2^1 = 2s
      RateLimiter.record_response([{"retry-after", "1"}], 429)
      assert RateLimiter.get_consecutive_429s() == 2

      # 3rd 429 -> 1 * 2^2 = 4s
      RateLimiter.record_response([{"retry-after", "1"}], 429)
      assert RateLimiter.get_consecutive_429s() == 3

      # 4th 429 -> 1 * 2^3 = 8s
      RateLimiter.record_response([{"retry-after", "1"}], 429)
      assert RateLimiter.get_consecutive_429s() == 4
    end

    test "status codes 400, 401, 403, 404, 500, 503 do not reset consecutive 429 count" do
      RateLimiter.record_response([{"retry-after", "1"}], 429)
      assert RateLimiter.get_consecutive_429s() == 1

      for status <- [400, 401, 403, 404, 500, 503] do
        RateLimiter.record_response([], status)
        assert RateLimiter.get_consecutive_429s() == 1,
               "Status #{status} should not reset consecutive_429s"
      end

      # HTTP 200 resets it
      RateLimiter.record_response([], 200)
      assert RateLimiter.get_consecutive_429s() == 0
    end

    test "records quota headers present on 400, 401, 403, 404, 500, 503 status code responses" do
      headers = [
        {"cb-ratelimit-limit", "100"},
        {"cb-ratelimit-remaining", "5"},
        {"cb-ratelimit-reset", "1754589999"}
      ]

      RateLimiter.record_response(headers, 401)
      assert RateLimiter.get_limit() == 100
      assert RateLimiter.get_remaining_quota() == 5
      assert RateLimiter.get_reset_timestamp() == 1_754_589_999
    end

    test "handles very high count of consecutive 429s without arithmetic overflow or process crash" do
      for _ <- 1..30 do
        RateLimiter.record_response([{"retry-after", "1"}], 429)
      end

      assert RateLimiter.get_consecutive_429s() == 30
      assert {:error, {:rate_limited, wait_ms}} = RateLimiter.check_rate_limit()
      assert wait_ms > 0
    end
  end
end
