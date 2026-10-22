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
  a state none models keeps its state. Water and lava flow in the same engine
  (VMC-031a, `priv/physics/fluids.json`): due fluid ticks, buckets and a
  generated chunk's post-processing marks are part of a run.
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
      "live_support" => Valimc.Data.Facts.read!("physics/support.json"),
      "fluids" => Valimc.Blocks.Fluids.native_facts()
    }
  end

  @doc """
  One engine run in a section's storage, reading across the stores of
  `siblings` (the group's other sections; `absent` lists their chunks not
  generated yet). `input` holds what starts it, each optional:

  - `changes`: `position => old state` for cells the owner just changed;
  - `actions`: `{:empty, position, fluid, retry, secondary}` (a bucket of a
    fluid source poured, then at `retry` or nil), `{:pickup, position}` (a
    bucket filled), `{:post, position}` (a post-processing mark);
  - `ticks`: dependent blocks' due ticks, `[{position, state}]`;
  - `fluid_ticks`: due fluid ticks, `[{position, fluid}]`;
  - `options`: the fluid settings' bits (`Valimc.Blocks.Fluids.options/3`).

  Returns `%{changes: [{position, state}], destroyed: [{position, state,
  drops?, effects?}], ticks: [{position, block, delay}], fluid_ticks:
  [{position, fluid, delay}], events: [{position, type, data}], results:
  [integer], stopped: n, skipped: n, updates: n}` (`effects?`: it breaks
  with particles and sound; `results`: one per action, see
  `live::Outcome::results`; the counts: updates dropped at the group's edge,
  past the chain limit and run); storage is not changed.
  """
  def run(%Valimc.World.Blocks{ref: ref}, siblings, input, absent) do
    changes = Map.get(input, :changes, %{})
    ticks = Map.get(input, :ticks, [])
    fluid_ticks = Map.get(input, :fluid_ticks, [])
    actions = Map.get(input, :actions, [])
    units = map_size(changes) + length(ticks) + length(fluid_ticks) + length(actions)
    stores = for %Valimc.World.Blocks{ref: sibling} <- siblings, do: sibling

    args = [
      ref,
      stores,
      native(),
      pack(changes),
      pack(ticks),
      for(
        {{x, y, z}, fluid} <- fluid_ticks,
        into: <<>>,
        do: <<x::32-signed, y::32-signed, z::32-signed, fluid>>
      ),
      for(action <- actions, into: <<>>, do: pack_action(action)),
      absent,
      :rand.uniform(1 <<< 62),
      Map.get(input, :options, 0)
    ]

    {:ok, {{changed, destroyed, scheduled, fluid, events, results}, {stopped, skipped, updates}}} =
      case Native.dispatch(:block_updates, units, args) do
        # A cascade past the normal scheduler's budget runs again, dirty.
        {:error, :too_large} -> apply(Native, :block_updates_dirty, args)
        result -> result
      end

    %{
      changes:
        for(<<x::32-signed, y::32-signed, z::32-signed, s::16 <- changed>>, do: {{x, y, z}, s}),
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
      fluid_ticks:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, kind::8, delay::32-signed <- fluid>>,
          do: {{x, y, z}, kind, delay}
        ),
      events:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, type::32-signed,
            data::32-signed <- events>>,
          do: {{x, y, z}, type, data}
        ),
      results: results,
      stopped: stopped,
      skipped: skipped,
      updates: updates
    }
  end

  defp pack_action({:empty, position, fluid, retry, secondary}) do
    flags = if(retry, do: 1, else: 0) ||| if(secondary, do: 2, else: 0)
    <<0, pos(position)::binary, fluid, flags, pos(retry || {0, 0, 0})::binary>>
  end

  defp pack_action({:pickup, position}),
    do: <<1, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:post, position}),
    do: <<2, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pos({x, y, z}), do: <<x::32-signed, y::32-signed, z::32-signed>>

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
