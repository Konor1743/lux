# Comprehensive Analysis Report: YouTube API Error Handling & Resiliency

- **Agent**: Explorer 3 (Milestone 1)
- **Subject**: YouTube Data & Live Streaming API v3 Error Handling, Structured Error Representation, Resiliency, Exponential Backoff, and Req.Test Mock Fixtures
- **Target Path**: `lib/lux/integrations/youtube/errors.ex`, `lib/lux/integrations/youtube/client.ex`, and test suites

---

## 1. Executive Summary

YouTube Data API v3 and Google OAuth 2.0 endpoints have specialized error response schemas that differ significantly from simple APIs (such as Telegram or Discord). Specifically:
1. Google API errors return a nested payload containing `error.code`, `error.message`, `error.status`, and an `error.errors` list with explicit `domain` and `reason` tags.
2. Quota limits (`quotaExceeded`) and Rate limits (`rateLimitExceeded` / `userRateLimitExceeded`) both present as HTTP 403 (or HTTP 429), but have fundamentally opposite operational semantics:
   - **Daily Quota (`quotaExceeded`)**: Project-level budget exhausted until midnight Pacific Time (PT). Retrying is futile and must fail fast.
   - **Rate Limit (`rateLimitExceeded`, `userRateLimitExceeded`, HTTP 429)**: Per-user or per-minute burst throttle. Eligible for exponential backoff with jitter and `Retry-After` header inspection.
3. Authentication errors (`authError` on HTTP 401) trigger automatic OAuth 2.0 token refresh when a refresh token is configured, retrying the original request transparently before returning `{:error, :invalid_token}` if refresh fails.
4. Domain-specific 403/404 errors (e.g. `liveStreamingNotEnabled`, `liveChatEnded`, `liveBroadcastNotFound`) require informative `{status, message}` representation for agent lenses and prisms.

This report establishes:
- The complete error categorization taxonomy for YouTube API v3.
- The architecture and implementation specification for `Lux.Integrations.YouTube.Errors`.
- The integration interface with `Lux.Integrations.YouTube.Client`.
- Concrete retry and exponential backoff strategies for rate limits and server errors.
- Comprehensive `Req.Test` fixtures and unit test templates.

---

## 2. Forensic Analysis of YouTube API Error Responses

### 2.1. Google API v3 Error Payload Anatomy

Google API error responses standardly serialize as JSON containing a root `"error"` object. There are two primary JSON schemas returned by Google servers:

#### Standard v3 Error Schema (Classic Google APIs)
```json
{
  "error": {
    "code": 403,
    "message": "The request cannot be completed because you have exceeded your <a href=\"/youtube/v3/getting-started#quota\">quota</a>.",
    "errors": [
      {
        "message": "The request cannot be completed because you have exceeded your <a href=\"/youtube/v3/getting-started#quota\">quota</a>.",
        "domain": "youtube.quota",
        "reason": "quotaExceeded"
      }
    ]
  }
}
```

#### Google Cloud API Gateway / gRPC Standard Schema
```json
{
  "error": {
    "code": 403,
    "message": "Quota exceeded for quota metric 'Queries' and limit 'Queries per day' of service 'youtube.googleapis.com'",
    "status": "RESOURCE_EXHAUSTED",
    "details": [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "domain": "youtube.googleapis.com",
        "reason": "RATE_LIMIT_EXCEEDED"
      }
    ]
  }
}
```

#### OAuth 2.0 Token Endpoint (`https://oauth2.googleapis.com/token`)
```json
{
  "error": "invalid_grant",
  "error_description": "Token has been expired or revoked."
}
```

---

### 2.2. Error Scenarios Matrix

