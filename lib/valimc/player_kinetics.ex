defmodule Valimc.PlayerKinetics do
  @moduledoc "Player-owned server velocity, separate from accepted client displacement."
  import Bitwise
  alias Valimc.{PlayerMotion, PlayerMotionQuery}

  alias Valimc.Physics.{
    AirMotion,
    BlockCollisions,
    Box,
    CollisionContext,
    CollisionResponse,
    MotionBlocks,
    PlayerPose
  }

  @sin_scale 10_430.378350470453
  @epsilon 9.999999747378752e-6
  @below 0.5000010132789612

  def velocity(player), do: Map.get(player, :motion, %Valimc.PlayerMotion{}).velocity

  def valid_velocity?({x, y, z}),
    do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))

  def valid_velocity?(_), do: false

  @doc "Native saved Motion load bound, independent for each component."
  def restore_velocity(velocity) do
    if valid_velocity?(velocity) do
      {:ok,
       velocity
       |> Tuple.to_list()
       |> Enum.map(&if(abs(&1) > 10.0, do: 0.0, else: &1 * 1.0))
       |> List.to_tuple()}
    else
      {:error, :invalid_velocity}
    end
  end

  def signature(player) do
    motion = Map.get(player, :motion, %PlayerMotion{})

    {motion.velocity, motion.physical_ground, motion.on_ground,
     (player.input.shared_flags &&& 8) != 0, Map.get(player, :yaw, 0.0)}
  end

  def apply_result(motion, result),
    do: struct!(motion, Map.take(result, [:velocity, :physical_ground, :settled]))

  def query_box(box, player, jumping \\ false) do
    v = velocity(player)

    if valid_velocity?(v) do
      with {:ok, jump_v} <-
             if(jumping,
               do:
                 jump(v, 1.0, (player.input.shared_flags &&& 8) != 0, Map.get(player, :yaw, 0.0)),
               else: {:ok, v}
             ),
           true <- valid_velocity?(jump_v) do
        {:ok,
         box
         |> Box.expand_towards(v)
         |> union(Box.expand_towards(box, jump_v))
         |> Box.expand_towards({0.0, 0.6, 0.0})
         |> Box.expand_towards({0.0, -@below, 0.0})}
      else
        _ -> {:error, :kinetic_query_limit}
      end
    else
      {:error, :kinetic_query_limit}
    end
  end

  def admissible?(player, velocity) do
    motion = %{player.motion | velocity: velocity}

    with {:ok, geometry} <- PlayerPose.geometry(:standing, point(player)),
         {:ok, query} <- query_box(geometry.box, %{player | motion: motion}),
         {:ok, _} <- Valimc.Physics.BlockScan.plan(query),
         do: true,
         else: (_ -> false)
  end

  def jumping?(player, {_, dy, _}, flags),
    do: Map.get(player, :motion, %PlayerMotion{}).on_ground and (flags &&& 1) == 0 and dy > 0

  def union({a, b, c, d, e, f}, {g, h, i, j, k, l}),
    do: Box.new({min(a, g), min(b, h), min(c, i), max(d, j), max(e, k), max(f, l)})

  @doc "Apply accepted packet collision/jump math before a possible logical server tick."
  def packet(player, destination, actual, flags, box, frame) do
    requested = subtract(point(destination), point(player))
    moved = add(point(player), actual)
    moved_box = Box.move(box, actual)

    with {:ok, before} <- material(frame, box, point(player), context(player, player.y)),
         {:ok, velocity} <- packet_jump(player, requested, flags, before),
         {:ok, after_move} <- material(frame, moved_box, moved, context(player, elem(moved, 1))),
         {:ok, result} <- response(velocity, requested, actual, after_move, player) do
      {:ok,
       Map.merge(result, %{
         physical_ground: after_move.support != nil,
         settled: false
       })}
    end
  end

  @doc "One dry-player scratch step. It never advances the accepted player position."
  def tick(player, pose, frame) do
    motion = Map.get(player, :motion, %PlayerMotion{})
    position = point(player)

    with {:ok, geometry} <- PlayerPose.geometry(pose, position),
         {:ok, before} <- material(frame, geometry.box, position, context(player, player.y)),
         {:ok, dry} <- dry_body(frame, geometry.box) do
      if dry do
        velocity = normalize(motion.velocity)
        spectator = player.game_mode.current == :spectator

        with {:ok, actual} <-
               PlayerMotionQuery.displacement(
                 geometry.box,
                 velocity,
                 position,
                 frame,
                 context(player, player.y),
                 spectator
               ),
             moved = add(position, actual),
             {:ok, after_move} <-
               material(
                 frame,
                 Box.move(geometry.box, actual),
                 moved,
                 context(player, elem(moved, 1))
               ),
             {:ok, result} <- response(velocity, velocity, actual, after_move, player),
             {:ok, next} <-
               air(
                 result.velocity,
                 elem(velocity, 1),
                 %AirMotion{on_ground: motion.physical_ground, friction: before.below.friction},
                 player.abilities.flying
               ),
             true <- valid_velocity?(next) do
          grounded = elem(actual, 1) != elem(velocity, 1) and elem(velocity, 1) < 0

          {:ok,
           %{
             velocity: next,
             physical_ground: grounded,
             settled: next == motion.velocity and (grounded or player.abilities.flying),
             bounced: result.bounced,
             supported: true
           }}
        else
          false -> {:error, :kinetic_velocity_limit}
          error -> error
        end
      else
        # Fluid travel is a separate missing simulation mechanic. Do not
        # manufacture an air step or reject an otherwise valid client move.
        {:ok,
         %{
           velocity: motion.velocity,
           physical_ground: before.support != nil,
           settled: true,
           bounced: false,
           supported: false
         }}
      end
    end
  end

  def normalize({x, y, z}) do
    {x, z} = if x * x + z * z < 9.0e-6, do: {0.0, 0.0}, else: {x, z}
    {x + 0.0, if(abs(y) < 0.003, do: 0.0, else: y) + 0.0, z + 0.0}
  end

  defp packet_jump(player, {_, dy, _}, flags, material) do
    motion = Map.get(player, :motion, %PlayerMotion{})

    if jumping?(player, {0.0, dy, 0.0}, flags) do
      factor =
        if material.feet.jump_factor == 1.0,
          do: material.below.jump_factor,
          else: material.feet.jump_factor

      jump(
        motion.velocity,
        factor,
        (player.input.shared_flags &&& 8) != 0,
        Map.get(player, :yaw, 0.0)
      )
    else
      {:ok, motion.velocity}
    end
  end

  defp response(velocity, requested, actual, material, player) do
    vertical = elem(requested, 1) != elem(actual, 1)

    with {:ok, result} <-
           CollisionResponse.step(velocity, elem(actual, 1), %CollisionResponse{
             x_collision: abs(elem(requested, 0) - elem(actual, 0)) >= @epsilon,
             z_collision: abs(elem(requested, 2) - elem(actual, 2)) >= @epsilon,
             vertical_collision: vertical,
             below: vertical and elem(requested, 1) < 0,
             suppress_bounce: (player.input.shared_flags &&& 2) != 0,
             block_suppresses_bounce: material.below.suppresses_bounce,
             block_bounciness: material.below.bounciness
           }) do
      factor =
        if material.feet.speed_factor == 1.0,
          do: material.below.speed_factor,
          else: material.feet.speed_factor

      {x, y, z} = result.velocity
      {:ok, %{result | velocity: {x * factor, y, z * factor}}}
    end
  end

  @doc false
  def material(frame, {a, b, c, d, _, f}, {x, y, z} = position, ctx) do
    thin = Box.new({a, b - 1.0e-6, c, d, b, f})

    with {:ok, colliders} <- BlockCollisions.collect_frame(thin, frame, ctx) do
      support =
        colliders.colliders
        |> Enum.min_by(
          fn %{position: {px, py, pz}} ->
            dx = px + 0.5 - x
            dy = py + 0.5 - y
            dz = pz + 0.5 - z
            {dx * dx + dy * dy + dz * dz, -py, -pz, -px}
          end,
          fn -> nil end
        )

      below_y = floor(y - @below)

      with {:ok, below_pos} <- below_position(support, below_y, position, frame),
           {:ok, below} <- fact(frame, below_pos),
           {:ok, feet} <- fact(frame, {floor(x), floor(y), floor(z)}) do
        {:ok, %{below: below, feet: feet, support: support, below_position: below_pos}}
      end
    end
  end

  defp below_position(nil, y, {x, _, z}, _), do: {:ok, {floor(x), y, floor(z)}}

  defp below_position(%{position: {x, _, z} = pos}, y, _, frame) do
    with {:ok, f} <- fact(frame, pos), do: {:ok, if(f.support_holds_y, do: pos, else: {x, y, z})}
  end

  defp fact(%BlockCollisions.Frame{states: states}, pos) do
    case Map.fetch(states, pos) do
      {:ok, id} -> MotionBlocks.fetch(id)
      :error -> {:error, :incomplete_kinetic_frame}
    end
  end

  defp dry_body(frame, {a, b, c, d, e, f}) do
    positions =
      for x <- floor(a + @epsilon)..floor(d - @epsilon),
          y <- floor(b + @epsilon)..floor(e - @epsilon),
          z <- floor(c + @epsilon)..floor(f - @epsilon),
          do: {x, y, z}

    Enum.reduce_while(positions, {:ok, true}, fn pos, {:ok, dry} ->
      case fact(frame, pos) do
        {:ok, f} -> {:cont, {:ok, dry and f.fluid_empty}}
        error -> {:halt, error}
      end
    end)
  end

  defp context(player, bottom),
    do:
      CollisionContext.entity(
        bottom,
        (player.input.shared_flags &&& 2) != 0
      )
      |> CollisionContext.with_entity(PlayerMotion.distance(player), false, false)

  defp point(p), do: {p.x, p.y, p.z}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}

  def jump({x, y, z} = velocity, factor, sprint, yaw)
      when is_number(factor) and factor >= 0 and factor <= 4 and is_boolean(sprint) and
             is_number(yaw) and abs(yaw) <= 1_000_000 do
    if valid_velocity?(velocity) do
      power = f32(f32(0.42) * f32(factor))

      cond do
        power <= @epsilon ->
          {:ok, velocity}

        sprint ->
          angle = f32(f32(yaw) * f32(0.017453292))
          sin = trig(trunc(angle * @sin_scale))
          cos = trig(trunc(angle * @sin_scale + 16_384.0))
          {:ok, {x + -sin * 0.2, max(y, power) + 0.0, z + cos * 0.2}}

        true ->
          {:ok, {x * 1.0, max(y, power), z * 1.0}}
      end
    else
      {:error, :invalid_velocity}
    end
  end

  def jump(_, _, _, _), do: {:error, :invalid_velocity}

  def air(resolved, old_y, facts, flying) when is_boolean(flying) do
    with {:ok, {x, y, z}} <- AirMotion.step(resolved, facts),
         do: {:ok, {x, if(flying, do: old_y * 0.6, else: y), z}}
  end

  defp trig(index), do: f32(:math.sin((index &&& 65_535) / @sin_scale))

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
