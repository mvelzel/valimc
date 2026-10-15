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

  def start(player, target, flags \\ 0) do
    with {:ok, start} <- prepare(player, target, flags), do: start.()
  end

  def prepare(player, target, flags \\ 0) do
    with {:ok, query} <- query_box(player, target, flags),
         do:
           CollisionQuery.prepare_movement_frame(
             query,
             context(player, player.y),
             &resolve(player, target, flags, &1)
           )
  end

  @doc false
  def query_box(player, target, flags \\ 0) do
    position = point(player)
    requested = subtract(point(target), position)

    with true <- Enum.all?(Tuple.to_list(requested), &(abs(&1) <= 64)),
         {:ok, step} <-
           Valimc.PlayerKinetics.prepare_move(
             player,
             requested,
             Valimc.PlayerKinetics.velocity(player)
           ),
         {:ok, standing} <- PlayerPose.geometry(:standing, position),
         {:ok, destination} <- PlayerPose.geometry(:standing, point(target)),
         {:ok, kinetic_box} <-
           Valimc.PlayerKinetics.query_box(
             destination.box,
             player,
             Valimc.PlayerKinetics.jumping?(player, requested, flags)
           ) do
      query =
        standing.box
        |> Box.expand_towards(requested)
        |> Valimc.PlayerKinetics.union(Box.expand_towards(standing.box, step.requested))
        |> Box.expand_towards({0, 0.6, 0})
        |> Box.expand_towards({0, -@support, 0})
        |> Valimc.PlayerKinetics.union(kinetic_box)

      {:ok, query}
    else
      false -> {:error, :movement_query_limit}
      error -> error
    end
  end

  defp resolve(player, target, flags, blocks) do
    with {:ok, frame} <- BlockCollisions.prepare(blocks),
         do: resolve_frame(player, target, flags, frame)
  end

  defp resolve_frame(player, target, flags, blocks) do
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

    with {:ok, swimming_before} <-
           Valimc.PlayerSwimming.sample(player, player.pose, position, blocks),
         {:ok, before} <-
           PoseFit.select(
             player.pose,
             %{intent | swimming: swimming_before},
             position,
             context,
             observations
           ),
         box = before.geometry.box,
         {:ok, step} <-
           Valimc.PlayerKinetics.prepare_collision(
             player,
             requested,
             Valimc.PlayerKinetics.velocity(player),
             box,
             blocks,
             Map.get(player, :motion, %Valimc.PlayerMotion{}).on_ground
           ),
         {:ok, actual} <-
           displacement(box, step.requested, position, blocks, context, intent.spectator),
         moved = Valimc.PlayerKinetics.physical_position(player, actual, step.requested),
         moved_box = Box.move(box, subtract(moved, position)),
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
         {:ok, swimming} <-
           Valimc.PlayerSwimming.sample(
             Map.put(player, :motion, %{
               Map.get(player, :motion, %Valimc.PlayerMotion{})
               | swimming: swimming_before
             }),
             before.pose,
             destination,
             blocks
           ),
         {:ok, after_move} <-
           PoseFit.select(
             before.pose,
             %{intent | swimming: swimming},
             destination,
             context(player, target.y),
             observations
           ),
         {:ok, powder} <- Valimc.PlayerEnvironment.sample(blocks, after_move.geometry.box),
         {:ok, packet} <- Valimc.PlayerKinetics.packet(player, target, actual, flags, box, blocks),
         accepted_motion =
           Valimc.PlayerMotion.accept(
             Map.get(player, :motion, %Valimc.PlayerMotion{}),
             requested,
             flags,
             player.abilities.flying
           ),
         candidate =
           player
           |> Map.merge(Map.take(target, [:x, :y, :z]))
           |> Map.put(
             :motion,
             Valimc.PlayerKinetics.apply_result(%{accepted_motion | swimming: swimming}, packet)
           ),
         {:ok, tick} <- Valimc.PlayerKinetics.tick(candidate, after_move.pose, blocks) do
      {:ok,
       %{
         accepted: not rejected,
         pose: after_move.pose,
         swimming: swimming,
         moved: moved,
         powder_snow: powder,
         kinetics: %{packet: packet, tick: tick},
         fences: blocks.fences
       }}
    end
  end

  @doc false
  def displacement(_, requested, _, _, _, true), do: {:ok, requested}

  def displacement(box, requested, position, blocks, context, false) do
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

  @doc false
  def support_free?(box, frame, context, position) do
    with {:ok, shapes} <- shapes(box, frame, context, position), do: {:ok, shapes == []}
  end

  @doc false
  def free_box?(box, frame, context, position) do
    with {:ok, shapes} <- shapes(box, frame, context, position) do
      if shapes == [] do
        with {:ok, fluid} <- Valimc.Physics.FluidContact.any_liquid?(frame, box),
             do: {:ok, not fluid}
      else
        {:ok, false}
      end
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
end
