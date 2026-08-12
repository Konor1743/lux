defmodule Lux.Telegram.WebhookPlug do
  @moduledoc """
  Plug endpoint for receiving and processing Telegram Bot API webhook updates.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl true
  def init(opts) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts || %{}

    secret_token =
      cond do
        is_binary(opts_map[:secret_token]) and opts_map[:secret_token] != "" ->
          opts_map[:secret_token]

        is_binary(opts_map["secret_token"]) and opts_map["secret_token"] != "" ->
          opts_map["secret_token"]

        true ->
          fetch_config_secret_token()
      end

    handler = Map.get(opts_map, :handler)

    %{
      secret_token: secret_token,
      handler: handler
    }
  end

  @impl true
  def call(conn, opts) do
    if secret_token_valid?(conn, opts.secret_token) do
      handle_update(conn, opts)
    else
      unauthorized(conn)
    end
  end

  defp secret_token_valid?(_conn, nil), do: true
  defp secret_token_valid?(_conn, ""), do: true

  defp secret_token_valid?(conn, expected_token) when is_binary(expected_token) do
    case get_req_header(conn, "x-telegram-bot-api-secret-token") do
      [header_token] -> Plug.Crypto.secure_compare(header_token, expected_token)
      _ -> false
    end
  end

  defp handle_update(conn, opts) do
    payload = parse_payload(conn)

    signal =
      case Lux.Signals.TelegramUpdate.new(payload) do
        {:ok, sig} -> sig
        sig -> sig
      end

    dispatch_signal(signal, opts.handler)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  defp parse_payload(%Plug.Conn{body_params: %{"update_id" => _} = params}), do: params
  defp parse_payload(%Plug.Conn{body_params: params}) when is_map(params) and not is_struct(params) and map_size(params) > 0, do: params

  defp parse_payload(conn) do
    case read_body(conn) do
      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp dispatch_signal(signal, handler) do
    cond do
      is_function(handler, 1) ->
        try do
          handler.(signal)
        rescue
          e -> Logger.error("WebhookPlug handler error: #{inspect(e)}")
        end

      is_pid(handler) ->
        send(handler, {:telegram_update, signal})

      is_atom(handler) and handler != nil ->
        if Code.ensure_loaded?(handler) and function_exported?(handler, :handle_signal, 1) do
          handler.handle_signal(signal)
        else
          :ok
        end

      true ->
        :ok
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized", status: "error"}))
    |> halt()
  end

  defp fetch_config_secret_token do
    try do
      case Lux.Config.telegram_secret_token() do
        token when is_binary(token) -> token
        _ -> System.get_env("TELEGRAM_SECRET_TOKEN")
      end
    rescue
      _ -> System.get_env("TELEGRAM_SECRET_TOKEN")
    catch
      _ -> System.get_env("TELEGRAM_SECRET_TOKEN")
    end
  end
end
