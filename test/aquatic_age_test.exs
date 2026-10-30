defmodule Valimc.AquaticAgeTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.Body

  @ageable %{age: 0, forced_age: 0, age_locked: false}

  test "legacy ocean-mob records preserve existing state and gain only ageable defaults" do
    for type <- ~w(dolphin squid glow_squid) do
      {:ok, body} = Body.new("minecraft:" <> type)

      old =
        case type do
          "dolphin" -> %{got_fish: true, moistness: 123, treasure: {4, 5, 6}}
          "squid" -> %{age: -123}
          "glow_squid" -> %{age: -123, dark: 42}
        end

      record = %{Body.record(body) | data: old}
      assert {:ok, restored} = Body.restore(record)
      assert restored.data == Map.merge(@ageable, old)
      assert {:ok, ^restored} = restored |> Body.record() |> Body.restore()

      assert {:error, :invalid_body} =
               Body.restore(%{record | data: Map.put(old, :unexpected, 1)})

      missing = if type == "dolphin", do: :moistness, else: :age
      assert {:error, :invalid_body} = Body.restore(%{record | data: Map.delete(old, missing)})
      malformed = %{Body.record(restored) | data: %{restored.data | age: "invalid"}}
      assert {:error, :invalid_body} = Body.restore(malformed)
    end
  end
end
