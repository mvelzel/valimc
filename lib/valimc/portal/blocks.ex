defmodule Valimc.Portal.Blocks do
  @moduledoc """
  Block facts portals read (VMC-026b2): vanilla's `canBeReplaced`, `isSolid`,
  `isFaceSturdy(UP)` and `FireBlock.canBurn` from the block fact table, the
  nether portal frame and fire tags, and the portal states.
  """
  alias Valimc.Registry.{BlockFacts, Blocks}

  @block_tags Valimc.Protocol.Data.tags()["minecraft:block"]
  @frame MapSet.new(@block_tags["minecraft:nether_portal_frame"])
  @fire MapSet.new(@block_tags["minecraft:fire"])
  @soul_fire_base MapSet.new(@block_tags["minecraft:soul_fire_base_blocks"])
  @portal_block Blocks.id("nether_portal")

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
  def air?(state), do: BlockFacts.air?(state)
  def frame?(state), do: MapSet.member?(@frame, Blocks.block_id(state))
  def fire?(state), do: MapSet.member?(@fire, Blocks.block_id(state))
  def soul_fire_base?(state), do: MapSet.member?(@soul_fire_base, Blocks.block_id(state))
  def obsidian, do: Blocks.default_state("obsidian")

  @doc "Vanilla `canBeReplaced()`."
  def replaceable?(state), do: BlockFacts.flag?(state, :replaceable)
  @doc "Vanilla `isSolid()` (the legacy solid flag)."
  def solid?(state), do: BlockFacts.flag?(state, :solid)
  @doc "Vanilla `isFaceSturdy(UP)`."
  def sturdy_up?(state), do: BlockFacts.flag?(state, :sturdy_up)
  @doc "Vanilla `FireBlock.canBurn` (ignite odds above zero, not waterlogged)."
  def burns?(state), do: BlockFacts.flag?(state, :flammable)

  @doc "Whether the state holds a fluid (`getFluidState().isEmpty()` false)."
  def fluid?(state), do: BlockFacts.fluid(state).kind != :empty
end
