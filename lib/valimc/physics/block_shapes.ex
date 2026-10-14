defmodule Valimc.Physics.BlockShapes do
  @moduledoc "Complete pinned cached state geometry; dynamic contexts are explicit unresolved lookups."
  @path Path.expand("../../../priv/physics/collision_shapes.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c",
         do: raise("Wrong collision catalog version")

  @shapes @facts["shapes"] |> Enum.map(&Valimc.Physics.Shape.from_facts!/1) |> List.to_tuple()
  @states @facts["runs"]
          |> Enum.reduce({0, []}, fn [start, count, value], {index, values} ->
            unless start == index and is_integer(count) and count > 0 and
                     start + count <= @facts["state_count"] and
                     ((is_integer(value) and value in 0..(tuple_size(@shapes) - 1)) or
                        (is_binary(value) and String.starts_with?(value, "minecraft:"))),
                   do: raise("Invalid collision catalog run")

            {index + count, [List.duplicate(value, count) | values]}
          end)
          |> then(fn {count, reversed} ->
            unless count == @facts["state_count"], do: raise("Incomplete collision catalog")
            reversed |> Enum.reverse() |> List.flatten() |> List.to_tuple()
          end)

  @position_shapes @facts["position_shapes"]
                   |> Enum.map(&Valimc.Physics.Shape.from_facts!/1)
                   |> List.to_tuple()
  @position_states Map.new(@facts["position_states"], fn [id, shape, limit] ->
                     unless is_integer(id) and id in 0..(tuple_size(@states) - 1) and
                              elem(@states, id) in [
                                "minecraft:bamboo",
                                "minecraft:pointed_dripstone",
                                "minecraft:sulfur_spike"
                              ] and is_integer(shape) and
                              shape in 0..(tuple_size(@position_shapes) - 1) and
                              is_number(limit) and limit > 0 and limit <= 0.25,
                            do: raise("Invalid position-dependent shape")

                     {id, {shape, limit}}
                   end)
  unless map_size(@position_states) == 52, do: raise("Incomplete position-dependent catalog")

  @scaffolding @facts["scaffolding"]
  @scaffolding_stable Valimc.Physics.Shape.from_facts!(@scaffolding["stable"])
  @scaffolding_bottom Valimc.Physics.Shape.from_facts!(@scaffolding["unstable_bottom"])
  @below_height @scaffolding["below_height"]
  unless is_number(@below_height) and abs(@below_height) <= 16.0,
    do: raise("Invalid scaffolding query height")

  @scaffolding_states Map.new(@scaffolding["states"], fn [id, distance, bottom] ->
                        unless is_integer(id) and id in 0..(tuple_size(@states) - 1) and
                                 elem(@states, id) == "minecraft:scaffolding" and
                                 is_integer(distance) and distance in 0..7 and is_boolean(bottom),
                               do: raise("Invalid scaffolding state facts")

                        {id, {distance, bottom}}
                      end)
  unless length(@scaffolding["states"]) == 32 and map_size(@scaffolding_states) == 32,
    do: raise("Incomplete scaffolding catalog")

  @powder_snow @facts["powder_snow"]
  @powder_falling Valimc.Physics.Shape.from_facts!(@powder_snow["falling"])
  @powder_full Valimc.Physics.Shape.from_facts!(@powder_snow["full"])
  @powder_state @powder_snow["state"]
  unless is_integer(@powder_state) and @powder_state in 0..(tuple_size(@states) - 1) and
           elem(@states, @powder_state) == "minecraft:powder_snow",
         do: raise("Invalid powder snow state facts")

  @shulker @facts["shulker_box"]
  @shulker_full Valimc.Physics.Shape.from_facts!(@shulker["full"])
  @shulker_states Map.new(@shulker["states"], fn [id, direction] ->
                    unless is_integer(id) and id in 0..(tuple_size(@states) - 1) and
                             is_binary(elem(@states, id)) and
                             String.ends_with?(elem(@states, id), "shulker_box") and
                             direction in ["down", "up", "north", "south", "west", "east"],
                           do: raise("Invalid shulker state facts")

                    {id, direction}
                  end)
  unless length(@shulker["states"]) == 102 and map_size(@shulker_states) == 102,
    do: raise("Incomplete shulker catalog")

  @moving_states @facts["piston"]["moving"]
  unless is_list(@moving_states) and length(@moving_states) == 12 and
           MapSet.size(MapSet.new(@moving_states)) == 12 and
           Enum.all?(@moving_states, fn id ->
             is_integer(id) and id in 0..(tuple_size(@states) - 1) and
               elem(@states, id) == "minecraft:moving_piston"
           end),
         do: raise("Incomplete moving-piston catalog")

  def state_count, do: tuple_size(@states)
  def shape_count, do: tuple_size(@shapes)
  def grids, do: @shapes
  def entries, do: @states

  def fetch(id) when is_integer(id) and id >= 0 and id < tuple_size(@states) do
    case elem(@states, id) do
      index when is_integer(index) -> {:ok, elem(@shapes, index)}
      name -> {:context_required, name}
    end
  end

  def fetch(_), do: {:error, :unknown_block_state}

  # Shapes are block-local, including native position offsets. Translate to world
  # coordinates only after the caller has obtained authoritative block state.
  def fetch(id, position) do
    if Valimc.Physics.BlockOffset.valid_position?(position) do
      case {fetch(id), Map.get(@position_states, id)} do
        {{:context_required, _}, {index, limit}} ->
          offset = Valimc.Physics.BlockOffset.horizontal(position, limit)
          {:ok, Valimc.Physics.Shape.move(elem(@position_shapes, index), offset)}

        {result, _} ->
          result
      end
    else
      {:error, :invalid_position}
    end
  end

  def fetch(id, position, context) do
    if Valimc.Physics.CollisionContext.valid?(context) do
      case fetch(id, position) do
        {:context_required, "minecraft:scaffolding"} ->
          {:ok, scaffolding(id, elem(position, 1), context)}

        {:context_required, "minecraft:powder_snow"} ->
          {:ok, powder_snow(elem(position, 1), context)}

        result ->
          result
      end
    else
      {:error, :invalid_context}
    end
  end

  def fetch(id, position, context, block_entity) do
    if Valimc.Physics.BlockEntityContext.valid?(block_entity) do
      case {fetch(id, position, context), Map.get(@shulker_states, id), block_entity.kind} do
        {{:context_required, _}, direction, :shulker} when is_binary(direction) ->
          {:ok, Valimc.Physics.ShulkerShape.shape(direction, block_entity, @shulker_full)}

        {{:context_required, _}, direction, kind}
        when is_binary(direction) and kind in [:absent, :other, :piston] ->
          {:ok, @shulker_full}

        {{:context_required, "minecraft:moving_piston"}, _, :piston} ->
          Valimc.Physics.PistonShape.fetch(block_entity.piston, position, context)

        {{:context_required, "minecraft:moving_piston"}, _, kind}
        when kind in [:absent, :other, :shulker] ->
          {:ok, %Valimc.Physics.Shape{}}

        {result, _, _} ->
          result
      end
    else
      {:error, :invalid_block_entity_context}
    end
  end

  defp powder_snow(y, context) do
    cond do
      context.placement or not context.entity_present ->
        %Valimc.Physics.Shape{}

      context.fall_distance > 2.5 ->
        @powder_falling

      context.falling_block ->
        @powder_full

      context.powder_snow_walkable and not context.descending and
          Valimc.Physics.CollisionContext.above?(context, 1.0, y, false) ->
        @powder_full

      true ->
        %Valimc.Physics.Shape{}
    end
  end

  defp scaffolding(id, y, context) do
    {distance, bottom} = Map.fetch!(@scaffolding_states, id)

    cond do
      context.placement ->
        %Valimc.Physics.Shape{}

      Valimc.Physics.CollisionContext.above?(context, 1.0, y, true) and not context.descending ->
        @scaffolding_stable

      distance != 0 and bottom and
          Valimc.Physics.CollisionContext.above?(context, @below_height, y, true) ->
        @scaffolding_bottom

      true ->
        %Valimc.Physics.Shape{}
    end
  end
end
