defmodule Valimc.Storage.Anvil.Chunk do
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
  alias Valimc.Data.Blocks
  alias Valimc.Storage.Schema

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

  @doc """
  A full chunk's root compound for a region file (export, VMC-021e3), from
  `Blocks.dump_column/2` states (24 × 4,096 big-endian u16) and biomes (24 × 64),
  block entity compounds and the chunk's preserved `extras` (structures, ticks...).
  Palettes list states in first-appearance order: a default state as its name,
  any other as `{id, properties}`, as 26.3 writes them. Heightmaps and light are
  left for vanilla to compute (`isLightOn` false).
  """
  def to_nbt({cx, cz}, states, biomes, block_entities, extras \\ %{})
      when byte_size(states) == 24 * 8192 and byte_size(biomes) == 24 * 128 do
    sections =
      for s <- 0..23 do
        {:compound,
         %{
           "Y" => {:byte, s + @min_section},
           "block_states" => container(binary_part(states, s * 8192, 8192), &block_entry/1, 4),
           "biomes" => container(binary_part(biomes, s * 128, 128), &biome_entry/1, 0)
         }}
      end

    {:compound,
     Map.merge(extras, %{
       "DataVersion" => {:int, Schema.data_version()},
       "xPos" => {:int, cx},
       "zPos" => {:int, cz},
       "yPos" => {:int, @min_section},
       "Status" => {:string, "minecraft:full"},
       "isLightOn" => {:byte, 0},
       "sections" => Valimc.Data.NBT.list(sections),
       "block_entities" => Valimc.Data.NBT.list(block_entities)
     })}
  end

  # A paletted container (`valimc_core::section::pack_vanilla`): palette in
  # first-appearance order, indices packed `max(minimum, ⌈log2 n⌉)` bits per value
  # without spanning longs; no data for a single entry.
  defp container(values, entry, minimum) do
    {:ok, {palette, data}} = Valimc.Native.pack_paletted(values, minimum)
    tags = Valimc.Data.NBT.list(Enum.map(palette, entry))

    if data == <<>>,
      do: {:compound, %{"palette" => tags}},
      else: {:compound, %{"palette" => tags, "data" => {:long_array, data}}}
  end

  @doc false
  # The Elixir reference of `Native.pack_paletted/2` (parity tests).
  def pack_reference(values, minimum) do
    ids = for <<id::16 <- values>>, do: id
    palette = Enum.uniq(ids)

    case palette do
      [_] ->
        {palette, <<>>}

      _ ->
        bits = max(minimum, bits(length(palette)))
        index = palette |> Enum.with_index() |> Map.new()

        data =
          for long <- Enum.chunk_every(ids, div(64, bits)), into: <<>> do
            {value, _} =
              Enum.reduce(long, {0, 0}, fn id, {acc, shift} ->
                {Bitwise.bor(acc, Bitwise.bsl(Map.fetch!(index, id), shift)), shift + bits}
              end)

            <<value::64>>
          end

        {palette, data}
    end
  end

  defp block_entry(state) do
    id = Blocks.block_id(state)
    name = "minecraft:" <> Blocks.name(id)

    if Blocks.default_state(Blocks.name(id)) == state do
      {:string, name}
    else
      properties = for {k, v} <- Blocks.properties(state), into: %{}, do: {k, {:string, v}}
      {:compound, %{"id" => {:string, name}, "properties" => {:compound, properties}}}
    end
  end

  defp biome_entry(id), do: {:string, Data.registry_name(@biomes, id)}
end
