defmodule Lux.Telegram.Lens do
  @moduledoc """
  Base Lens module for Telegram Bot API integration.

  Provides `use Lux.Telegram.Lens` macro to configure `use Lux.Lens` with
  custom auth function `&Lux.Integrations.Telegram.add_auth_header/1`.

  ## Examples

      defmodule MyTelegramLens do
        use Lux.Telegram.Lens,
          name: "Get Telegram Bot Info",
          description: "Fetches information about the bot user",
          url: "https://api.telegram.org/bot/getMe",
          method: :get
      end
  """

  defmacro __using__(opts) do
    auth = Keyword.get(opts, :auth, quote(do: Lux.Integrations.Telegram.auth()))
    headers = Keyword.get(opts, :headers, quote(do: Lux.Integrations.Telegram.headers()))

    opts =
      opts
      |> Keyword.put(:auth, auth)
      |> Keyword.put(:headers, headers)

    quote do
      use Lux.Lens, unquote(opts)
    end
  end
end
