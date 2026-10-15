defmodule Valimc.PlayerKinetics do
  @moduledoc "Player-owned server velocity, separate from accepted client displacement."
  import Bitwise
  alias Valimc.{PlayerMotion, PlayerMotionQuery}

  alias Valimc.Physics.{
    AirMotion,
    BlockCollisions,
    Box,
    ClimbContact,
    ClimbMotion,
    CollisionContext,
    CollisionResponse,
    FluidContact,
    FluidControls,
    FluidCurrents,
    FluidMotion,
    MotionBlocks,
    PlayerPose,
    SwimSteering
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
    sprint = (player.input.shared_flags &&& 8) != 0

    {motion.velocity, motion.physical_ground, motion.on_ground, motion.swimming, sprint,
     player.input.buttons, Valimc.PlayerInput.loaded?(player.input), Map.get(player, :yaw, 0.0),
     if(motion.swimming or sprint, do: Map.get(player, :pitch, 0.0))}
  end

  def apply_result(motion, result) do
    motion = struct!(motion, Map.take(result, [:velocity, :physical_ground, :settled]))

    cond do
      Map.get(result, :water, false) or Map.get(result, :reset_fall, false) ->
        %{motion | fall_distance: 0.0}

      Map.get(result, :lava, false) ->
        %{motion | fall_distance: motion.fall_distance * 0.5}

      true ->
        motion
    end
  end

  def query_box(box, player, jumping \\ false) do
    v = velocity(player)

    if valid_velocity?(v) do
      with {:ok, jump_v} <-
             if(jumping,
               do:
                 jump(v, 1.0, (player.input.shared_flags &&& 8) != 0, Map.get(player, :yaw, 0.0)),
               else: {:ok, v}
             ),
           true <- valid_velocity?(jump_v),
           {vx, vy, vz} = v,
           escape = {2 * vx, vy + 0.6000000238418579, 2 * vz},
           true <- Enum.all?(Tuple.to_list(escape), &(abs(&1) <= 64)) do
        # An escape checks a second, damped horizontal displacement. Currents
        # contribute at most .021 per axis, vertical input .04; .125 encloses
        # both displacements. Potential swimmers also enclose the pre-travel
        # pitch blend (at most .085 beyond the original velocity hull).
        # Frame admission is bounded independently of each
        # individual collision scan; source/worker/batch limits still apply.
        {:ok,
         box
         |> Box.expand_towards(v)
         |> union(Box.expand_towards(box, jump_v))
         |> Box.expand_towards({0.0, 0.6, 0.0})
         |> Box.expand_towards({0.0, -@below, 0.0})
         |> union(Box.expand_towards(box, escape))
         |> inflate(if(swimming_candidate?(player), do: 0.25, else: 0.125))}
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
         {:ok, _} <-
           Valimc.Physics.BlockScan.plan(query, Valimc.Physics.CollisionQuery.frame_cell_limit()),
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
         {:ok, depths} <- FluidContact.sample(frame, box),
         {:ok, velocity} <- packet_jump(player, requested, flags, before, depths),
         {:ok, after_move} <- material(frame, moved_box, moved, context(player, elem(moved, 1))),
         {:ok, after_fluid} <- FluidContact.sample(frame, moved_box),
         {:ok, result} <- response(velocity, requested, actual, after_move, player) do
      {:ok,
       Map.merge(result, %{
         physical_ground: after_move.support != nil,
         settled: false,
         water: after_fluid.water > 0
       })}
    end
  end

  @doc "One bounded player scratch step; it never advances the accepted player position."
  def tick(player, pose, frame) do
    motion = Map.get(player, :motion, %PlayerMotion{})
    player = Map.put_new(player, :motion, motion)
    position = point(player)

    with {:ok, geometry} <- PlayerPose.geometry(pose, position),
         {:ok, before} <- material(frame, geometry.box, position, context(player, player.y)),
         {:ok, currents} <-
           FluidCurrents.sample(frame, geometry.box, motion.velocity, not player.abilities.flying),
         fluid =
           not player.abilities.flying and (currents.depths.water > 0 or currents.depths.lava > 0),
         {:ok, controlled} <- tick_input(player, currents, fluid),
         {:ok, steered} <- steer(player, controlled, frame),
         {:ok, climb} <- prepare_climb(player, steered, frame, fluid) do
      velocity = climb.velocity
      # Native dry climbing clears fall distance before collision contexts are
      # constructed. This is scratch state; only the owner commits on its tick.
      player =
        if climb.reset_fall,
          do: %{player | motion: %{player.motion | fall_distance: 0.0}},
          else: player

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
             travel(
               player,
               velocity,
               result,
               actual,
               geometry.box,
               frame,
               before,
               currents.depths,
               fluid
             ),
           true <- valid_velocity?(next) do
        grounded = elem(actual, 1) != elem(velocity, 1) and elem(velocity, 1) < 0

        {:ok,
         %{
           velocity: next,
           physical_ground: grounded,
           settled:
             not fluid and next == motion.velocity and (grounded or player.abilities.flying),
           bounced: result.bounced,
           supported: true,
           water: currents.depths.water > 0,
           lava: currents.depths.lava > 0,
           reset_fall: climb.reset_fall
         }}
      else
        false -> {:error, :kinetic_velocity_limit}
        error -> error
      end
    end
  end

  defp prepare_climb(_, velocity, _, true),
    do: {:ok, %{velocity: velocity, reset_fall: false}}

  defp prepare_climb(player, velocity, frame, false) do
    with {:ok, contact} <- climb_contact(frame, player, point(player)),
         do:
           ClimbMotion.prepare(
             velocity,
             contact.climbing,
             (player.input.shared_flags &&& 2) != 0,
             contact.scaffolding
           )
  end

  defp climb_contact(frame, player, {x, y, z}) do
    # Fall-flying ownership is a later slice; current sessions cannot glide.
    ClimbContact.sample(
      frame,
      {floor(x), floor(y), floor(z)},
      player.abilities.flying,
      player.game_mode.current == :spectator,
      false
    )
  end

  defp climbable?(_, _, _, false), do: {:ok, false}

  defp climbable?(frame, player, position, true) do
    with {:ok, contact} <- climb_contact(frame, player, position), do: {:ok, contact.climbing}
  end

  defp swimming_candidate?(player),
    do:
      Map.get(player, :motion, %PlayerMotion{}).swimming or (player.input.shared_flags &&& 8) != 0

  defp steer(player, velocity, frame) do
    if player.motion.swimming and not player.abilities.flying and
         player.game_mode.current != :spectator do
      jump =
        Valimc.PlayerInput.loaded?(player.input) and
          Valimc.PlayerInput.pressed?(player.input, :jump)

      with {:ok, look} <- SwimSteering.look_y(Map.get(player, :pitch, 0.0)),
           {:ok, above} <- steering_above(frame, player, look, jump),
           do: SwimSteering.step(velocity, look, true, jump, above, false)
    else
      {:ok, velocity}
    end
  end

  defp steering_above(_, _, look, jump) when look <= 0 or jump, do: {:ok, false}

  defp steering_above(frame, player, _, _) do
    with {:ok, fluid} <-
           FluidContact.fluid_at(
             frame,
             {floor(player.x), floor(player.y + 1.0 - 0.1), floor(player.z)}
           ),
         do: {:ok, fluid.kind != :empty}
  end

  defp tick_input(_, currents, false), do: {:ok, normalize(currents.velocity)}

  defp tick_input(player, currents, true) do
    with {:ok, result} <-
           FluidControls.step(currents.velocity, %FluidControls{
             water: currents.depths.water,
             lava: currents.depths.lava,
             on_ground: player.motion.physical_ground,
             jump:
               Valimc.PlayerInput.loaded?(player.input) and
                 Valimc.PlayerInput.pressed?(player.input, :jump),
             shift:
               Valimc.PlayerInput.loaded?(player.input) and
                 Valimc.PlayerInput.pressed?(player.input, :shift)
           }),
         do: {:ok, result.velocity}
  end

  defp travel(player, velocity, result, actual, _box, frame, before, _depths, false) do
    horizontal = horizontal_collision?(velocity, actual)

    jump =
      Valimc.PlayerInput.loaded?(player.input) and
        Valimc.PlayerInput.pressed?(player.input, :jump)

    with {:ok, climbing} <-
           climbable?(frame, player, add(point(player), actual), horizontal or jump),
         {:ok, resolved} <- ClimbMotion.finish(result.velocity, climbing, horizontal, jump) do
      air(
        resolved,
        elem(velocity, 1),
        %AirMotion{on_ground: player.motion.physical_ground, friction: before.below.friction},
        player.abilities.flying
      )
    end
  end

  defp travel(player, velocity, result, actual, box, frame, _before, depths, true) do
    {_, y, _} = point(player)

    horizontal = horizontal_collision?(velocity, actual)

    with {:ok, climbing} <-
           climbable?(frame, player, add(point(player), actual), horizontal and depths.water > 0),
         {:ok, step} <-
           FluidMotion.prepare(result.velocity, %FluidMotion{
             kind: if(depths.water > 0, do: :water, else: :lava),
             falling: elem(velocity, 1) <= 0,
             on_ground: player.motion.physical_ground,
             sprint: (player.input.shared_flags &&& 8) != 0,
             horizontal_collision: horizontal,
             climbable: climbing,
             shallow: depths.lava <= 0.4,
             old_y: y,
             new_y: y + elem(actual, 1)
           }),
         {:ok, free} <-
           escape_free(
             step.escape_query,
             Box.move(box, actual),
             frame,
             player,
             y + elem(actual, 1)
           ),
         do: {:ok, FluidMotion.finish(step, free)}
  end

  defp horizontal_collision?(velocity, actual),
    do:
      abs(elem(velocity, 0) - elem(actual, 0)) >= @epsilon or
        abs(elem(velocity, 2) - elem(actual, 2)) >= @epsilon

  defp escape_free(nil, _, _, _, _), do: {:ok, false}

  defp escape_free(offset, box, frame, player, bottom),
    do:
      PlayerMotionQuery.free_box?(
        Box.move(box, offset),
        frame,
        context(player, bottom),
        point(player)
      )

  defp inflate({a, b, c, d, e, f}, margin),
    do: Box.new({a - margin, b - margin, c - margin, d + margin, e + margin, f + margin})

  def normalize({x, y, z}) do
    {x, z} = if x * x + z * z < 9.0e-6, do: {0.0, 0.0}, else: {x, z}
    {x + 0.0, if(abs(y) < 0.003, do: 0.0, else: y) + 0.0, z + 0.0}
  end

  defp packet_jump(player, {_, dy, _}, flags, material, depths) do
    motion = Map.get(player, :motion, %PlayerMotion{})

    if jumping?(player, {0.0, dy, 0.0}, flags) do
      factor =
        if material.feet.jump_factor == 1.0,
          do: material.below.jump_factor,
          else: material.feet.jump_factor

      with {:ok, control} <-
             FluidControls.step(motion.velocity, %FluidControls{
               water: depths.water,
               lava: depths.lava,
               on_ground: true,
               jump: true,
               flying: player.abilities.flying
             }) do
        if control.ground_jump,
          do:
            jump(
              motion.velocity,
              factor,
              (player.input.shared_flags &&& 8) != 0,
              Map.get(player, :yaw, 0.0)
            ),
          else: {:ok, motion.velocity}
      end
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
