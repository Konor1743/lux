defmodule Lux.LLM.FallbackTest do
  use UnitAPICase, async: true

  alias Lux.LLM.Fallback
  alias Lux.LLM.ResponseSignal
  alias Lux.Signal

  defp make_ok_signal(model_name) do
    payload = %{
      content: %{"answer" => "ok from #{model_name}"},
      model: model_name,
      finish_reason: "stop",
      tool_calls: nil,
      tool_calls_results: nil
    }

    Signal.new(%{schema_id: ResponseSignal, payload: payload, metadata: %{}})
  end

  describe "fallback_error?/2" do
    test "returns true for HTTP 429, 503, and server error codes" do
      assert Fallback.fallback_error?({429, "Rate limit"})
      assert Fallback.fallback_error?({503, "Service unavailable"})
      assert Fallback.fallback_error?({500, "Internal error"})
      assert Fallback.fallback_error?(429)
      assert Fallback.fallback_error?(503)
    end

    test "returns true for network errors" do
      assert Fallback.fallback_error?(:econnrefused)
      assert Fallback.fallback_error?(:timeout)
      assert Fallback.fallback_error?(:closed)
      assert Fallback.fallback_error?(%Req.TransportError{reason: :econnrefused})
    end

    test "returns true for string messages matching error criteria" do
      assert Fallback.fallback_error?("Error 429: Too Many Requests")
      assert Fallback.fallback_error?("Service overloaded 503")
      assert Fallback.fallback_error?("connection refused by peer")
    end

    test "returns false for unhandled domain errors unless fallback_on_all_errors is set" do
      refute Fallback.fallback_error?(:invalid_api_key)
      assert Fallback.fallback_error?(:invalid_api_key, %{fallback_on_all_errors: true})
    end

    test "returns true for additional error atoms and HTTP status codes" do
      for atom <- [:rate_limit, :too_many_requests, :service_unavailable, :timeout, :connect_timeout] do
        assert Fallback.fallback_error?(atom)
      end

      for status <- [408, 429, 500, 502, 503, 504, 507, 529] do
        assert Fallback.fallback_error?(status)
        assert Fallback.fallback_error?({status, "Error message"})
      end
    end
  end

  describe "call/3 failover execution" do
    test "returns primary result when primary succeeds" do
      primary_spec = fn _p, _t -> {:ok, make_ok_signal("primary")} end
      fallback_spec = fn _p, _t -> {:ok, make_ok_signal("fallback")} end

      assert {:ok, signal} = Fallback.call("hello", [], primary: primary_spec, fallbacks: [fallback_spec])
      assert signal.payload.model == "primary"
      assert signal.metadata.fallback_history == []
    end

    test "transparently fails over to fallback when primary encounters 429" do
      primary_spec = fn _p, _t -> {:error, {429, "Rate limit exceeded"}} end
      fallback_spec = fn _p, _t -> {:ok, make_ok_signal("fallback_1")} end

      assert {:ok, signal} = Fallback.call("hello", [], primary: primary_spec, fallbacks: [fallback_spec])
      assert signal.payload.model == "fallback_1"

      assert [attempt] = signal.metadata.fallback_history
      assert attempt.error == {429, "Rate limit exceeded"}
      assert %DateTime{} = attempt.timestamp
    end

    test "traverses multiple fallbacks sequentially recording history" do
      primary_spec = fn _p, _t -> {:error, {429, "Rate limit"}} end
      fallback_1 = fn _p, _t -> {:error, {503, "Service unavailable"}} end
      fallback_2 = fn _p, _t -> {:ok, make_ok_signal("fallback_2")} end

      assert {:ok, signal} = Fallback.call("hello", [], primary: primary_spec, fallbacks: [fallback_1, fallback_2])
      assert signal.payload.model == "fallback_2"

      history = signal.metadata.fallback_history
      assert length(history) == 2

      [attempt1, attempt2] = history
      assert attempt1.error == {429, "Rate limit"}
      assert attempt2.error == {503, "Service unavailable"}
    end

    test "returns error tuple when all fallbacks fail" do
      primary_spec = fn _p, _t -> {:error, {429, "Rate limit"}} end
      fallback_spec = fn _p, _t -> {:error, :econnrefused} end

      assert {:error, {:all_fallbacks_failed, history}} =
               Fallback.call("hello", [], primary: primary_spec, fallbacks: [fallback_spec])

      assert length(history) == 2
    end

    test "stops immediately on non-retryable error when fallback_on_all_errors is false" do
      primary_spec = fn _p, _t -> {:error, :invalid_request} end
      fallback_spec = fn _p, _t -> {:ok, make_ok_signal("fallback")} end

      assert {:error, :invalid_request} =
               Fallback.call("hello", [], primary: primary_spec, fallbacks: [fallback_spec])
    end
  end

  describe "AC2: Fallback integration with control options" do
    test "Fallback.call with router spec and control options does not raise KeyError on strict provider" do
      reg_name = :"ac2_fallback_strict_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Lux.LLM.ProviderRegistry.start_link(name: reg_name, providers: [Lux.LLM.RouterTest.StrictProvider])

      control_opts = [
        primary: {Lux.LLM.Router, [registry_name: reg_name, provider_id: :strict_provider, strategy: :cheapest]},
        fallbacks: [],
        fallback_on_all_errors: true,
        capabilities: [],
        estimated_prompt_tokens: 100,
        estimated_completion_tokens: 100
      ]

      assert {:ok, signal} = Fallback.call("hello", [], control_opts)
      assert signal.payload.model == "strict-model"
    end

    test "Fallback.call with router spec and control options works with OpenAI provider" do
      Req.Test.verify_on_exit!()

      reg_name = :"ac2_fallback_openai_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Lux.LLM.ProviderRegistry.start_link(name: reg_name, providers: [Lux.LLM.OpenAI])

      Req.Test.expect(Lux.LLM.OpenAI, fn conn ->
        Req.Test.json(conn, %{
          "model" => "gpt-4o",
          "choices" => [
            %{
              "message" => %{"content" => ~s({"result": "fallback_openai_ok"})},
              "finish_reason" => "stop"
            }
          ]
        })
      end)

      control_opts = [
        primary: {Lux.LLM.Router, [registry_name: reg_name, provider_id: :openai, strategy: :smartest]},
        fallbacks: [],
        fallback_on_all_errors: true,
        capabilities: [:tools],
        estimated_prompt_tokens: 500,
        estimated_completion_tokens: 500
      ]

      assert {:ok, signal} = Fallback.call("hello", [], control_opts)
      assert signal.payload.model == "gpt-4o"
    end
  end

  describe "AC3: Documented direct-provider fallback integration" do
    test "Fallback.call with atom provider ID filters control options and preserves credentials" do
      reg_name = :"ac3_fallback_atom_#{System.unique_integer([:positive])}"

      config = %Lux.LLM.ProviderConfig{
        id: :strict_provider,
        module: Lux.LLM.RouterTest.StrictProvider,
        api_key: nil
      }
      {:ok, _pid} = Lux.LLM.ProviderRegistry.start_link(name: reg_name, providers: [config])

      control_opts = [
        primary: :strict_provider,
        fallbacks: [],
        fallback_on_all_errors: true,
        registry_name: reg_name,
        capabilities: [],
        api_key: "app-configured-key"
      ]

      assert {:ok, signal} = Fallback.call("hello", [], control_opts)
      assert signal.payload.model == "strict-model"
    end

    test "Fallback.call with %ProviderConfig{} spec filters control options and preserves credentials" do
      config = %Lux.LLM.ProviderConfig{
        id: :strict_provider,
        module: Lux.LLM.RouterTest.StrictProvider,
        api_key: nil
      }

      control_opts = [
        primary: config,
        fallbacks: [],
        fallback_on_all_errors: true,
        api_key: "app-configured-key"
      ]

      assert {:ok, signal} = Fallback.call("hello", [], control_opts)
      assert signal.payload.model == "strict-model"
    end
  end
end
