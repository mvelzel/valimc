defmodule Valimc.Block.Rules do
  @moduledoc """
  Vanilla's block updates in a region (VMC-077m), run by the Rust rules engine
  that decoration shares (`valimc_core::rules`).

  After block changes in a region's storage the engine does what
  `Level.setBlock` starts: neighbour updates and shape updates in vanilla's
  orders, through a collecting updater with vanilla's chain limit. A shape
  that becomes air destroys its block (it leaves its fluid and drops its
  loot); a dependent block's due tick breaks it if it can no longer survive.
  The engine reads the region's cells and returns what it decided; the owner
  commits it. Updates stop at the region's border: an update at a cell the
  region does not hold, or whose rule reads one, is dropped.

  Rules come from the shared rule modules, live play's survival facts
  (`priv/physics/support.json`) and decoration's shape facts, in that order;
  a state none models keeps its state.
  """
  import Bitwise
  alias Valimc.{Native, Worldgen}
  alias Valimc.Registry.BlockFacts

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
    read = &(Application.app_dir(:valimc, &1) |> File.read!() |> JSON.decode!())

    %{
      "block_registry" => read.("priv/registry/blocks.json"),
      "block_facts" => Worldgen.block_facts(Valimc.Protocol.Data.tags()),
      "support" => read.("priv/worldgen/survival.json"),
      "shapes" => read.("priv/worldgen/shapes.json"),
      "live_support" => read.("priv/physics/support.json")
    }
  end

  @doc """
  The updates after the cells of `previous` (`position => old state`) changed
  in a region's storage, and at dependent blocks' due `ticks` (`[{position,
  state}]`); `absent` lists the region's chunks not generated yet. Returns
  `%{changes: [{position, state}], destroyed: [{position, state, drops?}],
  ticks: [{position, block, delay}], stopped: n, skipped: n}`; storage is not
  changed.
  """
  def run(%Valimc.World.Blocks{ref: ref}, previous, ticks, absent) do
    units = map_size(previous) + length(ticks)
    args = [ref, native(), pack(previous), pack(ticks), absent, :rand.uniform(1 <<< 62)]

    {:ok, {changes, destroyed, scheduled, stopped, skipped}} =
      Native.dispatch(:block_updates, units, args)

    %{
      changes:
        for(<<x::32-signed, y::32-signed, z::32-signed, s::16 <- changes>>, do: {{x, y, z}, s}),
      destroyed:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, s::16, drops::8 <- destroyed>>,
          do: {{x, y, z}, s, drops == 1}
        ),
      ticks:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, block::16, delay::32-signed <- scheduled>>,
          do: {{x, y, z}, block, delay}
        ),
      stopped: stopped,
      skipped: skipped
    }
  end

  defp pack(records),
    do:
      for(
        {{x, y, z}, state} <- records,
        into: <<>>,
        do: <<x::32-signed, y::32-signed, z::32-signed, state::16>>
      )
end