| Scenario | HTTP Status | Error Reason(s) | Domain | Retryable? | Target Return Tuple |
|---|---|---|---|---|---|
| **Daily Quota Exceeded** | 403 | `quotaExceeded`, `dailyLimitExceeded` | `youtube.quota` | **NO** (Fail fast until 00:00 PT) | `{:error, {:quota_exceeded, details_map}}` |
| **User Rate Limit** | 403 / 429 | `userRateLimitExceeded`, `rateLimitExceeded`, `concurrentLimitExceeded` | `usageLimits`, `youtube.quota` | **YES** (Exp backoff) | `{:error, {:rate_limited, details_map}}` |
| **HTTP 429 Throttle** | 429 | `rateLimitExceeded`, `RATE_LIMIT_EXCEEDED` | `global`, `usageLimits` | **YES** (Respect `Retry-After`) | `{:error, {:rate_limited, details_map}}` |
| **Expired / Invalid Auth** | 401 | `authError`, `invalid_token`, `invalid_credentials` | `youtube.header`, `global` | **ONCE** (via token refresh) | `{:error, :invalid_token}` |
| **Bad Request** | 400 | `badRequest`, `invalidArgument`, `required` | `global`, `youtube.parameter` | **NO** | `{:error, {400, message}}` |
| **Not Found** | 404 | `liveBroadcastNotFound`, `liveChatNotFound`, `notFound` | `youtube.liveBroadcast`, `youtube.liveChat` | **NO** | `{:error, {404, message}}` |
| **Live Stream Not Enabled** | 403 | `liveStreamingNotEnabled`, `livePermissionDenied` | `youtube.liveBroadcast` | **NO** | `{:error, {403, message}}` |
| **Live Chat Inactive** | 403 | `liveChatEnded`, `liveChatDisabled` | `youtube.liveChat` | **NO** | `{:error, {403, message}}` |
| **Server Errors** | 500, 503 | `backendError`, `internalError`, `serviceUnavailable` | `global` | **YES** (Exp backoff) | `{:error, {status, message}}` |
| **Network Transport** | N/A | `%Req.TransportError{reason: reason}` | N/A | **YES** | `{:error, transport_error}` |

---

## 3. Specification of `Lux.Integrations.YouTube.Errors`

### 3.1. Design Goals
1. **Accurate Discrimination**: Reliably distinguish `quotaExceeded` (403) from `userRateLimitExceeded` (403) from generic forbidden (403).
2. **Robust Extraction**: Defensively extract `reason`, `message`, `domain`, and `status` from both v3 `errors` arrays, gRPC `details` arrays, flat OAuth error responses, or raw string/HTML bodies without crashing or throwing.
3. **Ergonomic Return Tuples**: Provide standard Elixir error tagged tuples matching the `PROJECT.md` contracts:
   - `{:error, {:quota_exceeded, map()}}`
   - `{:error, {:rate_limited, map()}}`
   - `{:error, :invalid_token}`
   - `{:error, {integer(), String.t()}}`
4. **Resiliency Predicates**: Export helper predicates (`quota_exceeded?/1`, `rate_limited?/1`, `retryable?/1`, `extract_retry_after/1`) for polling loops and prisms.

---

### 3.2. Concrete Module Implementation Code

