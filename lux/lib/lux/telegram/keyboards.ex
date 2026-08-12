defmodule Lux.Telegram.Keyboards do
  @moduledoc """
  Helper module for generating Telegram bot keyboards and markup.
  """

  @doc """
  Constructs an inline keyboard markup map from rows of inline buttons.

  ## Examples

      iex> Keyboards.inline_keyboard([[Keyboards.inline_button("Click", "data_1")]])
      %{inline_keyboard: [[%{text: "Click", callback_data: "data_1"}]]}
  """
  def inline_keyboard(rows) when is_list(rows) do
    %{inline_keyboard: rows}
  end

  @doc """
  Constructs an inline keyboard button map.

  ## Examples

      iex> Keyboards.inline_button("Click me", "callback_data_1")
      %{text: "Click me", callback_data: "callback_data_1"}

      iex> Keyboards.inline_button("Visit Site", url: "https://example.com")
      %{text: "Visit Site", url: "https://example.com"}
  """
  def inline_button(text, callback_data) when is_binary(callback_data) do
    %{text: text, callback_data: callback_data}
  end

  def inline_button(text, opts) when is_list(opts) or is_map(opts) do
    Map.merge(%{text: text}, Map.new(opts))
  end

  @doc """
  Constructs a ReplyKeyboardMarkup map from rows of button texts or button maps.

  ## Examples

      iex> Keyboards.reply_keyboard([["Yes", "No"]], resize_keyboard: true)
      %{keyboard: [[%{text: "Yes"}, %{text: "No"}]], resize_keyboard: true}
  """
  def reply_keyboard(rows, opts \\ %{}) when is_list(rows) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts || %{}

    normalized_rows =
      Enum.map(rows, fn row ->
        Enum.map(row, fn
          btn when is_binary(btn) -> %{text: btn}
          btn when is_map(btn) -> btn
          btn -> %{text: to_string(btn)}
        end)
      end)

    Map.merge(%{keyboard: normalized_rows}, opts_map)
  end

  @doc """
  Constructs a ReplyKeyboardRemove map.

  ## Examples

      iex> Keyboards.remove_reply_keyboard(selective: true)
      %{remove_keyboard: true, selective: true}
  """
  def remove_reply_keyboard(opts \\ %{}) do
    opts_map = if is_list(opts), do: Map.new(opts), else: opts || %{}
    Map.merge(%{remove_keyboard: true}, opts_map)
  end
end
