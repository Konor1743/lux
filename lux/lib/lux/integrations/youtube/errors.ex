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
    "RESOURCE_EXHAUSTED_QUOTA",
    "RESOURCE_EXHAUSTED"
  ]

  @rate_limit_reasons [
    "rateLimitExceeded",
    "userRateLimitExceeded",
    "concurrentLimitExceeded",
    "servingLimitExceeded",
    "RATE_LIMIT_EXCEEDED",
    "USER_RATE_LIMIT_EXCEEDED"
  ]

  @default_base_backoff_ms 500
  @default_max_backoff_ms 16_000
  @default_max_retries 3

  @doc """
  Parses a `Req.Response` or `{status, body, headers}` into a structured error tuple.
  """
  @spec parse(integer() | Req.Response.t(), term(), keyword() | map() | [{String.t(), String.t()}]) ::
          parsed_error()
  def parse(response_or_status, body \\ nil, headers \\ [])

  def parse(%Req.Response{status: status, body: body, headers: headers}, _body, _headers) do
    parse(status, body, headers)
  end

  def parse(status, body, headers) when is_integer(status) do
    extracted = extract_error_info(body)
    retry_after = extract_retry_after(headers)

    classify(status, extracted, retry_after, body)
  end

  # --- Error Classification Logic ---

  defp classify(401, _extracted, _retry_after, _raw_body) do
    {:error, :invalid_token}
  end

  defp classify(status, %{reason: reason} = info, _retry_after, raw_body)
       when (status == 403 and reason in @quota_reasons) or
              (status == 429 and reason in ["quotaExceeded", "dailyLimitExceeded", "QUOTA_EXCEEDED", "RESOURCE_EXHAUSTED_QUOTA"]) do
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
    first_error =
      case error_map["errors"] do
        [first | _] when is_map(first) -> first
        _ -> %{}
      end

    details = error_map["details"] || error_map[:details]
    {detail_reason, detail_domain, detail_msg} = extract_from_details_list(details)

    reason =
      first_error["reason"] ||
        first_error[:reason] ||
        detail_reason ||
        error_map["reason"] ||
        error_map[:reason] ||
        error_map["status"] ||
        error_map[:status]

    domain = first_error["domain"] || first_error[:domain] || detail_domain

    message =
      error_map["message"] ||
        error_map[:message] ||
        first_error["message"] ||
        first_error[:message] ||
        detail_msg

    %{
      reason: reason,
      domain: domain,
      message: message,
      error_description: nil
    }
  end

  defp extract_error_info(%{error: %{} = error_map}) do
    first_error =
      case error_map[:errors] || error_map["errors"] do
        [first | _] when is_map(first) -> first
        _ -> %{}
      end

    details = error_map[:details] || error_map["details"]
    {detail_reason, detail_domain, detail_msg} = extract_from_details_list(details)

    reason =
      first_error[:reason] ||
        first_error["reason"] ||
        detail_reason ||
        error_map[:reason] ||
        error_map["reason"] ||
        error_map[:status] ||
        error_map["status"]

    domain = first_error[:domain] || first_error["domain"] || detail_domain

    message =
      error_map[:message] ||
        error_map["message"] ||
        first_error[:message] ||
        first_error["message"] ||
        detail_msg

    %{
      reason: reason,
      domain: domain,
      message: message,
      error_description: nil
    }
  end

  defp extract_error_info(%{"error" => error_str} = map) when is_binary(error_str) do
    %{
      reason: error_str,
      domain: nil,
      message: map["error_description"] || map[:error_description] || error_str,
      error_description: map["error_description"] || map[:error_description]
    }
  end

  defp extract_error_info(%{error: error_str} = map) when is_binary(error_str) do
    %{
      reason: error_str,
      domain: nil,
      message: map[:error_description] || map["error_description"] || error_str,
      error_description: map[:error_description] || map["error_description"]
    }
  end

  defp extract_error_info(%{"message" => message} = map) when is_binary(message) do
    %{
      reason: map["reason"] || map[:reason],
      domain: map["domain"] || map[:domain],
      message: message,
      error_description: map["description"] || map[:description]
    }
  end

  defp extract_error_info(%{message: message} = map) when is_binary(message) do
    %{
      reason: map[:reason] || map["reason"],
      domain: map[:domain] || map["domain"],
      message: message,
      error_description: map[:description] || map["description"]
    }
  end

  defp extract_error_info(body) when is_binary(body) do
    # Try decoding JSON if string
    case Jason.decode(body) do
      {:ok, %{} = decoded} ->
        extract_error_info(decoded)

      _ ->
        %{
          reason: nil,
          domain: nil,
          message: body,
          error_description: nil
        }
    end
  end

  defp extract_error_info(_) do
    %{
      reason: nil,
      domain: nil,
      message: nil,
      error_description: nil
    }
  end

  defp extract_from_details_list(details) when is_list(details) do
    reason =
      Enum.find_value(details, fn
        %{"reason" => r} when is_binary(r) and r != "" -> r
        %{reason: r} when is_binary(r) and r != "" -> r
        _ -> nil
      end)

    domain =
      Enum.find_value(details, fn
        %{"domain" => d} when is_binary(d) and d != "" -> d
        %{domain: d} when is_binary(d) and d != "" -> d
        _ -> nil
      end)

    msg =
      Enum.find_value(details, fn
        %{"message" => m} when is_binary(m) and m != "" -> m
        %{message: m} when is_binary(m) and m != "" -> m
        _ -> nil
      end)

    {reason, domain, msg}
  end

  defp extract_from_details_list(_), do: {nil, nil, nil}

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

      {key, [val | _]} when is_binary(key) and is_binary(val) ->
        if String.downcase(key) == "retry-after" do
          parse_integer(val)
        end

      {key, val} when is_atom(key) and is_binary(val) ->
        if key in [:"retry-after", :retry_after] do
          parse_integer(val)
        end

      _ ->
        nil
    end)
  end

  def extract_retry_after(%{} = headers) do
    case Map.get(headers, "retry-after") || Map.get(headers, "Retry-After") || Map.get(headers, :retry_after) do
      val when is_binary(val) -> parse_integer(val)
      val when is_integer(val) and val >= 0 -> val
      [val | _] when is_binary(val) -> parse_integer(val)
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
  Rate limits and 5xx server errors are retryable; quota exhaustion, 400s, 404s, and auth errors are not.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:error, {:rate_limited, _}}), do: true
  def retryable?({:error, {status, _}}) when status in [429, 500, 502, 503, 504], do: true
  def retryable?({:error, %Req.TransportError{}}), do: true
  def retryable?(_), do: false

  # --- Exponential Backoff & Retry Helpers ---

  @doc """
  Computes exponential backoff delay with full jitter for a given attempt (1-based index).
  Formula: `delay = max(min_delay, trunc(:rand.uniform() * min(max_backoff, base_backoff * 2^(attempt - 1))))`
  """
  @spec backoff_delay(non_neg_integer(), keyword()) :: non_neg_integer()
  def backoff_delay(attempt, opts \\ []) do
    base = Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms)
    max_delay = Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    min_delay = Keyword.get(opts, :min_backoff_ms, 50)

    clamped_exp = min(max(0, attempt - 1), 30)
    temp_delay = min(max_delay, trunc(base * :math.pow(2, clamped_exp)))
    jitter_factor = :rand.uniform()
    max(min_delay, trunc(jitter_factor * temp_delay))
  end

  @doc """
  Executes a 0-arity function with automatic retries on retryable errors.
  """
  @spec with_retry((() -> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    do_retry(fun, 1, max_retries, opts)
  end

  defp do_retry(fun, attempt, max_retries, opts) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, {:rate_limited, %{retry_after: retry_after}}} when attempt <= max_retries ->
        delay_ms =
          if is_integer(retry_after) and retry_after > 0 do
            retry_after * 1000
          else
            backoff_delay(attempt, opts)
          end

        sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
        sleep_fun.(delay_ms)
        do_retry(fun, attempt + 1, max_retries, opts)

      {:error, _reason} = err ->
        if attempt <= max_retries and retryable?(err) do
          delay_ms = backoff_delay(attempt, opts)
          sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
          sleep_fun.(delay_ms)
          do_retry(fun, attempt + 1, max_retries, opts)
        else
          err
        end
    end
  end
end
