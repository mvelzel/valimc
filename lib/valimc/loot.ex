defmodule Valimc.Loot do
  @moduledoc """
  Vanilla's container loot tables (VMC-072a). The loot facts in `priv/loot`
  (`LootOracle`: the tables chests, barrels, dispensers, decorated pots and
  brushable blocks name, as a server loads them, and what evaluating them
  reads) parse once per VM into a native registry (`valimc_core::loot`).

  `fill/3` is `RandomizableContainer.unpackLootTable` on an empty container:
  `LootTable.fill` with the stored seed (a fresh random one when none is
  stored, where vanilla draws from the world's random sequence), from the
  centre of the container's block. `items/3` is a brushable block's
  `getRandomItems`. The world's answers come with the call: the biome at the
  loot origin, the structure an exploration map would find (none where
  ValiMC has no map search) and the next free map id.
  """
  alias Valimc.Native
  alias Valimc.Protocol.{ItemData, ItemStack}

  @doc "The native loot registry, parsed from the facts on first use."
  def registry do
    case :persistent_term.get({__MODULE__, :registry}, nil) do
      nil ->
        read = &Valimc.Facts.read!("loot/#{&1}.json")

        tables = read.("tables")
        {:ok, registry} = Native.loot_registry(tables, read.("registries"))
        :persistent_term.put({__MODULE__, :tables}, MapSet.new(Map.keys(tables)))
        :persistent_term.put({__MODULE__, :registry}, registry)
        registry

      registry ->
        registry
    end
  end

  @doc "Whether the facts hold `table` (vanilla fills nothing from an unknown one)."
  def known?(table) do
    registry()
    MapSet.member?(:persistent_term.get({__MODULE__, :tables}), table)
  end

  @doc """
  The container a table fills: `{:ok, slots, next_map}` with `slots` a tuple
  of `size` stacks or nil. Options: `:size` (27), `:luck` (0.0), `:biome`
  (the loot origin's biome identifier), `:structure` (`{x, y, z}` an
  exploration map finds, or nil), `:next_map` (0), `:registry` (another
  native registry, for checks).
  """
  def fill(table, seed, {x, y, z}, opts \\ []) when is_binary(table) and is_integer(seed) do
    size = Keyword.get(opts, :size, 27)

    with {:ok, {tags, next_map}} <-
           call(fn ->
             Native.loot_fill(
               Keyword.get_lazy(opts, :registry, &registry/0),
               table,
               effective_seed(seed),
               Keyword.get(opts, :luck, 0.0) * 1.0,
               {x + 0.5, y + 0.5, z + 0.5},
               size,
               Keyword.get(opts, :biome),
               Keyword.get(opts, :structure),
               Keyword.get(opts, :next_map, 0)
             )
           end),
         {:ok, stacks} <- stacks(tags) do
      {:ok, List.to_tuple(stacks), next_map}
    end
  end

  @doc "A brushable block's items: `{:ok, stacks, next_map}` (options as `fill/4`)."
  def items(table, seed, {x, y, z}, opts \\ []) when is_binary(table) and is_integer(seed) do
    with {:ok, {tags, next_map}} <-
           call(fn ->
             Native.loot_items(
               Keyword.get_lazy(opts, :registry, &registry/0),
               table,
               effective_seed(seed),
               Keyword.get(opts, :luck, 0.0) * 1.0,
               {x + 0.5, y + 0.5, z + 0.5},
               Keyword.get(opts, :biome),
               Keyword.get(opts, :structure),
               Keyword.get(opts, :next_map, 0)
             )
           end),
         {:ok, stacks} <- stacks(tags) do
      {:ok, stacks, next_map}
    end
  end

  # A stored seed of 0 means none: vanilla then draws from the world's random
  # sequence for the table, which ValiMC does not keep; a fresh seed gives the
  # same distribution.
  defp effective_seed(0) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    if seed == 0, do: 1, else: seed
  end

  defp effective_seed(seed), do: seed

  defp call(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:ok, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp stacks(tags) do
    Enum.reduce_while(tags, {:ok, []}, fn
      nil, {:ok, acc} ->
        {:cont, {:ok, [nil | acc]}}

      tag, {:ok, acc} ->
        case ItemData.stack(tag) do
          {:ok, stack} -> {:cont, {:ok, [stack && ItemStack.normalize(stack) | acc]}}
          {:unsupported, names} -> {:halt, {:error, {:unsupported_components, names}}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
