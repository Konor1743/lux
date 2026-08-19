defmodule Lux.Integrations.YouTube.ErrorsTest do
  use ExUnit.Case, async: true

  alias Lux.Integrations.YouTube.Errors

  describe "parse/3 with classic Google v3 JSON payloads" do
    test "parses 403 quotaExceeded" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "The request cannot be completed because you have exceeded your quota.",
          "errors" => [
            %{
              "domain" => "youtube.quota",
              "message" => "The request cannot be completed because you have exceeded your quota.",
              "reason" => "quotaExceeded"
            }
          ]
        }
      }

      assert {:error, {:quota_exceeded, details}} = Errors.parse(403, body)
      assert details.reason == "quotaExceeded"
      assert details.status == 403
      assert details.domain == "youtube.quota"
      assert details.message =~ "quota"
      assert Errors.quota_exceeded?({:error, {:quota_exceeded, details}})
      assert Errors.quota_exceeded?(%{reason: "quotaExceeded"})
      assert Errors.quota_exceeded?(%{reason: "QUOTA_EXCEEDED"})
      refute Errors.quota_exceeded?(%{reason: "other"})
      refute Errors.quota_exceeded?(:invalid)
      refute Errors.retryable?({:error, {:quota_exceeded, details}})
    end

    test "parses 403 dailyLimitExceeded" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Daily Limit Exceeded",
          "errors" => [
            %{
              "domain" => "usageLimits",
              "message" => "Daily Limit Exceeded",
              "reason" => "dailyLimitExceeded"
            }
          ]
        }
      }

      assert {:error, {:quota_exceeded, details}} = Errors.parse(403, body)
      assert details.reason == "dailyLimitExceeded"
      assert details.status == 403
    end

    test "parses 403 userRateLimitExceeded" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "User Rate Limit Exceeded",
          "errors" => [
            %{
              "domain" => "usageLimits",
              "message" => "User Rate Limit Exceeded",
              "reason" => "userRateLimitExceeded"
            }
          ]
        }
      }

      headers = [{"retry-after", "15"}]
      assert {:error, {:rate_limited, details}} = Errors.parse(403, body, headers)
      assert details.reason == "userRateLimitExceeded"
      assert details.status == 403
      assert details.retry_after == 15
      assert Errors.rate_limited?({:error, {:rate_limited, details}})
      assert Errors.rate_limited?(%{reason: "rateLimitExceeded"})
      assert Errors.rate_limited?({:error, {429, "Too many"}})
      refute Errors.rate_limited?(%{reason: "other"})
      refute Errors.rate_limited?(:ok)
      assert Errors.retryable?({:error, {:rate_limited, details}})
    end

    test "parses 429 rateLimitExceeded" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Too Many Requests",
          "errors" => [
            %{
              "domain" => "global",
              "message" => "Too Many Requests",
              "reason" => "rateLimitExceeded"
            }
          ]
        }
      }

      assert {:error, {:rate_limited, details}} = Errors.parse(429, body)
      assert details.status == 429
      assert details.reason == "rateLimitExceeded"
      assert Errors.retryable?({:error, {:rate_limited, details}})
    end

    test "parses 401 auth error" do
      body = %{
        "error" => %{
          "code" => 401,
          "message" => "Invalid Credentials",
          "errors" => [
            %{
              "domain" => "global",
              "message" => "Invalid Credentials",
              "reason" => "authError"
            }
          ]
        }
      }

      assert {:error, :invalid_token} = Errors.parse(401, body)
      refute Errors.retryable?({:error, :invalid_token})
    end

    test "parses 404 not found" do
      body = %{
        "error" => %{
          "code" => 404,
          "message" => "Broadcast not found",
          "errors" => [
            %{
              "domain" => "youtube.liveBroadcast",
              "message" => "Broadcast not found",
              "reason" => "liveBroadcastNotFound"
            }
          ]
        }
      }

      assert {:error, {404, "Broadcast not found"}} = Errors.parse(404, body)
      refute Errors.retryable?({:error, {404, "Broadcast not found"}})
    end

    test "parses 403 live streaming not enabled" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "The user is not enabled for live streaming.",
          "errors" => [
            %{
              "domain" => "youtube.liveBroadcast",
              "message" => "The user is not enabled for live streaming.",
              "reason" => "liveStreamingNotEnabled"
            }
          ]
        }
      }

      assert {:error, {403, "The user is not enabled for live streaming."}} =
               Errors.parse(403, body)
    end
  end

  describe "parse/3 with gRPC details and flat error schemas" do
    test "parses gRPC details with RESOURCE_EXHAUSTED" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota exceeded for quota metric",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "domain" => "youtube.googleapis.com",
              "reason" => "RATE_LIMIT_EXCEEDED"
            }
          ]
        }
      }

      assert {:error, {:rate_limited, details}} = Errors.parse(403, body)
      assert details.reason == "RATE_LIMIT_EXCEEDED"
    end

    test "parses flat OAuth error" do
      body = %{
        "error" => "invalid_grant",
        "error_description" => "Token has been expired or revoked."
      }

      assert {:error, {400, "Token has been expired or revoked."}} = Errors.parse(400, body)
    end

    test "parses flat message map" do
      body = %{
        "message" => "Custom error occurred",
        "reason" => "customReason"
      }

      assert {:error, {500, "Custom error occurred"}} = Errors.parse(500, body)
    end

    test "parses empty or nil info to default status messages" do
      assert {:error, {400, "Bad Request"}} = Errors.parse(400, nil)
      assert {:error, :invalid_token} = Errors.parse(401, nil)
      assert {:error, {403, "Forbidden"}} = Errors.parse(403, nil)
      assert {:error, {404, "Not Found"}} = Errors.parse(404, nil)
      assert {:error, {:rate_limited, details}} = Errors.parse(429, nil)
      assert details.message == "YouTube API rate limit exceeded."
      assert {:error, {500, "Internal Server Error"}} = Errors.parse(500, nil)
      assert {:error, {503, "Service Unavailable"}} = Errors.parse(503, nil)
      assert {:error, {502, "HTTP 502 Error"}} = Errors.parse(502, nil)
    end

    test "parses Req.Response struct" do
      resp = %Req.Response{
        status: 429,
        body: %{"error" => %{"message" => "Rate limit hit"}},
        headers: [{"retry-after", ["30"]}]
      }

      assert {:error, {:rate_limited, details}} = Errors.parse(resp)
      assert details.status == 429
      assert details.retry_after == 30
    end

    test "parses raw string JSON body" do
      json_str = Jason.encode!(%{
        "error" => %{
          "code" => 403,
          "message" => "Quota error",
          "errors" => [%{"reason" => "quotaExceeded"}]
        }
      })

      assert {:error, {:quota_exceeded, details}} = Errors.parse(403, json_str)
      assert details.reason == "quotaExceeded"
    end

    test "parses multi-item gRPC details" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Multi details error",
          "details" => [
            %{"@type" => "type.googleapis.com/google.rpc.ErrorInfo", "reason" => "RATE_LIMIT_EXCEEDED", "domain" => "youtube.googleapis.com"}
          ]
        }
      }

      assert {:error, {:rate_limited, details}} = Errors.parse(403, body)
      assert details.reason == "RATE_LIMIT_EXCEEDED"
      assert details.domain == "youtube.googleapis.com"
    end

    test "parses atom-keyed error maps" do
      body = %{
        error: %{
          code: 403,
          message: "Atom key quota exceeded",
          errors: [%{reason: "quotaExceeded", domain: "youtube.quota"}]
        }
      }

      assert {:error, {:quota_exceeded, details}} = Errors.parse(403, body)
      assert details.reason == "quotaExceeded"
      assert details.domain == "youtube.quota"
    end

    test "parses plain string error" do
      assert {:error, {500, "Internal error plain text"}} = Errors.parse(500, "Internal error plain text")
    end
  end

  describe "extract_retry_after/1" do
    test "extracts integer from header list" do
      assert Errors.extract_retry_after([{"Retry-After", "60"}]) == 60
      assert Errors.extract_retry_after([{"retry-after", "120"}]) == 120
      assert Errors.extract_retry_after([{:retry_after, "40"}]) == 40
      assert Errors.extract_retry_after([{:"retry-after", "50"}]) == 50
    end

    test "extracts integer from header map" do
      assert Errors.extract_retry_after(%{"retry-after" => "45"}) == 45
      assert Errors.extract_retry_after(%{"Retry-After" => "55"}) == 55
      assert Errors.extract_retry_after(%{"retry-after" => 30}) == 30
      assert Errors.extract_retry_after(%{"retry-after" => ["35"]}) == 35
      assert Errors.extract_retry_after(%{retry_after: "25"}) == 25
      assert Errors.extract_retry_after(%{}) == nil
    end

    test "returns nil for unparseable or missing header" do
      assert Errors.extract_retry_after([{"content-type", "application/json"}]) == nil
      assert Errors.extract_retry_after([{"retry-after", "invalid"}]) == nil
      assert Errors.extract_retry_after(nil) == nil
      assert Errors.extract_retry_after(123) == nil
    end
  end

  describe "retryable?/1" do
    test "correctly identifies retryable errors" do
      assert Errors.retryable?({:error, {:rate_limited, %{}}})
      assert Errors.retryable?({:error, {429, "Too many"}})
      assert Errors.retryable?({:error, {500, "Internal"}})
      assert Errors.retryable?({:error, {502, "Bad Gateway"}})
      assert Errors.retryable?({:error, {503, "Service Unavailable"}})
      assert Errors.retryable?({:error, {504, "Gateway Timeout"}})
      assert Errors.retryable?({:error, %Req.TransportError{reason: :econnrefused}})
      refute Errors.retryable?({:error, {400, "Bad Request"}})
      refute Errors.retryable?({:error, {404, "Not Found"}})
      refute Errors.retryable?(:other)
    end
  end

  describe "backoff_delay/2 and with_retry/2" do
    test "backoff_delay returns positive integer within bounds" do
      delay = Errors.backoff_delay(1, base_backoff_ms: 100, max_backoff_ms: 500, min_backoff_ms: 10)
      assert is_integer(delay)
      assert delay >= 10
      assert delay <= 500

      delay3 = Errors.backoff_delay(3, base_backoff_ms: 100, max_backoff_ms: 500, min_backoff_ms: 10)
      assert is_integer(delay3)
      assert delay3 >= 10
      assert delay3 <= 500

      delay_large = Errors.backoff_delay(2000, base_backoff_ms: 500, max_backoff_ms: 16_000, min_backoff_ms: 50)
      assert is_integer(delay_large)
      assert delay_large >= 50
      assert delay_large <= 16_000
    end

    test "with_retry succeeds on first try" do
      res = Errors.with_retry(fn -> {:ok, "success"} end)
      assert res == {:ok, "success"}
    end

    test "with_retry retries retryable errors until success" do
      agent = start_supervised!({Agent, fn -> 0 end})

      fun = fn ->
        attempts = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

        if attempts < 3 do
          {:error, {:rate_limited, %{retry_after: nil}}}
        else
          {:ok, "recovered"}
        end
      end

      # Use no-op sleep to run test fast
      res = Errors.with_retry(fun, max_retries: 3, sleep_fun: fn _ -> :ok end)
      assert res == {:ok, "recovered"}
      assert Agent.get(agent, fn count -> count end) == 3
    end

    test "with_retry handles retry_after in rate_limited errors" do
      agent = start_supervised!({Agent, fn -> 0 end})

      fun = fn ->
        attempts = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

        if attempts == 1 do
          {:error, {:rate_limited, %{retry_after: 1}}}
        else
          {:ok, "done"}
        end
      end

      res = Errors.with_retry(fun, max_retries: 2, sleep_fun: fn ms ->
        assert ms == 1000
        :ok
      end)

      assert res == {:ok, "done"}
    end

    test "with_retry exhausts retries and returns last error" do
      fun = fn -> {:error, {500, "Server Down"}} end
      res = Errors.with_retry(fun, max_retries: 2, sleep_fun: fn _ -> :ok end)
      assert res == {:error, {500, "Server Down"}}
    end

    test "with_retry fails immediately on non-retryable errors" do
      agent = start_supervised!({Agent, fn -> 0 end})

      fun = fn ->
        Agent.update(agent, &(&1 + 1))
        {:error, {:quota_exceeded, %{reason: "quotaExceeded"}}}
      end

      res = Errors.with_retry(fun, max_retries: 3, sleep_fun: fn _ -> :ok end)
      assert {:error, {:quota_exceeded, _}} = res
      assert Agent.get(agent, fn count -> count end) == 1
    end
  end

  describe "additional error branches and predicate tests" do
    test "extracts info from atom-keyed details and errors" do
      body1 = %{
        error: %{
          details: [
            %{reason: "rateLimitExceeded", domain: "usageLimits", message: "Rate limit message"}
          ]
        }
      }

      assert {:error, {:rate_limited, details}} = Errors.parse(403, body1)
      assert details.reason == "rateLimitExceeded"
      assert details.domain == "usageLimits"
      assert details.message == "Rate limit message"

      body2 = %{
        error: %{
          status: "custom_status",
          message: "Custom status message"
        }
      }

      assert {:error, {400, "Custom status message"}} = Errors.parse(400, body2)

      body3 = %{
        message: "Direct atom message",
        description: "Direct atom description",
        reason: "atom_reason",
        domain: "atom_domain"
      }

      assert {:error, {500, "Direct atom message"}} = Errors.parse(500, body3)

      body4 = %{
        "message" => "",
        "reason" => "only_reason"
      }

      assert {:error, {400, "400: only_reason"}} = Errors.parse(400, body4)

      body5 = %{
        error: "invalid_client",
        error_description: "Client auth failed"
      }

      assert {:error, {400, "Client auth failed"}} = Errors.parse(400, body5)
    end

    test "predicates test all patterns" do
      assert Errors.quota_exceeded?(%{reason: "quotaExceeded"})
      assert Errors.quota_exceeded?(%{reason: "dailyLimitExceeded"})
      refute Errors.quota_exceeded?(%{reason: "unknown"})
      refute Errors.quota_exceeded?(nil)

      assert Errors.rate_limited?(%{reason: "rateLimitExceeded"})
      assert Errors.rate_limited?(%{reason: "userRateLimitExceeded"})
      assert Errors.rate_limited?({:error, {429, "Too Many Requests"}})
      refute Errors.rate_limited?(%{reason: "unknown"})
      refute Errors.rate_limited?(123)

      assert Errors.retryable?({:error, {:rate_limited, %{}}})
      assert Errors.retryable?({:error, {429, "Too Many"}})
      assert Errors.retryable?({:error, {500, "Internal"}})
      assert Errors.retryable?({:error, %Req.TransportError{reason: :nxdomain}})
      refute Errors.retryable?({:error, {400, "Bad Request"}})
      refute Errors.retryable?({:error, :invalid_token})
      refute Errors.retryable?(nil)
    end
  end
end
