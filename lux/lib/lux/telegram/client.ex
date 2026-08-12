defmodule Lux.Telegram.Client do
  @moduledoc """
  Client module for Telegram Bot API integration. Delegates to `Lux.Integrations.Telegram.Client`.
  """

  @doc """
  Makes an HTTP request to Telegram Bot API endpoint.
  """
  def request(method, path, opts \\ %{}) do
    Lux.Integrations.Telegram.Client.request(method, path, opts)
  end
end
