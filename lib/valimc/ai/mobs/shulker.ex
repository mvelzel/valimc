defmodule Valimc.AI.Mobs.Shulker do
  @moduledoc """
  `Shulker`: a box on a block face that never moves. It peeks now and then
  and opens fully to shoot bullets at its target (`Attack`, `Peek`); while
  closed it has 20 more armor and arrows glance off. Each tick it checks it
  can stay where it is, else it finds another face of its block or
  teleports up to eight blocks away, as it may when hurt below half health
  or hit by a bullet (which can bring a second shulker).

  Its data: the face it is attached to (`Direction`'s 3D value, down by
  default), its raw peek (0, 30 or 100), the peek it has opened to
  (`currentPeekAmount`, 0.05 a tick toward the raw one), and its colour
  (16 for none).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Facts, Goals, Random, Self, Shapes, World}
  alias Valimc.Data.{BlockFacts, Blocks, Float32}

  @type_name "minecraft:shulker"
  @covered {"minecraft:covered", 20.0, 0}
  @arrows ["minecraft:arrow", "minecraft:spectral_arrow", "minecraft:trident"]
  @no_teleport MapSet.new(
                 Valimc.Protocol.Data.tags()["minecraft:block"][
                   "minecraft:shulker_does_not_teleport_to"
                 ] || []
               )
  @moving_piston Blocks.default_state("moving_piston")
  @step Float32.round(0.05)
  @hundredth Float32.round(0.01)

  @impl true
  def types, do: [@type_name]

  @impl true
  def goals(_type) do
    {[
       {1, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look],
        Goals.LookAtPlayer.new(8.0, 0.02, only_horizontal: true)},
       {4, "ShulkerAttackGoal", __MODULE__.Attack, [:move, :look], __MODULE__.Attack.new()},
       {7, "ShulkerPeekGoal", __MODULE__.Peek, [], __MODULE__.Peek.new()},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, alert_types: [@type_name], ignore: [@type_name])},
       {2, "ShulkerNearestAttackGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true, peaceful: false)},
       # Only a shulker on a team defends others (`getTeam() == null`).
       {3, "ShulkerDefenseAttackGoal", Goals.Idle, [:target],
        Goals.Idle.new("ShulkerDefenseAttackGoal")}
     ]}
  end

  @impl true
  def motion, do: [fixed: true, pushable: false, emission: :none]

  @impl true
  def data(_type), do: %{attach_face: 0, peek: 0, peek_amount: 0.0, color: 16}

  @impl true
  def values(%{data: data}),
    do: [
      {:shulker_attach_face, data.attach_face, 0},
      {:shulker_peek, data.peek, 0},
      {:shulker_color, data.color, 16}
    ]

  @doc """
  `getDefaultDimensions`: one opening upward is taller by its peek, its eye
  with it.
  """
  @impl true
  def dimensions(%{data: %{attach_face: 0, peek_amount: peek}}) when peek > 0.0 do
    facts = Valimc.Data.EntityTypes.fetch(@type_name)
    scale = Float32.round(1.0 + peek)

    {Float32.round(facts.width), Float32.round(Float32.round(facts.height) * scale),
     Float32.round(Float32.round(facts.eye_height) * scale)}
  end

  def dimensions(_body), do: nil

  @doc """
  `makeBoundingBox` at `{x, y, z}`: the cube on its block, opened by its
  physical peek away from the face it holds.
  """
  @impl true
  def box(%{data: data}, position), do: physical_box(data, position)

  @doc "A living shulker is solid to other entities (`canBeCollidedWith`)."
  @impl true
  def collider(body, position),
    do: if(Valimc.Entity.Body.alive?(body), do: box(body, position))

  defp physical_box(%{attach_face: face, peek_amount: peek}, position),
    do: progress_box(Shapes.opposite(face), physical(peek), position)

  @pi Float32.round(:math.pi())

  # `getPhysicalPeek`: `0.5F - Mth.sin((0.5F + amount) * (float)Math.PI) * 0.5F`.
  defp physical(amount) do
    angle = Float32.round(Float32.round(0.5 + amount) * @pi)
    Float32.round(0.5 - Float32.round(Valimc.Data.Mth.sin(angle) * 0.5))
  end

  # `getProgressAabb(1, direction, progress, position)`.
  defp progress_box(direction, progress, {x, y, z}) do
    {dx, dy, dz} = Shapes.step(direction)

    grow = fn low, high, d ->
      if d > 0, do: {low, high + d * progress}, else: {low + d * progress, high}
    end

    {x0, x1} = grow.(-0.5, 0.5, dx)
    {y0, y1} = grow.(0.0, 1.0, dy)
    {z0, z1} = grow.(-0.5, 0.5, dz)
    {x0 + x, y0 + y, z0 + z, x1 + x, y1 + y, z1 + z}
  end

  # ---- look and body (`ShulkerLookControl`, `ShulkerBodyRotationControl`)

  @doc """
  The head's wanted yaw measured in the frame of its face (`getYRotD`), the
  pitch always level (`getXRotD`).
  """
  @impl true
  def look_rotations(%Self{} = self, look) do
    [fx, fy, fz, rx, ry, rz] = Facts.shulker_look(self.data.attach_face)

    out =
      {Float32.round(look.x - self.x), Float32.round(look.y - Self.eye_y(self)),
       Float32.round(look.z - self.z)}

    right = dot({rx, ry, rz}, out)
    forward = dot({fx, fy, fz}, out)
    near = Float32.round(1.0e-5)

    yaw =
      if abs(right) > near or abs(forward) > near,
        do: Float32.round(Valimc.AI.Mth.atan2(-right, forward) * 57.2957763671875),
        else: nil

    {yaw, 0.0}
  end

  # `Vector3f.dot`: x * x' + (y * y' + z * z'), in floats.
  defp dot({a, b, c}, {x, y, z}) do
    f = &Float32.round/1
    f.(f.(a * x) + f.(f.(b * y) + f.(c * z)))
  end

  @impl true
  def clamps_head?, do: false
  @impl true
  def turns_body?, do: false

  # ---- its tick

  @doc "A hurt's reaction waits for its next tick (`hurtServer`'s teleport)."
  @impl true
  def tick_start(%Self{mind: %{own: %{hurt: reaction}}} = self) do
    self = Self.mind(self, &%{&1 | own: Map.delete(&1.own, :hurt)})

    case reaction do
      :teleport -> elem(teleport(self), 1)
      :bullet -> hit_by_bullet(self)
    end
  end

  def tick_start(self), do: self

  @doc """
  After its tick: if it cannot stay on its face it finds another or
  teleports, then its peek moves toward the raw one.
  """
  @impl true
  def after_tick(%Self{} = self) do
    self =
      if stays?(self, Self.block(self), self.data.attach_face) do
        self
      else
        case surface(self, Self.block(self)) do
          nil -> elem(teleport(self), 1)
          face -> %{self | data: %{self.data | attach_face: face}}
        end
      end

    peek(self)
  end

  # `updatePeekAmount` (pushing what an opening lid meets is not modelled).
  defp peek(%Self{data: data} = self) do
    target = Float32.round(data.peek * @hundredth)
    current = data.peek_amount

    amount =
      cond do
        current == target -> current
        current > target -> Float32.round(max(Float32.round(current - @step), target) |> min(1.0))
        true -> Float32.round(min(Float32.round(current + @step), target) |> max(0.0))
      end

    %{self | data: %{data | peek_amount: amount}}
  end

  @doc "`setRawPeekAmount`: the covered armor while closed, the lid's sound."
  def set_peek(%Self{data: data, mob: mob} = self, amount) do
    armor = mob.attributes["minecraft:armor"] || %{base: nil, modifiers: []}
    modifiers = Enum.reject(armor.modifiers, &(elem(&1, 0) == elem(@covered, 0)))

    {modifiers, sound} =
      if amount == 0,
        do: {modifiers ++ [@covered], "minecraft:entity.shulker.close"},
        else: {modifiers, "minecraft:entity.shulker.open"}

    attributes = Map.put(mob.attributes, "minecraft:armor", %{armor | modifiers: modifiers})

    %{self | data: %{data | peek: amount}, mob: %{mob | attributes: attributes}}
    |> play(sound, 1.0, 1.0)
  end

  @doc "`Entity.playSound` at the mob, with a pitch drawn by the caller."
  def play(self, name, volume, pitch),
    do:
      Self.effect(
        self,
        {:sound, Facts.sound_id(name), "hostile", Float32.round(volume), Float32.round(pitch),
         seed()}
      )

  defp seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end

  @doc "`isClosed`."
  def closed?(%{peek: peek}), do: peek == 0

  @doc "`canStayAt`: its cell is free, the face holds and the open box fits."
  def stays?(%Self{} = self, cell, face) do
    opposite = Shapes.opposite(face)

    not blocked?(self, cell) and
      Shapes.face_full?(self.world, Shapes.relative(cell, face), opposite) and
      free?(self, deflate(progress_box(opposite, 1.0, bottom_center(cell))))
  end

  # `isPositionBlocked`: anything but air, unless a moving piston where it is.
  defp blocked?(self, cell) do
    case World.block(self.world, cell) do
      nil ->
        true

      state ->
        not BlockFacts.air?(state) and not (state == @moving_piston and cell == Self.block(self))
    end
  end

  # `findAttachableSurface`: the first face, in `Direction` order, it can stay on.
  defp surface(self, cell), do: Enum.find(0..5, &stays?(self, cell, &1))

  # `noCollision`: blocks, the border and the other shulkers.
  defp free?(self, box) do
    Shapes.free?(self.world, box) and
      not Enum.any?(World.mobs_of(self.world, @type_name), fn other ->
        other.uuid != self.uuid and other.alive and World.intersects?(World.box(other), box)
      end)
  end

  defp bottom_center({x, y, z}), do: {x + 0.5, y * 1.0, z + 0.5}

  defp deflate({x0, y0, z0, x1, y1, z1}),
    do: {x0 + 1.0e-6, y0 + 1.0e-6, z0 + 1.0e-6, x1 - 1.0e-6, y1 - 1.0e-6, z1 - 1.0e-6}

  @doc """
  `teleportSomewhere`: five tries at a random empty cell within eight
  blocks that it can stay in, onto a face whose block it may teleport to.
  `{moved, self}`.
  """
  def teleport(%Self{} = self) do
    if self.mob.no_ai, do: {false, self}, else: try_teleport(self, Self.block(self), 5)
  end

  defp try_teleport(self, _old, 0), do: {false, self}

  defp try_teleport(self, {ox, oy, oz} = old, tries) do
    {dx, self} = between(self)
    {dy, self} = between(self)
    {dz, self} = between(self)
    target = {ox + dx, oy + dy, oz + dz}

    with true <- elem(target, 1) > self.world.min_y,
         state when is_integer(state) <- World.block(self.world, target),
         true <- BlockFacts.air?(state),
         true <- within_border?(self.world, target),
         true <- free?(self, deflate(cube(target))),
         face when face != nil <- surface(self, target),
         onto when is_integer(onto) <- World.block(self.world, Shapes.relative(target, face)),
         false <- MapSet.member?(@no_teleport, onto) do
      {true, moved(self, old, target, face)}
    else
      _ -> try_teleport(self, old, tries - 1)
    end
  end

  defp between(self) do
    {n, self} = Self.int(self, 17)
    {n - 8, self}
  end

  defp within_border?(%World{border: nil}, _cell), do: true

  defp within_border?(%World{border: {min_x, min_z, max_x, max_z}}, {x, _, z}),
    do: x >= min_x and x < max_x and z >= min_z and z < max_z

  defp cube({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0, x + 1.0, y + 1.0, z + 1.0}

  # It plays the teleport sound where it was, moves, and the level shows
  # its trail (level event 2016); its lid shuts at once and it forgets its
  # target.
  defp moved(%Self{} = self, {ox, oy, oz} = old, {tx, ty, tz}, face) do
    packed =
      Bitwise.bor(
        Bitwise.bor(
          Bitwise.bsl(Bitwise.band(tx - ox + 8, 255), 16),
          Bitwise.bsl(Bitwise.band(ty - oy + 8, 255), 8)
        ),
        Bitwise.band(tz - oz + 8, 255)
      )

    self
    |> Self.effect(
      {:sound_at, Facts.sound_id("minecraft:entity.shulker.teleport"), "hostile",
       {self.x, self.y, self.z}, 1.0, 1.0}
    )
    |> Map.merge(%{x: tx + 0.5, y: ty * 1.0, z: tz + 0.5})
    |> then(&%{&1 | data: %{&1.data | attach_face: face, peek: 0}})
    |> Self.effect({:level_event, old, 2016, packed})
    |> Self.set_target(nil)
  end

  # `hitByShulkerBullet`: an open shulker that teleports may leave a second
  # one where it was, less likely the more shulkers are near.
  defp hit_by_bullet(%Self{} = self) do
    old = {self.x, self.y, self.z}
    old_box = physical_box(self.data, old)

    if closed?(self.data) do
      self
    else
      case teleport(self) do
        {false, self} ->
          self

        {true, self} ->
          area = World.inflate(old_box, 8.0, 8.0, 8.0)

          others =
            Enum.count(World.mobs_of(self.world, @type_name), fn other ->
              other.uuid != self.uuid and other.alive and
                World.intersects?(World.box(other), area)
            end)

          me =
            if World.intersects?(physical_box(self.data, {self.x, self.y, self.z}), area),
              do: 1,
              else: 0

          failure = Float32.round((others + me - 1) / 5.0)
          {f, random} = Random.float(self.world.random)
          self = %{self | world: %{self.world | random: random}}

          if f < failure,
            do: self,
            else: Self.effect(self, {:spawn_mob, @type_name, old, %{color: self.data.color}})
      end
    end
  end

  # ---- its hurts (`hurtServer`, through `Valimc.Entity.Combat`)

  @doc "A closed shulker takes nothing from arrows."
  @impl true
  def ignores?(%{data: data}, hit),
    do: closed?(data) and match?(%{type: type} when type in @arrows, hit[:direct])

  @doc "It is silent while closed (`playAmbientSound`)."
  @impl true
  def ambient_sound(%Self{data: data, facts: facts}),
    do: if(closed?(data), do: nil, else: facts.ambient_sound)

  @doc "Its hurt sound: muffled while closed."
  @impl true
  def sound(%{data: data}, "hurt_sound"),
    do: if(closed?(data), do: nil, else: "minecraft:entity.shulker.hurt")

  def sound(_body, _which), do: nil

  @doc """
  After a hurt: below half health one in four teleports; otherwise a
  bullet's hit may (both on its next tick).
  """
  @impl true
  def hurt(%{mob: %{ai: %Valimc.AI.Mind{} = mind} = mob} = body, hit) do
    max = Valimc.Entity.Mob.value(@type_name, mob, "minecraft:max_health")

    {reaction, mind} =
      if mob.living.health.value < max * 0.5 do
        {n, random} = Random.int(mind.random, 4)
        {if(n == 0, do: :teleport), %{mind | random: random}}
      else
        {nil, mind}
      end

    reaction =
      reaction ||
        if Valimc.Living.DamageSource.is?(hit.source, :is_projectile) and
             match?(%{type: "minecraft:shulker_bullet"}, hit[:direct]),
           do: :bullet

    mind = if reaction, do: %{mind | own: Map.put(mind.own || %{}, :hurt, reaction)}, else: mind
    %{body | mob: %{mob | ai: mind}}
  end

  def hurt(body, _hit), do: body
end

defmodule Valimc.AI.Mobs.Shulker.Peek do
  @moduledoc """
  `ShulkerPeekGoal`: with no target, one update in twenty a shulker that
  can stay where it is opens a little (raw peek 30) for 20, 40 or 60 ticks.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Shulker

  def new, do: %{time: 0}

  def can_use(state, self) do
    if self.mind.target != nil do
      {false, state, self}
    else
      {n, self} = Self.int(self, Mth.reduced(40))
      {n == 0 and Shulker.stays?(self, Self.block(self), self.data.attach_face), state, self}
    end
  end

  def can_continue(state, self), do: {self.mind.target == nil and state.time > 0, state, self}

  def start(state, self) do
    {n, self} = Self.int(self, 3)
    {%{state | time: adjusted(state, 20 * (1 + n))}, Shulker.set_peek(self, 30)}
  end

  def stop(state, self),
    do: {state, if(self.mind.target == nil, do: Shulker.set_peek(self, 0), else: self)}

  def tick(state, self), do: {%{state | time: state.time - 1}, self}
