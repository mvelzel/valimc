defmodule Valimc.World.LootChests do
  @moduledoc """
  Unrolled loot in chests (VMC-072b). Generated dungeon and structure chests,
  and imported chests nobody opened, keep a loot table and seed instead of
  items; ValiMC holds them as preserved block entities. `unpack/6` is
  `RandomizableContainer.unpackLootTable` for a single chest whose compound
  holds nothing else ValiMC cannot own (no custom name or lock): vanilla's fill
  for the stored seed (a fresh one when none is stored) becomes the contents
  of an ordinary owned chest, and the preserved entry goes. The owner commits
  both in one frame, so a chest never rolls twice.

  As vanilla, a looted chest's stored `Items` are ignored and a table the
  server does not know fills nothing.
  """
  alias Valimc.{Loot, NBT}
  alias Valimc.World.{BlockEntities, Containers}

  @fields ~w(id x y z keepPacked Items LootTable LootTableSeed)

  @doc "`{:ok, table, seed}` for a chest compound ValiMC can unpack, else `:error`."
  def unrolled(nbt) when is_binary(nbt) do
    with {:ok, {:compound, fields}} <- NBT.read(nbt),
         {:string, table} <- fields["LootTable"],
         true <- Enum.all?(Map.keys(without_empty_components(fields)), &(&1 in @fields)),
         {:ok, seed} <- seed(fields["LootTableSeed"]) do
      {:ok, qualified(table), seed}
    else
      _ -> :error
    end
  end

  def unrolled(_), do: :error

  @doc "Whether the single chest `block` at `position` holds unrolled loot ValiMC can unpack."
  def unrolled?(containers, entities, position, block) do
    match?({:ok, _, _}, unrolled_at(containers, entities, position, block))
  end

  @doc """
  Unpack the chest at `position`: `{:ok, containers, entities, entry}` with the
  filled owned entry, or `:error` when there is nothing ValiMC can unpack or
  the fill does not fit. `opts`: `:luck` (0.0) and `:biome` (a function giving
  the biome at the chest, read only when the table asks).
  """
  def unpack(%Containers{} = containers, %BlockEntities{} = entities, key, position, block, opts) do
    with {:ok, table, seed} <- unrolled_at(containers, entities, position, block),
         {:ok, slots} <- fill(table, seed, position, opts),
         {:ok, created, entry} <- Containers.create(containers, key, position, 3),
         {:ok, filled, entry} <- Containers.replace(created, position, entry.revision, slots),
         {:ok, _} <- Containers.encode(key, filled) do
      {:ok, filled, BlockEntities.drop(entities, position), entry}
    else
      _ -> :error
    end
  end

  defp unrolled_at(containers, entities, position, block) do
    with true <- Valimc.Block.Chest.single?(block),
         false <- Map.has_key?(containers.entries, position),
         %{nbt: nbt} <- BlockEntities.live(entities, position, block) do
      unrolled(nbt)
    else
      _ -> :error
    end
  end

  defp fill(table, seed, position, opts) do
    if Loot.known?(table) do
      biome = Keyword.get(opts, :biome, fn -> nil end)

      case Loot.fill(table, seed, position, luck: Keyword.get(opts, :luck, 0.0), biome: biome.()) do
        {:ok, slots, _} -> {:ok, slots}
        error -> error
      end
    else
      {:ok, Tuple.duplicate(nil, 27)}
    end
  end

  defp seed(nil), do: {:ok, 0}
  defp seed({:long, seed}), do: {:ok, seed}
  defp seed(_), do: :error

  # Vanilla writes `components` on every block entity, empty when it has none.
  defp without_empty_components(%{"components" => {:compound, c}} = fields) when map_size(c) == 0,
    do: Map.delete(fields, "components")

  defp without_empty_components(fields), do: fields

  defp qualified(name), do: if(String.contains?(name, ":"), do: name, else: "minecraft:" <> name)
end
