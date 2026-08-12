defmodule Lux.Signals.TelegramUpdate do
  @moduledoc """
  Signal struct/schema for incoming Telegram updates.
  """

  use Lux.SignalSchema,
    name: "TelegramUpdate",
    description: "Signal representing an incoming Telegram update",
    version: "1.0.0",
    schema: %{
      type: :object,
      properties: %{
        update_id: %{type: :integer},
        message: %{type: :object},
        edited_message: %{type: :object},
        channel_post: %{type: :object},
        edited_channel_post: %{type: :object},
        inline_query: %{type: :object},
        chosen_inline_result: %{type: :object},
        callback_query: %{type: :object},
        shipping_query: %{type: :object},
        pre_checkout_query: %{type: :object},
        poll: %{type: :object},
        poll_answer: %{type: :object},
        my_chat_member: %{type: :object},
        chat_member: %{type: :object},
        chat_join_request: %{type: :object}
      },
      required: ["update_id"]
    }

  @doc """
  Constructs a Lux.Signal containing a Telegram update payload.
  """
  def new(payload, opts \\ %{}) when is_map(payload) do
    id = opts[:id] || Lux.UUID.generate()
    sender = opts[:sender] || "telegram"
    recipient = opts[:recipient]
    topic = opts[:topic] || "telegram.update"
    metadata = opts[:metadata] || %{}

    signal = Lux.Signal.new(%{
      id: id,
      payload: payload,
      sender: sender,
      recipient: recipient,
      topic: topic,
      metadata: metadata,
      schema_id: __MODULE__
    })

    validate(signal)
  end
end