end

defmodule Valimc.AI.Mobs.Shulker.Attack do
  @moduledoc """
  `ShulkerAttackGoal`: with a living target, unless peaceful, the shulker
  opens fully, looks at it and, while it is within 20 blocks, shoots a
  bullet every 20 to 110 ticks (the first after 20); farther away it loses
  it.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Shulker

  def new, do: %{time: 0}

  def can_use(state, self) do
    target = World.target(self)
    {target != nil and target.alive and self.world.difficulty != :peaceful, state, self}
  end

  def start(state, self), do: {%{state | time: 20}, Shulker.set_peek(self, 100)}

  def stop(state, self), do: {state, Shulker.set_peek(self, 0)}

  def every_tick?(_state), do: true

  def tick(state, self) do
    if self.world.difficulty == :peaceful do
      {state, self}
    else
      state = %{state | time: state.time - 1}

      case World.target(self) do
        nil ->
          {state, self}

        target ->
          self = Self.look_at(self, {target.x, World.eye_y(target), target.z}, 180.0, 180.0)

          cond do
            World.distance_sq(self, target) >= 400.0 ->
              {state, Self.set_target(self, nil)}

            state.time <= 0 ->
              {n, self} = Self.int(self, 10)
              state = %{state | time: 20 + div(n * 20, 2)}
              {cx, cy, cz} = center(Shulker.box(self, {self.x, self.y, self.z}))

              self =
                Self.effect(
                  self,
                  {:shoot_bullet, {cx, cy, cz}, World.ref(target),
                   Valimc.AI.Shapes.axis(self.data.attach_face)}
                )

              {a, self} = Self.float(self)
              {b, self} = Self.float(self)
              f = &Valimc.Data.Float32.round/1
              pitch = f.(f.(f.(a - b) * f.(0.2)) + 1.0)
              {state, Shulker.play(self, "minecraft:entity.shulker.shoot", 2.0, pitch)}

            true ->
              {state, self}
          end
      end
    end
  end

  # `AABB.getCenter`: `Mth.lerp(0.5, min, max)`.
  defp center({x0, y0, z0, x1, y1, z1}),
    do: {x0 + 0.5 * (x1 - x0), y0 + 0.5 * (y1 - y0), z0 + 0.5 * (z1 - z0)}
end
