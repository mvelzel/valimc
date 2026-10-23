defmodule Valimc.Blocks.Breaking do
  @moduledoc """
  A survival player's break of a block (`ServerPlayerGameMode.destroyBlock`,
  VMC-029e) as a plan its group commits: the cells written, the drops and
  the experience.

  - `playerWillDestroy`: a tall plant drops its loot with the player's tool
    whether or not it is harvested (`DoublePlantBlock`), and leaves none for
    `playerDestroy`; a door's upper half broken without its tool takes the
    lower half without drops (`preventDropFromBottomPart`); a tool in
    `#breaks_decorated_pots` cracks a decorated pot first, so it drops its
    sherds.
  - The cell becomes its fluid (`removeBlock`).
  - `playerDestroy` with the right tool: the loot of the state with the
    original tool and the player as breaker, and the experience
    `spawnAfterBreak` pops. Ice melts into water above a block in
    `#ice_melts_when_destroyed_above` or a liquid, unless the tool's
    enchantments prevent it or water evaporates in the dimension; a turtle
    egg cluster loses one egg.

  What the change does to its neighbours (the other half of a door, bed or
  tall plant, attached blocks) is the block rules' (VMC-077m): the commit
  starts their updates, and the blocks they destroy drop their tool-less loot.
  """
  alias Valimc.Blocks.MiningLoot
  alias Valimc.Data.Blocks
  alias Valimc.Protocol.{Data, ItemStack}

  @tags Data.tags()
  @double_plants ~w(DoublePlantBlock TallFlowerBlock SmallDripleafBlock TallSeagrassBlock PitcherCropBlock)
  @doors ~w(DoorBlock WeatheringCopperDoorBlock)
  @ice ~w(IceBlock FrostedIceBlock)
  @pot Blocks.id("decorated_pot")
  @turtle_egg Blocks.id("turtle_egg")
  @water Blocks.default_state("water")
  @liquids MapSet.new([Blocks.id("water"), Blocks.id("lava")])
  @melts_above MapSet.new(@tags["minecraft:block"]["minecraft:ice_melts_when_destroyed_above"])
  @breaks_pots MapSet.new(@tags["minecraft:item"]["minecraft:breaks_decorated_pots"])
  @keeps_pots @tags["minecraft:enchantment"]["minecraft:prevents_decorated_pot_shattering"]
  @keeps_ice @tags["minecraft:enchantment"]["minecraft:prevents_ice_melting"]
  @enchantments Data.registries()["minecraft:enchantment"]

  @doc """
  The plan for breaking `state` at `position` with `tool` (the held stack
  before wear, nil for an empty hand). `harvest` is whether the player has
  the right tool for drops; `around` holds the states `:above` and `:below`
  (nil where unknown) and whether water `:evaporates` in the dimension.

  `%{writes: %{position => {expected, new}}, drops: [stack], experience: n,
  harvest: harvest}`; a harvest also costs the player food.
  """
  def plan(state, {x, y, z} = position, tool, harvest, around) do
    class = Blocks.class(state)
    below = around[:below]
    loot = fn loot_state -> loot(loot_state, position, tool, around) end
    removed = Valimc.Blocks.after_removal(state)
    writes = %{position => {state, removed}}

    plan =
      cond do
        class in @double_plants ->
          %{writes: writes, drops: loot.(state), experience: 0}

        class in @doors and not harvest and half(state) == "upper" and below != nil and
          Blocks.block_id(below) == Blocks.block_id(state) and half(below) == "lower" ->
          lower = {x, y - 1, z}

          %{
            writes: Map.put(writes, lower, {below, Valimc.Blocks.after_removal(below)}),
            drops: [],
            experience: 0
          }

        not harvest ->
          %{writes: writes, drops: [], experience: 0}

        true ->
          loot_state =
            if cracks?(state, tool), do: property(state, "cracked", "true"), else: state

          %{
            writes: %{position => {state, after_harvest(state, class, removed, tool, around)}},
            drops: loot.(loot_state),
            experience: MiningLoot.experience(state, tool)
          }
      end

    Map.put(plan, :harvest, harvest)
  end

  defp loot(state, position, tool, around) do
    case MiningLoot.drops(state, position,
           tool: tool,
           entity: true,
           above: around[:above],
           below: around[:below]
         ) do
      {:ok, stacks} -> stacks
      {:error, _} -> []
    end
  end

  defp after_harvest(state, class, removed, tool, around) do
    below = around[:below]

    cond do
      class in @ice and not tagged_enchantment?(tool, @keeps_ice) and
        not Map.get(around, :evaporates, false) and below != nil and
          (MapSet.member?(@melts_above, Blocks.block_id(below)) or
             MapSet.member?(@liquids, Blocks.block_id(below))) ->
        @water

      Blocks.block_id(state) == @turtle_egg and eggs(state) > 1 ->
        property(state, "eggs", Integer.to_string(eggs(state) - 1))

      true ->
        removed
    end
  end

  # `DecoratedPotBlock.playerWillDestroy`.
  defp cracks?(state, %ItemStack{item_id: item} = tool),
    do:
      Blocks.block_id(state) == @pot and MapSet.member?(@breaks_pots, item) and
        not tagged_enchantment?(tool, @keeps_pots)

  defp cracks?(_state, nil), do: false

  defp tagged_enchantment?(tool, tag) do
    Enum.any?(tag, fn id -> MiningLoot.enchanted?(tool, Enum.at(@enchantments, id)) end)
  end

  defp half(state), do: state |> Blocks.properties() |> List.keyfind("half", 0) |> elem(1)

  defp eggs(state),
    do: state |> Blocks.properties() |> List.keyfind("eggs", 0) |> elem(1) |> String.to_integer()

  defp property(state, name, value) do
    block = Blocks.name(Blocks.block_id(state))
    Blocks.state(block, state |> Blocks.properties() |> Map.new() |> Map.put(name, value))
  end
end
