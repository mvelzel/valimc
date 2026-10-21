defmodule Valimc.Physics.BlockShapes do
  @moduledoc "Collision shapes of block states from the block fact table; dynamic contexts are explicit unresolved lookups."
  alias Valimc.Physics.{BlockOffset, Shape}
  alias Valimc.Registry.{BlockFacts, Blocks}

  @count BlockFacts.count()
  @scaffolding_stable BlockFacts.contextual_shape(:scaffolding_stable)
  @scaffolding_bottom BlockFacts.contextual_shape(:scaffolding_unstable_bottom)
  @below_height BlockFacts.contextual_shape(:scaffolding_below_height)
  @powder_falling BlockFacts.contextual_shape(:powder_snow_falling)
  @full BlockFacts.contextual_shape(:full)

  # Scaffolding distance and bottom, and shulker box facing, are block properties.
  @scaffolding_states Map.new(Blocks.states("scaffolding"), fn id ->
                        properties = Map.new(Blocks.properties(id))

                        {id,
                         {String.to_integer(properties["distance"]),
                          properties["bottom"] == "true"}}
                      end)
  @shulker_states for block <- 0..(Blocks.block_count() - 1),
                      name = Blocks.name(block),
                      String.ends_with?(name, "shulker_box"),
                      id <- Blocks.states(name),
                      into: %{},
                      do: {id, Map.new(Blocks.properties(id))["facing"]}
  unless map_size(@scaffolding_states) == 32 and map_size(@shulker_states) == 102,
    do: raise("Scaffolding or shulker box states changed")

  def state_count, do: @count

  def fetch(id) when is_integer(id) and id >= 0 and id < @count do
    case BlockFacts.shape(id) do
      %Shape{} = shape -> {:ok, shape}
      {:context, name, _} -> {:context_required, name}
    end
  end

  def fetch(_), do: {:error, :unknown_block_state}

  # Shapes are block-local, including native position offsets. Translate to world
  # coordinates only after the caller has obtained authoritative block state.
  def fetch(id, position) do
    if BlockOffset.valid_position?(position) do
      with {:context_required, _} = result <- fetch(id) do
        case BlockFacts.shape(id) do
          {:context, _, {shape, limit}} ->
            {:ok, Shape.move(shape, BlockOffset.horizontal(position, limit))}

          _ ->
            result
        end
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
          {:ok, Valimc.Physics.ShulkerShape.shape(direction, block_entity, @full)}

        {{:context_required, _}, direction, kind}
        when is_binary(direction) and kind in [:absent, :other, :piston] ->
          {:ok, @full}

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
        @full

      context.powder_snow_walkable and not context.descending and
          Valimc.Physics.CollisionContext.above?(context, 1.0, y, false) ->
        @full

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
