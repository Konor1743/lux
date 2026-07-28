defmodule Lux.LLM.OpenRouterTest do
  use UnitAPICase, async: true

  alias Lux.LLM.OpenRouter
  alias Lux.LLM.ResponseSignal
  alias Lux.Signal

  require Lux.Beam
  require Lux.Lens
  require Lux.Prism

  defmodule TestPrism do
    @moduledoc false
    use Lux.Prism,
      name: "Test Prism",
      input_schema: %{type: :object, properties: %{value: %{type: :string}}},
      description: "A test prism"

    def handler(%{"value" => "success"}, _context), do: {:ok, %{result: "success test"}}
    def handler(%{"value" => "failure"}, _context), do: {:error, "failure test"}
  end

  defmodule TestBeam do
    @moduledoc false
    use Lux.Beam,
      name: "Test Beam",
      input_schema: %{type: :object, properties: %{value: %{type: :string}}},
      description: "A test beam"

    sequence do
      step(:test, TestPrism, %{})
    end
  end

  defmodule ExceptionPrism do
    @moduledoc false
    use Lux.Prism,
      name: "Exception Prism",
      input_schema: %{type: :object},
      description: "A prism that raises an error"

    def handler(_params, _context) do
      raise "tool execution exception test"
    end
  end

  defmodule TestLensWithSchema do
    @moduledoc false
    use Lux.Lens,
      name: "WeatherAPI",
      description: "Gets weather data",
      schema: %{
        type: "object",
        properties: %{
          location: %{
            type: "string",
            description: "City name"
          },
          units: %{
            type: "string",
            description: "Temperature units"
          }
        }
      }
  end

  defmodule TestLensWithParams do
    @moduledoc false
    use Lux.Lens,
      name: "ParamsAPI",
      description: "Gets params data",
      params: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Query parameter"
          }
        }
      }
  end

  setup do
    Req.Test.verify_on_exit!()
  end

  describe "tool_to_function/1" do
    test "converts a beam to an OpenRouter function" do
      beam = TestBeam.view()

      function = OpenRouter.tool_to_function(beam)

      assert %{
               type: "function",
               function: %{
                 name: "Lux_LLM_OpenRouterTest_TestBeam",
                 description: "A test beam",
                 parameters: %{
                   type: :object,
                   properties: %{
                     value: %{type: :string}
                   }
                 }
               }
             } = function
    end

    test "converts a prism to an OpenRouter function" do
      prism = TestPrism.view()

      function = OpenRouter.tool_to_function(prism)

      assert %{
               type: "function",
               function: %{
                 name: "Lux_LLM_OpenRouterTest_TestPrism",
                 description: "A test prism",
                 parameters: %{
                   type: :object,
                   properties: %{
                     value: %{type: :string}
                   }
                 }
               }
             } = function
    end

    test "converts a lens with schema to an OpenRouter function" do
      lens = TestLensWithSchema.view()

      function = OpenRouter.tool_to_function(lens)

      assert %{
               type: "function",
               function: %{
                 name: "Lux_LLM_OpenRouterTest_TestLensWithSchema",
                 description: "Gets weather data",
                 parameters: %{
                   type: "object",
                   properties: %{
                     location: %{type: "string", description: "City name"},
                     units: %{type: "string", description: "Temperature units"}
                   }
                 }
               }
             } = function
    end

    test "converts a lens with params to an OpenRouter function" do
      lens = TestLensWithParams.view()

      function = OpenRouter.tool_to_function(lens)

      assert %{
               type: "function",
               function: %{
                 name: "Lux_LLM_OpenRouterTest_TestLensWithParams",
                 description: "Gets params data",
                 parameters: %{
                   type: "object",
                   properties: %{
                     query: %{type: "string", description: "Query parameter"}
                   }
                 }
               }
             } = function
    end

    test "converts explicit %Lens{} struct with schema" do
      lens_schema = %Lux.Lens{
        name: "ExplicitSchema",
        module_name: "Explicit.Schema",
        description: "Schema Lens",
        schema: %{type: "object", properties: %{field1: %{type: "string"}}}
      }

      func1 = OpenRouter.tool_to_function(lens_schema)
      assert func1.function.name == "Explicit_Schema"
      assert func1.function.parameters == %{type: "object", properties: %{field1: %{type: "string"}}}
    end
  end

  describe "call/3" do
    test "successful API completion with ResponseSignal payload & token usage extraction" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o-mini"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/chat/completions"

        assert ["Bearer test_key"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)

        assert decoded_body["model"] == "openai/gpt-4o-mini"

        Req.Test.json(conn, %{
          "id" => "gen-12345",
          "created" => 1700000000,
          "model" => "openai/gpt-4o-mini",
          "choices" => [
            %{
              "message" => %{
                "content" => ~s({"result": "Successful response"})
              },
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{
            "prompt_tokens" => 12,
            "completion_tokens" => 8,
            "total_tokens" => 20
          }
        })
      end)

      assert {:ok,
              %Signal{
                schema_id: ResponseSignal,
                payload: %{
                  content: %{"result" => "Successful response"},
                  finish_reason: "stop",
                  model: "openai/gpt-4o-mini",
                  tool_calls: nil,
                  tool_calls_results: nil
                },
                metadata: %{
                  id: "gen-12345",
                  created: 1700000000,
                  usage: %{
                    "prompt_tokens" => 12,
                    "completion_tokens" => 8,
                    "total_tokens" => 20
                  }
                }
              }} = OpenRouter.call("test prompt", [], config)
    end

    test "optional headers: HTTP-Referer and X-OpenRouter-Title passed and verified" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o",
        site_url: "https://my-awesome-site.com",
        site_name: "My Awesome App"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        assert ["https://my-awesome-site.com"] = Plug.Conn.get_req_header(conn, "http-referer")
        assert ["My Awesome App"] = Plug.Conn.get_req_header(conn, "x-openrouter-title")

        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o",
          "choices" => [
            %{
              "message" => %{"content" => ~s({"result": "Header test passed"})},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10}
        })
      end)

      assert {:ok, %Signal{payload: %{content: %{"result" => "Header test passed"}}}} =
               OpenRouter.call("test prompt", [], config)
    end

    test "optional headers with http_referer and openrouter_title keys" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o",
        http_referer: "https://referer-site.com",
        openrouter_title: "Title App"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        assert ["https://referer-site.com"] = Plug.Conn.get_req_header(conn, "http-referer")
        assert ["Title App"] = Plug.Conn.get_req_header(conn, "x-openrouter-title")

        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o",
          "choices" => [
            %{
              "message" => %{"content" => ~s({"result": "Referer test passed"})},
              "finish_reason" => "stop"
            }
          ]
        })
      end)

      assert {:ok, %Signal{}} = OpenRouter.call("test prompt", [], config)
    end

    test "dynamic model slugs (e.g. ~openai/gpt-latest)" do
      config = %{
        api_key: "test_key",
        model: "~openai/gpt-latest"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)

        assert decoded_body["model"] == "~openai/gpt-latest"

        Req.Test.json(conn, %{
          "model" => "~openai/gpt-latest",
          "choices" => [
            %{
              "message" => %{"content" => ~s({"result": "Dynamic slug response"})},
              "finish_reason" => "stop"
            }
          ]
        })
      end)

      assert {:ok, %Signal{payload: %{model: "~openai/gpt-latest"}}} =
               OpenRouter.call("test prompt", [], config)
    end

    test "handles tool execution (Prism tool call)" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o-mini"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o-mini",
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "type" => "function",
                    "function" => %{
                      "name" => "#{TestPrism}",
                      "arguments" => ~s({"value": "success"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })
      end)

      assert {:ok,
              %Signal{
                schema_id: ResponseSignal,
                payload: %{
                  content: nil,
                  finish_reason: "tool_calls",
                  model: "openai/gpt-4o-mini",
                  tool_calls: [
                    %{
                      "function" => %{
                        "arguments" => ~s({"value": "success"}),
                        "name" => "Elixir.Lux.LLM.OpenRouterTest.TestPrism"
                      },
                      "type" => "function"
                    }
                  ],
                  tool_calls_results: [%{result: "success test"}]
                }
              }} = OpenRouter.call("test prompt", [TestPrism], config)
    end

    test "error status handling: 401 invalid API key" do
      config = %{
        api_key: "invalid_key",
        model: "openai/gpt-4o-mini"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        Plug.Conn.send_resp(conn, 401, Jason.encode!(%{"error" => %{"message" => "Invalid API key"}}))
      end)

      assert {:error, :invalid_api_key} = OpenRouter.call("test prompt", [], config)
    end

    test "error status handling: 400 bad request" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o-mini"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        Plug.Conn.send_resp(conn, 400, Jason.encode!(%{"error" => %{"message" => "Unsupported parameters"}}))
      end)

      assert {:error, {400, "Unsupported parameters"}} = OpenRouter.call("test prompt", [], config)
    end

    test "adversarial header handling: dynamic tuple resolution and fallback edge cases" do
      System.put_env("TEST_OPENROUTER_KEY", "env_secret_key")
      System.put_env("TEST_SITE_URL", "https://env-site.com")
      System.put_env("TEST_SITE_NAME", "Env App Name")

      config = %{
        api_key: {:env, "TEST_OPENROUTER_KEY"},
        model: "openai/gpt-4o",
        site_url: {:env, "TEST_SITE_URL"},
        site_name: {:env, "TEST_SITE_NAME"}
      }

      Req.Test.expect(OpenRouter, fn conn ->
        assert ["Bearer env_secret_key"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["https://env-site.com"] = Plug.Conn.get_req_header(conn, "http-referer")
        assert ["Env App Name"] = Plug.Conn.get_req_header(conn, "x-openrouter-title")

        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o",
          "choices" => [%{"message" => %{"content" => "OK"}, "finish_reason" => "stop"}]
        })
      end)

      assert {:ok, %Signal{}} = OpenRouter.call("test prompt", [], config)
    end

    test "adversarial model slug handling: custom slugs and model: nil fallback" do
      config = %{
        api_key: "test_key",
        model: "meta-llama/llama-3.3-70b-instruct:free"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "meta-llama/llama-3.3-70b-instruct:free"

        Req.Test.json(conn, %{
          "model" => "meta-llama/llama-3.3-70b-instruct:free",
          "choices" => [%{"message" => %{"content" => "OK"}, "finish_reason" => "stop"}]
        })
      end)

      assert {:ok, %Signal{payload: %{model: "meta-llama/llama-3.3-70b-instruct:free"}}} =
               OpenRouter.call("test prompt", [], config)
    end

    test "adversarial token stats: missing usage, zero usage, and null usage field" do
      config = %{api_key: "test_key", model: "openai/gpt-4o-mini"}

      # Case A: Missing usage key
      Req.Test.expect(OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o-mini",
          "choices" => [%{"message" => %{"content" => "OK"}, "finish_reason" => "stop"}]
        })
      end)

      assert {:ok, %Signal{metadata: %{usage: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}}}} =
               OpenRouter.call("test prompt", [], config)

      # Case B: Null usage key
      Req.Test.expect(OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o-mini",
          "choices" => [%{"message" => %{"content" => "OK"}, "finish_reason" => "stop"}],
          "usage" => nil
        })
      end)

      assert {:ok, %Signal{metadata: %{usage: %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}}}} =
               OpenRouter.call("test prompt", [], config)
    end

    test "adversarial error handling: 500 internal server error and string error bodies" do
      config = %{api_key: "test_key", model: "openai/gpt-4o-mini"}

      # Case 500 nested error
      Req.Test.expect(OpenRouter, fn conn ->
        Plug.Conn.send_resp(conn, 500, Jason.encode!(%{"error" => %{"message" => "Internal Server Error"}}))
      end)

      assert {:error, {500, "Internal Server Error"}} = OpenRouter.call("test prompt", [], config)

      # Case 500 raw HTML error body
      Req.Test.expect(OpenRouter, fn conn ->
        Plug.Conn.send_resp(conn, 500, "<html>Bad Gateway</html>")
      end)

      assert {:error, {500, "\"<html>Bad Gateway</html>\""}} = OpenRouter.call("test prompt", [], config)
    end

    test "adversarial tool execution: missing module and argument JSON decode failure" do
      config = %{api_key: "test_key", model: "openai/gpt-4o-mini"}

      Req.Test.expect(OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o-mini",
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "type" => "function",
                    "function" => %{
                      "name" => "NonExistentModule",
                      "arguments" => "{invalid_json}"
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })
      end)

      assert {:error, msg} = OpenRouter.call("test prompt", [], config)
      assert msg =~ "Failed to decode arguments for tool NonExistentModule"
    end

    test "header truthiness guard: empty string http_referer and openrouter_title fall back to site_url and site_name" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o",
        http_referer: "",
        site_url: "https://fallback-url.com",
        openrouter_title: "",
        site_name: "Fallback App Title"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        assert ["https://fallback-url.com"] = Plug.Conn.get_req_header(conn, "http-referer")
        assert ["Fallback App Title"] = Plug.Conn.get_req_header(conn, "x-openrouter-title")

        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o",
          "choices" => [%{"message" => %{"content" => ~s({"result": "OK"})}, "finish_reason" => "stop"}]
        })
      end)

      assert {:ok, %Signal{}} = OpenRouter.call("test prompt", [], config)
    end

    test "plain-text content parsing compatibility with ResponseSignal schema" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o-mini"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o-mini",
          "choices" => [
            %{
              "message" => %{
                "content" => "This is raw unformatted text content from OpenRouter."
              },
              "finish_reason" => "stop"
            }
          ]
        })
      end)

      assert {:ok,
              %Signal{
                schema_id: ResponseSignal,
                payload: %{
                  content: %{"text" => "This is raw unformatted text content from OpenRouter."},
                  finish_reason: "stop"
                }
              }} = OpenRouter.call("test prompt", [], config)
    end

    test "tool execution exception rescue prevents process crash" do
      config = %{
        api_key: "test_key",
        model: "openai/gpt-4o-mini"
      }

      Req.Test.expect(OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "model" => "openai/gpt-4o-mini",
          "choices" => [
            %{
              "message" => %{
                "tool_calls" => [
                  %{
                    "type" => "function",
                    "function" => %{
                      "name" => "#{ExceptionPrism}",
                      "arguments" => ~s({"value": "trigger_exception"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })
      end)

      assert {:error, error_msg} = OpenRouter.call("test prompt", [ExceptionPrism], config)
      assert error_msg =~ "Error executing tool"
      assert error_msg =~ "tool execution exception test"
    end
  end

  describe "parse_content/1" do
    test "parses valid JSON string into map" do
      assert {:ok, %{"key" => "value"}} = OpenRouter.parse_content(~s({"key": "value"}))
    end

    test "wraps plain text string into text map for ResponseSignal schema compatibility" do
      assert {:ok, %{"text" => "Plain string"}} = OpenRouter.parse_content("Plain string")
    end

    test "handles nil and map content" do
      assert {:ok, nil} = OpenRouter.parse_content(nil)
      assert {:ok, %{"a" => 1}} = OpenRouter.parse_content(%{"a" => 1})
    end
  end

  describe "execute_tool_call/1" do
    test "rescues runtime exceptions raised by tool execution" do
      tool_call = %{
        "function" => %{
          "name" => "#{ExceptionPrism}",
          "arguments" => %{"value" => "foo"}
        }
      }

      assert {:error, msg} = OpenRouter.execute_tool_call(tool_call)
      assert msg =~ "Error executing tool"
      assert msg =~ "tool execution exception test"
    end

    test "safely reports JSON argument decode failure" do
      tool_call = %{
        "function" => %{
          "name" => "SomeTool",
          "arguments" => "{invalid_json}"
        }
      }

      assert {:error, msg} = OpenRouter.execute_tool_call(tool_call)
      assert msg =~ "Failed to decode arguments for tool SomeTool"
    end
  end
end

