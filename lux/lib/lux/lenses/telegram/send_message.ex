defmodule Lux.Lenses.Telegram.SendMessage do
  @moduledoc """
  Lens for sending a text message via Telegram Bot API.
  """

  use Lux.Telegram.Lens,
    name: "SendMessage",
    description: "Sends a text message to a Telegram chat",
    url: "https://api.telegram.org/bot/sendMessage",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer], description: "Target chat ID or username"},
        text: %{type: :string, description: "Text message to send"},
        parse_mode: %{type: :string, description: "Formatting mode"}
      },
      required: ["chat_id", "text"]
    }
end
