defmodule Valimc.Portal.Blocks do
  @moduledoc """
  Block facts portals read (VMC-026b2), from `priv/worldgen/blocks.json`
  (`WorldgenBlocksOracle`) and the block tags: vanilla's `canBeReplaced`,
  `isSolid`, `isFaceSturdy(UP)` and `FireBlock.canBurn`, the nether portal
  frame and fire tags, and the portal states.
  """
  import Bitwise
  alias Valimc.Registry.Blocks

  @path Path.expand("../../../priv/worldgen/blocks.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count Blocks.state_count()
  unless @facts["state_count"] == @count, do: raise("Wrong worldgen block facts")

  @bits Map.new(Enum.with_index(@facts["bits"]), fn {name, index} -> {name, 1 <<< index} end)
  @mask @bits["replaceable"] ||| @bits["solid"] ||| @bits["sturdy_up"]

  # One byte per state: 1 replaceable, 2 solid, 4 sturdy up, 8 can burn.
  @table (for <<hex::binary-size(8) <- @facts["flags"]>>, into: <<>> do
            flags = String.to_integer(hex, 16) &&& @mask

            <<if((flags &&& @bits["replaceable"]) != 0, do: 1, else: 0) |||
                if((flags &&& @bits["solid"]) != 0, do: 2, else: 0) |||
                if((flags &&& @bits["sturdy_up"]) != 0, do: 4, else: 0)>>
          end)
  @flammable for [first, last] <- @facts["flammable"],
                 state <- first..last,
                 into: MapSet.new(),
                 do: state
  @table (for <<byte <- @table>>, reduce: {<<>>, 0} do
            {acc, state} ->
              {<<acc::binary, byte ||| if(state in @flammable, do: 8, else: 0)>>, state + 1}
          end)
         |> elem(0)

  @block_tags Valimc.Protocol.Data.tags()["minecraft:block"]
  @frame MapSet.new(@block_tags["minecraft:nether_portal_frame"])
  @fire MapSet.new(@block_tags["minecraft:fire"])
  @soul_fire_base MapSet.new(@block_tags["minecraft:soul_fire_base_blocks"])
  @portal_block Blocks.id("nether_portal")
  @air Enum.map(~w(air cave_air void_air), &Blocks.default_state/1)

  def portal(:x), do: Blocks.state("nether_portal", %{"axis" => "x"})
  def portal(:z), do: Blocks.state("nether_portal", %{"axis" => "z"})

  @doc "A nether portal state's axis, or nil."
  def portal_axis(state) do
    cond do
      state == portal(:x) -> :x
      state == portal(:z) -> :z
      true -> nil
    end
  end

  # States with vanilla's `HORIZONTAL_AXIS` property (an axis of x or z).
  @horizontal_axis for block <- 0..(Blocks.block_count() - 1),
                       name = Blocks.name(block),
                       {"axis", values} <- Blocks.definitions(name),
                       Enum.sort(Tuple.to_list(values)) == ["x", "z"],
                       state <- Blocks.states(name),
                       into: MapSet.new(),
                       do: state

  def portal?(state), do: Blocks.block_id(state) == @portal_block

  @doc "Whether the state has vanilla's `HORIZONTAL_AXIS` property (a portal POI's test)."
  def horizontal_axis?(state), do: MapSet.member?(@horizontal_axis, state)
  def air?(state), do: state in @air
  def frame?(state), do: MapSet.member?(@frame, Blocks.block_id(state))
  def fire?(state), do: MapSet.member?(@fire, Blocks.block_id(state))
  def soul_fire_base?(state), do: MapSet.member?(@soul_fire_base, Blocks.block_id(state))
  def obsidian, do: Blocks.default_state("obsidian")

  @doc "Vanilla `canBeReplaced()`."
  def replaceable?(state), do: (:binary.at(@table, state) &&& 1) != 0
  @doc "Vanilla `isSolid()` (the legacy solid flag)."
  def solid?(state), do: (:binary.at(@table, state) &&& 2) != 0
  @doc "Vanilla `isFaceSturdy(UP)`."
  def sturdy_up?(state), do: (:binary.at(@table, state) &&& 4) != 0
  @doc "Vanilla `FireBlock.canBurn` (ignite odds above zero, not waterlogged)."
  def burns?(state), do: (:binary.at(@table, state) &&& 8) != 0

  @doc "Whether the state holds a fluid (`getFluidState().isEmpty()` false)."
  def fluid?(state) do
    {:ok, %{kind: kind}} = Valimc.Physics.FluidBlocks.fetch(state)
    kind != :empty
  end
end