```elixir
defmodule Lux.Integrations.YouTube.Errors do
  @moduledoc """
  Error parsing, classification, and resiliency helpers for YouTube Data API v3
  and Google OAuth 2.0 endpoints.
  """

  @type quota_error ::
          {:error,
           {:quota_exceeded,
            %{
              reason: String.t(),
              message: String.t(),
              status: integer(),
              domain: String.t() | nil,
              details: map() | String.t() | nil
            }}}

  @type rate_limit_error ::
          {:error,
           {:rate_limited,
            %{
              reason: String.t(),
              message: String.t(),
              status: integer(),
              domain: String.t() | nil,
              retry_after: non_neg_integer() | nil,
              details: map() | String.t() | nil
            }}}

  @type auth_error :: {:error, :invalid_token}

  @type generic_error :: {:error, {integer(), String.t()}}

  @type parsed_error :: quota_error() | rate_limit_error() | auth_error() | generic_error()

  @quota_reasons [
    "quotaExceeded",
    "dailyLimitExceeded",
    "QUOTA_EXCEEDED",
    "RESOURCE_EXHAUSTED_QUOTA"
  ]

  @rate_limit_reasons [
    "rateLimitExceeded",
    "userRateLimitExceeded",
    "concurrentLimitExceeded",
    "servingLimitExceeded",
    "RATE_LIMIT_EXCEEDED",
    "USER_RATE_LIMIT_EXCEEDED"
  ]

  @doc """
  Parses a `Req.Response` or `{status, body, headers}` into a structured error tuple.
  """
  @spec parse(integer() | Req.Response.t(), term(), keyword() | [{String.t(), String.t()}]) ::
          parsed_error()
  def parse(%Req.Response{status: status, body: body, headers: headers}, _body \\ nil, _headers \\ []) do
    parse(status, body, headers)
  end

  def parse(status, body, headers \\ []) when is_integer(status) do
    extracted = extract_error_info(body)
    retry_after = extract_retry_after(headers)

    classify(status, extracted, retry_after, body)
  end

  # --- Error Classification Logic ---

  defp classify(401, _extracted, _retry_after, _raw_body) do
    {:error, :invalid_token}
  end

  defp classify(status, %{reason: reason} = info, _retry_after, raw_body)
       when (status == 403 or status == 429) and reason in @quota_reasons do
    {:error,
     {:quota_exceeded,
      %{
        reason: reason,
        message: info.message || "YouTube API daily quota exceeded.",
        status: status,
        domain: info.domain,
        details: raw_body
      }}}
  end

  defp classify(status, %{reason: reason} = info, retry_after, raw_body)
       when (status == 403 and reason in @rate_limit_reasons) or status == 429 do
    effective_reason = if reason in @rate_limit_reasons, do: reason, else: "rateLimitExceeded"

    {:error,
     {:rate_limited,
      %{
        reason: effective_reason,
        message: info.message || "YouTube API rate limit exceeded.",
        status: status,
        domain: info.domain,
        retry_after: retry_after,
        details: raw_body
      }}}
  end

  defp classify(status, info, _retry_after, _raw_body) do
    message =
      cond do
        is_binary(info.message) and String.trim(info.message) != "" ->
          info.message

        is_binary(info.error_description) and String.trim(info.error_description) != "" ->
          info.error_description

        is_binary(info.reason) and String.trim(info.reason) != "" ->
          "#{status}: #{info.reason}"

        true ->
          default_message_for_status(status)
      end

    {:error, {status, message}}
  end

  # --- Payload Extraction Helpers ---

  defp extract_error_info(%{"error" => %{} = error_map}) do
    # Standard Google API v3 error wrapper
    first_error =
      case error_map["errors"] do
        [first | _] when is_map(first) -> first
        _ -> %{}
      end

    first_detail =
      case error_map["details"] do
        [first | _] when is_map(first) -> first
        _ -> %{}
      end

    reason =
      first_error["reason"] ||
        first_detail["reason"] ||
        error_map["reason"] ||
        error_map["status"]

    domain = first_error["domain"] || first_detail["domain"]
    message = error_map["message"] || first_error["message"]

    %{
      reason: reason,
      domain: domain,
      message: message,
      error_description: nil
    }
  end

  defp extract_error_info(%{"error" => error_str} = map) when is_binary(error_str) do
    # Flat OAuth 2.0 error format (e.g. {"error": "invalid_grant", "error_description": "..."})
    %{
      reason: error_str,
      domain: nil,
      message: map["error_description"] || error_str,
      error_description: map["error_description"]
    }
  end

  defp extract_error_info(%{"message" => message} = map) when is_binary(message) do
    # Generic JSON message payload
    %{
      reason: map["reason"],
      domain: map["domain"],
      message: message,
      error_description: map["description"]
    }
  end

  defp extract_error_info(body) when is_binary(body) do
    %{
      reason: nil,
      domain: nil,
      message: body,
      error_description: nil
    }
  end

  defp extract_error_info(_) do
    %{
      reason: nil,
      domain: nil,
      message: nil,
      error_description: nil
    }
  end

  # --- Resiliency & Header Extraction Helpers ---

  @doc """
  Extracts the `Retry-After` header value in seconds from headers list or map.
  Returns `nil` if not present or unparseable.
  """
  @spec extract_retry_after(keyword() | map() | [{String.t(), String.t()}]) ::
          non_neg_integer() | nil
  def extract_retry_after(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, val} when is_binary(key) and is_binary(val) ->
        if String.downcase(key) == "retry-after" do
          parse_integer(val)
        end

      _ ->
        nil
    end)
  end

  def extract_retry_after(%{} = headers) do
    case Map.get(headers, "retry-after") || Map.get(headers, "Retry-After") do
      val when is_binary(val) -> parse_integer(val)
      val when is_integer(val) and val >= 0 -> val
      _ -> nil
    end
  end

  def extract_retry_after(_), do: nil

  defp parse_integer(str) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {num, ""} when num >= 0 -> num
      _ -> nil
    end
  end

  defp default_message_for_status(400), do: "Bad Request"
  defp default_message_for_status(401), do: "Unauthorized"
  defp default_message_for_status(403), do: "Forbidden"
  defp default_message_for_status(404), do: "Not Found"
  defp default_message_for_status(429), do: "Too Many Requests"
  defp default_message_for_status(500), do: "Internal Server Error"
  defp default_message_for_status(503), do: "Service Unavailable"
  defp default_message_for_status(status), do: "HTTP #{status} Error"

  # --- Public Predicates ---

  @doc """
  Returns true if the error represents a daily quota limit exhaustion.
  """
  @spec quota_exceeded?(term()) :: boolean()
  def quota_exceeded?({:error, {:quota_exceeded, _}}), do: true
  def quota_exceeded?(%{reason: r}) when r in @quota_reasons, do: true
  def quota_exceeded?(_), do: false

  @doc """
  Returns true if the error represents a rate limit / burst throttle.
  """
  @spec rate_limited?(term()) :: boolean()
  def rate_limited?({:error, {:rate_limited, _}}), do: true
  def rate_limited?(%{reason: r}) when r in @rate_limit_reasons, do: true
  def rate_limited?({:error, {429, _}}), do: true
  def rate_limited?(_), do: false

  @doc """
  Determines whether an error can be safely retried.
  Rate limits and 5xx server errors are retryable; quota exhaustion, 400s, 404s, and auth errors are NOT.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:error, {:rate_limited, _}}), do: true
  def retryable?({:error, {status, _}}) when status in [429, 500, 502, 503, 504], do: true
  def retryable?({:error, %Req.TransportError{}}), do: true
  def retryable?(_), do: false
end
```

