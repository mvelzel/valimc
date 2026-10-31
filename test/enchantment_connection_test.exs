defmodule Valimc.EnchantmentConnectionTest do
  @moduledoc """
  Enchantments a player wears through a connection (VMC-037q): Soul Speed
  boots on soul sand add their speed and wear now and then.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestClient, as: Client
  import Valimc.TestPlayer, only: [login: 1, state: 1]

  setup do: Valimc.TestPlayer.scope("Soul", {84_000, 982})

  test "Soul Speed boots on soul sand speed the player up until it steps off", ctx do
    boots = %{
      ItemStack.new("iron_boots")
      | components: %{"minecraft:enchantments" => %{"minecraft:soul_speed" => 3}}
    }

    player =
      Map.merge(ctx.pose, %{
        y: 64.0,
        game_mode: Valimc.Player.GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival),
        motion: %Valimc.Player.Motion{on_ground: true},
        last_death: nil
      })

    Valimc.TestPlayer.save(ctx, player, %Inventory{slots: %{8 => boots}})
    below = {floor(ctx.pose.x), 63, floor(ctx.pose.z)}
    :ok = Valimc.TestRegion.set_published(below, Valimc.Data.Blocks.default_state("soul_sand"))
    {client, pid} = login(ctx)
    Valimc.TestPlayer.ticks(pid, 2, true)

    speed = fn ->
      state(pid)
      |> Map.get(:enchant_location, %{modifiers: %{}})
      |> Map.get(:modifiers)
      |> Map.get("minecraft:movement_speed", [])
    end

    # Soul Speed III: 0.0405 + 2 × 0.0105.
    Valimc.TestWait.until(fn ->
      match?([{"minecraft:enchantment.soul_speed/feet", _, 0}], speed.())
    end)

    [{_, amount, 0}] = speed.()
    assert_in_delta amount, 0.0615, 1.0e-6

    # Taken off, the speed goes with them.
    Valimc.TestConn.replace(pid, fn s ->
      %{s | inventory: %{s.inventory | slots: Map.delete(s.inventory.slots, 8)}}
    end)

    Valimc.TestPlayer.ticks(pid, 1, true)
    Valimc.TestWait.until(fn -> speed.() == [] end)
    _ = client
  end
end
