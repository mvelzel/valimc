defmodule Valimc.NetherMobsTest do
  @moduledoc """
  The Nether's mobs' own rules beyond their AI fixtures (VMC-043d): a large
  fireball a player sent back kills a ghast outright; another ghast's only
  burns, which a ghast is immune to.
  """
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Combat}
  alias Valimc.Living.DamageSource

  defp fireball(owner),
    do: %{
      source: DamageSource.new(:fireball),
      amount: 6.0,
      attacker: owner,
      direct: %{
        uuid: <<9::128>>,
        entity_id: 9,
        player: false,
        type: "minecraft:fireball",
        mainhand: nil
      }
    }

  test "a ghast dies to a fireball a player sent back, not to its own" do
    {:ok, ghast} = Body.new("minecraft:ghast")
    entity = %{x: 0.0, y: 70.0, z: 0.0}

    player = %{
      uuid: <<1::128>>,
      entity_id: 1,
      player: true,
      type: "minecraft:player",
      mainhand: nil
    }

    other = %{
      uuid: <<2::128>>,
      entity_id: 2,
      player: false,
      type: "minecraft:ghast",
      mainhand: nil
    }

    {_, _, outcome} = Combat.hurt_body(ghast, entity, fireball(player))
    assert outcome.died

    assert Combat.hurt_body(ghast, entity, fireball(other)) == :ignored
  end
end
