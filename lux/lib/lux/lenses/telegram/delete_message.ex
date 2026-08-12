defmodule Lux.Lenses.Telegram.DeleteMessage do
  @moduledoc """
  Lens for deleting a message via Telegram Bot API.
  """

  use Lux.Telegram.Lens,
    name: "DeleteMessage",
    description: "Deletes a message from a Telegram chat",
    url: "https://api.telegram.org/bot/deleteMessage",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer], description: "Target chat ID or username"},
        message_id: %{type: :integer, description: "ID of message to delete"}
      },
      required: ["chat_id", "message_id"]
    }
end
