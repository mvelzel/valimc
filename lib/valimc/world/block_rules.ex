defmodule Valimc.World.BlockRules do
  @moduledoc """
  Vanilla's block updates in a region (VMC-077m), run by the Rust rules engine
  that decoration shares (`valimc_core::rules`).

  After block changes in a region's storage the engine does what
  `Level.setBlock` starts: neighbour updates and shape updates in vanilla's
  orders, through a collecting updater with vanilla's chain limit. A shape
  that becomes air destroys its block (it leaves its fluid and drops its
  loot); a dependent block's due tick breaks it if it can no longer survive.
  The engine reads the cells of a section and its group's other sections
  (VMC-077j) and returns what it decided; each section commits its part.
  Updates stop at the group's edge: an update at a cell the group does not
  hold, or whose rule reads one, is dropped.

  Rules come from the shared rule modules, live play's survival facts
  (`priv/physics/support.json`) and decoration's shape facts, in that order;
  a state none models keeps its state.
  """
  import Bitwise
  alias Valimc.{Native, Worldgen}
  alias Valimc.Data.BlockFacts

  @doc "The native rules, parsed once per VM (the block facts are installed first)."
  def native do
    case :persistent_term.get({__MODULE__, :native}, nil) do
      nil ->
        :global.trans({__MODULE__, self()}, fn ->
          case :persistent_term.get({__MODULE__, :native}, nil) do
            nil ->
              BlockFacts.install!()
              {:ok, rules} = Native.rules_new(facts())
              :persistent_term.put({__MODULE__, :native}, rules)
              rules

            rules ->
              rules
          end
        end)

      rules ->
        rules
    end
  end

  defp facts do
    %{
      "block_registry" => Valimc.Data.Blocks.native_facts(),
      "block_facts" => Worldgen.block_facts(Valimc.Protocol.Data.tags()),
      "support" => Worldgen.fact("survival"),
      "shapes" => Worldgen.fact("shapes"),
      "live_support" => Valimc.Data.Facts.read!("physics/support.json")
    }
  end

  @doc """
  The updates after the cells of `previous` (`position => old state`) changed
  in a section's storage, and at dependent blocks' due `ticks` (`[{position,
  state}]`), reading across the stores of `siblings` (the group's other
  sections); `absent` lists their chunks not generated yet. Returns
  `%{changes: [{position, state}], destroyed: [{position, state, drops?,
  effects?}], ticks: [{position, block, delay}], stopped: n, skipped: n,
  updates: n}` (`effects?`: it breaks with particles and sound; the counts:
  updates dropped at the group's edge, past the chain limit and run); storage
  is not changed.
  """
  def run(%Valimc.World.Blocks{ref: ref}, siblings, previous, ticks, absent) do
    units = map_size(previous) + length(ticks)
    stores = for %Valimc.World.Blocks{ref: sibling} <- siblings, do: sibling
    args = [ref, stores, native(), pack(previous), pack(ticks), absent, :rand.uniform(1 <<< 62)]

    {:ok, {changes, destroyed, scheduled, stopped, skipped, updates}} =
      case Native.dispatch(:block_updates, units, args) do
        # A cascade past the normal scheduler's budget runs again, dirty.
        {:error, :too_large} -> apply(Native, :block_updates_dirty, args)
        result -> result
      end

    %{
      changes:
        for(<<x::32-signed, y::32-signed, z::32-signed, s::16 <- changes>>, do: {{x, y, z}, s}),
      destroyed:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, s::16, flags::8 <- destroyed>>,
          do: {{x, y, z}, s, (flags &&& 1) == 1, (flags &&& 2) == 2}
        ),
      ticks:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, block::16, delay::32-signed <- scheduled>>,
          do: {{x, y, z}, block, delay}
        ),
      stopped: stopped,
      skipped: skipped,
      updates: updates
    }
  end

  @doc """
  The first of `states` that can survive at `position` in a section's storage
  (placement's `canSurvive`, `BlockItem.canPlace`), read with `siblings` as
  `run/5` does, or `nil`; `absent` lists their chunks not generated yet.
  """
  def first_surviving(%Valimc.World.Blocks{ref: ref}, siblings, position, states, absent) do
    stores = for %Valimc.World.Blocks{ref: sibling} <- siblings, do: sibling
    {:ok, state} = Native.block_first_surviving(ref, stores, native(), position, states, absent)
    state
  end

  defp pack(records),
    do:
      for(
        {{x, y, z}, state} <- records,
        into: <<>>,
        do: <<x::32-signed, y::32-signed, z::32-signed, state::16>>
      )
end
