defmodule Lux.Telegram.KeyboardsTest do
  use ExUnit.Case, async: true

  alias Lux.Telegram.Keyboards

  describe "inline_button/2" do
    test "creates inline button with string callback_data" do
      btn = Keyboards.inline_button("Option A", "cb_a")
      assert btn == %{text: "Option A", callback_data: "cb_a"}
    end

    test "creates inline button with options keyword list" do
      btn = Keyboards.inline_button("Open URL", url: "https://example.com")
      assert btn == %{text: "Open URL", url: "https://example.com"}
    end

    test "creates inline button with options map" do
      btn = Keyboards.inline_button("Search", %{switch_inline_query: "lux"})
      assert btn == %{text: "Search", switch_inline_query: "lux"}
    end
  end

  describe "inline_keyboard/1" do
    test "constructs inline keyboard structure" do
      b1 = Keyboards.inline_button("Yes", "yes")
      b2 = Keyboards.inline_button("No", "no")

      kb = Keyboards.inline_keyboard([[b1, b2]])
      assert kb == %{inline_keyboard: [[%{text: "Yes", callback_data: "yes"}, %{text: "No", callback_data: "no"}]]}
    end
  end

  describe "reply_keyboard/2" do
    test "constructs reply keyboard from string rows" do
      kb = Keyboards.reply_keyboard([["Option 1", "Option 2"]], resize_keyboard: true, one_time_keyboard: true)

      assert kb == %{
               keyboard: [[%{text: "Option 1"}, %{text: "Option 2"}]],
               resize_keyboard: true,
               one_time_keyboard: true
             }
    end

    test "constructs reply keyboard preserving button maps" do
      kb = Keyboards.reply_keyboard([[%{text: "Contact", request_contact: true}]])
      assert kb == %{keyboard: [[%{text: "Contact", request_contact: true}]]}
    end
  end

  describe "remove_reply_keyboard/1" do
    test "constructs remove reply keyboard markup" do
      kb = Keyboards.remove_reply_keyboard(selective: true)
      assert kb == %{remove_keyboard: true, selective: true}
    end
  end
end
