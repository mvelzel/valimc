defmodule Valimc.AquaticAgeTest do
  use ExUnit.Case, async: true
  alias Valimc.AI.{Mind, Self, World}
  alias Valimc.Entity.{Animal, Body}
  alias Valimc.Protocol.ItemStack

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
      assert restored.data == Map.merge(Animal.ageable_data(), old)
      assert {:ok, ^restored} = restored |> Body.record() |> Body.restore()

      assert {:error, :invalid_body} =
               Body.restore(%{record | data: Map.put(old, :unexpected, 1)})

      missing = if type == "dolphin", do: :moistness, else: :age
      assert {:error, :invalid_body} = Body.restore(%{record | data: Map.delete(old, missing)})
      malformed = %{Body.record(restored) | data: %{restored.data | age: "invalid"}}
      assert {:error, :invalid_body} = Body.restore(malformed)
    end
  end

  test "ageable ocean mobs grow with NoAI, preserve age locks and feed baby dolphins" do
    for type <- ~w(dolphin squid glow_squid), no_ai <- [false, true] do
      {:ok, body} = Body.new("minecraft:" <> type)
      body = %{body | data: %{body.data | age: -1}, mob: %{body.mob | no_ai: no_ai}}
      mind = %Mind{random: Valimc.AI.Random.new(7)}
      self = %Self{type: body.type, data: body.data, mob: body.mob, mind: mind, world: %World{}}
      assert Animal.settle_ageable(self).data.age == 0
      locked = %{self | data: %{self.data | age_locked: true}}
      assert Animal.settle_ageable(locked).data.age == -1
      {_, _, eye} = Body.dimensions(body)
      assert eye == elem(Animal.water_ageable(body.type).baby, 2)
    end

    {:ok, body} = Body.new("minecraft:dolphin")
    body = %{body | data: %{body.data | age: -24_000}, mob: %{body.mob | ai: %Mind{}}}

    assert {:ok, fed, %{hand: {:use, 1}}} =
             Valimc.AI.Mobs.Dolphin.mob_interact(body, %{item: ItemStack.new("cod")})

    assert fed.data.age == -21_600 and fed.data.forced_age == 2400
    refute fed.data.got_fish
    assert fed.mob.ai.forced_age_timer == 40
    refute Valimc.AI.Mobs.Dolphin.can_attack?(%Self{data: fed.data}, %{})
    locked = %{body | data: %{body.data | age_locked: true}}

    assert {:ok, fed, _} =
             Valimc.AI.Mobs.Dolphin.mob_interact(locked, %{item: ItemStack.new("cod")})

    assert fed.data.age == -24_000 and fed.data.got_fish
  end
end