---

## 4. Integration with `Lux.Integrations.YouTube.Client`

### 4.1. Request Lifecycle & Error Handling Flow

When `Lux.Integrations.YouTube.Client.request/3` executes, it follows this strict pipeline:

```
[Client.request(method, path, opts)]
            │
            ▼
    [Execute HTTP via Req]
            │
    ┌───────┴──────────────────────────────────────────────┐
    ▼                                                      ▼
{:ok, %{status: 200..299}}                    {:ok, %{status: status}}
    │                                                      │
    ▼                                                      ▼
{:ok, body}                                         Is status == 401?
                                                    ├── YES: auto_refresh: true & has refresh_token?
                                                    │         ├── YES: Call OAuth.refresh_token/2
                                                    │         │         ├── {:ok, %{"access_token" => new_token}}:
                                                    │         │         │     Retry request(..., opts: [token: new_token, auto_refresh: false])
                                                    │         │         └── {:error, _}:
                                                    │         │               Return {:error, :invalid_token}
                                                    │         └── NO: Return {:error, :invalid_token}
                                                    └── NO:
                                                              │
                                                              ▼
                                                Errors.parse(status, body, headers)
                                                ├── {:error, {:quota_exceeded, details}}
                                                ├── {:error, {:rate_limited, details}}
                                                └── {:error, {status, message}}
```

### 4.2. Client Pipeline Code Snippet

```elixir
def request(method, path, opts \\ %{}) do
  token = opts[:token] || Lux.Config.youtube_access_token()
  refresh_token = opts[:refresh_token] || Lux.Config.youtube_refresh_token()
  auto_refresh = Map.get(opts, :auto_refresh, true)

  headers = [
    {"Authorization", "Bearer #{token}"},
    {"Content-Type", "application/json"}
    | Map.get(opts, :headers, [])
  ]

  req_opts =
    [
      method: method,
      url: @base_endpoint <> path,
      headers: headers,
      params: opts[:params],
      json: opts[:json]
    ]
    |> Keyword.merge(Application.get_env(:lux, __MODULE__, []))
    |> maybe_add_plug(opts[:plug])

  req_opts
  |> Req.new()
  |> Req.request()
  |> case do
    {:ok, %{status: status, body: body}} when status in 200..299 ->
      {:ok, body}

    {:ok, %{status: 401} = resp} ->
      if auto_refresh and not is_nil(refresh_token) and refresh_token != "" do
        attempt_token_refresh_and_retry(method, path, refresh_token, opts)
      else
        Errors.parse(resp)
      end

    {:ok, %{status: status, body: body, headers: headers}} ->
      Errors.parse(status, body, headers)

    {:error, error} ->
      {:error, error}
  end
end

defp attempt_token_refresh_and_retry(method, path, refresh_token, opts) do
  oauth_opts = %{
    client_id: opts[:client_id] || Lux.Config.youtube_client_id(),
    client_secret: opts[:client_secret] || Lux.Config.youtube_client_secret(),
    plug: opts[:plug]
  }

  case Lux.Integrations.YouTube.OAuth.refresh_token(refresh_token, oauth_opts) do
    {:ok, %{"access_token" => new_access_token}} ->
      new_opts =
        opts
        |> Map.put(:token, new_access_token)
        |> Map.put(:auto_refresh, false)

      request(method, path, new_opts)

    {:error, _reason} ->
      {:error, :invalid_token}
  end
end
```

