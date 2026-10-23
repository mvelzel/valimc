defmodule Valimc.Blocks.Behaviour do
  @moduledoc """
  Callbacks for the block behaviour of a state; `Valimc.Blocks` picks the module by
  the state's generated vanilla block class. `use Valimc.Blocks.Behaviour` supplies
  the plain-block defaults, so a module overrides only what its class changes.
  """
  @type state :: non_neg_integer()

  @doc "The block-entity kind ValiMC owns for this state, or nil."
  @callback block_entity(state) :: atom() | nil

  @doc "The state left behind when this state's block is removed."
  @callback after_removal(state) :: state

  @doc """
  Region tick reactions (VMC-066), optional: effects for a random or scheduled
  tick of this state at `position`, which the owner applies as one batch:
  `{:set, position, block}` replaces a block in the same region and
  `{:schedule, position, block, delay, priority}` schedules a tick. `read`
  returns the block at a position in the same region (nil elsewhere) and
  `random.(n)` draws an integer in `0..n-1`. Behaviours never touch storage or
  other owners.
  """
  @callback random_tick(position :: tuple(), state, read :: function(), random :: function()) ::
              [tuple()]
  @callback scheduled_tick(position :: tuple(), state, read :: function(), random :: function()) ::
              [tuple()]

  @doc """
  Vanilla `updateShape` for a block with effects of its own (optional; the
  block rules do the rest, VMC-077m): called after the block at `position` or
  one of its six neighbours changed. It may only schedule ticks.
  """
  @callback shape_update(position :: tuple(), state, read :: function(), random :: function()) ::
              [tuple()]
  @optional_callbacks random_tick: 4, scheduled_tick: 4, shape_update: 4

  defmacro __using__(_) do
    quote do
      @behaviour Valimc.Blocks.Behaviour

      @impl true
      def block_entity(_state), do: nil

      @impl true
      def after_removal(state), do: Valimc.Data.BlockFacts.fluid_remains(state)

      defoverridable block_entity: 1,
                     after_removal: 1
    end
  end
end
