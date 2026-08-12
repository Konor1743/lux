defmodule Lux.Lenses.Telegram.GetFile do
  @moduledoc """
  Lens for fetching file metadata via Telegram Bot API.
  """

  use Lux.Telegram.Lens,
    name: "GetFile",
    description: "Gets basic info about a file and prepares it for downloading",
    url: "https://api.telegram.org/bot/getFile",
    method: :post,
    schema: %{
      type: :object,
      properties: %{
        file_id: %{type: :string, description: "File identifier to get info about"}
      },
      required: ["file_id"]
    }
end
