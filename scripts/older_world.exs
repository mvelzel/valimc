# VMC-028d: a 26.2 world made from a vanilla 26.3 one (AnvilContentOracle's
# world: every block entity type, signs, pots, component items, entities).
# Every region and entities chunk is written back as 26.2 stored it, undoing
# what 26.3's fixes and codecs changed: block states as `{Name, Properties}`
# (26.3 also writes a bare name), signs without `allow_op_features`, pot
# decorations as four item ids, the terrain status as carvers, no blending
# data; every file at data version 4903. The chunks are listed for
# DataFixOracle, which upgrades them as vanilla does.
[facts_path, older, cases_path] = System.argv()
alias Valimc.Storage.Anvil.{RegionFile, RegionWriter}
alias Valimc.Data.NBT

defmodule Older do
  @version 4903
  @state_keys ~w(blockState DisplayState inBlockState BlockState carriedBlockState block_state)
  @sides ~w(back left right front)

  def version, do: @version

  def chunk({:compound, root}) do
    root =
      root
      |> Map.put("DataVersion", {:int, @version})
      |> Map.delete("blending_data")

    root =
      case root["Status"] do
        {:string, "minecraft:terrain"} -> Map.put(root, "Status", {:string, "minecraft:carvers"})
        _ -> root
      end

    walk({:compound, root}, nil)
  end

  def entities({:compound, root}),
    do: walk({:compound, Map.put(root, "DataVersion", {:int, @version})}, nil)

  defp walk({:compound, fields}, key) do
    fields =
      Map.new(fields, fn
        {name, value} when name in ["minecraft:custom_data", "minecraft:bucket_entity_data"] ->
          {name, value}

        {name, value} ->
          {name, walk(value, name)}
      end)

    {:compound, at(key, fields)}
  end

  defp walk({:list, {:compound, entries}}, key) do
    {:list,
     {:compound,
      for entry <- entries do
        {:compound, entry} = walk({:compound, entry}, nil)
        if key == "block_entities", do: block_entity(entry), else: entry
      end}}
  end

  defp walk({:list, {:list, lists}}, _key),
    do: {:list, {:list, Enum.map(lists, &elem(walk({:list, &1}, nil), 1))}}

  defp walk({:string, _} = tag, key) when key in @state_keys, do: {:compound, state(tag)}
  defp walk(tag, _key), do: tag

  defp at(key, fields) when key in @state_keys, do: state({:compound, fields})
  defp at("block_states", fields), do: Map.update!(fields, "palette", &palette/1)

  defp at(key, fields) when key in ["TileEntityData", "minecraft:block_entity_data"],
    do: block_entity(fields)

  defp at("components", fields) do
    fields =
      case fields do
        %{"minecraft:pot_decorations" => sides} ->
          %{fields | "minecraft:pot_decorations" => sherds(sides)}

        _ ->
          fields
      end

    case fields do
      %{"minecraft:attack_animation" => same, "minecraft:interact_animation" => same} ->
        fields
        |> Map.drop(["minecraft:attack_animation", "minecraft:interact_animation"])
        |> Map.put("minecraft:swing_animation", same)

      _ ->
        fields
    end
  end

  defp at(_key, fields), do: fields

  defp block_entity(%{"id" => {:string, id}} = fields)
       when id in ["minecraft:sign", "minecraft:hanging_sign"],
       do: Map.delete(fields, "allow_op_features")

  defp block_entity(%{"id" => {:string, "minecraft:decorated_pot"}, "sherds" => sides} = fields),
    do: %{fields | "sherds" => sherds(sides)}

  defp block_entity(fields), do: fields

  # 26.3's sides (missing ones bricks) as 26.2's list of four item ids.
  defp sherds({:compound, sides}) do
    ids =
      for side <- @sides do
        case sides[side] do
          {:compound, %{"id" => {:string, id}}} -> id
          _ -> "minecraft:brick"
        end
      end

    {:list, {:string, ids}}
  end

  defp sherds(other), do: other

  defp palette({:list, {:string, names}}),
    do: {:list, {:compound, Enum.map(names, &state({:string, &1}))}}

  defp palette({:list, {:compound, entries}}),
    do: {:list, {:compound, Enum.map(entries, &state({:compound, &1}))}}

  defp palette(other), do: other

  defp state({:string, name}), do: %{"Name" => {:string, name}}
  defp state({:compound, %{"" => {:string, name}}}), do: %{"Name" => {:string, name}}

  defp state({:compound, fields}) do
    fields
    |> rename("id", "Name")
    |> rename("properties", "Properties")
  end

  defp rename(fields, from, to) do
    case Map.pop(fields, from) do
      {nil, fields} -> fields
      {value, fields} -> Map.put(fields, to, value)
    end
  end
end

facts = facts_path |> File.read!() |> JSON.decode!()
File.rm_rf!(older)
File.cp_r!(facts["world"], older)
dimension = Path.join(older, "dimensions/minecraft/overworld")

cases =
  for {folder, kind, downgrade} <- [
        {"region", "chunk", &Older.chunk/1},
        {"entities", "entities", &Older.entities/1}
      ],
      path <- Enum.sort(Path.wildcard(Path.join([dimension, folder, "r.*.mca"]))) do
    {:ok, region} = RegionFile.coords(path)
    {:ok, chunks} = RegionFile.chunks(path)

    written =
      for {chunk, {:ok, bytes}} <- chunks, into: %{} do
        {:ok, tag} = NBT.read(bytes)
        {chunk, IO.iodata_to_binary(NBT.write(downgrade.(tag)))}
      end

    File.rm!(path)
    :ok = RegionWriter.write(Path.dirname(path), region, written)

    for {{x, z}, bytes} <- Enum.sort(written),
        do: %{name: "#{folder} #{x} #{z}", kind: kind, nbt: Base.encode64(bytes)}
  end
  |> List.flatten()

# `level.dat` and the generation settings at 26.2's version too (the fields
# ValiMC reads of them did not change).
version = {:int, Older.version()}

for {file, data?} <- [{"level.dat", true}, {"data/minecraft/world_gen_settings.dat", false}],
    file = Path.join(older, file),
    File.exists?(file) do
  {:ok, {:compound, root}} = file |> File.read!() |> NBT.read_compressed(:gzip)

  root =
    if data?,
      do:
        Map.update!(root, "Data", fn {:compound, d} ->
          {:compound, %{d | "DataVersion" => version}}
        end),
      else: %{root | "DataVersion" => version}

  File.write!(file, NBT.compress(NBT.write({:compound, root}), :gzip))
end

File.write!(cases_path, JSON.encode!(%{cases: cases}))
IO.puts("PASS: a 26.2 world of #{length(cases)} chunks in #{older}")
