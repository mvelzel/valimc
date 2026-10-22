defmodule Valimc.Storage.DataFix do
  @moduledoc """
  Region and entity chunks of older data versions, upgraded as vanilla 26.3's
  data fixers upgrade them (VMC-028d).

  ValiMC upgrades chunks from data version #{4899} on: 26.2 (4903) and 26.3's
  snapshots. After 4899 vanilla's fixer (`DataFixers`) has these fixes, each
  applied, in order, to data older than its schema:

  | Schema | Vanilla fix | Change |
  |---|---|---|
  | 4996 | `PotDecorationsComponentUnflatteningFix` | `minecraft:pot_decorations`: a list of four item ids becomes `back`, `left`, `right` and `front` compounds of `id` (bricks where missing) |
  | 4996.1 | `PotDecorationsBlockEntityUnflatteningFix` | a decorated pot's `sherds` likewise (four bricks when it has none) |
  | 4997 | `BlendingDataFix` | an overworld chunk with a status beyond biomes is marked for blending with new terrain (`blending_data` of sections −4 to 20, or 0 to 16 below its retrogen) |
  | 5002 | `SignsOpFlagFix` | signs and hanging signs get `allow_op_features` |
  | 5006 | `BlockStateFieldNamesFix` | block states' `Name` and `Properties` become `id` and `properties` |
  | 5007 | `SwingAnimationComponentSplitFix` | `minecraft:swing_animation` becomes `attack_animation` and `interact_animation` |
  | 5008 | `ExplorerMapItemFix`, `MapColorComponentRemovalFix` | a filled map with an explorer decoration becomes its explorer map item (without its legacy name); `minecraft:map_color` is dropped |
  | 5009 | `BlendingDataNoValueHeightFix` | blending heights become floats |
  | 5012 | `ItemRenameFix` | the explorer map items get their final ids |
  | 5013 | `MergeTerrainChunkStatusFix` | the noise and surface statuses become biomes (their block states dropped), carvers becomes terrain |
  | 5014 | `RemoveBlockTransformerComponentFix` | `minecraft:block_transformer` is dropped |
  | 5016 | `UnfilledBuriedTreasureMapFix` | an empty map named as a buried treasure map takes the item's own name |

  The other schemas in that range add types (entities, blocks, items) or fix
  client options and change no stored data. ValiMC applies each fix where its
  type occurs in a chunk: block states at the keys vanilla's schemas type as
  block states, block entities in `block_entities`, a falling block's
  `TileEntityData` and the `minecraft:block_entity_data` component, data
  components under `components`, item stacks by their `id`; never inside
  `minecraft:custom_data`, `minecraft:bucket_entity_data` or a marker's
  `data`, which vanilla does not type. Stage `world_upgrade`
  compares every result with vanilla's own fixer.

  Files ValiMC only reads a few fields of (`level.dat`'s spawn, the generation
  settings) are read as they are (`readable/2`): those fixes do not touch them,
  and the copies an import keeps for export stay at their version, which
  vanilla upgrades when it opens the export.
  """
  alias Valimc.Storage.Schema

  @oldest 4899

  # {DataFixUtils.makeKey(version, subversion), fix}, in DataFixers' order.
  @fixes [
    {49_960, :pot_decorations_component},
    {49_961, :pot_decorations_block_entity},
    {49_970, :blending_data},
    {50_020, :sign_op_flag},
    {50_060, :block_state_field_names},
    {50_070, :swing_animation_split},
    {50_080, :explorer_map_items},
    {50_080, :map_color_removal},
    {50_090, :blending_heights},
    {50_120, :explorer_map_rename},
    {50_130, :merge_terrain_status},
    {50_140, :remove_block_transformer},
    {50_160, :unfilled_buried_treasure_map}
  ]

  # Fields vanilla's schemas type as block states (`References.BLOCK_STATE`).
  @state_keys ~w(blockState DisplayState inBlockState BlockState carriedBlockState block_state)

  @decoration_items %{
    "minecraft:mansion" => {"minecraft:woodland_explorer_map", "filled_map.mansion"},
    "minecraft:monument" => {"minecraft:ocean_explorer_map", "filled_map.monument"},
    "minecraft:trial_chambers" => {"minecraft:trial_explorer_map", "filled_map.trial_chambers"},
    "minecraft:jungle_temple" => {"minecraft:jungle_explorer_map", "filled_map.explorer_jungle"},
    "minecraft:swamp_hut" => {"minecraft:swamp_explorer_map", "filled_map.explorer_swamp"},
    "minecraft:village_desert" => {"minecraft:desert_village_map", "filled_map.village_desert"},
    "minecraft:village_plains" => {"minecraft:plains_village_map", "filled_map.village_plains"},
    "minecraft:village_savanna" =>
      {"minecraft:savanna_village_map", "filled_map.village_savanna"},
    "minecraft:village_snowy" => {"minecraft:snowy_village_map", "filled_map.village_snowy"},
    "minecraft:village_taiga" => {"minecraft:taiga_village_map", "filled_map.village_taiga"},
    "minecraft:red_x" => {"minecraft:buried_treasure_map", "filled_map.buried_treasure"}
  }

  @renamed_items %{
    "minecraft:ocean_explorer_map" => "minecraft:ocean_monument_map",
    "minecraft:swamp_explorer_map" => "minecraft:swamp_hut_map",
    "minecraft:trial_explorer_map" => "minecraft:buried_trial_chambers_map",
    "minecraft:woodland_explorer_map" => "minecraft:woodland_mansion_map",
    "minecraft:jungle_explorer_map" => "minecraft:jungle_pyramid_map"
  }

  # Components vanilla's schemas leave untyped: no fix reaches inside them.
  @untyped ~w(minecraft:custom_data minecraft:bucket_entity_data)

  @skip_blending ~w(minecraft:empty minecraft:structure_starts minecraft:structure_references minecraft:biomes)
  @intermediate ~w(minecraft:noise minecraft:surface)
  @sherd_sides ~w(back left right front)

  @doc "The oldest data version ValiMC upgrades."
  def oldest, do: @oldest

  @doc """
  A region (`:chunk`) or entities (`:entities`) chunk at the pinned data
  version: `{:ok, root}` (upgraded when older, `DataVersion` set), or
  `Schema.check/2`'s error for a version ValiMC does not upgrade. `dimension`
  is the chunk's, as vanilla's chunk storage passes it to the fixer.
  """
  def upgrade(kind, root, dimension \\ "minecraft:overworld")
      when kind in [:chunk, :entities] do
    current = Schema.data_version()

    case Schema.version(kind, root) do
      version when is_integer(version) and version >= @oldest and version < current ->
        {:compound, fields} =
          Enum.reduce(@fixes, root, fn {key, fix}, tag ->
            if key > version * 10, do: fix(fix, kind, tag, dimension), else: tag
          end)

        {:ok, {:compound, Map.put(fields, "DataVersion", {:int, current})}}

      _ ->
        with {:ok, _} <- Schema.check(kind, root), do: {:ok, root}
    end
  end

  @doc """
  Accept a file of `kind` whose fields ValiMC reads are the same from
  `oldest/0` on (`level.dat`'s spawn, world generation settings): `{:ok,
  version}`, or `Schema.check/2`'s error.
  """
  def readable(kind, root) do
    case Schema.version(kind, root) do
      version when is_integer(version) and version >= @oldest ->
        if version < Schema.data_version(), do: {:ok, version}, else: Schema.check(kind, root)

      _ ->
        Schema.check(kind, root)
    end
  end

  ## Fixes on the chunk root

  defp fix(:blending_data, :chunk, {:compound, root}, dimension) do
    root = Map.delete(root, "blending_data")

    blending =
      cond do
        dimension != "minecraft:overworld" or not Map.has_key?(root, "Status") ->
          nil

        status_name(root["Status"]) not in @skip_blending ->
          {-64, 384}

        match?({:compound, _}, root["below_zero_retrogen"]) ->
          {:compound, retrogen} = root["below_zero_retrogen"]
          if status_name(retrogen["target_status"]) in @skip_blending, do: nil, else: {0, 256}

        true ->
          nil
      end

    {:compound,
     case blending do
       nil ->
         root

       {bottom, height} ->
         Map.put(
           root,
           "blending_data",
           {:compound,
            %{
              "min_section" => {:int, Bitwise.bsr(bottom, 4)},
              "max_section" => {:int, Bitwise.bsr(bottom + height, 4)}
            }}
         )
     end}
  end

  defp fix(:blending_heights, :chunk, {:compound, root}, _) do
    case root["blending_data"] do
      {:compound, %{"heights" => heights} = blending} ->
        floats = for value <- elements(heights), do: height(value)
        heights = if floats == [], do: {:list, {:end, []}}, else: {:list, {:float, floats}}
        {:compound, %{root | "blending_data" => {:compound, %{blending | "heights" => heights}}}}

      _ ->
        {:compound, root}
    end
  end

  defp fix(:merge_terrain_status, :chunk, {:compound, root}, _) do
    old = status_name(root["Status"], "minecraft:empty")
    root = Map.put(root, "Status", {:string, terrain_status(old)})

    {root, old_target} =
      case root["below_zero_retrogen"] do
        {:compound, retrogen} ->
          target = status_name(retrogen["target_status"], "minecraft:empty")
          retrogen = Map.put(retrogen, "target_status", {:string, terrain_status(target)})
          {Map.put(root, "below_zero_retrogen", {:compound, retrogen}), target}

        _ ->
          {root, nil}
      end

    target_intermediate = old_target != nil and old_target in @intermediate

    if old in @intermediate or target_intermediate do
      keep_above = old_target != nil and not target_intermediate
      root = Map.drop(root, ["Heightmaps", "blending_data"])

      sections =
        case root["sections"] do
          {:list, {:compound, sections}} ->
            {:list,
             {:compound,
              Enum.map(sections, fn section ->
                y =
                  case section["Y"] do
                    {:byte, y} -> y
                    _ -> 0
                  end

                if y >= 0 and keep_above,
                  do: section,
                  else: Map.delete(section, "block_states")
              end)}}

          other ->
            other
        end

      {:compound, if(sections, do: Map.put(root, "sections", sections), else: root)}
    else
      {:compound, root}
    end
  end

  defp fix(fix, _kind, tag, _)
       when fix in [:blending_data, :blending_heights, :merge_terrain_status],
       do: tag

  ## Fixes wherever their type occurs

  defp fix(fix, _kind, tag, _), do: walk(tag, fix)

  # Visit every compound below `tag` (not inside custom data), applying `fix`
  # to the compounds it concerns; `key` is the parent's key.
  defp walk(tag, fix, key \\ nil)

  defp walk({:compound, fields}, fix, key) do
    marker = fields["id"] == {:string, "minecraft:marker"}

    fields =
      Map.new(fields, fn
        {name, value} when name in @untyped -> {name, value}
        # A marker's data is free-form, as custom data is.
        {"data" = name, value} when marker -> {name, value}
        {name, value} -> {name, walk(value, fix, name)}
      end)

    {:compound, at(fix, key, fields)}
  end

  defp walk({:list, {:compound, entries}}, fix, key) do
    {:list,
     {:compound,
      Enum.map(entries, fn entry ->
        {:compound, entry} = walk({:compound, entry}, fix, nil)
        if key in ["block_entities", "palette"], do: element(fix, key, entry), else: entry
      end)}}
  end

  defp walk({:list, {:list, lists}}, fix, _key) do
    {:list, {:list, Enum.map(lists, fn list -> elem(walk({:list, list}, fix, nil), 1) end)}}
  end

  defp walk(tag, _fix, _key), do: tag

  # A compound at key `key` (its own fields already fixed).
  defp at(:block_state_field_names, key, fields) when key in @state_keys, do: state(fields)

  defp at(fix, key, fields) when key in ["TileEntityData", "minecraft:block_entity_data"],
    do: block_entity(fix, fields)

  defp at(fix, "components", fields), do: components(fix, fields)
  defp at(fix, _key, %{"id" => {:string, _}} = fields), do: item(fix, fields)
  defp at(_fix, _key, fields), do: fields

  # An element of a list at key `key`: a chunk's block entities, a section's
  # block state palette (the biome palette holds strings).
  defp element(fix, "block_entities", fields), do: block_entity(fix, fields)
  defp element(:block_state_field_names, "palette", fields), do: state(fields)
  defp element(_fix, _key, fields), do: fields

  defp state(fields), do: fields |> rename("Name", "id") |> rename("Properties", "properties")

  defp block_entity(:sign_op_flag, %{"id" => {:string, id}} = fields)
       when id in ["minecraft:sign", "minecraft:hanging_sign"],
       do: Map.put(fields, "allow_op_features", {:byte, 1})

  defp block_entity(
         :pot_decorations_block_entity,
         %{"id" => {:string, "minecraft:decorated_pot"}} = fields
       ),
       do: Map.put(fields, "sherds", sherds(Map.get(fields, "sherds", {:list, {:end, []}})))

  defp block_entity(_fix, fields), do: fields

  defp components(:pot_decorations_component, fields) do
    case fields do
      %{"minecraft:pot_decorations" => value} ->
        %{fields | "minecraft:pot_decorations" => sherds(value)}

      _ ->
        fields
    end
  end

  defp components(:swing_animation_split, fields) do
    case Map.pop(fields, "minecraft:swing_animation") do
      {nil, fields} ->
        fields

      {animation, fields} ->
        fields
        |> Map.put("minecraft:attack_animation", animation)
        |> Map.put("minecraft:interact_animation", animation)
    end
  end

  defp components(:map_color_removal, fields), do: Map.delete(fields, "minecraft:map_color")

  defp components(:remove_block_transformer, fields),
    do: Map.delete(fields, "minecraft:block_transformer")

  defp components(_fix, fields), do: fields

  defp item(
         :explorer_map_items,
         %{
           "id" => {:string, "minecraft:filled_map"},
           "components" => {:compound, %{"minecraft:map_decorations" => {:compound, marks}} = c}
         } = fields
       ) do
    type =
      case marks["+"] do
        {:compound, %{"type" => {:string, type}}} -> namespaced(type)
        _ -> nil
      end

    case @decoration_items[type] do
      nil ->
        fields

      {item, legacy} ->
        components =
          if translation_key(c["minecraft:item_name"]) == legacy,
            do: Map.delete(c, "minecraft:item_name"),
            else: c

        %{fields | "id" => {:string, item}, "components" => {:compound, components}}
    end
  end

  defp item(:explorer_map_rename, %{"id" => {:string, id}} = fields)
       when is_map_key(@renamed_items, id),
       do: %{fields | "id" => {:string, @renamed_items[id]}}

  defp item(
         :unfilled_buried_treasure_map,
         %{
           "id" => {:string, "minecraft:map"},
           "components" => {:compound, %{"minecraft:item_name" => name} = c}
         } = fields
       ) do
    if translation_key(name) == "filled_map.buried_treasure" do
      name = {:compound, %{"translate" => {:string, "item.minecraft.buried_treasure_map"}}}
      %{fields | "components" => {:compound, %{c | "minecraft:item_name" => name}}}
    else
      fields
    end
  end

  defp item(_fix, fields), do: fields

  ## Helpers

  # `PotDecorationsComponentUnflatteningFix.unpackList`: a list of item ids as
  # four sides; anything that is not a list stays. The ids are typed item
  # names, which vanilla's fixer reads namespaced (`""` is `minecraft:`), so
  # the empty id that would keep the list never reaches it.
  defp sherds(value) do
    case list_strings(value) do
      nil ->
        value

      ids ->
        ids = Enum.take(ids ++ List.duplicate("minecraft:brick", 4), 4)

        {:compound,
         Map.new(Enum.zip(@sherd_sides, ids), fn {side, id} ->
           {side, {:compound, %{"id" => {:string, id}}}}
         end)}
    end
  end

  # A list's entries as strings (bricks for entries that are not), or nil.
  defp list_strings({:list, {:string, values}}), do: Enum.map(values, &namespaced/1)

  defp list_strings({:list, {:compound, entries}}) do
    for entry <- entries do
      case entry do
        %{"" => {:string, id}} when map_size(entry) == 1 -> namespaced(id)
        _ -> "minecraft:brick"
      end
    end
  end

  defp list_strings({:list, {_type, values}}), do: Enum.map(values, fn _ -> "minecraft:brick" end)
  defp list_strings(_), do: nil

  # `ExtraDataFixUtils.getPlainTranslationKey`: a text component that is only
  # a translation key.
  defp translation_key({:compound, %{"translate" => {:string, key}} = fields})
       when map_size(fields) == 1,
       do: key

  defp translation_key(_), do: nil

  defp status_name(tag, default \\ "minecraft:empty")
  defp status_name({:string, name}, _default), do: namespaced(name)
  defp status_name(_, default), do: default

  defp terrain_status("minecraft:carvers"), do: "minecraft:terrain"
  defp terrain_status(status) when status in @intermediate, do: "minecraft:biomes"
  defp terrain_status(status), do: status

  # `NamespacedSchema.ensureNamespaced`: ids that parse as identifiers get the
  # `minecraft` namespace (the empty one too); others stay.
  defp namespaced(id) do
    cond do
      String.contains?(id, ":") -> id
      Regex.match?(~r/^[a-z0-9_.\/-]*$/, id) -> "minecraft:" <> id
      true -> id
    end
  end

  defp rename(fields, from, to) do
    case Map.pop(fields, from) do
      {nil, fields} -> fields
      {value, fields} -> Map.put(fields, to, value)
    end
  end

  # A list or array's numbers (`Dynamic.asStream`); nothing for other tags.
  # Mixed lists hold their elements in `{"": tag}` compounds, which vanilla
  # unwraps.
  defp elements({:list, {:compound, entries}}) do
    Enum.map(entries, fn
      %{"" => tag} = entry when map_size(entry) == 1 -> tag
      entry -> {:compound, entry}
    end)
  end

  defp elements({:list, {type, values}}), do: Enum.map(values, &{type, &1})
  defp elements({:byte_array, bytes}), do: for(<<b::signed-8 <- bytes>>, do: {:byte, b})
  defp elements({:int_array, bytes}), do: for(<<i::signed-32 <- bytes>>, do: {:int, i})
  defp elements({:long_array, bytes}), do: for(<<l::signed-64 <- bytes>>, do: {:long, l})
  defp elements(_), do: []

  @double_max 1.7976931348623157e308
  @float_max <<0x7F7FFFFF::32>>

  # `fixHeightValue`: Double.MAX_VALUE (no height) becomes Float.MAX_VALUE,
  # any other number its float; NaN is written as Java's canonical NaN.
  defp height({:float, <<_::1, 255::8, 0::23>> = infinity}), do: infinity
  defp height({:double, <<0::1, 2047::11, 0::52>>}), do: <<0x7F800000::32>>
  defp height({:double, <<1::1, 2047::11, 0::52>>}), do: <<0xFF800000::32>>
  defp height({type, <<_::1, 255::8, _::23>>}) when type == :float, do: <<0x7FC00000::32>>
  defp height({type, <<_::1, 2047::11, _::52>>}) when type == :double, do: <<0x7FC00000::32>>

  defp height(tag) do
    case number(tag) do
      nil -> @float_max
      value when value == @double_max -> @float_max
      value -> to_float32(value)
    end
  end

  defp number({type, value}) when type in [:byte, :short, :int, :long], do: value * 1.0
  defp number({:float, <<value::float-32>>}), do: value
  defp number({:double, <<value::float-64>>}), do: value
  defp number(_), do: nil

  # Java's `d2f`: round to nearest, infinity beyond the float range.
  defp to_float32(value) do
    <<value::float-32>>
  rescue
    ArgumentError -> if value > 0, do: <<0x7F800000::32>>, else: <<0xFF800000::32>>
  end
end
