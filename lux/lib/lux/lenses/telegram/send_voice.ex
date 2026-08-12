defmodule Lux.Lenses.Telegram.SendVoice do
  @moduledoc """
  Lens for sending voice audio via Telegram Bot API.
  """

  use Lux.Telegram.Lens,
    name: "SendVoice",
    description: "Sends a voice message to a Telegram chat",
    url: "https://api.telegram.org/bot/sendVoice",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        chat_id: %{type: [:string, :integer], description: "Target chat ID or username"},
        voice: %{type: :string, description: "Voice file_id or HTTP URL"},
        caption: %{type: :string, description: "Voice caption"}
      },
      required: ["chat_id", "voice"]
    }
end
