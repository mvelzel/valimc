defmodule Valimc.Physics.BlockContacts do
  @moduledoc "Ordered support, immediate damage and deferred fire/fluid plans from fenced accepted paths."
  alias Valimc.Physics.{
    BlockCollisions.Frame,
    BlockHazards,
    BlockShapes,
    BodyPaths,
    Box,
    CollisionContext,
    FluidBlocks,
    FluidContact,
    InsideBlocks,
    PlayerPose,
    Shape,
    StuckBlocks,
    StuckMotion
  }

  def sample_paths(
        %Frame{states: states} = frame,
        paths,
        context,
        %{
          pose: _,
          feet: _,
          flying: _,
          spectator: _,
          weaving: _,
          grounded: _,
          careful: _,
          known_movement: _,
          support_state: _
        } = facts
      )
      when is_map(states) and map_size(states) <= 2048 and is_list(paths) and length(paths) <= 101 do
    if CollisionContext.valid?(context) and context.entity_present and
         Enum.all?(
           [facts.flying, facts.spectator, facts.weaving, facts.grounded, facts.careful],
           &is_boolean/1
         ) do
      if facts.spectator or paths == [] do
        {:ok, %{operations: [], active: false}}
      else
        with {:ok, _} <- PlayerPose.geometry(facts.pose, facts.feet),
             {:ok, feet_state} <- at(frame, floor_point(facts.feet)),
             {:ok, feet_kind} <- StuckBlocks.fetch(feet_state),
             {:ok, support} <- request(facts.support_state, facts),
             initial = %{
               context: context,
               seen: MapSet.new(),
               step: nil,
               steps: [],
               current: [],
               immediate:
                 if(facts.grounded and match?({:hot_floor, _}, support),
                   do: [damage(support)],
                   else: []
                 ),
               active: facts.grounded and match?({:hot_floor, _}, support)
             },
             {:ok, acc} <-
               BodyPaths.reduce(paths, facts.pose, initial, fn acc, pos, step, body, delta ->
                 visit(frame, pos, step, body, delta, facts, feet_kind, acc)
               end),
             {:ok, operations} <- Valimc.PlayerFireContacts.plan(finish(acc)) do
          {:ok, %{operations: Enum.reverse(acc.immediate, operations), active: acc.active}}
        end
      end
    else
      {:error, :invalid_fire_context}
    end
  end

  def sample_paths(_, _, _, _), do: {:error, :invalid_fire_frame}

  defp visit(frame, pos, step, body, delta, facts, feet, acc) do
    if MapSet.member?(acc.seen, pos) do
      {:ok, acc}
    else
      with {:ok, state} <- at(frame, pos),
           {:ok, {kind, shape}} <- InsideBlocks.fetch(state) do
        if kind == :air do
          {:ok, acc}
        else
          with {:ok, block_hit} <- hit?(shape, state, pos, body, delta, acc.context),
               {:ok, fluid} <- fluid_hit(frame, state, pos, body, delta),
               {:ok, slow_kind} <- StuckBlocks.fetch(state),
               {:ok, request} <- request(state, facts) do
            if block_hit or fluid != :empty do
              acc = advance(acc, step)

              contacts =
                if block_hit and kind in [:fire, :soul_fire, :powder_snow], do: [kind], else: []

              contacts = if fluid != :empty, do: contacts ++ [fluid], else: contacts

              immediate =
                if block_hit and request != nil and not match?({:hot_floor, _}, request),
                  do: [damage(request) | acc.immediate],
                  else: acc.immediate

              acc = %{
                acc
                | seen: MapSet.put(acc.seen, pos),
                  current: Enum.reverse(contacts, acc.current),
                  immediate: immediate,
                  active: acc.active or kind in [:fire, :soul_fire] or immediate != []
              }

              # Native immediate slowing callbacks can reset fall distance before
              # a later powder-snow shape; deferred fire callbacks cannot.
              {:ok, slow} =
                StuckMotion.player_contact(
                  if(block_hit, do: slow_kind, else: :none),
                  facts.weaving,
                  feet == :powder_snow,
                  false
                )

              context =
                if slow.reset_fall and not facts.flying,
                  do: %{acc.context | fall_distance: 0.0},
                  else: acc.context

              {:ok, %{acc | context: context}}
            else
              {:ok, acc}
            end
          end
        end
      end
    end
  end

  defp request(state, facts),
    do: BlockHazards.request(state, facts.careful, true, facts.known_movement, {0.0, 0.0, 0.0})

  defp damage({source, amount}), do: {:damage, source, amount}

  defp hit?(:full, _, _, _, _, _), do: {:ok, true}

  defp hit?(:powder_snow, state, pos, body, delta, context) do
    with {:ok, shape} <- BlockShapes.fetch(state, pos, context) do
      if Shape.empty?(shape) or shape.full_block,
        do: {:ok, true},
        else: {:ok, Box.collided_along?(body, delta, Enum.map(shape.boxes, &Box.move(&1, pos)))}
    end
  end

  defp hit?(boxes, _, pos, body, delta, _) when is_list(boxes),
    do: {:ok, Box.collided_along?(body, delta, Enum.map(boxes, &Box.move(&1, pos)))}

  defp fluid_hit(frame, state, {x, y, z}, body, delta) do
    with {:ok, fluid} <- FluidBlocks.fetch(state) do
      if fluid.kind == :empty do
        {:ok, :empty}
      else
        with {:ok, above} <- FluidContact.fluid_at(frame, {x, y + 1, z}) do
          height = if above.kind == fluid.kind, do: 1.0, else: fluid.height
          box = {x * 1.0, y * 1.0, z * 1.0, x + 1.0, y + height, z + 1.0}
          {:ok, if(Box.collided_along?(body, delta, [box]), do: fluid.kind, else: :empty)}
        end
      end
    end
  end

  defp advance(%{step: step} = acc, step), do: acc
  defp advance(%{step: nil} = acc, step), do: %{acc | step: step}

  defp advance(acc, step),
    do: %{acc | step: step, steps: [Enum.reverse(acc.current) | acc.steps], current: []}

  defp finish(%{step: nil}), do: []
  defp finish(acc), do: Enum.reverse([Enum.reverse(acc.current) | acc.steps])
  defp floor_point({x, y, z}), do: {floor(x), floor(y), floor(z)}

  defp at(%Frame{states: states}, pos) do
    case Map.fetch(states, pos) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :incomplete_fire_frame}
    end
  end
end