---

## 5. Resiliency & Retry Strategies

### 5.1. Exponential Backoff with Full Jitter Formula

For transient errors (429 Too Many Requests, 403 `userRateLimitExceeded`, 500/503 server errors), we employ **Exponential Backoff with Full Jitter** (AWS architecture standard). This avoids the "thundering herd" problem when multiple concurrent agents or pollers hit the YouTube API.

```elixir
defmodule Lux.Integrations.YouTube.Resiliency do
  @moduledoc """
  Backoff and retry utilities for YouTube integration.
  """

  @default_base_backoff_ms 500
  @default_max_backoff_ms 16_000
  @default_max_retries 3

  @doc """
  Computes exponential backoff delay with full jitter for a given attempt (1-based index).
  Formula: `delay = trunc(:rand.uniform() * min(max_backoff, base_backoff * 2^(attempt - 1)))`
  """
  @spec backoff_delay(non_neg_integer(), keyword()) :: non_neg_integer()
  def backoff_delay(attempt, opts \\ []) do
    base = Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms)
    max_delay = Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)

    temp_delay = min(max_delay, trunc(base * :math.pow(2, max(0, attempt - 1))))
    # Full jitter: random between 0 and temp_delay, minimum 50ms
    max(50, trunc(:rand.uniform() * temp_delay))
  end

  @doc """
  Executes a function with automatic retries on retryable errors.
  """
  @spec with_retry((() -> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    do_retry(fun, 1, max_retries, opts)
  end

  defp do_retry(fun, attempt, max_retries, opts) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, {:rate_limited, %{retry_after: retry_after}}} = err when attempt <= max_retries ->
        delay_ms =
          if is_integer(retry_after) and retry_after > 0 do
            retry_after * 1000
          else
            backoff_delay(attempt, opts)
          end

        Process.sleep(delay_ms)
        do_retry(fun, attempt + 1, max_retries, opts)

      {:error, reason} = err ->
        if attempt <= max_retries and Lux.Integrations.YouTube.Errors.retryable?(err) do
          delay_ms = backoff_delay(attempt, opts)
          Process.sleep(delay_ms)
          do_retry(fun, attempt + 1, max_retries, opts)
        else
          {:error, reason}
        end
    end
  end
end
```

### 5.2. Operational Guidelines for Live Chat Poller & Prisms

1. **Live Chat Polling (`Lux.Integrations.YouTube.LiveChat.Poller`)**:
   - Poller receives `pollingIntervalMillis` in every successful `list_messages` response (typically 3000ms-10000ms).
   - If the poller receives `{:error, {:rate_limited, details}}`:
     - If `details.retry_after` is set, delay polling by `details.retry_after * 1000` ms.
     - Else, increase the next polling interval by multiplying by 2 (capped at 30,000ms).
   - If the poller receives `{:error, {:quota_exceeded, _}}`:
     - Transition poller state to `:quota_exhausted`.
     - Emit error signal / log error; **do not continue looping**.
   - If the poller receives `{:error, {403, "The live chat is no longer active."}}` or reason `liveChatEnded`:
     - Transition poller state to `:completed` and stop gracefully.

---

## 6. Comprehensive `Req.Test` Fixtures & Test Matrix

### 6.1. Test Helper Integration

In `test/test_helper.exs`:
```elixir
Application.put_env(:lux, Lux.Integrations.YouTube.Client, plug: {Req.Test, YouTubeClientMock})
Application.put_env(:lux, Lux.Integrations.YouTube.OAuth, plug: {Req.Test, YouTubeOAuthMock})
```

