defmodule Valimc.Anvil.Chunk do
  @moduledoc """
  A vanilla chunk's NBT as ValiMC section storage (VMC-021b).

  Only full chunks (`Status` `minecraft:full`) at the pinned data version become
  columns. Each of the 24 sections (y −4..19) is a block palette (names and
  properties as state ids) with packed indices, and a biome palette (registry ids)
  with packed indices; the packing is vanilla's `PalettedContainer` storage, with
  `max(4, ⌈log2 n⌉)` bits for blocks and `⌈log2 n⌉` for biomes, none for one entry.
  A section missing from the NBT is air in plains, as vanilla fills it. Light-only
  sections outside the world are ignored. 26.3 writes a palette entry as its
  block's name (its default state) or `{id, properties}`; a palette mixing both
  is a compound list with names wrapped as `{"": name}`.

  `column/2` threads a cache of palette entries to state ids, so an importer
  resolves each distinct block state once.
  """
  alias Valimc.Protocol.Data
  alias Valimc.Registry.Blocks
  alias Valimc.World.Schema

  @min_section -4
  @max_section 19
  @biomes "minecraft:worldgen/biome"

  @type spec ::
          {[non_neg_integer()], binary(), non_neg_integer(), [non_neg_integer()], binary(),
           non_neg_integer()}

  @doc """
  `{{:ok, %{chunk: {x, z}, sections: [spec]}}, cache}` for a full chunk,
  `{{:skip, status}, cache}` for any other status, or `{{:error, reason}, cache}`.
  """
  def column({:compound, root} = tag, cache \\ %{}) do
    with {:ok, _} <- Schema.check(:chunk, tag),
         {:int, x} <- root["xPos"],
         {:int, z} <- root["zPos"],
         {:string, status} <- root["Status"] do
      if status == "minecraft:full",
        do: full({x, z}, root["sections"], cache),
        else: {{:skip, status}, cache}
    else
      {:error, _} = error -> {error, cache}
      _ -> {{:error, :invalid_chunk}, cache}
    end
  end

  defp full(chunk, sections, cache) do
    present =
      case sections do
        {:list, {:compound, list}} -> list
        {:list, {:end, []}} -> []
        nil -> []
        _ -> :invalid
      end

    by_y =
      if present == :invalid,
        do: :invalid,
        else:
          Map.new(
            for %{"Y" => {:byte, y}} = s <- present, y in @min_section..@max_section, do: {y, s}
          )

    if by_y == :invalid do
      {{:error, :invalid_sections}, cache}
    else
      {specs, cache} =
        Enum.map_reduce(@min_section..@max_section, cache, fn y, cache ->
          section(Map.get(by_y, y, %{}), cache)
        end)

      case Enum.find(specs, &match?({:error, _}, &1)) do
        nil -> {{:ok, %{chunk: chunk, sections: specs}}, cache}
        error -> {error, cache}
      end
    end
  end

  defp section(fields, cache) do
    case blocks(fields["block_states"], cache) do
      {:ok, {palette, data, bits}, cache} ->
        case biomes(fields["biomes"]) do
          {:ok, {biomes, biome_data, biome_bits}} ->
            {{palette, data, bits, biomes, biome_data, biome_bits}, cache}

          error ->
            {error, cache}
        end

      {:error, reason, cache} ->
        {{:error, reason}, cache}
    end
  end

  defp blocks(nil, cache), do: {:ok, {[0], <<>>, 0}, cache}

  defp blocks({:compound, %{"palette" => {:list, palette}} = container}, cache) do
    entries =
      case palette do
        {:string, [_ | _] = names} -> Enum.map(names, &{:name, &1})
        {:compound, [_ | _] = entries} -> Enum.map(entries, &entry/1)
        _ -> [nil]
      end

    {ids, cache} =
      Enum.map_reduce(entries, cache, fn entry, cache ->
        case cache do
          %{^entry => id} ->
            {id, cache}

          _ ->
            id = state(entry)
            {id, Map.put(cache, entry, id)}
        end
      end)

    if Enum.any?(ids, &is_nil/1),
      do: {:error, :unknown_block_state, cache},
      else: packed(ids, container, max(4, bits(length(ids))), cache)
  end

  defp blocks(_, cache), do: {:error, :invalid_block_states, cache}

  defp packed([id], _container, _bits, cache), do: {:ok, {[id], <<>>, 0}, cache}

  defp packed(ids, %{"data" => {:long_array, data}}, bits, cache),
    do: {:ok, {ids, data, bits}, cache}

  defp packed(_, _, _, cache), do: {:error, :missing_section_data, cache}

  defp entry(%{"" => {:string, name}} = wrapper) when map_size(wrapper) == 1, do: {:name, name}

  defp entry(%{"id" => {:string, name}} = entry) do
    case entry["properties"] do
      {:compound, props} -> {name, for({k, {:string, v}} <- props, into: %{}, do: {k, v})}
      nil -> {:name, name}
      _ -> nil
    end
  end

  defp entry(_), do: nil

  defp state({:name, name}), do: state({name, %{}})

  defp state({"minecraft:" <> name, properties}) do
    if Blocks.id(name), do: Blocks.state(name, properties)
  rescue
    ArgumentError -> nil
  end

  defp state(_), do: nil

  @plains Data.registry_id(@biomes, "minecraft:plains")

  defp biomes(nil), do: {:ok, {[@plains], <<>>, 0}}

  defp biomes({:compound, %{"palette" => {:list, {:string, names}}} = container})
       when names != [] do
    ids = Enum.map(names, &Data.find_registry_id(@biomes, &1))

    cond do
      Enum.any?(ids, &is_nil/1) ->
        {:error, :unknown_biome}

      length(ids) == 1 ->
        {:ok, {ids, <<>>, 0}}

      match?(%{"data" => {:long_array, _}}, container) ->
        {:ok, {ids, elem(container["data"], 1), bits(length(ids))}}

      true ->
        {:error, :missing_section_data}
    end
  end

  defp biomes(_), do: {:error, :invalid_biomes}

  # ⌈log2 n⌉ for n ≥ 2.
  defp bits(n), do: n |> Kernel.-(1) |> Integer.digits(2) |> length()
end
