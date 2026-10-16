defmodule Valimc.PlayerStatusImmunityTest do
  use ExUnit.Case, async: true
  alias Valimc.{PlayerStatusImmunity, StatusEffect}
  alias Valimc.Protocol.EffectTypes

  test "Fire Resistance is present until removed, independent of remaining duration and amplifier" do
    id = EffectTypes.id("fire_resistance")

    for ticks <- [-1, 0, 1], amplifier <- [0, 255] do
      {:ok, state} = StatusEffect.new(ticks, amplifier)
      effects = %{id => state}

      for source <- [:in_fire, :on_fire, :lava, :hot_floor, :campfire] do
        assert PlayerStatusImmunity.immune?(effects, source)
        refute PlayerStatusImmunity.immune?(Map.delete(effects, id), source)
      end

      for source <- [:fall, :freeze, :drown, :out_of_world, :cactus, :sweet_berry_bush] do
        refute PlayerStatusImmunity.immune?(effects, source)
      end
    end
  end

  test "another active effect provides no Fire Resistance immunity" do
    {:ok, state} = StatusEffect.new(-1, 255)
    effects = %{EffectTypes.id("water_breathing") => state}
    refute PlayerStatusImmunity.immune?(effects, :lava)
    refute PlayerStatusImmunity.immune?(%{}, :lava)
  end
end
