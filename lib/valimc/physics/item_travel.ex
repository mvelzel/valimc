defmodule Valimc.Physics.ItemTravel do
  @moduledoc "Pure item travel from one fenced block frame; scheduling and commits belong to owners."
  alias Valimc.ItemMotionState

  alias Valimc.Physics.{
    BlockCollisions,
    BorderSnapshot,
    Box,
    Collision,
    CollisionContext,
    CollisionResponse,
    FluidCurrents,
    ItemMotion,
    MotionBlocks
  }

  @doc "Conservative current/gravity envelope; BlockScan supplies the dependency halo."
  def query_box(%{position: position, motion: motion}) do
    with true <- Valimc.World.Items.valid_position?(position) and ItemMotionState.valid?(motion) do
      {x, y, z} = motion.velocity

      lower =
        {max(-64, min(0, x - 0.022)), max(-64, min(0, y - 0.062)), max(-64, min(0, z - 0.022))}

      upper = {min(64, max(0, x + 0.022)), min(64, max(0, y + 0.023)), min(64, max(0, z + 0.022))}
      {:ok, position |> body() |> Box.expand_towards(lower) |> Box.expand_towards(upper)}
    else
      _ -> {:error, :invalid_item_travel}
    end
  end

  def query_box(_), do: {:error, :invalid_item_travel}

  @doc "Resolve one supplied owner snapshot. Embedded escape and block effects are separate work."
  def sample(input, frame, refresh \\ true)

  def sample(
        %{position: position, motion: motion} = input,
        %BlockCollisions.Frame{} = frame,
        refresh
      )
      when is_boolean(refresh) do
    with {:ok, _} <- query_box(input),
         box = body(position),
         :ok <- clear_body(box, frame, position),
         {:ok, before} <- FluidCurrents.sample_item(frame, box, motion.velocity),
         {fluid, depth} = fluid(before.depths),
         {:ok, prepared} <-
           ItemMotion.prepare(before.velocity, %ItemMotion{
             fluid: fluid,
             depth: depth,
             on_ground: motion.on_ground,
             no_gravity: motion.no_gravity,
             refresh: refresh
           }),
         {:ok, moved} <- move(position, box, motion, prepared, frame),
         # ItemEntity refreshes fluid interaction again after movement/drag.
         {:ok, after_move} <-
           FluidCurrents.sample_item(frame, body(moved.position), moved.velocity),
         next = %{
           motion
           | velocity: after_move.velocity,
             on_ground: moved.on_ground,
             age: if(motion.age == -32_768, do: motion.age, else: min(6000, motion.age + 1)),
             pickup_delay:
               if(motion.pickup_delay == 32_767,
                 do: motion.pickup_delay,
                 else: max(0, motion.pickup_delay - 1)
               )
         },
         true <- ItemMotionState.valid?(next) do
      {:ok, %{input | position: moved.position, motion: next}}
    else
      false -> {:error, :item_motion_limit}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :item_geometry_limit}
  end

  def sample(_, _, _), do: {:error, :invalid_item_travel}

  defp move(position, _, motion, %{request: nil, velocity: velocity}, _),
    do: {:ok, %{position: position, velocity: velocity, on_ground: motion.on_ground}}

  defp move(position, box, motion, %{request: requested, velocity: velocity}, frame) do
    with {:ok, shapes} <- shapes(Box.expand_towards(box, requested), frame, position),
         actual = Collision.move(box, shapes, requested),
         destination = translated(position, requested, actual),
         grounded = elem(requested, 1) < 0 and elem(requested, 1) != elem(actual, 1),
         {:ok, material} <- material(frame, body(destination), destination, grounded, actual),
         {:ok, response} <-
           CollisionResponse.step(velocity, elem(actual, 1), %CollisionResponse{
             x_collision: abs(elem(requested, 0) - elem(actual, 0)) >= 9.999999747378752e-6,
             z_collision: abs(elem(requested, 2) - elem(actual, 2)) >= 9.999999747378752e-6,
             vertical_collision: elem(requested, 1) != elem(actual, 1),
             below: grounded,
             block_bounciness: f32(material.legacy.bounciness * f32(0.8)),
             block_suppresses_bounce: material.legacy.suppresses_bounce,
             gravity: if(motion.no_gravity, do: 0.0, else: 0.04)
           }),
         {vx, vy, vz} = response.velocity,
         {:ok, velocity} <-
           ItemMotion.finish(
             {vx * material.speed, vy, vz * material.speed},
             grounded,
             material.below.friction
           ),
         true <- Valimc.World.Items.valid_position?(destination) do
      {:ok, %{position: destination, velocity: velocity, on_ground: grounded}}
    else
      false -> {:error, :item_position_limit}
      error -> error
    end
  end

  defp clear_body({a, b, c, d, e, f}, frame, position) do
    box = {a + 1.0e-7, b + 1.0e-7, c + 1.0e-7, d - 1.0e-7, e - 1.0e-7, f - 1.0e-7}

    with {:ok, shapes} <- shapes(box, frame, position),
         do: if(shapes == [], do: :ok, else: {:error, :item_inside_block})
  end

  defp shapes(box, frame, {x, y, z}) do
    with {:ok, found} <- BlockCollisions.collect_frame(box, frame, context(y)),
         {:ok, border} <- BorderSnapshot.colliders(%BorderSnapshot{}, {x, z}, box),
         true <- length(found.colliders) + length(border) <= 128 do
      {:ok, Enum.map(found.colliders, & &1.shape) ++ border}
    else
      false -> {:error, :item_geometry_limit}
      error -> error
    end
  end

  defp material(frame, {a, b, c, d, _, f}, {x, y, z} = position, grounded, actual) do
    thin = {a, b - 1.0e-6, c, d, b, f}

    with {:ok, found} <-
           support(frame, thin, grounded, actual),
         support =
           Enum.min_by(
             found.colliders,
             fn %{position: {px, py, pz}} ->
               dx = px + 0.5 - x
               dy = py + 0.5 - y
               dz = pz + 0.5 - z
               {dx * dx + dy * dy + dz * dz, -py, -pz, -px}
             end,
             fn -> nil end
           ),
         {:ok, legacy} <- below(frame, support, position, f32(0.2)),
         # ItemEntity overrides Entity's movement-material offset.
         {:ok, below} <- below(frame, support, position, f32(0.999999)),
         {:ok, feet} <- fact(frame, {floor(x), floor(y), floor(z)}),
         {:ok, feet_id} <- state(frame, {floor(x), floor(y), floor(z)}) do
      speed =
        if MotionBlocks.uses_own_speed?(feet_id) or feet.speed_factor != 1.0,
          do: feet.speed_factor,
          else: below.speed_factor

      {:ok, %{legacy: legacy, below: below, speed: speed}}
    end
  end

  defp support(_, _, false, _), do: {:ok, %{colliders: []}}

  defp support(frame, thin, true, {dx, _, dz}) do
    with {:ok, found} <- BlockCollisions.collect_frame(thin, frame, context(elem(thin, 4))) do
      if found.colliders == [],
        do:
          BlockCollisions.collect_frame(
            Box.move(thin, {-dx, 0, -dz}),
            frame,
            context(elem(thin, 4))
          ),
        else: {:ok, found}
    end
  end

  defp below(frame, nil, {x, y, z}, offset),
    do: fact(frame, {floor(x), floor(y - offset), floor(z)})

  defp below(frame, %{position: {x, _, z} = support}, {_, y, _}, offset) do
    with {:ok, id} <- state(frame, support),
         {:ok, properties} <- MotionBlocks.fetch(id),
         do:
           if(properties.support_holds_y or (offset <= 0.5 and MotionBlocks.fence?(id)),
             do: {:ok, properties},
             else: fact(frame, {x, floor(y - offset), z})
           )
  end

  defp state(%{states: states}, pos) do
    case Map.fetch(states, pos) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :incomplete_item_frame}
    end
  end

  defp fact(frame, pos), do: with({:ok, id} <- state(frame, pos), do: MotionBlocks.fetch(id))

  defp translated(position, requested, actual) do
    length = fn {x, y, z} -> x * x + y * y + z * z end

    if length.(actual) > 1.0e-7 or length.(requested) - length.(actual) < 1.0e-7 do
      {x, y, z} = position
      {dx, dy, dz} = actual
      {x + dx, y + dy, z + dz}
    else
      position
    end
  end

  defp fluid(%{water: water}) when water > 0.10000000149011612, do: {:water, water}
  defp fluid(%{lava: lava}) when lava > 0.10000000149011612, do: {:lava, lava}
  defp fluid(_), do: {:air, 0.0}
  defp context(y), do: CollisionContext.entity(y) |> CollisionContext.with_entity(0, false, false)
  defp body({x, y, z}), do: {x - 0.125, y * 1.0, z - 0.125, x + 0.125, y + 0.25, z + 0.125}

  defp f32(value) do
    <<v::float-32>> = <<value::float-32>>
    v
  end
end