### 6.2. JSON Response Fixtures Catalog

#### Fixture 1: Quota Exceeded (HTTP 403 `quotaExceeded`)
```elixir
def quota_exceeded_fixture do
  %{
    "error" => %{
      "code" => 403,
      "message" => "The request cannot be completed because you have exceeded your quota.",
      "errors" => [
        %{
          "message" => "The request cannot be completed because you have exceeded your quota.",
          "domain" => "youtube.quota",
          "reason" => "quotaExceeded"
        }
      ],
      "status" => "RESOURCE_EXHAUSTED"
    }
  }
end
```

#### Fixture 2: User Rate Limit Exceeded (HTTP 403 `userRateLimitExceeded`)
```elixir
def user_rate_limit_fixture do
  %{
    "error" => %{
      "code" => 403,
      "message" => "User Rate Limit Exceeded",
      "errors" => [
        %{
          "message" => "User Rate Limit Exceeded",
          "domain" => "usageLimits",
          "reason" => "userRateLimitExceeded"
        }
      ]
    }
  }
end
```

#### Fixture 3: Rate Limit Exceeded (HTTP 403 `rateLimitExceeded`)
```elixir
def rate_limit_fixture do
  %{
    "error" => %{
      "code" => 403,
      "message" => "Rate Limit Exceeded",
      "errors" => [
        %{
          "message" => "Rate Limit Exceeded",
          "domain" => "usageLimits",
          "reason" => "rateLimitExceeded"
        }
      ]
    }
  }
end
```

#### Fixture 4: Too Many Requests (HTTP 429)
```elixir
def too_many_requests_fixture do
  %{
    "error" => %{
      "code" => 429,
      "message" => "Too Many Requests",
      "errors" => [
        %{
          "message" => "Too Many Requests",
          "domain" => "global",
          "reason" => "rateLimitExceeded"
        }
      ],
      "status" => "RESOURCE_EXHAUSTED"
    }
  }
end
```

#### Fixture 5: Invalid Token / Auth Error (HTTP 401 `authError`)
```elixir
def auth_error_fixture do
  %{
    "error" => %{
      "code" => 401,
      "message" => "Request had invalid authentication credentials.",
      "errors" => [
        %{
          "message" => "Invalid Credentials",
          "domain" => "global",
          "reason" => "authError",
          "locationType" => "header",
          "location" => "Authorization"
        }
      ],
      "status" => "UNAUTHENTICATED"
    }
  }
end
```

#### Fixture 6: Live Streaming Not Enabled (HTTP 403 `liveStreamingNotEnabled`)
```elixir
def live_streaming_disabled_fixture do
  %{
    "error" => %{
      "code" => 403,
      "message" => "The user is not enabled for live streaming.",
      "errors" => [
        %{
          "message" => "The user is not enabled for live streaming.",
          "domain" => "youtube.liveBroadcast",
          "reason" => "liveStreamingNotEnabled"
        }
      ]
    }
  }
end
```

#### Fixture 7: Live Broadcast Not Found (HTTP 404 `liveBroadcastNotFound`)
```elixir
def broadcast_not_found_fixture do
  %{
    "error" => %{
      "code" => 404,
      "message" => "Broadcast not found",
      "errors" => [
        %{
          "message" => "Broadcast not found",
          "domain" => "youtube.liveBroadcast",
          "reason" => "liveBroadcastNotFound"
        }
      ]
    }
  }
end
```

#### Fixture 8: Missing Required Parameter (HTTP 400 `required`)
```elixir
def bad_request_fixture do
  %{
    "error" => %{
      "code" => 400,
      "message" => "Required parameter: part",
      "errors" => [
        %{
          "message" => "Required parameter: part",
          "domain" => "global",
          "reason" => "required",
          "location" => "part",
          "locationType" => "parameter"
        }
      ]
    }
  }
end
```

#### Fixture 9: Backend Error (HTTP 500 `backendError`)
```elixir
def backend_error_fixture do
  %{
    "error" => %{
      "code" => 500,
      "message" => "Backend Error",
      "errors" => [
        %{
          "message" => "Backend Error",
          "domain" => "global",
          "reason" => "backendError"
        }
      ]
    }
  }
end
```

