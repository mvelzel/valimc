defmodule Valimc.PlayerMotionQuery do
  @moduledoc """
  One move packet's validation and observations, run synchronously by the
  player's connection over published snapshots (VMC-077l): the collision
  with step-up, vanilla's "moved wrongly" and new-collision rules, the pose,
  fluids, powder snow, landing and kinetics. Only the connection applies it.
  """
  import Bitwise

  alias Valimc.Physics.{
    Box,
    CollisionContext,
    ClimbContact,
    Kernel,
    MovementFood,
    MovementValidation,
    PlayerPose,
    PoseFit
  }

  alias Valimc.World.View

  @support 0.001

  @doc "Validate a move of `player` to `target` (`%{x, y, z}`) with packet `flags`."
  def run(player, target, flags \\ 0) do
    with {:ok, query} <- query_box(player, target, flags) do
      if Kernel.bounded?(query),
        do: resolve_frame(player, target, flags, View.load(View.new(), query)),
        else: {:error, :movement_query_limit}
    end
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
      entities: [],
      border: Valimc.World.Clock.border_snapshot(),
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
         target_box = Box.move(moved_box, subtract(destination, moved)),
         {:ok, wrongly} <-
           MovementValidation.wrongly?(destination, moved, player.game_mode.current, false, false),
         {:ok, old_colliding} <-
           Kernel.colliding?(blocks, box, context(player, elem(moved, 1)), extra(), moved),
         {:ok, new_collision} <-
           Kernel.new_collision?(blocks, box, target_box, context, extra()),
         {:ok, rejected} <-
           MovementValidation.collision_rejected?(
             intent.spectator,
             wrongly,
             not old_colliding,
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
         {:ok, powder} <- Valimc.Living.Freezing.sample(blocks, after_move.geometry.box),
         {:ok, air} <- Valimc.Living.Air.contact(blocks, after_move.geometry),
         {:ok, packet} <- Valimc.PlayerKinetics.packet(player, target, actual, flags, box, blocks),
         {:ok, landing} <- Valimc.PlayerLanding.sample(player, target, flags, box, blocks),
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
         {:ok, tick} <- Valimc.PlayerKinetics.tick(candidate, after_move.pose, blocks),
         {:ok, rain} <- Valimc.PlayerRainQuery.sample(destination, after_move.geometry, blocks),
         {:ok, exhaustion} <-
           food_requests(player, candidate, requested, flags, air, tick, blocks) do
      {:ok,
       %{
         accepted: not rejected,
         pose: after_move.pose,
         swimming: swimming,
         moved: moved,
         powder_snow: powder,
         submerged: air.submerged,
         eye_water: air.water,
         exhaustion: exhaustion,
         kinetics: %{packet: packet, tick: Map.put(tick, :rain, rain)},
         landing: landing,
         sources: Valimc.World.View.owners(blocks)
       }}
    end
  end

  defp food_requests(%{abilities: %{invulnerable: true}}, _, _, _, _, _, _),
    do: {:ok, %{jump: 0.0, travel: 0.0}}

  defp food_requests(player, candidate, movement, flags, air, tick, blocks) do
    sprinting = (player.input.shared_flags &&& 8) != 0
    grounded = (flags &&& 1) != 0
    fluid = candidate.motion.swimming or air.water or tick.water

    climb =
      if sprinting and grounded and not fluid do
        ClimbContact.sample(
          blocks,
          {floor(candidate.x), floor(candidate.y), floor(candidate.z)},
          candidate.abilities.flying,
          candidate.game_mode.current == :spectator,
          false
        )
      else
        {:ok, %{climbing: false}}
      end

    with {:ok, contact} <- climb do
      travel =
        MovementFood.amount(movement, %{
          passenger: false,
          swimming: candidate.motion.swimming,
          underwater: air.water,
          water: tick.water,
          climbing: contact.climbing,
          grounded: grounded,
          sprinting: sprinting
        })

      jump =
        if Valimc.PlayerKinetics.jumping?(player, movement, flags),
          do: MovementFood.jump(sprinting),
          else: 0.0

      {:ok, %{jump: jump, travel: travel}}
    end
  end

  @doc false
  def displacement(_, requested, _, _, _, true), do: {:ok, requested}

  def displacement(box, requested, _position, blocks, context, false) do
    with {:ok, moved} <- Kernel.move(blocks, box, requested, context, extra(), 0.6, @support),
         do: {:ok, moved.actual}
  end

  @doc false
  def support_free?(box, frame, context, position) do
    with {:ok, colliding} <- Kernel.colliding?(frame, box, context, extra(), position),
         do: {:ok, not colliding}
  end

  @doc false
  def free_box?(box, frame, context, position) do
    with {:ok, false} <- Kernel.colliding?(frame, box, context, extra(), position),
         {:ok, fluid} <- Valimc.Physics.FluidContact.any_liquid?(frame, box) do
      {:ok, not fluid}
    else
      {:ok, true} -> {:ok, false}
      error -> error
    end
  end

  defp extra, do: Kernel.extra([], Valimc.World.Clock.border_snapshot())

  defp context(player, bottom), do: CollisionContext.player(player, bottom)

  defp point(p), do: {p.x, p.y, p.z}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
end
