defmodule Valimc.Blocks.MiningLoot do
  @moduledoc """
  What breaking a block drops (VMC-029e): the items of its loot table
  (`priv/loot/blocks.json` names each block's, `LootOracle facts`) through
  the native evaluator (`Valimc.Blocks.Loot.block_drops/5`), and the
  experience a harvest pops (`spawnAfterBreak`).

  Vanilla draws a block table's items from the world's random sequence for
  the table, which is shared mutable state across groups; a fresh seed per
  break gives the same distribution. A block entity ValiMC places carries its
  item's defaults, so a decorated pot's sherds are four bricks.
  """
  alias Valimc.Blocks.Loot
  alias Valimc.Data.Blocks
  alias Valimc.Protocol.ItemStack
  use Valimc.Data.Facts, "loot/blocks.json"

  @tables List.to_tuple(@facts["tables"])
  unless tuple_size(@tables) == Blocks.block_count(), do: raise("Wrong block loot facts")

  @experience Map.new(@facts["experience"], fn {"minecraft:" <> name, row} ->
                terms = for [low, high] <- row["terms"], do: {low, high}

                {Blocks.id(name) || raise("Unknown block #{name}"),
                 {terms, row["silk_touch_cancels"]}}
              end)

  @pot Blocks.id("decorated_pot")
  @sherds [{"minecraft:sherds", List.duplicate("minecraft:brick", 4)}]

  @doc "The loot table of `state`'s block, or nil."
  def table(state), do: elem(@tables, Blocks.block_id(state))

  @doc """
  The drops of `state` broken at `position`: `{:ok, stacks}`, or an
  evaluation error (which the `block_loot` stage rules out for every state;
  callers drop nothing then). Options:
  `:tool` (the stack it was broken with, before wear; nil for an empty hand
  and for blocks the world breaks), `:entity` (whether an entity broke it: a
  player, an explosion's source), `:radius` (an explosion's), `:above` and
  `:below` (the states there) and `:seed`.
  """
  def drops(state, position, opts \\ []) do
    case table(state) do
      nil ->
        {:ok, []}

      table ->
        Loot.block_drops(table, Keyword.get_lazy(opts, :seed, &seed/0), position, %{
          state: state,
          tool: Keyword.get(opts, :tool),
          entity: Keyword.get(opts, :entity, false),
          radius: Keyword.get(opts, :radius),
          above: Keyword.get(opts, :above),
          below: Keyword.get(opts, :below),
          dynamic: if(Blocks.block_id(state) == @pot, do: @sherds, else: [])
        })
    end
  end

  @doc """
  The experience a harvest of `state` with `tool` pops (`spawnAfterBreak`):
  the sum of its draws, none when Silk Touch cancels it.
  """
  def experience(state, tool) do
    case Map.get(@experience, Blocks.block_id(state)) do
      nil ->
        0

      {terms, cancels} ->
        if cancels and enchanted?(tool, "minecraft:silk_touch"),
          do: 0,
          else: Enum.sum(for {low, high} <- terms, do: low + :rand.uniform(high - low + 1) - 1)
    end
  end

  @doc "Whether `tool` holds `enchantment` (applied, not stored)."
  def enchanted?(nil, _enchantment), do: false

  def enchanted?(%ItemStack{components: components}, enchantment),
    do: Map.get(Map.get(components, "minecraft:enchantments", %{}), enchantment, 0) > 0

  defp seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end
end
