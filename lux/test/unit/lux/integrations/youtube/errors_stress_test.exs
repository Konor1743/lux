defmodule Lux.Integrations.YouTube.ErrorsStressTest do
  use UnitAPICase, async: false

  alias Lux.Integrations.YouTube.Errors
  alias Lux.Integrations.YouTube.Client

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  @moduledoc """
  Empirical stress tests for YouTube API error parsing, retry backoff calculation,
  and quotaExceeded detection across diverse payload structures.
  """

  # ---------------------------------------------------------------------------
  # 1. gRPC / Google RPC Payload Structure Stress Tests
  # ---------------------------------------------------------------------------
  describe "gRPC / Google RPC payload structure stress testing" do
    test "gRPC standard ErrorInfo with QUOTA_EXCEEDED" do
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota exceeded for quota metric 'Queries' and limit 'Queries per day' of service 'youtube.googleapis.com'",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "QUOTA_EXCEEDED",
              "domain" => "youtube.googleapis.com",
              "metadata" => %{
                "service" => "youtube.googleapis.com",
                "consumer" => "projects/123456789"
              }
            }
          ]
        }
      }

      parsed = Errors.parse(403, grpc_body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "QUOTA_EXCEEDED"
      assert details.domain == "youtube.googleapis.com"
      assert details.status == 403
      assert details.message =~ "Quota exceeded"
      assert Errors.quota_exceeded?(parsed)
      refute Errors.retryable?(parsed)
    end

    test "gRPC ErrorInfo with RATE_LIMIT_EXCEEDED" do
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "User rate limit exceeded",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "RATE_LIMIT_EXCEEDED",
              "domain" => "youtube.googleapis.com"
            }
          ]
        }
      }

      parsed = Errors.parse(403, grpc_body, [{"retry-after", "45"}])
      assert {:error, {:rate_limited, details}} = parsed
      assert details.reason == "RATE_LIMIT_EXCEEDED"
      assert details.domain == "youtube.googleapis.com"
      assert details.status == 403
      assert details.retry_after == 45
      assert Errors.rate_limited?(parsed)
      assert Errors.retryable?(parsed)
    end

    test "gRPC with RESOURCE_EXHAUSTED_QUOTA reason" do
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota exhausted",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "reason" => "RESOURCE_EXHAUSTED_QUOTA",
              "domain" => "youtube.googleapis.com"
            }
          ]
        }
      }

      parsed = Errors.parse(403, grpc_body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "RESOURCE_EXHAUSTED_QUOTA"
      assert Errors.quota_exceeded?(parsed)
      refute Errors.retryable?(parsed)
    end

    test "gRPC multi-element details where Help/QuotaFailure precedes ErrorInfo (VULNERABILITY PROBE)" do
      # In Google RPC responses, `details` is a list where Help or QuotaFailure can precede ErrorInfo
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Daily quota exceeded for project 123",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.Help",
              "links" => [%{"description" => "Google Cloud Console", "url" => "https://console.cloud.google.com"}]
            },
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "QUOTA_EXCEEDED",
              "domain" => "googleapis.com"
            }
          ]
        }
      }

      parsed = Errors.parse(403, grpc_body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "QUOTA_EXCEEDED"
      assert details.domain == "googleapis.com"
      assert Errors.quota_exceeded?(parsed)
    end

    test "gRPC status RESOURCE_EXHAUSTED with empty details on 403 (VULNERABILITY PROBE)" do
      # When gRPC returns code: 403, status: "RESOURCE_EXHAUSTED", without details
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Quota metric exceeded",
          "status" => "RESOURCE_EXHAUSTED",
          "details" => []
        }
      }

      parsed = Errors.parse(403, grpc_body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "RESOURCE_EXHAUSTED"
      assert Errors.quota_exceeded?(parsed)
    end

    test "gRPC with status RESOURCE_EXHAUSTED on 429" do
      grpc_body = %{
        "error" => %{
          "code" => 429,
          "message" => "Resource exhausted / rate limit",
          "status" => "RESOURCE_EXHAUSTED"
        }
      }

      parsed = Errors.parse(429, grpc_body)
      # 429 with non-quota reason classifies as rate_limited
      assert {:error, {:rate_limited, details}} = parsed
      assert details.status == 429
      assert details.reason == "rateLimitExceeded"
      assert Errors.rate_limited?(parsed)
      assert Errors.retryable?(parsed)
    end

    test "gRPC with non-map items in details list" do
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Rate limit exceeded",
          "details" => ["string_detail", 123, nil]
        }
      }

      parsed = Errors.parse(403, grpc_body)
      assert match?({:error, {403, "Rate limit exceeded"}}, parsed)
    end

    test "gRPC with details as a single map instead of a list" do
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "Rate limit exceeded",
          "details" => %{"reason" => "RATE_LIMIT_EXCEEDED"}
        }
      }

      parsed = Errors.parse(403, grpc_body)
      assert match?({:error, _}, parsed)
    end

    test "gRPC with status PERMISSION_DENIED (403)" do
      grpc_body = %{
        "error" => %{
          "code" => 403,
          "message" => "The caller does not have permission",
          "status" => "PERMISSION_DENIED"
        }
      }

      parsed = Errors.parse(403, grpc_body)
      assert {:error, {403, "The caller does not have permission"}} = parsed
      refute Errors.quota_exceeded?(parsed)
      refute Errors.rate_limited?(parsed)
      refute Errors.retryable?(parsed)
    end

    test "gRPC with status INVALID_ARGUMENT (400)" do
      grpc_body = %{
        "error" => %{
          "code" => 400,
          "message" => "Invalid part parameter",
          "status" => "INVALID_ARGUMENT",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.BadRequest",
              "fieldViolations" => [
                %{"field" => "part", "description" => "Invalid value 'invalid_part'"}
              ]
            }
          ]
        }
      }

      parsed = Errors.parse(400, grpc_body)
      assert {:error, {400, "Invalid part parameter"}} = parsed
      refute Errors.retryable?(parsed)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Classic Google v3 API Error Payload Stress Tests
  # ---------------------------------------------------------------------------
  describe "classic Google v3 API payload structure stress testing" do
    test "classic quotaExceeded with multiple errors in errors list" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "The request cannot be completed because you have exceeded your quota.",
          "errors" => [
            %{
              "domain" => "youtube.quota",
              "message" => "The request cannot be completed because you have exceeded your quota.",
              "reason" => "quotaExceeded"
            },
            %{
              "domain" => "global",
              "message" => "Secondary error",
              "reason" => "secondary"
            }
          ]
        }
      }

      parsed = Errors.parse(403, body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "quotaExceeded"
      assert details.domain == "youtube.quota"
      assert details.status == 403
      assert Errors.quota_exceeded?(parsed)
      refute Errors.retryable?(parsed)
    end

    test "classic dailyLimitExceeded" do
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

      parsed = Errors.parse(403, body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "dailyLimitExceeded"
      assert Errors.quota_exceeded?(parsed)
    end

    test "classic rate limiting reasons: concurrentLimitExceeded and servingLimitExceeded" do
      for reason <- ["concurrentLimitExceeded", "servingLimitExceeded", "RATE_LIMIT_EXCEEDED", "USER_RATE_LIMIT_EXCEEDED"] do
        body = %{
          "error" => %{
            "code" => 403,
            "message" => "Rate limit",
            "errors" => [%{"reason" => reason, "domain" => "usageLimits"}]
          }
        }

        parsed = Errors.parse(403, body)
        assert {:error, {:rate_limited, details}} = parsed
        assert details.reason == reason
        assert details.status == 403
        assert Errors.rate_limited?(parsed)
        assert Errors.retryable?(parsed)
      end
    end

    test "classic with empty errors array" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Forbidden access",
          "errors" => []
        }
      }

      parsed = Errors.parse(403, body)
      assert {:error, {403, "Forbidden access"}} = parsed
    end

    test "classic with non-map elements in errors array" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Forbidden",
          "errors" => ["invalid_error_element", 42, nil]
        }
      }

      parsed = Errors.parse(403, body)
      assert {:error, {403, "Forbidden"}} = parsed
    end

    test "classic with atom-keyed maps (VULNERABILITY PROBE)" do
      atom_body = %{
        error: %{
          code: 403,
          message: "The request cannot be completed because you have exceeded your quota.",
          errors: [%{reason: "quotaExceeded", domain: "youtube.quota"}]
        }
      }

      parsed = Errors.parse(403, atom_body)
      assert {:error, {:quota_exceeded, details}} = parsed
      assert details.reason == "quotaExceeded"
      assert details.domain == "youtube.quota"
      assert Errors.quota_exceeded?(parsed)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Malformed JSON, Truncated JSON, and Non-JSON Bodies
  # ---------------------------------------------------------------------------
  describe "malformed JSON and non-JSON body stress testing" do
    test "truncated JSON string" do
      truncated = ~s({"error": {"code": 403, "message": "Quo)
      parsed = Errors.parse(403, truncated)
      assert {:error, {403, ^truncated}} = parsed
      refute Errors.quota_exceeded?(parsed)
      refute Errors.retryable?(parsed)
    end

    test "invalid JSON syntax" do
      invalid = ~s({invalid: json, "missing": quote})
      parsed = Errors.parse(500, invalid)
      assert {:error, {500, ^invalid}} = parsed
      assert Errors.retryable?(parsed)
    end

    test "empty string body" do
      parsed = Errors.parse(500, "")
      assert {:error, {500, "Internal Server Error"}} = parsed
    end

    test "whitespace only body" do
      parsed = Errors.parse(404, "   \n\t  ")
      assert {:error, {404, "Not Found"}} = parsed
    end

    test "JSON primitive values (number, boolean, null, array)" do
      assert {:error, {500, "12345"}} = Errors.parse(500, "12345")
      assert {:error, {500, "true"}} = Errors.parse(500, "true")
      assert {:error, {500, "null"}} = Errors.parse(500, "null")
      assert {:error, {500, "[1, 2, 3]"}} = Errors.parse(500, "[1, 2, 3]")
    end

    test "JSON body with nil error value" do
      body = %{"error" => nil}
      parsed = Errors.parse(500, body)
      assert {:error, {500, "Internal Server Error"}} = parsed
    end

    test "JSON body with integer or boolean error value" do
      body_int = %{"error" => 500}
      body_bool = %{"error" => false}
      assert match?({:error, {500, _}}, Errors.parse(500, body_int))
      assert match?({:error, {500, _}}, Errors.parse(500, body_bool))
    end

    test "binary containing non-UTF-8 bytes" do
      bad_binary = <<0xFFFF::16, 0xFEFF::16, "random binary content">>
      parsed = Errors.parse(500, bad_binary)
      assert match?({:error, {500, _}}, parsed)
    end

    test "non-string, non-map terms as body (atoms, tuples, integers)" do
      assert {:error, {500, "Internal Server Error"}} = Errors.parse(500, :some_atom)
      assert {:error, {500, "Internal Server Error"}} = Errors.parse(500, {:error, :closed})
      assert {:error, {500, "Internal Server Error"}} = Errors.parse(500, 12345)
      assert {:error, {500, "Internal Server Error"}} = Errors.parse(500, [:a, :b])
    end
  end

  # ---------------------------------------------------------------------------
  # 4. HTML 500 / 502 / 503 / 504 Error Pages Stress Tests
  # ---------------------------------------------------------------------------
  describe "HTML error pages stress testing" do
    test "standard Google 500 HTML error page" do
      html_500 = """
      <!DOCTYPE html>
      <html lang=en>
        <meta charset=utf-8>
        <meta name=viewport content="initial-scale=1, minimum-scale=1, width=device-width">
        <title>Error 500 (Server Error)!!1</title>
        <p><b>500.</b> <ins>That’s an error.</ins>
        <p>There was an error. Please try again later. <ins>That’s all we know.</ins>
      </html>
      """

      parsed = Errors.parse(500, html_500)
      assert {:error, {500, message}} = parsed
      assert message == html_500
      assert Errors.retryable?(parsed)
    end

    test "Google Frontend (GFE) 502 Bad Gateway HTML page" do
      html_502 = """
      <html><head>
      <meta http-equiv="content-type" content="text/html;charset=utf-8">
      <title>502 Server Error</title>
      </head>
      <body text=#000000 bgcolor=#ffffff>
      <h1>Error: Server Error</h1>
      <h2>The server encountered a temporary error and could not complete your request.<p>Please try again in 30 seconds.</h2>
      </body></html>
      """

      parsed = Errors.parse(502, html_502)
      assert {:error, {502, message}} = parsed
      assert message == html_502
      assert Errors.retryable?(parsed)
    end

    test "Cloudflare / Proxy 503 Service Unavailable HTML page" do
      html_503 = "<!DOCTYPE html><html><body><h1>503 Service Temporarily Unavailable</h1></body></html>"
      headers = [{"retry-after", "30"}]

      parsed = Errors.parse(503, html_503, headers)
      assert {:error, {503, ^html_503}} = parsed
      assert Errors.retryable?(parsed)
      assert Errors.extract_retry_after(headers) == 30
    end

    test "504 Gateway Timeout HTML page" do
      html_504 = "<html><body><h1>504 Gateway Time-out</h1></body></html>"
      parsed = Errors.parse(504, html_504)
      assert {:error, {504, ^html_504}} = parsed
      assert Errors.retryable?(parsed)
    end

    test "large multi-kilobyte HTML error page (stress memory / string parsing)" do
      # 100KB HTML error payload
      large_html = "<!DOCTYPE html><html><body>" <> String.duplicate("<p>Stress testing error handling</p>", 2500) <> "</body></html>"
      parsed = Errors.parse(500, large_html)
      assert {:error, {500, returned_msg}} = parsed
      assert byte_size(returned_msg) == byte_size(large_html)
      assert Errors.retryable?(parsed)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Retry-After Header Extraction Stress Tests
  # ---------------------------------------------------------------------------
  describe "Retry-After header extraction edge cases" do
    test "various casing and formats in list" do
      assert Errors.extract_retry_after([{"retry-after", "120"}]) == 120
      assert Errors.extract_retry_after([{"Retry-After", "120"}]) == 120
      assert Errors.extract_retry_after([{"RETRY-AFTER", "120"}]) == 120
      assert Errors.extract_retry_after([{:retry_after, "120"}]) == 120
      assert Errors.extract_retry_after([{:"retry-after", "120"}]) == 120
    end

    test "whitespace padded values in header" do
      assert Errors.extract_retry_after([{"retry-after", "   45   "}]) == 45
      assert Errors.extract_retry_after([{"retry-after", "\t60\n"}]) == 60
    end

    test "integer in header map" do
      assert Errors.extract_retry_after(%{"retry-after" => 60}) == 60
      assert Errors.extract_retry_after(%{"retry-after" => 0}) == 0
    end

    test "zero value retry-after" do
      assert Errors.extract_retry_after([{"retry-after", "0"}]) == 0
    end

    test "negative or invalid numeric strings" do
      assert Errors.extract_retry_after([{"retry-after", "-10"}]) == nil
      assert Errors.extract_retry_after([{"retry-after", "10.5"}]) == nil
      assert Errors.extract_retry_after([{"retry-after", "abc"}]) == nil
      assert Errors.extract_retry_after([{"retry-after", ""}]) == nil
    end

    test "HTTP-date format (RFC 7231)" do
      assert Errors.extract_retry_after([{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}]) == nil
    end

    test "empty or non-collection headers" do
      assert Errors.extract_retry_after([]) == nil
      assert Errors.extract_retry_after(%{}) == nil
      assert Errors.extract_retry_after(nil) == nil
      assert Errors.extract_retry_after("invalid_header_type") == nil
      assert Errors.extract_retry_after(12345) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Retry Backoff Calculation Stress Tests
  # ---------------------------------------------------------------------------
  describe "backoff_delay/2 calculation and bounds stress testing" do
    test "computes delays within expected bounds across attempts 1..10" do
      opts = [base_backoff_ms: 500, max_backoff_ms: 16_000, min_backoff_ms: 50]

      for attempt <- 1..10 do
        for _ <- 1..100 do
          delay = Errors.backoff_delay(attempt, opts)
          assert is_integer(delay)
          assert delay >= 50, "Delay #{delay} was below min_backoff_ms 50 on attempt #{attempt}"
          assert delay <= 16_000, "Delay #{delay} exceeded max_backoff_ms 16000 on attempt #{attempt}"
        end
      end
    end

    test "statistical jitter distribution over 1,000 samples" do
      opts = [base_backoff_ms: 1000, max_backoff_ms: 8000, min_backoff_ms: 50]
      samples = Enum.map(1..1000, fn _ -> Errors.backoff_delay(3, opts) end)

      min_sample = Enum.min(samples)
      max_sample = Enum.max(samples)
      avg_sample = Enum.sum(samples) / length(samples)

      # Attempt 3 temp_delay = min(8000, 1000 * 2^2) = 4000
      # With full jitter U(0, 1), delay should be uniformly spread in [50, 4000]
      # Mean should be approximately ~2000 ms
      assert min_sample >= 50
      assert max_sample <= 4000
      assert avg_sample > 1500 and avg_sample < 2500, "Average sample #{avg_sample} deviated significantly from expected ~2000"
    end

    test "handles attempt <= 0 safely" do
      delay0 = Errors.backoff_delay(0, base_backoff_ms: 500, min_backoff_ms: 50)
      delay_neg = Errors.backoff_delay(-5, base_backoff_ms: 500, min_backoff_ms: 50)

      assert delay0 >= 50 and delay0 <= 500
      assert delay_neg >= 50 and delay_neg <= 500
    end

    test "handles very high attempt count without crashing (bounds check)" do
      # Attempt 30: 2^29 is ~536 million ms, capped by max_backoff_ms
      delay30 = Errors.backoff_delay(30, max_backoff_ms: 16_000, min_backoff_ms: 50)
      assert delay30 >= 50 and delay30 <= 16_000

      # Attempt 64: 2^63 is ~9.22 * 10^18, capped by max_backoff_ms
      delay64 = Errors.backoff_delay(64, max_backoff_ms: 16_000, min_backoff_ms: 50)
      assert delay64 >= 50 and delay64 <= 16_000
    end

    test "extreme attempt >= 1025 float exponentiation limits (VULNERABILITY PROBE)" do
      delay = Errors.backoff_delay(1025, base_backoff_ms: 500, max_backoff_ms: 16_000, min_backoff_ms: 50)
      assert is_integer(delay)
      assert delay >= 50 and delay <= 16_000
    end
  end

  # ---------------------------------------------------------------------------
  # 7. with_retry/2 Execution Harness Stress Tests
  # ---------------------------------------------------------------------------
  describe "with_retry/2 execution stress testing" do
    test "retries on 500, 502, 503, 504 status errors" do
      for status <- [500, 502, 503, 504] do
        agent = start_supervised!({Agent, fn -> 0 end}, id: :"agent_#{status}")

        fun = fn ->
          count = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)
          if count < 3 do
            {:error, {status, "Server error"}}
          else
            {:ok, "recovered_#{status}"}
          end
        end

        res = Errors.with_retry(fun, max_retries: 3, sleep_fun: fn _ -> :ok end)
        assert res == {:ok, "recovered_#{status}"}
        assert Agent.get(agent, & &1) == 3
      end
    end

    test "retries on Req.TransportError" do
      agent = start_supervised!({Agent, fn -> 0 end}, id: :agent_transport)

      fun = fn ->
        count = Agent.get_and_update(agent, fn c -> {c + 1, c + 1} end)
        if count < 2 do
          {:error, %Req.TransportError{reason: :nxdomain}}
        else
          {:ok, "connected"}
        end
      end

      res = Errors.with_retry(fun, max_retries: 2, sleep_fun: fn _ -> :ok end)
      assert res == {:ok, "connected"}
      assert Agent.get(agent, & &1) == 2
    end

    test "records backoff delays with custom sleep_fun" do
      delays_agent = start_supervised!({Agent, fn -> [] end}, id: :agent_delays)

      fun = fn ->
        {:error, {503, "Unavailable"}}
      end

      sleep_collector = fn ms ->
        Agent.update(delays_agent, fn list -> [ms | list] end)
        :ok
      end

      res = Errors.with_retry(fun,
        max_retries: 3,
        base_backoff_ms: 100,
        max_backoff_ms: 1000,
        min_backoff_ms: 20,
        sleep_fun: sleep_collector
      )

      assert {:error, {503, "Unavailable"}} = res
      delays = Agent.get(delays_agent, &Enum.reverse/1)
      assert length(delays) == 3
      for delay <- delays do
        assert delay >= 20 and delay <= 1000
      end
    end

    test "aborts immediately on 400 Bad Request, 401 Unauthorized, 404 Not Found" do
      for non_retryable <- [{400, "Bad Request"}, :invalid_token, {404, "Not Found"}, {:quota_exceeded, %{reason: "quotaExceeded"}}] do
        agent = start_supervised!({Agent, fn -> 0 end}, id: :"agent_abort_#{inspect(non_retryable)}")

        fun = fn ->
          Agent.update(agent, &(&1 + 1))
          {:error, non_retryable}
        end

        res = Errors.with_retry(fun, max_retries: 5, sleep_fun: fn _ -> :ok end)
        assert res == {:error, non_retryable}
        assert Agent.get(agent, & &1) == 1
      end
    end

    test "handles max_retries: 0 and max_retries: -1" do
      for retries <- [0, -1] do
        agent = start_supervised!({Agent, fn -> 0 end}, id: :"agent_retries_#{retries}")

        fun = fn ->
          Agent.update(agent, &(&1 + 1))
          {:error, {500, "Internal"}}
        end

        res = Errors.with_retry(fun, max_retries: retries, sleep_fun: fn _ -> :ok end)
        assert res == {:error, {500, "Internal"}}
        assert Agent.get(agent, & &1) == 1
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Integration with Client.request/3 with Adverse Responses
  # ---------------------------------------------------------------------------
  describe "Client.request/3 with adverse and malformed responses" do
    test "handles 500 HTML body response via Req.Test mock" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(500, "<html><body><h1>500 Internal Server Error</h1></body></html>")
      end)

      assert {:error, {500, body}} = Client.get("/channels", token: "test_token", retry: false)
      assert body =~ "500 Internal Server Error"
    end

    test "handles 403 quotaExceeded JSON via Req.Test mock" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "Quota Exceeded",
              "errors" => [%{"reason" => "quotaExceeded", "domain" => "youtube.quota"}]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, details}} = Client.get("/liveBroadcasts", token: "tok", retry: false)
      assert details.reason == "quotaExceeded"
      assert details.status == 403
    end

    test "handles 429 Rate Limit with Retry-After header with retry: false" do
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "45")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{
              "code" => 429,
              "message" => "Too Many Requests"
            }
          })
        )
      end)

      # Passing retry: false prevents Req from sleeping 45s internally
      assert {:error, {:rate_limited, details}} = Client.get("/liveBroadcasts", token: "tok", retry: false)
      assert details.status == 429
      assert details.retry_after == 45
    end

    test "handles malformed JSON body on 400 Bad Request via Req.Test mock" do
      # When content-type is application/json but body is invalid JSON,
      # Req's decode_body step intercepts and returns {:error, %Jason.DecodeError{}}
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, "{\"error\": malformed json")
      end)

      assert {:error, %Jason.DecodeError{}} = Client.get("/channels", token: "tok", retry: false)

      # When content-type is text/plain, Req does not auto-decode, passing raw body to Errors.parse/3
      Req.Test.expect(YouTubeClientMock, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(400, "{\"error\": malformed json")
      end)

      assert {:error, {400, "{\"error\": malformed json"}} = Client.get("/channels", token: "tok", retry: false)
    end
  end
end
