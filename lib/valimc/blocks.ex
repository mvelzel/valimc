defmodule Valimc.Blocks do
  @moduledoc """
  Block behaviour dispatch. Each state's generated vanilla block class
  (`Valimc.Data.Blocks.class/1`) selects one `Valimc.Blocks.Behaviour` module;
  classes without a ValiMC behaviour yet use `Valimc.Blocks.Default`. The choice
  compiles to one byte per state. `block_entity/1` is a pure function of the state,
  so its callback results are tabulated at compile time as well.
  """
  alias Valimc.Blocks.{
    Barrel,
    BuddingAmethyst,
    Chest,
    FallingBlock,
    Furnace,
    Coral,
    Default,
    Machine,
    NetherPortal,
    TurtleEgg
  }

  alias Valimc.Blocks.CookingBlocks
  alias Valimc.Data.Blocks

  @classes %{
    "ChestBlock" => Chest,
    "BarrelBlock" => Barrel,
    "FurnaceBlock" => Furnace,
    "SmokerBlock" => Furnace,
    "BlastFurnaceBlock" => Furnace,
    "CoralBlock" => Coral,
    "BuddingAmethystBlock" => BuddingAmethyst,
    "NetherPortalBlock" => NetherPortal,
    "ColoredFallingBlock" => FallingBlock,
    "SandBlock" => FallingBlock,
    "ConcretePowderBlock" => FallingBlock,
    "AnvilBlock" => FallingBlock,
    "DragonEggBlock" => FallingBlock,
    "HopperBlock" => Machine,
    "DispenserBlock" => Machine,
    "DropperBlock" => Machine,
    "TurtleEggBlock" => TurtleEgg
  }
  @modules List.to_tuple([Default | Enum.uniq(Enum.sort(Map.values(@classes)))])
  @module_index @modules |> Tuple.to_list() |> Enum.with_index() |> Map.new()
  @count Blocks.state_count()
  @by_state for(
              block <- 0..(Blocks.block_count() - 1),
              states = Blocks.states(Blocks.name(block)),
              module = Map.get(@classes, Blocks.class(states.first), Default),
              do: :binary.copy(<<Map.fetch!(@module_index, module)>>, Range.size(states))
            )
            |> IO.iodata_to_binary()

  # Owned block entities must stay exactly the generated chest, furnace,
  # machine (hopper, dropper, dispenser) and barrel states.
  unless Enum.all?(Map.keys(@classes), &Map.has_key?(Blocks.classes(), &1)) and
           byte_size(@by_state) == @count and
           Enum.all?(Valimc.Blocks.Chest.single_states(), fn state ->
             elem(@modules, :binary.at(@by_state, state)) == Chest
           end) and
           Enum.all?(0..(@count - 1), fn state ->
             CookingBlocks.kind(state) == nil or
               elem(@modules, :binary.at(@by_state, state)) == Furnace
           end) and
           Enum.all?(0..(@count - 1), fn state ->
             Machine.kind(state) == nil or elem(@modules, :binary.at(@by_state, state)) == Machine
           end) and
           Enum.all?(Valimc.Data.Blocks.states("barrel"), fn state ->
             elem(@modules, :binary.at(@by_state, state)) == Barrel
           end),
         do: raise("Block behaviour classes do not cover the owned block entities")

  # Every `FallingBlock` falls (VMC-050a2), and only those.
  unless Enum.all?(0..(@count - 1), fn state ->
           Valimc.Data.BlockFacts.flag?(state, :falling) ==
             (elem(@modules, :binary.at(@by_state, state)) == FallingBlock)
         end),
         do: raise("Falling block classes differ from the falling block facts")

  @entity_values for(
                   state <- 0..(@count - 1),
                   do: elem(@modules, :binary.at(@by_state, state)).block_entity(state)
                 )
  @entity_kinds List.to_tuple([nil | Enum.uniq(Enum.reject(@entity_values, &is_nil/1))])
  @entity_index @entity_kinds |> Tuple.to_list() |> Enum.with_index() |> Map.new()
  @entities for(kind <- @entity_values, into: <<>>, do: <<Map.fetch!(@entity_index, kind)>>)

  @tick_states for(
                 {module, index} <- @module_index,
                 Code.ensure_compiled!(module),
                 Enum.any?(
                   [:random_tick, :scheduled_tick, :shape_update],
                   &function_exported?(module, &1, 4)
                 ),
                 state <- 0..(@count - 1),
                 :binary.at(@by_state, state) == index,
                 do: {state, module}
               )

  @doc "States whose behaviour reacts to region ticks (VMC-066), with that module."
  def tick_states, do: @tick_states

  @doc "The behaviour module of a block state."
  def behaviour(state) when is_integer(state) and state >= 0 and state < @count,
    do: elem(@modules, :binary.at(@by_state, state))

  @doc "Owned block-entity kind (`:chest`, `:furnace`, `:smoker`, `:blast_furnace`, `:hopper`, `:dropper`, `:dispenser`, `:barrel`) or nil; any term is accepted."
  def block_entity(state) when is_integer(state) and state >= 0 and state < @count,
    do: elem(@entity_kinds, :binary.at(@entities, state))

  def block_entity(_), do: nil

  def after_removal(state), do: behaviour(state).after_removal(state)
end
