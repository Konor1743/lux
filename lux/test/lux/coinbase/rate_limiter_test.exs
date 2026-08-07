defmodule Lux.Coinbase.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Lux.Coinbase.Client
  alias Lux.Coinbase.RateLimiter

  setup do
    RateLimiter.reset()
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "GenServer & ETS Table Initialization" do
    test "creates and manages ETS table :lux_coinbase_rate_limiter" do
      assert :ets.whereis(:lux_coinbase_rate_limiter) != :undefined
      assert RateLimiter.get_limit() == 0
      assert RateLimiter.get_remaining_quota() == 0
      assert RateLimiter.get_reset_timestamp() == 0
      assert RateLimiter.get_backoff_until() == 0
      assert RateLimiter.get_consecutive_429s() == 0
    end

    test "reset/0 resets ETS table values to 0" do
      headers = [
        {"cb-ratelimit-limit", "100"},
        {"cb-ratelimit-remaining", "50"},
        {"cb-ratelimit-reset", "1754582600"}
      ]

      RateLimiter.record_response(headers, 200)
      assert RateLimiter.get_remaining_quota() == 50

      RateLimiter.reset()
      assert RateLimiter.get_limit() == 0
      assert RateLimiter.get_remaining_quota() == 0
      assert RateLimiter.get_reset_timestamp() == 0
      assert RateLimiter.get_backoff_until() == 0
      assert RateLimiter.get_consecutive_429s() == 0
    end
  end

  describe "Quota Headers Tracking (cb-ratelimit-*)" do
    test "records quota metrics from list of tuples" do
      headers = [
        {"cb-ratelimit-limit", "30"},
        {"cb-ratelimit-remaining", "25"},
        {"cb-ratelimit-reset", "1754582600"}
      ]

      RateLimiter.record_response(headers, 200)

      assert RateLimiter.get_limit() == 30
      assert RateLimiter.get_remaining_quota() == 25
      assert RateLimiter.get_reset_timestamp() == 1_754_582_600
    end

    test "records quota metrics with mixed case headers" do
      headers = [
        {"CB-RATELIMIT-LIMIT", "50"},
        {"CB-RATELIMIT-REMAINING", "10"},
        {"CB-RATELIMIT-RESET", "1754589999"}
      ]

      RateLimiter.record_response(headers, 200)

      assert RateLimiter.get_limit() == 50
      assert RateLimiter.get_remaining_quota() == 10
      assert RateLimiter.get_reset_timestamp() == 1_754_589_999
    end

    test "handles map of headers" do
      headers = %{
        "cb-ratelimit-limit" => "60",
        "cb-ratelimit-remaining" => "40",
        "cb-ratelimit-reset" => "1800000000"
      }

      RateLimiter.record_response(headers, 200)

      assert RateLimiter.get_limit() == 60
      assert RateLimiter.get_remaining_quota() == 40
      assert RateLimiter.get_reset_timestamp() == 1_800_000_000
    end
  end

  describe "HTTP 429 & Exponential Backoff Calculation" do
    test "initially check_rate_limit/0 returns :ok" do
      assert RateLimiter.check_rate_limit() == :ok
    end

    test "handles 429 response with retry-after header and records backoff_until" do
      headers = [{"retry-after", "10"}, {"cb-ratelimit-remaining", "0"}]
      RateLimiter.record_response(headers, 429)

      assert {:error, {:rate_limited, wait_ms}} = RateLimiter.check_rate_limit()
      assert wait_ms > 0 and wait_ms <= 10_000
      assert RateLimiter.get_consecutive_429s() == 1
    end

    test "calculates exponential backoff on consecutive 429 responses" do
      headers = [{"retry-after", "2"}]

      # First 429 hit -> base wait 2s (2 * 2^0) = 2s
      RateLimiter.record_response(headers, 429)
      assert RateLimiter.get_consecutive_429s() == 1
      assert {:error, {:rate_limited, wait1}} = RateLimiter.check_rate_limit()
      assert wait1 > 0 and wait1 <= 2000

      # Second consecutive 429 hit -> 2 * 2^1 = 4s wait
      RateLimiter.record_response(headers, 429)
      assert RateLimiter.get_consecutive_429s() == 2
      assert {:error, {:rate_limited, wait2}} = RateLimiter.check_rate_limit()
      assert wait2 > 2000 and wait2 <= 4000

      # Third consecutive 429 hit -> 2 * 2^2 = 8s wait
      RateLimiter.record_response(headers, 429)
      assert RateLimiter.get_consecutive_429s() == 3
      assert {:error, {:rate_limited, wait3}} = RateLimiter.check_rate_limit()
      assert wait3 > 4000 and wait3 <= 8000
    end

    test "resets consecutive 429 count on successful HTTP 200 response" do
      headers = [{"retry-after", "5"}]
      RateLimiter.record_response(headers, 429)
      assert RateLimiter.get_consecutive_429s() == 1

      RateLimiter.record_response([], 200)
      assert RateLimiter.get_consecutive_429s() == 0
    end
  end

  describe "Req Middleware Attach & Request Delaying via Req.Test" do
    test "attaches pre and post steps to Req request" do
      req = Req.new()
      attached = RateLimiter.attach(req)
      refute req == attached
    end

    test "delays request execution when rate limit backoff is active" do
      headers = [{"retry-after", "1"}]
      RateLimiter.record_response(headers, 429)

      Req.Test.expect(Lux.Coinbase.RateLimiterTest, fn conn ->
        Req.Test.json(conn, %{"products" => []})
      end)

      t0 = System.system_time(:millisecond)

      opts = [
        req_options: [
          plug: {Req.Test, Lux.Coinbase.RateLimiterTest},
          retry_delay_multiplier: 0.1
        ]
      ]

      assert {:ok, %{"products" => []}} =
               Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)

      t1 = System.system_time(:millisecond)
      # With 1 sec retry-after and 0.1 multiplier, sleep is ~100ms
      assert t1 - t0 >= 80
    end

    test "halts request immediately with 429 when coinbase_auto_backoff is false" do
      headers = [{"retry-after", "10"}]
      RateLimiter.record_response(headers, 429)

      opts = [
        req_options: [
          coinbase_auto_backoff: false,
          plug: {Req.Test, Lux.Coinbase.RateLimiterTest}
        ]
      ]

      assert {:error, %{status: 429, body: %{"message" => "Rate limit backoff active"}}} =
               Client.request(:get, "/api/v3/brokerage/market/products", %{}, opts)
    end
  end
end
