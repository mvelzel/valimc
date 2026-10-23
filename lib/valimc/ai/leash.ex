defmodule Valimc.AI.Leash do
  @moduledoc """
  A mob on a lead (VMC-043c3): vanilla's `Leashable.tickLeash` at the end
  of `Entity.baseTick`, as `Mob` and `PathfinderMob` implement it.

  The mob's `leash` (`Valimc.Entity.Mob`) names its holder: a player the
  AI senses (`Valimc.AI.World`), or a fence knot at a block (`World.knots`
  maps a knot's block to its network id). A lead restored from a record
  looks for its holder (a missing knot is made again, `{:make_knot, pos}`)
  and is dropped as an item after 100 ticks without one. A holder the mob
  can no longer interact with (gone, dead, a spectator, its knot broken)
  drops the lead (an item while `entity_drops` is on).

  With its holder: the mob's home is the holder's block (radius 5), and
  beyond 12 blocks between their boxes' centres the lead breaks (its sound
  at the holder, the lead an item, `:move` goals stopped until the next
  `updateControlFlags`); beyond the slack (6 less both widths) the lead
  pulls it as a damped spring (`checkElasticInteractions`: a force and a
  torque into its motion and angular momentum); closer, it walks toward the
  holder (`closeRangeLeashBehaviour`) unless panicking. Its yaw turns by
  the angular momentum, which friction slows.

  Effects: `{:sound_at, ...}` (the break), `{:lead, position}` (the
  dropped lead), `{:knot_free, pos}` (a knot whose mob let go,
  `notifyLeasheeRemoved`) and `{:make_knot, pos}`.
  """
  alias Valimc.AI.{Goals, Mobs, Navigation, Self, World}
  alias Valimc.Data.{BlockFacts, Float32}

  @snap 12.0
  @elastic 6.0
  @spring Float32.round(0.3)
  @friction Float32.round(0.91)
  @radians Float32.round(:math.pi() / 180.0)
  @knot_width 0.375
  @knot_height 0.5
  @break "minecraft:item.lead.break"

  @doc "`canBeLeashed`: whether a mob of `type` takes a lead (its family's `leashable?/0`)."
  def leashable?(type), do: Mobs.hook(type, :leashable?, [], false)

  @doc """
  The holder `holder` names as the mob's AI reads it, or nil where it cannot
  interact with the level: `%{x, y, z, width, height, yaw, movement, id}`.
  """
  def holder(%World{} = world, {:player, uuid}) do
    case World.entity(world, {:player, uuid}) do
      %{alive: true} = p ->
        %{
          x: p.x,
          y: p.y,
          z: p.z,
          width: p.width,
          height: p.height,
          yaw: p.yaw,
          movement: Map.get(p, :movement, {0.0, 0.0, 0.0}),
          id: p.id
        }

      _ ->
        nil
    end
  end

  def holder(%World{knots: knots}, {:knot, pos}) do
    case knots do
      %{^pos => id} -> knot(pos, id)
      _ -> nil
    end
  end

  # `LeashFenceKnotEntity`: at its block's centre, 0.375 up.
  defp knot({x, y, z}, id),
    do: %{
      x: x + 0.5,
      y: y + 0.375,
      z: z + 0.5,
      width: @knot_width,
      height: @knot_height,
      yaw: 0.0,
      movement: {0.0, 0.0, 0.0},
      id: id
    }

  @doc "`tickLeash`: one tick of the mob's lead, if it has one."
  def tick(%Self{mob: %{leash: nil}} = self), do: self

  def tick(%Self{mob: %{leash: leash}} = self) do
    {self, holder} = restore(self, leash)

    case self.mob.leash do
      %{restored: false} = leash -> held(self, leash, holder)
      _ -> self
    end
  end

  # `restoreLeashFromSave`: the holder found takes the lead (observers are
  # linked to it again); a knot is made where it is missing; past 100
  # ticks without one the lead drops, quietly.
  defp restore(self, %{restored: false} = leash), do: {self, holder(self.world, leash.holder)}

  defp restore(self, %{holder: holder_ref} = leash) do
    case {holder(self.world, holder_ref), holder_ref} do
      {%{} = holder, _} ->
        {put_leash(self, %{leash | id: holder.id, restored: false}), holder}

      {nil, {:knot, pos}} ->
        holder = knot(pos, nil)
        self = Self.effect(self, {:make_knot, pos})
        {put_leash(self, %{leash | restored: false}), holder}

      {nil, _} when self.mind.tick > 100 ->
        {self |> drop_item() |> put_leash(nil), nil}

      {nil, _} ->
        {self, nil}
    end
  end

  # The mob's tick with its holder (nil: it can no longer hold it, and
  # without one nothing more happens).
  defp held(self, _leash, nil),
    do: if(self.world.entity_drops, do: drop(self), else: remove(self))

  defp held(self, leash, holder) do
    leash = %{leash | id: holder.id}
    self = put_leash(self, leash)
    distance = distance(self, holder)
    # `whenLeashedTo`: home at the holder's block.
    self = put_home(self, {block(holder), trunc(@elastic) - 1})

    {self, leash} =
      cond do
        distance > @snap ->
          self =
            Self.effect(
              self,
              {:sound_at, @break, "neutral", {holder.x, holder.y, holder.z}, 1.0, 1.0}
            )

          # `leashTooFarBehaviour`: the lead drops, `:move` goals stop.
          self = drop(self)
          {Self.mind(self, &%{&1 | disabled: Enum.uniq([:move | &1.disabled])}), leash}

        distance > @elastic - holder.width - self.width ->
          case elastic(self, holder, leash) do
            nil -> {close(self, holder), leash}
            {self, leash} -> {pull(self), leash}
          end

        true ->
          {close(self, holder), leash}
      end

    yaw(self, leash)
  end

  # The yaw turns by the angular momentum, which friction slows.
  defp yaw(self, leash) do
    self = %{self | yaw: Float32.round(self.yaw - leash.momentum)}

    case self.mob.leash do
      %{} = now -> put_leash(self, %{now | momentum: leash.momentum * angular_friction(self)})
      nil -> self
    end
  end

  # `angularFriction`: its block's friction on the ground, else liquid's or air's.
  defp angular_friction(%Self{on_ground: true} = self) do
    below = {floor(self.x), floor(self.y - 0.500001), floor(self.z)}

    friction =
      case World.block(self.world, below) do
        nil -> 0.6
        state -> BlockFacts.motion(state).friction
      end

    Float32.round(Float32.round(friction) * @friction)
  end

  defp angular_friction(self),
    do: if(Self.in_liquid?(self), do: Float32.round(0.8), else: @friction)

  defp distance(self, holder), do: between(self, holder)

  @doc """
  `leashDistanceTo`: the distance between the boxes' centres of two
  bodies (`%{x, y, z, width, height}`).
  """
  def between(a, b) do
    {ax, ay, az} = center(a.x, a.y, a.z, a.width, a.height)
    {bx, by, bz} = center(b.x, b.y, b.z, b.width, b.height)
    :math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay) + (bz - az) * (bz - az))
  end

  @doc "A fence knot's body at block `pos` with network id `id` (`holder/2`'s shape)."
  def knot_holder(pos, id), do: knot(pos, id)

  # `AABB.getCenter` of `EntityDimensions.makeBoundingBox` (a float half width).
  defp center(x, y, z, width, height) do
    half = Float32.round(width / 2.0)
    {x0, x1, z0, z1} = {x - half, x + half, z - half, z + half}
    {y0, y1} = {y, y + height}
    {lerp(x0, x1), lerp(y0, y1), lerp(z0, z1)}
  end

  defp lerp(a, b), do: a + 0.5 * (b - a)

  defp block(%{x: x, y: y, z: z}), do: {floor(x), floor(y), floor(z)}

  # `checkElasticInteractions` with one attachment point each:
  # `{self, leash}` with the pull applied, or nil within the slack.
  defp elastic(self, holder, leash) do
    own = if self.mob.no_ai, do: {0.0, 0.0, 0.0}, else: self.velocity
    yaw = Float32.round(self.yaw * @radians)
    lever = rotate({0.0, 0.5 * self.height, 0.5 * self.width}, -yaw)
    holder_yaw = Float32.round(holder.yaw * @radians)
    {hx, hy, hz} = rotate({0.0, 0.5 * holder.height, 0.0}, -holder_yaw)
    {lx, ly, lz} = lever
    object = {self.x + lx, self.y + ly, self.z + lz}
    pivot = {holder.x + hx, holder.y + hy, holder.z + hz}

    case spring(pivot, object, own, lever) do
      nil ->
        nil

      {{fx, fy, fz}, torque} ->
        leash = %{leash | momentum: leash.momentum + 10.0 * torque}
        {mx, my, mz} = holder.movement
        {ox, oy, oz} = self.velocity
        {rx, ry, rz} = {mx - ox, my - oy, mz - oz}
        {vx, vy, vz} = self.velocity

        velocity =
          {vx + (fx * 0.8 + rx * 0.11), vy + (fy * 0.2 + ry * 0.11), vz + (fz * 0.8 + rz * 0.11)}

        {put_leash(%{self | velocity: velocity}, leash), leash}
    end
  end

  # `computeDampenedSpringInteraction`.
  defp spring({px, py, pz}, {ox, oy, oz}, {mx, my, mz}, {lx, _, lz}) do
    {dx, dy, dz} = {px - ox, py - oy, pz - oz}
    distance = :math.sqrt(dx * dx + dy * dy + dz * dz)

    if distance < @elastic do
      nil
    else
      {nx, ny, nz} = normalize({dx, dy, dz})
      stretch = distance - @elastic
      {fx, fy, fz} = {nx * stretch, ny * stretch, nz * stretch}
      torque = lz * fx - lx * fz

      force =
        if mx * fx + my * fy + mz * fz >= 0.0,
          do: {fx * @spring, fy * @spring, fz * @spring},
          else: {fx, fy, fz}

      {force, torque}
    end
  end

  defp normalize({x, y, z}) do
    length = :math.sqrt(x * x + y * y + z * z)
    if length < 1.0e-5, do: {0.0, 0.0, 0.0}, else: {x / length, y / length, z / length}
  end

  # `Vec3.yRot` (`Mth.cos`, `Mth.sin`).
  defp rotate({x, y, z}, angle) do
    {sin, cos} = Valimc.Physics.Clip.sin_cos(angle)
    {x * cos + z * sin, y, z * cos - x * sin}
  end

  # `onElasticLeashPull`: `checkFallDistanceAccumulation`.
  defp pull(%Self{velocity: {_, vy, _}, mob: mob} = self) do
    if vy > -0.5 and mob.motion.fall_distance > 1.0,
      do: %{self | mob: %{mob | motion: %{mob.motion | fall_distance: 1.0}}},
      else: self
  end

  # `PathfinderMob.closeRangeLeashBehaviour`: toward the holder, two blocks short.
  defp close(self, holder) do
    if panicking?(self) do
      self
    else
      self = Self.mind(self, &%{&1 | disabled: List.delete(&1.disabled, :move)})
      {dx, dy, dz} = {holder.x - self.x, holder.y - self.y, holder.z - self.z}
      # `distanceTo`, in floats.
      [fx, fy, fz] = for v <- [dx, dy, dz], f = Float32.round(v), do: Float32.round(f * f)
      d = Float32.round(:math.sqrt(Float32.round(Float32.round(fx + fy) + fz)))
      scale = max(Float32.round(d - 2.0), 0.0)
      {nx, ny, nz} = normalize({dx, dy, dz})
      target = {self.x + nx * scale, self.y + ny * scale, self.z + nz * scale}
      {_, self} = Navigation.move_to(self, target, 1.0)
      self
    end
  end

  # `PathfinderMob.isPanicking`: a running panic goal.
  defp panicking?(%Self{mind: %{goals: goals}}),
    do:
      Enum.any?(Tuple.to_list(goals), fn entry ->
        entry.running and
          (entry.module == Goals.Panic or function_exported?(entry.module, :panic?, 0))
      end)

  @doc """
  `dropLeash`: the lead goes, an item where the mob stands; a knot it held
  checks whether it holds any other mob.
  """
  def drop(self), do: self |> drop_item() |> remove()

  # `removeLeash`: no item.
  defp remove(%Self{mob: %{leash: leash}} = self) do
    self =
      case leash do
        %{holder: {:knot, pos}} -> Self.effect(self, {:knot_free, pos})
        _ -> self
      end

    # `onLeashRemoved`: no home.
    self |> put_leash(nil) |> put_home(nil)
  end

  # `spawnAtLocation(LEAD)`: an item where the mob stands (`new ItemEntity`
  # draws its motion from its own fresh random).
  defp drop_item(self), do: Self.effect(self, {:lead, {self.x, self.y, self.z}})

  defp put_leash(%Self{mob: mob} = self, leash), do: %{self | mob: %{mob | leash: leash}}
  defp put_home(%Self{mob: mob} = self, home), do: %{self | mob: %{mob | home: home}}

  @doc """
  `Mob.updateControlFlags` every fifth tick (after the tick): the goal
  selector's flags enabled again.
  """
  def control_flags(%Self{mind: %{disabled: []}} = self), do: self

  def control_flags(%Self{mind: mind} = self),
    do: if(rem(mind.tick, 5) == 0, do: Self.mind(self, &%{&1 | disabled: []}), else: self)
end
