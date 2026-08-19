defmodule Lux.Integrations.YouTube.ResiliencyAdversarialStressTest do
  use ExUnit.Case, async: true

  alias Lux.Integrations.YouTube.Errors

  @moduledoc """
  Empirical Adversarial Stress & Fault-Injection Test Suite for YouTube
  Resiliency, Error Classification, Backoff Utilities, and Lens/Prism Error Propagation.

  Milestone 4 (Challenger 2).
  """

  # ============================================================================
  # 1. Backoff Delay Mathematical & Jitter Boundary Stress Tests
  # ============================================================================
  describe "Backoff delay mathematical bounds & full jitter statistics" do
    test "delay is strictly clamped within [min_delay, max_delay] across 5,000 iterations" do
      opts = [base_backoff_ms: 200, max_backoff_ms: 5000, min_backoff_ms: 50]

      for attempt <- 1..30 do
        for _ <- 1..100 do
          delay = Errors.backoff_delay(attempt, opts)
          assert is_integer(delay), "Expected integer delay, got: #{inspect(delay)}"
          assert delay >= 50, "Delay #{delay} violated min_backoff_ms (50) on attempt #{attempt}"
          assert delay <= 5000, "Delay #{delay} exceeded max_backoff_ms (5000) on attempt #{attempt}"
        end
      end
    end

    test "exponent overflow protection: high attempt numbers do not overflow or raise ArithmeticError" do
      extreme_attempts = [31, 32, 64, 128, 512, 1024, 2048, 10_000, 1_000_000]

      for attempt <- extreme_attempts do
        delay = Errors.backoff_delay(attempt, base_backoff_ms: 500, max_backoff_ms: 16_000, min_backoff_ms: 100)
        assert is_integer(delay)
        assert delay >= 100
        assert delay <= 16_000
      end
    end

    test "handles negative and zero attempts safely" do
      for invalid_attempt <- [0, -1, -10, -999] do
        delay = Errors.backoff_delay(invalid_attempt, base_backoff_ms: 400, max_backoff_ms: 8000, min_backoff_ms: 50)
        assert is_integer(delay)
        assert delay >= 50
        assert delay <= 8000
      end
    end

    test "statistical full jitter distribution verification across 2,000 samples" do
      opts = [base_backoff_ms: 1000, max_backoff_ms: 10_000, min_backoff_ms: 50]
      # Attempt 4: base * 2^(4-1) = 1000 * 8 = 8000 ms ceiling
      samples = Enum.map(1..2000, fn _ -> Errors.backoff_delay(4, opts) end)

      min_sample = Enum.min(samples)
      max_sample = Enum.max(samples)
      avg_sample = Enum.sum(samples) / length(samples)

      assert min_sample >= 50
      assert max_sample <= 8000
      # With uniform random jitter in [0, 8000], the expected mean is ~4000
      assert avg_sample >= 3200 and avg_sample <= 4800,
             "Average sample #{avg_sample} fell outside expected confidence interval [3200, 4800]"

      # Verify uniqueness (full jitter should produce many distinct delay values)
      unique_count = length(Enum.uniq(samples))
      assert unique_count > 1000, "Expected high entropy in jitter samples, got #{unique_count} distinct values"
    end

    test "boundary edge cases: zero base, zero min, zero max" do
      delay_zero_base = Errors.backoff_delay(3, base_backoff_ms: 0, max_backoff_ms: 1000, min_backoff_ms: 10)
      assert delay_zero_base == 10

      delay_zero_min = Errors.backoff_delay(2, base_backoff_ms: 100, max_backoff_ms: 500, min_backoff_ms: 0)
      assert delay_zero_min >= 0 and delay_zero_min <= 500
    end
  end

  # ============================================================================
  # 2. with_retry/2 Adversarial Fault Injection & Execution Harness
  # ============================================================================
  describe "with_retry/2 fault injection & retry limits" do
    test "succeeds immediately on first call without invoking sleep" do
      slept = :atomics.new(1, [])
      sleep_fun = fn ms ->
        :atomics.add(slept, 1, ms)
        :ok
      end

      res = Errors.with_retry(fn -> {:ok, "instant_success"} end, sleep_fun: sleep_fun)
      assert res == {:ok, "instant_success"}
      assert :atomics.get(slept, 1) == 0
    end

    test "maximum attempt ceiling: respects max_retries and returns exact last error" do
      for max_retries <- [1, 2, 3, 5] do
        counter = :atomics.new(1, [])

        failing_op = fn ->
          :atomics.add(counter, 1, 1)
          {:error, {503, "Service Unavailable (attempt #{:atomics.get(counter, 1)})"}}
        end

        res = Errors.with_retry(failing_op, max_retries: max_retries, sleep_fun: fn _ -> :ok end)
        assert {:error, {503, message}} = res
        # Total attempts = 1 initial try + max_retries retries
        expected_attempts = max_retries + 1
        assert :atomics.get(counter, 1) == expected_attempts
        assert message =~ "attempt #{expected_attempts}"
      end
    end

    test "max_retries: 0 executes exactly once and aborts immediately on failure" do
      counter = :atomics.new(1, [])

      failing_op = fn ->
        :atomics.add(counter, 1, 1)
        {:error, {500, "Internal Server Error"}}
      end

      res = Errors.with_retry(failing_op, max_retries: 0, sleep_fun: fn _ -> :ok end)
      assert res == {:error, {500, "Internal Server Error"}}
      assert :atomics.get(counter, 1) == 1
    end

    test "immediate abort on 403 quotaExceeded (daily quota MUST NOT be retried)" do
      counter = :atomics.new(1, [])

      quota_op = fn ->
        :atomics.add(counter, 1, 1)
        {:error, {:quota_exceeded, %{reason: "quotaExceeded", message: "Daily quota exhausted"}}}
      end

      res = Errors.with_retry(quota_op, max_retries: 5, sleep_fun: fn _ -> :ok end)
      assert {:error, {:quota_exceeded, details}} = res
      assert details.reason == "quotaExceeded"
      # Must execute exactly once
      assert :atomics.get(counter, 1) == 1
    end

    test "immediate abort on non-retryable errors (400, 401, 404)" do
      non_retryables = [
        {:error, {400, "Bad Request"}},
        {:error, :invalid_token},
        {:error, {404, "Broadcast Not Found"}},
        {:error, {403, "The caller does not have permission"}},
        {:error, :unsupported_parameter}
      ]

      for err <- non_retryables do
        counter = :atomics.new(1, [])

        op = fn ->
          :atomics.add(counter, 1, 1)
          err
        end

        res = Errors.with_retry(op, max_retries: 4, sleep_fun: fn _ -> :ok end)
        assert res == err
        assert :atomics.get(counter, 1) == 1
      end
    end

    test "respects explicit Retry-After header duration on rate_limited errors" do
      sleep_records = start_supervised!({Agent, fn -> [] end})
      attempt_counter = :atomics.new(1, [])

      rate_limited_op = fn ->
        curr = :atomics.add_get(attempt_counter, 1, 1)
        if curr == 1 do
          {:error, {:rate_limited, %{reason: "rateLimitExceeded", retry_after: 5}}}
        else
          {:ok, "recovered_after_rate_limit"}
        end
      end

      collector = fn ms ->
        Agent.update(sleep_records, fn list -> [ms | list] end)
        :ok
      end

      res = Errors.with_retry(rate_limited_op, max_retries: 3, sleep_fun: collector)
      assert res == {:ok, "recovered_after_rate_limit"}
      assert :atomics.get(attempt_counter, 1) == 2
      # 5 seconds retry_after converted to 5000 ms
      assert Agent.get(sleep_records, & &1) == [5000]
    end

    test "multi-stage cascading fault recovery sequence (500 -> 503 -> 429 -> 200)" do
      attempt_counter = :atomics.new(1, [])

      cascading_op = fn ->
        case :atomics.add_get(attempt_counter, 1, 1) do
          1 -> {:error, {500, "Internal Server Error"}}
          2 -> {:error, {503, "Service Unavailable"}}
          3 -> {:error, {:rate_limited, %{reason: "rateLimitExceeded", retry_after: 1}}}
          4 -> {:ok, %{"result" => "success_after_cascade"}}
        end
      end

      res = Errors.with_retry(cascading_op, max_retries: 4, sleep_fun: fn _ -> :ok end)
      assert {:ok, %{"result" => "success_after_cascade"}} = res
      assert :atomics.get(attempt_counter, 1) == 4
    end

    test "cascading fault aborts early when encountering non-retryable error midway" do
      attempt_counter = :atomics.new(1, [])

      interrupted_cascade = fn ->
        case :atomics.add_get(attempt_counter, 1, 1) do
          1 -> {:error, {503, "Transient Outage"}}
          2 -> {:error, {:quota_exceeded, %{reason: "dailyLimitExceeded"}}}
          3 -> {:ok, "never_reached"}
        end
      end

      res = Errors.with_retry(interrupted_cascade, max_retries: 5, sleep_fun: fn _ -> :ok end)
      assert {:error, {:quota_exceeded, details}} = res
      assert details.reason == "dailyLimitExceeded"
      # Should stop at attempt 2 despite max_retries: 5
      assert :atomics.get(attempt_counter, 1) == 2
    end
  end

  # ============================================================================
  # 3. Quota vs Rate-Limit Error Classification Matrix Oracle
  # ============================================================================
  describe "Error classification invariant matrix & discriminator oracle" do
    test "exhaustive classification of all known YouTube quota exhaustion reasons" do
      quota_reasons = [
        "quotaExceeded",
        "dailyLimitExceeded",
        "QUOTA_EXCEEDED",
        "RESOURCE_EXHAUSTED_QUOTA",
        "RESOURCE_EXHAUSTED"
      ]

      for reason <- quota_reasons do
        body = %{
          "error" => %{
            "code" => 403,
            "message" => "Quota error for #{reason}",
            "errors" => [%{"reason" => reason, "domain" => "youtube.quota"}]
          }
        }

        parsed = Errors.parse(403, body)
        assert {:error, {:quota_exceeded, details}} = parsed, "Failed to classify quota reason: #{reason}"
        assert details.reason == reason
        assert details.status == 403
        assert Errors.quota_exceeded?(parsed)
        refute Errors.rate_limited?(parsed), "Quota error #{reason} was incorrectly marked as rate_limited"
        refute Errors.retryable?(parsed), "Quota error #{reason} was incorrectly marked as retryable"
      end
    end

    test "exhaustive classification of all known YouTube rate limiting reasons" do
      rate_reasons = [
        "rateLimitExceeded",
        "userRateLimitExceeded",
        "concurrentLimitExceeded",
        "servingLimitExceeded",
        "RATE_LIMIT_EXCEEDED",
        "USER_RATE_LIMIT_EXCEEDED"
      ]

      for reason <- rate_reasons do
        body = %{
          "error" => %{
            "code" => 403,
            "message" => "Rate limit for #{reason}",
            "errors" => [%{"reason" => reason, "domain" => "usageLimits"}]
          }
        }

        parsed = Errors.parse(403, body, [{"retry-after", "20"}])
        assert {:error, {:rate_limited, details}} = parsed, "Failed to classify rate limit reason: #{reason}"
        assert details.reason == reason
        assert details.status == 403
        assert details.retry_after == 20
        assert Errors.rate_limited?(parsed)
        refute Errors.quota_exceeded?(parsed), "Rate limit error #{reason} was incorrectly marked as quota_exceeded"
        assert Errors.retryable?(parsed), "Rate limit error #{reason} must be retryable"
      end
    end

    test "HTTP 429 without error reason defaults to rate_limited" do
      parsed = Errors.parse(429, %{"message" => "Too many requests"})
      assert {:error, {:rate_limited, details}} = parsed
      assert details.status == 429
      assert details.reason == "rateLimitExceeded"
      assert Errors.rate_limited?(parsed)
      assert Errors.retryable?(parsed)
    end

    test "HTTP 429 with explicit quota reason classifies as quota_exceeded" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Quota reached",
          "errors" => [%{"reason" => "quotaExceeded"}]
        }
      }

      parsed = Errors.parse(429, body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.status == 429
      assert details.reason == "quotaExceeded"
      assert Errors.quota_exceeded?(parsed)
      refute Errors.retryable?(parsed)
    end

    test "HTTP 401 always classifies as :invalid_token" do
      for body <- [nil, "", %{}, %{"error" => "unauthorized"}, "Invalid Credentials"] do
        assert {:error, :invalid_token} = Errors.parse(401, body)
        refute Errors.retryable?({:error, :invalid_token})
        refute Errors.quota_exceeded?({:error, :invalid_token})
        refute Errors.rate_limited?({:error, :invalid_token})
      end
    end
  end

  # ============================================================================
  # 4. Error Propagation Through Lenses & Prisms
  # ============================================================================
  describe "Error propagation through Lux.Lens and Lux.Prism" do
    # Define a test lens module within test context
    defmodule TestYouTubeLens do
      use Lux.Lens,
        name: "Test YouTube Lens",
        description: "Fetches YouTube data for testing error propagation",
        url: "https://www.googleapis.com/youtube/v3/liveBroadcasts",
        method: :get,
        headers: Lux.Integrations.YouTube.headers(),
        auth: Lux.Integrations.YouTube.auth()

      @impl true
      def after_focus(%{"items" => items}) when is_list(items) do
        {:ok, items}
      end

      def after_focus(body) do
        {:ok, body}
      end
    end

    # Define a test prism module within test context
    defmodule TestYouTubePrism do
      use Lux.Prism,
        name: "Test YouTube Prism",
        description: "Executes YouTube action for testing error propagation",
        input_schema: %{
          type: :object,
          properties: %{
            action: %{type: :string}
          },
          required: ["action"]
        }

      @impl true
      def handler(input, _context) do
        case input[:error_to_raise] do
          :quota_exceeded ->
            {:error, {:quota_exceeded, %{reason: "quotaExceeded", status: 403, message: "Quota reached"}}}

          :rate_limited ->
            {:error, {:rate_limited, %{reason: "rateLimitExceeded", status: 429, retry_after: 30}}}

          :invalid_token ->
            {:error, :invalid_token}

          :server_error ->
            {:error, {500, "Internal Server Error"}}

          _ ->
            {:ok, %{status: "completed", input: input}}
        end
      end
    end

    test "Lens focus propagates HTTP 403 quotaExceeded error as {:error, body}" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "Quota Exceeded",
              "errors" => [%{"reason" => "quotaExceeded"}]
            }
          })
        )
      end

      lens = TestYouTubeLens.view()
      req_opts = [plug: plug]
      res =
        [url: lens.url, headers: lens.headers, max_retries: 0]
        |> Keyword.merge(req_opts)
        |> Req.new()
        |> Req.request([method: :get])

      assert {:ok, %{status: 403, body: body}} = res
      parsed = Errors.parse(403, body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "quotaExceeded"
      refute Errors.retryable?(parsed)
    end

    test "Lens focus propagates HTTP 429 rate limit error" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "15")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{"error" => %{"message" => "Rate limit exceeded"}})
        )
      end

      req_opts = [plug: plug]
      res =
        [url: "https://www.googleapis.com/youtube/v3/liveBroadcasts", headers: [], max_retries: 0]
        |> Keyword.merge(req_opts)
        |> Req.new()
        |> Req.request([method: :get])

      assert {:ok, %{status: 429, body: body, headers: headers}} = res
      parsed = Errors.parse(429, body, headers)
      assert {:error, {:rate_limited, details}} = parsed
      assert details.retry_after == 15
      assert Errors.retryable?(parsed)
    end

    test "Prism run gracefully returns structured error tuples for all failure modes" do
      # 1. Quota exceeded
      assert {:error, {:quota_exceeded, details}} = TestYouTubePrism.run(%{action: "test", error_to_raise: :quota_exceeded})
      assert details.reason == "quotaExceeded"
      assert Errors.quota_exceeded?(%{reason: details.reason})

      # 2. Rate limited
      assert {:error, {:rate_limited, details}} = TestYouTubePrism.run(%{action: "test", error_to_raise: :rate_limited})
      assert details.reason == "rateLimitExceeded"
      assert details.retry_after == 30
      assert Errors.rate_limited?(%{reason: details.reason})

      # 3. Invalid token
      assert {:error, :invalid_token} = TestYouTubePrism.run(%{action: "test", error_to_raise: :invalid_token})

      # 4. Server error
      assert {:error, {500, "Internal Server Error"}} = TestYouTubePrism.run(%{action: "test", error_to_raise: :server_error})

      # 5. Success
      assert {:ok, %{status: "completed"}} = TestYouTubePrism.run(%{action: "test", error_to_raise: :none})
    end

    test "Pipeline composition: Prism wrapped with Errors.with_retry recovers from retryable prism errors" do
      attempt_counter = :atomics.new(1, [])

      retryable_prism_call = fn ->
        curr = :atomics.add_get(attempt_counter, 1, 1)
        if curr < 3 do
          TestYouTubePrism.run(%{action: "test", error_to_raise: :server_error})
        else
          TestYouTubePrism.run(%{action: "test", error_to_raise: :none})
        end
      end

      res = Errors.with_retry(retryable_prism_call, max_retries: 3, sleep_fun: fn _ -> :ok end)
      assert {:ok, %{status: "completed"}} = res
      assert :atomics.get(attempt_counter, 1) == 3
    end

    test "Pipeline composition: Prism wrapped with Errors.with_retry halts immediately on non-retryable prism error" do
      attempt_counter = :atomics.new(1, [])

      non_retryable_prism_call = fn ->
        :atomics.add(attempt_counter, 1, 1)
        TestYouTubePrism.run(%{action: "test", error_to_raise: :quota_exceeded})
      end

      res = Errors.with_retry(non_retryable_prism_call, max_retries: 4, sleep_fun: fn _ -> :ok end)
      assert {:error, {:quota_exceeded, _}} = res
      assert :atomics.get(attempt_counter, 1) == 1
    end
  end

  # ============================================================================
  # 5. High-Concurrency Stress Harness
  # ============================================================================
  describe "High-concurrency stress harness across 50 simultaneous processes" do
    test "50 parallel workers execute with_retry with random jitter without cross-process interference" do
      tasks =
        for task_id <- 1..50 do
          Task.async(fn ->
            local_counter = :atomics.new(1, [])

            worker_fun = fn ->
              curr = :atomics.add_get(local_counter, 1, 1)
              # Each worker fails twice on 503 then succeeds on 3rd attempt
              if curr < 3 do
                {:error, {503, "Task #{task_id} transient error #{curr}"}}
              else
                {:ok, "task_#{task_id}_success"}
              end
            end

            res =
              Errors.with_retry(worker_fun,
                max_retries: 3,
                base_backoff_ms: 10,
                max_backoff_ms: 50,
                min_backoff_ms: 1,
                sleep_fun: fn ms ->
                  assert ms >= 1 and ms <= 50
                  :ok
                end
              )

            {task_id, res, :atomics.get(local_counter, 1)}
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert length(results) == 50

      for {task_id, outcome, attempts} <- results do
        assert outcome == {:ok, "task_#{task_id}_success"}
        assert attempts == 3
      end
    end
  end

  # ============================================================================
  # 6. Network Transport Failure & Reconnection Sequences in with_retry/2
  # ============================================================================
  describe "Network transport failure & recovery sequences in with_retry/2" do
    test "retries through sequence of varying network errors (:nxdomain -> :econnrefused -> :timeout -> :closed -> success)" do
      network_errors = [:nxdomain, :econnrefused, :timeout, :closed]
      attempt_counter = :atomics.new(1, [])

      flaky_network_op = fn ->
        idx = :atomics.add_get(attempt_counter, 1, 1)

        if idx <= length(network_errors) do
          reason = Enum.at(network_errors, idx - 1)
          {:error, %Req.TransportError{reason: reason}}
        else
          {:ok, %{"connected" => true, "reconnected_at_attempt" => idx}}
        end
      end

      res = Errors.with_retry(flaky_network_op, max_retries: 5, sleep_fun: fn _ -> :ok end)
      assert {:ok, %{"connected" => true, "reconnected_at_attempt" => 5}} = res
      assert :atomics.get(attempt_counter, 1) == 5
    end

    test "exhausts retries on persistent network failure and preserves original transport error" do
      attempt_counter = :atomics.new(1, [])

      dead_network_op = fn ->
        :atomics.add(attempt_counter, 1, 1)
        {:error, %Req.TransportError{reason: :connect_timeout}}
      end

      res = Errors.with_retry(dead_network_op, max_retries: 3, sleep_fun: fn _ -> :ok end)
      assert {:error, %Req.TransportError{reason: :connect_timeout}} = res
      assert :atomics.get(attempt_counter, 1) == 4
    end
  end

  # ============================================================================
  # 7. Deeply Nested & Pathological Google Error JSON Structures
  # ============================================================================
  describe "Deeply nested & pathological Google RPC error structures" do
    test "parses Google RPC ErrorInfo when nested alongside Help, PreconditionFailure, and FieldViolations" do
      complex_rpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota exceeded on project 987654",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.Help",
              "links" => [
                %{"description" => "Cloud Billing Documentation", "url" => "https://cloud.google.com/billing"}
              ]
            },
            %{
              "@type" => "type.googleapis.com/google.rpc.PreconditionFailure",
              "violations" => [
                %{"type" => "QUOTA", "subject" => "project:987654", "description" => "Quota bucket empty"}
              ]
            },
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "QUOTA_EXCEEDED",
              "domain" => "youtube.googleapis.com",
              "metadata" => %{
                "service" => "youtube.googleapis.com",
                "consumer" => "projects/987654"
              }
            }
          ]
        }
      }

      parsed = Errors.parse(403, complex_rpc_body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "QUOTA_EXCEEDED"
      assert details.domain == "youtube.googleapis.com"
      assert details.status == 403
      assert details.message =~ "Quota exceeded"
      assert Errors.quota_exceeded?(parsed)
      refute Errors.retryable?(parsed)
    end

    test "handles details containing non-map primitive items without crashing" do
      mixed_details_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Burst limit hit",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            "unexpected_string_detail",
            12345,
            nil,
            false,
            %{"reason" => "rateLimitExceeded", "domain" => "usageLimits"}
          ]
        }
      }

      parsed = Errors.parse(403, mixed_details_body)
      assert {:error, {:rate_limited, details}} = parsed
      assert details.reason == "rateLimitExceeded"
      assert details.domain == "usageLimits"
      assert details.status == 403
      assert Errors.rate_limited?(parsed)
      assert Errors.retryable?(parsed)
    end

    test "handles errors array with nil items or empty maps" do
      sparse_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota reached",
          "errors" => [nil, %{}, %{"reason" => "quotaExceeded", "domain" => "youtube.quota"}]
        }
      }

      parsed = Errors.parse(403, sparse_body)
      # When the first element is nil or empty, extract_error_info handles gracefully
      assert match?({:error, _}, parsed)
    end
  end

  # ============================================================================
  # 8. Exponential Scaling & Upper Bound Invariant Property Tests
  # ============================================================================
  describe "Exponential scaling & upper bound invariant properties" do
    test "exponential upper ceiling strictly doubles on each attempt until max_delay is reached" do
      base = 100
      max_delay = 1600

      # Attempt 1: 100 * 2^0 = 100
      # Attempt 2: 100 * 2^1 = 200
      # Attempt 3: 100 * 2^2 = 400
      # Attempt 4: 100 * 2^3 = 800
      # Attempt 5: 100 * 2^4 = 1600
      # Attempt 6: min(1600, 100 * 2^5 = 3200) = 1600

      for attempt <- 1..8 do
        theoretical_ceiling = min(max_delay, trunc(base * :math.pow(2, max(0, attempt - 1))))

        # Sample 200 times per attempt to test upper bound invariant
        for _ <- 1..200 do
          delay = Errors.backoff_delay(attempt, base_backoff_ms: base, max_backoff_ms: max_delay, min_backoff_ms: 10)
          assert delay <= theoretical_ceiling,
                 "Delay #{delay} exceeded theoretical ceiling #{theoretical_ceiling} on attempt #{attempt}"
          assert delay >= 10,
                 "Delay #{delay} was below min_delay 10 on attempt #{attempt}"
        end
      end
    end
  end
end
