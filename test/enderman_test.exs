defmodule Valimc.EndermanTest do
  @moduledoc """
  Endermen's hurts and death (VMC-043b5): projectiles never hurt one (it
  teleports on its next tick instead), water and other hurts without a
  living attacker may send it away, and a carried block drops on death as
  if mined with Silk Touch.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks
  alias Valimc.Entity.{Body, Combat}
  alias Valimc.Protocol.ItemTypes

  # One that has thought once (its mind holds a hurt's reaction).
  defp enderman do
    {:ok, body} = Body.new("minecraft:enderman")
    put_in(body.mob.ai, Valimc.AI.Self.fresh(<<5::128>>))
  end

  defp reaction(mob), do: (mob.ai.own || %{})[:hurt]

  test "a projectile is turned away and sends it off; water hurts it and may" do
    %Body{type: type, mob: mob, data: data} = enderman()
    health = mob.living.health.value

    assert {mob, [], false} = Combat.hurt_mob(type, mob, :arrow, 5.0, data)
    assert mob.living.health.value == health
    assert reaction(mob) == :away

    assert {mob, _events, true} = Combat.hurt_mob(type, mob, :drown, 1.0, data)
    assert mob.living.health.value < health
    assert reaction(mob) == :maybe
  end

  test "its carried block drops on death, as if mined with Silk Touch" do
    body = enderman()
    body = %{body | data: %{body.data | carried: Blocks.default_state("grass_block")}}
    body = Combat.died(body, %{})
    grass = ItemTypes.id("minecraft:grass_block")
    assert Enum.any?(body.mob.death.equipment, &match?(%{item_id: ^grass, count: 1}, &1))
  end
end
