defmodule Lux.Lenses.Telegram.SendDocument do
  @moduledoc """
  Lens for sending a document via Telegram Bot API.
  """

  use Lux.Telegram.Lens,
    name: "SendDocument",
    description: "Sends a document to a Telegram chat",
    url: "https://api.telegram.org/bot/sendDocument",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer], description: "Target chat ID or username"},
        document: %{type: :string, description: "Document file_id or HTTP URL"},
        caption: %{type: :string, description: "Document caption"}
      },
      required: ["chat_id", "document"]
    }
end
