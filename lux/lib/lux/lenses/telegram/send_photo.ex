defmodule Lux.Lenses.Telegram.SendPhoto do
  @moduledoc """
  Lens for sending a photo via Telegram Bot API.
  """

  use Lux.Telegram.Lens,
    name: "SendPhoto",
    description: "Sends a photo to a Telegram chat",
    url: "https://api.telegram.org/bot/sendPhoto",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer], description: "Target chat ID or username"},
        photo: %{type: :string, description: "Photo file_id or HTTP URL"},
        caption: %{type: :string, description: "Photo caption"}
      },
      required: ["chat_id", "photo"]
    }
end