#### Fixture 10: OAuth Token Refresh Error (`invalid_grant`)
```elixir
def oauth_invalid_grant_fixture do
  %{
    "error" => "invalid_grant",
    "error_description" => "Token has been expired or revoked."
  }
end
```

---

### 6.3. Comprehensive Unit Test Template for `ErrorsTest`

```elixir
defmodule Lux.Integrations.YouTube.ErrorsTest do
  use ExUnit.Case, async: true

  alias Lux.Integrations.YouTube.Errors

  describe "parse/3" do
    test "parses 403 quotaExceeded into {:error, {:quota_exceeded, details}}" do
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
      assert String.contains?(details.message, "exceeded your quota")
      assert Errors.quota_exceeded?({:error, {:quota_exceeded, details}})
      refute Errors.retryable?({:error, {:quota_exceeded, details}})
    end

    test "parses 403 userRateLimitExceeded into {:error, {:rate_limited, details}}" do
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

      assert {:error, {:rate_limited, details}} = Errors.parse(403, body)
      assert details.reason == "userRateLimitExceeded"
      assert details.status == 403
      assert details.domain == "usageLimits"
      assert Errors.rate_limited?({:error, {:rate_limited, details}})
      assert Errors.retryable?({:error, {:rate_limited, details}})
    end

    test "parses 403 rateLimitExceeded into {:error, {:rate_limited, details}}" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "Rate Limit Exceeded",
          "errors" => [
            %{
              "domain" => "usageLimits",
              "reason" => "rateLimitExceeded"
            }
          ]
        }
      }

      assert {:error, {:rate_limited, details}} = Errors.parse(403, body)
      assert details.reason == "rateLimitExceeded"
      assert details.status == 403
    end

    test "parses 429 Too Many Requests with Retry-After header" do
      body = %{
        "error" => %{
          "code" => 429,
          "message" => "Too Many Requests",
          "errors" => [%{"reason" => "rateLimitExceeded"}]
        }
      }

      headers = [{"retry-after", "10"}, {"content-type", "application/json"}]

      assert {:error, {:rate_limited, details}} = Errors.parse(429, body, headers)
      assert details.status == 429
      assert details.retry_after == 10
      assert Errors.rate_limited?({:error, {:rate_limited, details}})
    end

    test "parses 401 into {:error, :invalid_token}" do
      body = %{
        "error" => %{
          "code" => 401,
          "message" => "Invalid Credentials",
          "errors" => [%{"reason" => "authError"}]
        }
      }

      assert {:error, :invalid_token} = Errors.parse(401, body)
    end

    test "parses 400 bad request into {:error, {400, message}}" do
      body = %{
        "error" => %{
          "code" => 400,
          "message" => "Required parameter: part",
          "errors" => [%{"reason" => "required"}]
        }
      }

      assert {:error, {400, "Required parameter: part"}} = Errors.parse(400, body)
    end

    test "parses 404 not found into {:error, {404, message}}" do
      body = %{
        "error" => %{
          "code" => 404,
          "message" => "Broadcast not found",
          "errors" => [%{"reason" => "liveBroadcastNotFound"}]
        }
      }

      assert {:error, {404, "Broadcast not found"}} = Errors.parse(404, body)
    end

    test "parses 403 domain forbidden into {:error, {403, message}}" do
      body = %{
        "error" => %{
          "code" => 403,
          "message" => "The user is not enabled for live streaming.",
          "errors" => [%{"reason" => "liveStreamingNotEnabled"}]
        }
      }

      assert {:error, {403, "The user is not enabled for live streaming."}} =
               Errors.parse(403, body)
    end

    test "parses 500 server error into {:error, {500, message}}" do
      body = %{
        "error" => %{
          "code" => 500,
          "message" => "Backend Error",
          "errors" => [%{"reason" => "backendError"}]
        }
      }

      assert {:error, {500, "Backend Error"}} = Errors.parse(500, body)
      assert Errors.retryable?({:error, {500, "Backend Error"}})
    end

    test "handles flat OAuth error map" do
      body = %{
        "error" => "invalid_grant",
        "error_description" => "Token has been expired or revoked."
      }

      assert {:error, {400, "Token has been expired or revoked."}} = Errors.parse(400, body)
    end

    test "handles raw string / HTML error body gracefully" do
      assert {:error, {502, "502 Bad Gateway"}} = Errors.parse(502, "502 Bad Gateway")
      assert {:error, {503, "Service Unavailable"}} = Errors.parse(503, nil)
    end
  end
end
```

