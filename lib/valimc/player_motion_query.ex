defmodule Valimc.PlayerMotionQuery do
  @moduledoc "Bounded sampled movement geometry; only the player owner accepts the result."
  import Bitwise

  alias Valimc.Physics.{
    BlockCollisions,
    BorderSnapshot,
    Box,
    Collision,
    CollisionContext,
    CollisionQuery,
    MovementValidation,
    PlayerPose,
    PoseFit,
    StepMovement
  }

  @epsilon 9.999999747378752e-6
  @support 0.001

  def start(player, target) do
    with {:ok, start} <- prepare(player, target), do: start.()
  end

  def prepare(player, target) do
    position = point(player)
    requested = subtract(point(target), position)
    context = context(player, player.y)

    with true <- Enum.all?(Tuple.to_list(requested), &(abs(&1) <= 64)),
         {:ok, standing} <- PlayerPose.geometry(:standing, position),
         {:ok, _} <- PlayerPose.geometry(:standing, point(target)) do
      query =
        standing.box
        |> Box.expand_towards(requested)
        |> Box.expand_towards({0, 0.6, 0})
        |> Box.expand_towards({0, -@support, 0})

      CollisionQuery.prepare_movement_frame(query, context, &resolve(player, target, &1))
    else
      false -> {:error, :movement_query_limit}
      error -> error
    end
  end

  defp resolve(player, target, blocks) do
    with {:ok, frame} <- BlockCollisions.prepare(blocks), do: resolve_frame(player, target, frame)
  end

  defp resolve_frame(player, target, blocks) do
    position = point(player)
    destination = point(target)
    requested = subtract(destination, position)
    context = context(player, player.y)

    intent = %PlayerPose{
      shift: (player.input.shared_flags &&& 2) != 0,
      flying: player.abilities.flying,
      spectator: player.game_mode.current == :spectator
    }

    observations = %{
      blocks: blocks,
      block_entities: %{},
      entities: [],
      border: %BorderSnapshot{},
      subject: player.entity_id
    }

    with {:ok, before} <- PoseFit.select(player.pose, intent, position, context, observations),
         box = before.geometry.box,
         {:ok, actual} <-
           displacement(box, requested, position, blocks, context, intent.spectator),
         moved = add(position, actual),
         moved_box = Box.move(box, actual),
         # Match native translation order, including cancellation at remote coordinates.
         target_box = moved_box |> Box.move(subtract(destination, moved)) |> deflate(),
         {:ok, wrongly} <-
           MovementValidation.wrongly?(destination, moved, player.game_mode.current, false, false),
         {:ok, old_shapes} <- shapes(box, blocks, context(player, elem(moved, 1)), moved),
         {:ok, new_shapes} <- shapes(target_box, blocks, context, position),
         {:ok, new_collision} <- MovementValidation.new_collision?(box, new_shapes),
         {:ok, rejected} <-
           MovementValidation.collision_rejected?(
             intent.spectator,
             wrongly,
             old_shapes == [],
             new_collision
           ),
         {:ok, after_move} <-
           PoseFit.select(
             before.pose,
             intent,
             destination,
             context(player, target.y),
             observations
           ) do
      {:ok,
       %{
         accepted: not rejected,
         pose: after_move.pose,
         moved: moved,
         fences: blocks.fences
       }}
    end
  end

  defp displacement(_, requested, _, _, _, true), do: {:ok, requested}

  defp displacement(box, requested, position, blocks, context, false) do
    sweep = Box.expand_towards(box, requested)
    support = Box.expand_towards(box, {0, -@support, 0})

    with {:ok, initial} <- shapes(sweep, blocks, context, position),
         {:ok, below} <- shapes(support, blocks, context, position) do
      grounded = elem(Collision.move(box, below, {0, -@support, 0}), 1) != -@support

      case StepMovement.prepare(box, initial, requested, 0.6, grounded) do
        {:resolved, actual} ->
          {:ok, actual}

        {:step, plan} ->
          with {:ok, step_shapes} <- shapes(plan.query, blocks, context, position),
               do: StepMovement.finish(plan, step_shapes)

        error ->
          error
      end
    end
  end

  defp shapes(box, blocks, context, {x, _, z}) do
    with {:ok, result} <- BlockCollisions.collect_frame(box, blocks, context),
         {:ok, border} <- BorderSnapshot.colliders(%BorderSnapshot{}, {x, z}, box) do
      {:ok, Enum.map(result.colliders, & &1.shape) ++ border}
    end
  end

  defp context(player, bottom),
    do:
      CollisionContext.entity(bottom, (player.input.shared_flags &&& 2) != 0)
      |> CollisionContext.with_entity(Valimc.PlayerMotion.distance(player), false, false)

  defp deflate({a, b, c, d, e, f}),
    do:
      Box.new(
        {a + @epsilon, b + @epsilon, c + @epsilon, d - @epsilon, e - @epsilon, f - @epsilon}
      )

  defp point(p), do: {p.x, p.y, p.z}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
end
