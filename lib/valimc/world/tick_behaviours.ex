defmodule Valimc.World.TickBehaviours do
  @moduledoc """
  Block behaviours driven by the region tick pipeline (VMC-066).

  A behaviour module names the block states it handles and reacts to scheduled
  or random ticks with effects the owner applies as one batch:

  - `{:set, position, block}` replaces a block in the same region;
  - `{:schedule, position, block, delay, priority}` schedules a tick.

  `read` returns the current block at a position (`nil` outside the region).
  Behaviours are pure: they never touch storage or other owners.
  """

  @type effect ::
          {:set, tuple(), non_neg_integer()}
          | {:schedule, tuple(), non_neg_integer(), pos_integer(), integer()}

  @callback states() :: Enumerable.t()
  @callback scheduled_tick(position :: tuple(), block :: integer(), read :: function()) :: [
              effect
            ]
  @callback random_tick(position :: tuple(), block :: integer(), read :: function()) :: [effect]
  @optional_callbacks scheduled_tick: 3, random_tick: 3

  @doc "Extra configured behaviour modules (`:tick_behaviours`, scoped per region; tests)."
  def modules(key), do: Valimc.config(:tick_behaviours, key)

  @doc """
  State id => module, built once per owner: `Valimc.Block` behaviours that react
  to ticks, plus any extra configured modules (tests).
  """
  def index(modules) do
    configured = for module <- modules, state <- module.states(), into: %{}, do: {state, module}
    Map.merge(Map.new(Valimc.Block.tick_states()), configured)
  end
end
