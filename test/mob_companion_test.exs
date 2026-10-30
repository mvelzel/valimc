defmodule Valimc.MobCompanionTest do
  @moduledoc """
  Mobs another mob's spawn made, as the region adopts them: a drowned's zombie
  nautilus carries only the rider's yaw. The M3 gate's owner crashed when one
  reached the chicken jockey's clause, which reads a follow bonus.
  """
  use ExUnit.Case, async: true

  alias Valimc.Entity.Body
  alias Valimc.World.RegionData

  test "a drowned's nautilus faces as its rider" do
    {:ok, nautilus} = Body.spawned("minecraft:zombie_nautilus", :natural)
    made = RegionData.companion(nautilus, %{jockey: true, yaw: 173.5})
    assert {made.yaw, made.head_yaw} == {173.5, 173.5}
  end

  test "a chicken jockey's chicken takes the zombie's follow bonus" do
    {:ok, chicken} = Body.spawned("minecraft:chicken", :natural)

    made =
      RegionData.companion(chicken, %{
        jockey: true,
        yaw: 10.0,
        follow_bonus: 0.05,
        left_handed: true
      })

    assert made.data.jockey and made.mob.left_handed and made.yaw == 10.0

    assert made.mob.attributes["minecraft:follow_range"].modifiers == [
             {"minecraft:random_spawn_bonus", 0.05, 1}
           ]
  end
end