---

### 6.4. Client Error Integration Test Template with `Req.Test`

```elixir
defmodule Lux.Integrations.YouTube.ClientErrorTest do
  use UnitAPICase, async: true

  alias Lux.Integrations.YouTube.Client

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "Client error parsing & auto-refresh" do
    test "returns {:error, {:quota_exceeded, ...}} on 403 quotaExceeded" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "Quota exceeded",
              "errors" => [%{"reason" => "quotaExceeded", "domain" => "youtube.quota"}]
            }
          })
        )
      end)

      assert {:error, {:quota_exceeded, %{reason: "quotaExceeded", status: 403}}} =
               Client.request(:get, "/liveBroadcasts", %{
                 token: "test-token",
                 plug: {Req.Test, __MODULE__}
               })
    end

    test "returns {:error, {:rate_limited, ...}} on 403 userRateLimitExceeded" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "User Rate Limit Exceeded",
              "errors" => [%{"reason" => "userRateLimitExceeded"}]
            }
          })
        )
      end)

      assert {:error, {:rate_limited, %{reason: "userRateLimitExceeded", status: 403}}} =
               Client.request(:get, "/liveBroadcasts", %{
                 token: "test-token",
                 plug: {Req.Test, __MODULE__}
               })
    end

    test "auto-refreshes token on 401 when refresh_token is provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/youtube/v3/liveBroadcasts" ->
            auth_header = Plug.Conn.get_req_header(conn, "authorization")

            if auth_header == ["Bearer expired-token"] do
              send(test_pid, :received_expired_token)

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                401,
                Jason.encode!(%{
                  "error" => %{"code" => 401, "message" => "Invalid Credentials"}
                })
              )
            else
              send(test_pid, {:received_fresh_token, auth_header})

              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                200,
                Jason.encode!(%{"kind" => "youtube#liveBroadcastListResponse", "items" => []})
              )
            end

          "/token" ->
            send(test_pid, :token_refresh_called)

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "access_token" => "fresh-token-123",
                "expires_in" => 3600,
                "token_type" => "Bearer"
              })
            )
        end
      end)

      assert {:ok, %{"items" => []}} =
               Client.request(:get, "/liveBroadcasts", %{
                 token: "expired-token",
                 refresh_token: "valid-refresh-token",
                 client_id: "test-client-id",
                 client_secret: "test-client-secret",
                 plug: {Req.Test, __MODULE__}
               })

      assert_received :received_expired_token
      assert_received :token_refresh_called
      assert_received {:received_fresh_token, ["Bearer fresh-token-123"]}
    end

    test "returns {:error, :invalid_token} when 401 occurs and auto_refresh is false" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => %{"code" => 401, "message" => "Unauthorized"}
          })
        )
      end)

      assert {:error, :invalid_token} =
               Client.request(:get, "/liveBroadcasts", %{
                 token: "invalid-token",
                 auto_refresh: false,
                 plug: {Req.Test, __MODULE__}
               })
    end
  end
end
```

---

## 7. Recommendations for Implementer & Downstream Milestones

1. **Keep `Lux.Integrations.YouTube.Errors` Self-Contained**:
   - Ensure `Errors` module has zero external dependencies other than `Req` and standard Elixir library functions.
   - All parser functions should be pure and total (never crashing on odd inputs).
2. **Support Both Keyword and Map Header Collections**:
   - `Req.Response.headers` is typically a `map` in Req 0.5.x (`%{"content-type" => ["application/json"], ...}`) or keyword list. `extract_retry_after/1` handles both gracefully.
3. **Strict Quota vs Rate-Limit Separation**:
   - In M3 (`LiveChat.Poller`) and M4 (`Lenses`/`Prisms`), never retry `{:quota_exceeded, _}`. Immediately halt the poller or fail the Lens with a descriptive signal.
   - For `{:rate_limited, _}`, use exponential backoff or the `retry_after` interval.
4. **Clean Dialyzer Types & Specs**:
   - Export `@type quota_error`, `@type rate_limit_error`, `@type auth_error`, and `@type generic_error` so that Lenses, Prisms, and Pollers can use clean `@spec` definitions.

---
