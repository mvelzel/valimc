defmodule Valimc.AI.Mobs.Enderman do
  @moduledoc """
  Endermen (VMC-043b5), as vanilla's `EnderMan`:

  - **Goals**: floating, freezing while its target player stares at it,
    melee, wandering (never preferring a spot) and looking around, putting
    down and picking up blocks; as targets a player who stares at it or
    whom it is angry at (`LookForPlayer`), whoever hurt it, endermites, and
    universal anger (`Valimc.AI.Neutral`, 20 to 39 seconds).
  - **Staring**: a player within its follow range who looks into its eyes
    (`isLookingAtMe`: a narrowing cone and line of sight, no carved pumpkin
    on the head) angers it after a few ticks; stared at from close by it
    teleports away, and far from its target it teleports toward it.
  - **Teleporting** (`randomTeleport`): down from a random spot up to 32
    blocks away to a block entities may teleport onto (not one endermen
    avoid), where it fits out of liquids and not above water; the trail
    (level event 2018) and the sound at both ends. By day in the open a
    bright spot sends it away; projectiles never hurt it (it teleports
    instead), and other hurts without a living attacker usually do; water
    and rain hurt it.
  - **Blocks**: while mobs may grief it now and then picks up a block it
    can reach within two blocks that endermen hold, and later puts it down
    where it fits (the owner checks that it survives there,
    `{:place_carried, ...}`); a carried block drops on death as if mined
    with silk touch.
  - Its own data: the carried block state, the creepy and stared-at flags
    clients see, its age and when its target last changed.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Facts, Goals, Navigation, Neutral, Self, Spawn, World}
  alias Valimc.Data.{BlockFacts, Blocks, Float32}
  alias Valimc.Physics.Clip
  alias Valimc.Protocol.ItemStack

  @type_name "minecraft:enderman"
  # `PERSISTENT_ANGER_TIME`: 20 to 39 seconds.
  @anger {400, 780}
  @speed "minecraft:movement_speed"
  @attacking "minecraft:attacking"

  tags = Valimc.Protocol.Data.tags()
  @disguises MapSet.new(tags["minecraft:item"]["minecraft:gaze_disguise_equipment"])
  @onto MapSet.new(tags["minecraft:block"]["minecraft:entities_can_teleport_to"])
  @avoided MapSet.new(tags["minecraft:block"]["minecraft:enderman_does_not_teleport_to"])

  @impl true
  def types, do: [@type_name]

  ## Goals

  @impl true
  def goals(_type) do
    {[
       {0, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "EndermanFreezeWhenLookedAt", __MODULE__.Freeze, [:move, :jump],
        __MODULE__.Freeze.new()},
       {2, "MeleeAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, false)},
       {7, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true, probability: 0.0)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       {10, "EndermanLeaveBlockGoal", __MODULE__.LeaveBlock, [], %{}},
       {11, "EndermanTakeBlockGoal", __MODULE__.TakeBlock, [], %{}}
     ],
     [
       {1, "EndermanLookForPlayerGoal", __MODULE__.LookForPlayer, [:target],
        __MODULE__.LookForPlayer.new()},
       {2, "HurtByTargetGoal", Goals.HurtByTarget, [:target], Goals.HurtByTarget.new()},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:endermite"], true)},
       {4, "ResetUniversalAngerTargetGoal", Goals.ResetUniversalAnger, [],
        Goals.ResetUniversalAnger.new(@anger)}
     ]}
  end

  @doc "`getWalkTargetValue`: no spot is better than another."
  @impl true
  def walk_value(_self, _pos), do: 0.0

  ## Data

  @impl true
  def data(_type),
    do: %{carried: nil, creepy: false, stared_at: false, ticks: 0, target_time: 0}

  @impl true
  def values(%{data: data}) do
    [
      {:enderman_carry_state, data.carried, nil},
      {:enderman_creepy, data.creepy, false},
      {:enderman_stared_at, data.stared_at, false}
    ]
  end

  @doc "`getAmbientSound`: it screams while creepy."
  @impl true
  def ambient_sound(%Self{data: %{creepy: true}}), do: "minecraft:entity.enderman.scream"
  def ambient_sound(%Self{facts: facts}), do: facts.ambient_sound

  ## Targets

  @doc """
  `setTarget`: a target makes it creepy and adds the attacking speed (+0.15)
  and notes the time; none clears both flags and the speed.
  """
  @impl true
  def set_target(%Self{data: data} = self, target) do
    self = Self.put_target(self, target)

    if target == nil do
      %{self | data: %{data | target_time: 0, creepy: false, stared_at: false}}
      |> modify(false)
    else
      %{self | data: %{data | target_time: data.ticks, creepy: true}}
      |> modify(true)
    end
  end

  defp modify(%Self{mob: mob} = self, on) do
    instance = Map.get(mob.attributes, @speed, %{base: nil, modifiers: []})
    rest = Enum.reject(instance.modifiers, &(elem(&1, 0) == @attacking))
    present = rest != instance.modifiers

    modifiers =
      cond do
        on and present -> instance.modifiers
        on -> rest ++ [{@attacking, Float32.round(0.15), 0}]
        true -> rest
      end

    attributes =
      if modifiers == [] and instance.base == nil,
        do: Map.delete(mob.attributes, @speed),
        else: Map.put(mob.attributes, @speed, %{instance | modifiers: modifiers})

    %{self | mob: %{mob | attributes: attributes}}
  end

  @doc """
  `isBeingStaredBy`: a player without a disguise on its head looking into
  its eyes (`isLookingAtMe(player, 0.025, true, false, eyeY)`).
  """
  def stared_by?(%Self{} = self, %{kind: :player} = player) do
    if MapSet.member?(@disguises, player.equipment[:head]),
      do: false,
      else: looked_at?(self, player, 0.025, Self.eye_y(self))
  end

  def stared_by?(_self, _target), do: false

  defp looked_at?(self, player, cone, gaze) do
    {lx, ly, lz} = normalize(Clip.view_vector(player.pitch, player.yaw))
    peye = player.y + player.eye
    {dx, dy, dz} = {self.x - player.x, gaze - peye, self.z - player.z}
    distance = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {nx, ny, nz} = normalize({dx, dy, dz})
    dot = lx * nx + ly * ny + lz * nz

    dot > 1.0 - cone / distance and
      sight?(self.world, {player.x, peye, player.z}, {self.x, gaze, self.z})
  end

  # `LivingEntity.hasLineOfSight(target, VISUAL, NONE, eyeY)` from the
  # player's eye (visual shapes read as collision shapes).
  defp sight?(world, from, to) do
    {fx, fy, fz} = from
    {tx, ty, tz} = to
    dx = tx - fx
    dy = ty - fy
    dz = tz - fz

    :math.sqrt(dx * dx + dy * dy + dz * dz) <= 128.0 and
      Clip.clip(from, to, :none, &World.block(world, &1), :collider).miss
  end

  # `Vec3.normalize`: zero below 1.0e-5.
  defp normalize({x, y, z}) do
    length = :math.sqrt(x * x + y * y + z * z)
    if length < 1.0e-5, do: {0.0, 0.0, 0.0}, else: {x / length, y / length, z / length}
  end

  ## Its tick

  @doc """
  Before the rest of its tick: it ages, and a hurt's reaction comes now
  (`hurtServer`'s teleports: 64 tries from a projectile, one in nine of ten
  other hurts without a living attacker).
  """
  @impl true
  def tick_start(%Self{data: data} = self) do
    self = %{self | data: %{data | ticks: data.ticks + 1}}

    case self.mind.own do
      %{hurt: reaction} ->
        self = Self.mind(self, &%{&1 | own: Map.delete(&1.own, :hurt)})

        case reaction do
          :away ->
            away(self)

          :maybe ->
            {n, self} = Self.int(self, 10)
            if n != 0, do: elem(teleport(self), 1), else: self
        end

      _ ->
        self
    end
  end

  @doc "`aiStep`: the anger kept up to date before its AI (`updatePersistentAnger`)."
  @impl true
  def before_ai(%Self{} = self), do: Neutral.update(self, true, @anger)

  @doc """
  `customServerAiStep`: by day, 30 seconds after its target last changed,
  a bright spot under the open sky sends it away now and then.
  """
  @impl true
  def custom_step(%Self{data: data, world: world} = self) do
    if world.bright and data.ticks >= data.target_time + 600 do
      bright = World.light(world, Self.block(self))

      if bright > 0.5 and World.sees_sky?(world, Self.block(self)) do
        {f, self} = Self.float(self)

        if Float32.round(f * 30.0) <
             Float32.round(Float32.round(bright - Float32.round(0.4)) * 2.0),
           do: self |> Self.set_target(nil) |> teleport() |> elem(1),
           else: self
      else
        self
      end
    else
      self
    end
  end

  ## Spawning and death

  @impl true
  def finalize(self, reason), do: Spawn.mob(self, reason)

  @doc """
  `dropCustomDeathLoot`: a carried block drops as if mined with a diamond
  axe enchanted with Silk Touch (`ENDERMAN_LOOT_DROP`).
  """
  @impl true
  def death_drops(%{data: %{carried: carried}}) when carried != nil do
    axe = %{
      ItemStack.new("diamond_axe")
      | components: %{"minecraft:enchantments" => %{"minecraft:silk_touch" => 1}}
    }

    case Valimc.Blocks.MiningLoot.drops(carried, {0, 0, 0}, tool: axe) do
      {:ok, stacks} -> stacks
      _ -> []
    end
  end

  def death_drops(_body), do: []

  ## Hurts

  @doc "Projectiles never hurt it (`hurtServer`): it teleports instead."
  @impl true
  def ignores?(_body, hit), do: Valimc.Living.DamageSource.is?(hit.source, :is_projectile)

  @impl true
  def repelled(body, hit), do: react(body, if(ignores?(body, hit), do: :away))

  @doc "A hurt without a living attacker may send it away on its next tick."
  @impl true
  def hurt(body, hit) do
    living = match?(%{uuid: _}, hit[:attacker])
    react(body, if(not living, do: :maybe))
  end

  defp react(body, nil), do: body

  defp react(%{mob: %{ai: %Valimc.AI.Mind{} = mind} = mob} = body, reaction),
    do: %{body | mob: %{mob | ai: %{mind | own: Map.put(mind.own || %{}, :hurt, reaction)}}}

  defp react(body, _reaction), do: body

  ## Teleporting

  @doc "`repeatedlyTryToTeleport`: up to 64 tries."
  def away(self), do: away(self, 64)

  defp away(self, 0), do: self

  defp away(self, n) do
    case teleport(self) do
      {true, self} -> self
      {false, self} -> away(self, n - 1)
    end
  end

  @doc "`teleport()`: a random spot up to 32 blocks away: `{teleported, self}`."
  def teleport(%Self{} = self) do
    if Valimc.Entity.Mob.alive?(self.mob) do
      {a, self} = Self.double(self)
      {n, self} = Self.int(self, 64)
      {b, self} = Self.double(self)
      teleport(self, {self.x + (a - 0.5) * 64.0, self.y + (n - 32), self.z + (b - 0.5) * 64.0})
    else
      {false, self}
    end
  end

  @doc "`teleportTowards`: a spot about 16 blocks toward `target`."
  def teleport_towards(%Self{} = self, target) do
    {dx, dy, dz} =
      normalize(
        {self.x - target.x, self.y + self.height * 0.5 - World.eye_y(target), self.z - target.z}
      )

    {a, self} = Self.double(self)
    {n, self} = Self.int(self, 16)
    {b, self} = Self.double(self)

    teleport(
      self,
      {self.x + (a - 0.5) * 8.0 - dx * 16.0, self.y + (n - 8) - dy * 16.0,
       self.z + (b - 0.5) * 8.0 - dz * 16.0}
    )
  end

  # `teleport(x, y, z)` through `randomTeleport` (avoiding the blocks endermen
  # do not teleport to).
  defp teleport(self, {x, y, z}) do
    {x, z} = clamp(self.world.border, x, z)
    {bx, by, bz} = {floor(x), floor(y), floor(z)}

    if World.block(self.world, {bx, by, bz}) == nil,
      do: {false, self},
      else: down(self, {x, y, z}, {bx, by, bz})
  end

  defp clamp(nil, x, z), do: {x, z}

  defp clamp({min_x, min_z, max_x, max_z}, x, z),
    do: {min(max(x, min_x), max_x - 1.0e-5), min(max(z, min_z), max_z - 1.0e-5)}

  # Down the column to the first block entities may teleport onto.
  defp down(self, {x, y, z}, {bx, by, bz}) do
    below = by - 1

    if below < self.world.min_y do
      {false, self}
    else
      state = World.block(self.world, {bx, below, bz})

      cond do
        state == nil -> {false, self}
        MapSet.member?(@onto, Blocks.block_id(state)) -> place(self, {x, y, z}, state)
        true -> down(self, {x, y - 1, z}, {bx, below, bz})
      end
    end
  end

  # `checkPositionAndTeleport`.
  defp place(self, {x, y, z} = at, onto) do
    w = self.width / 2
    box = {x - w, y, z - w, x + w, y + self.height, z + w}

    if not MapSet.member?(@avoided, Blocks.block_id(onto)) and World.fits?(self.world, box) and
         not liquid?(self.world, box) and not avoided_in?(self.world, box) and
         not water_below?(self.world, at) do
      {true, moved(self, at)}
    else
      {false, self}
    end
  end

  defp cells({x0, y0, z0, x1, y1, z1}) do
    for x <- floor(x0)..(ceil(x1) - 1)//1,
        y <- floor(y0)..(ceil(y1) - 1)//1,
        z <- floor(z0)..(ceil(z1) - 1)//1,
        do: {x, y, z}
  end

  defp liquid?(world, box) do
    Enum.any?(cells(box), fn cell ->
      case World.block(world, cell) do
        nil -> false
        state -> BlockFacts.fluid(state).kind != :empty
      end
    end)
  end

  defp avoided_in?(world, {x0, y0, z0, x1, y1, z1}) do
    for(
      x <- floor(x0)..floor(x1),
      y <- floor(y0)..floor(y1),
      z <- floor(z0)..floor(z1),
      do: {x, y, z}
    )
    |> Enum.any?(fn cell ->
      state = World.block(world, cell)
      state != nil and MapSet.member?(@avoided, Blocks.block_id(state))
    end)
  end

  # `canRandomlyTeleportTo`: not onto water.
  defp water_below?(world, {x, y, z}) do
    case World.block(world, {floor(x), floor(y) - 1, floor(z)}) do
      nil -> false
      state -> BlockFacts.fluid(state).kind == :water
    end
  end

  # It moves there (entity event 46, its navigation stopped); the trail from
  # its old block (level event 2018) and the sound where it was and where it
  # is.
  defp moved(%Self{} = self, {x, y, z}) do
    old = Self.block(self)
    {ox, oy, oz} = old
    {nx, ny, nz} = {floor(x), floor(y), floor(z)}
    # `BlockUtil.clampedPackDifferenceInPosition(old, new, 127, 127, 127)`.
    clamp = fn d -> Bitwise.band(min(max(d, -127), 127) + 127, 255) end

    packed =
      Bitwise.bor(
        Bitwise.bor(Bitwise.bsl(clamp.(nx - ox), 16), Bitwise.bsl(clamp.(ny - oy), 8)),
        clamp.(nz - oz)
      )

    source = Valimc.Protocol.CombatPackets.mob_sounds(@type_name)["sound_source"]
    sound = Facts.sound_id("minecraft:entity.enderman.teleport")
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    self
    |> Self.effect({:sound_at, sound, source, {self.x, self.y, self.z}, 1.0, 1.0})
    |> Map.merge(%{x: x, y: y, z: z})
    |> Self.mind(&%{&1 | snapped: {x, z}})
    |> Self.effect({:event, 46})
    |> Navigation.stop()
    |> Self.effect({:level_event, old, 2018, packed})
    |> Self.effect({:sound, "minecraft:entity.enderman.teleport", source, 1.0, 1.0, seed})
  end
end

defmodule Valimc.AI.Mobs.Enderman.Freeze do
  @moduledoc """
  `EndermanFreezeWhenLookedAt`: while its target is a player within 16
  blocks staring at it, it stands still looking at the player.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Enderman

  def new, do: %{target: nil}

  def can_use(state, self) do
    case World.target(self) do
      %{kind: :player} = player ->
        {World.distance_sq(self, player) <= 256.0 and Enderman.stared_by?(self, player),
         %{state | target: World.ref(player)}, self}

      _ ->
        {false, %{state | target: nil}, self}
    end
  end

  def start(state, self), do: {state, Navigation.stop(self)}

  def tick(state, self) do
    case World.entity(self.world, state.target) do
      nil -> {state, self}
      t -> {state, Self.look_at(self, {t.x, World.eye_y(t), t.z})}
    end
  end
end

defmodule Valimc.AI.Mobs.Enderman.TakeBlock do
  @moduledoc """
  `EndermanTakeBlockGoal`: carrying nothing, while mobs may grief, one
  update in ten it picks a cell within two blocks around and up to three
  above its feet; a block endermen hold there that an outline ray from its
  column reaches is taken (`{:take_block, cell, state}`) and carried as its
  block's default state.
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Blocks
  alias Valimc.Physics.Clip

  @holdable MapSet.new(
              Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:enderman_holdable"]
            )

  def can_use(state, self) do
    if self.data.carried != nil or not self.world.mob_griefing do
      {false, state, self}
    else
      {n, self} = Self.int(self, Mth.reduced(20))
      {n == 0, state, self}
    end
  end

  def tick(state, self) do
    {a, self} = Self.double(self)
    {b, self} = Self.double(self)
    {c, self} = Self.double(self)
    {bx, _, bz} = Self.block(self)

    {x, y, z} =
      cell =
      {floor(self.x - 2.0 + a * 4.0), floor(self.y + b * 3.0), floor(self.z - 2.0 + c * 4.0)}

    block = World.block(self.world, cell)
    from = {bx + 0.5, y + 0.5, bz + 0.5}
    to = {x + 0.5, y + 0.5, z + 0.5}
    hit = Clip.clip(from, to, :none, &World.block(self.world, &1), :outline)

    if block != nil and MapSet.member?(@holdable, Blocks.block_id(block)) and hit.position == cell do
      carried = Blocks.default_state(Blocks.name(Blocks.block_id(block)))

      self =
        %{self | data: %{self.data | carried: carried}}
        |> Self.effect({:take_block, cell, block})

      {state, self}
    else
      {state, self}
    end
  end
end

defmodule Valimc.AI.Mobs.Enderman.LeaveBlock do
  @moduledoc """
  `EndermanLeaveBlockGoal`: carrying a block, while mobs may grief, one
  update in a thousand it picks a cell within a block around and up to two
  above its feet: an air cell over a full, non-bedrock block with nothing
  in it takes the block (`{:place_carried, cell, state}`; the owner places
  it only where it survives, else gives it back).
  """
  use Valimc.AI.Goal
  alias Valimc.Data.{BlockFacts, Blocks}

  @bedrock Blocks.default_state("bedrock")

  def can_use(state, self) do
    if self.data.carried == nil or not self.world.mob_griefing do
      {false, state, self}
    else
      {n, self} = Self.int(self, Mth.reduced(2000))
      {n == 0, state, self}
    end
  end

  def tick(state, self) do
    {a, self} = Self.double(self)
    {b, self} = Self.double(self)
    {c, self} = Self.double(self)

    {x, y, z} =
      cell =
      {floor(self.x - 1.0 + a * 2.0), floor(self.y + b * 2.0), floor(self.z - 1.0 + c * 2.0)}

    target = World.block(self.world, cell)
    below = World.block(self.world, {x, y - 1, z})
    carried = self.data.carried

    if carried != nil and target != nil and below != nil and BlockFacts.air?(target) and
         not BlockFacts.air?(below) and below != @bedrock and
         BlockFacts.flag?(below, :full_collision) and empty?(self, cell) do
      self =
        %{self | data: %{self.data | carried: nil}}
        |> Self.effect({:place_carried, cell, carried})

      {state, self}
    else
      {state, self}
    end
  end

  # No other entity in the cell (`getEntities(enderman, cube)`).
  defp empty?(self, {x, y, z}) do
    cube = {x * 1.0, y * 1.0, z * 1.0, x + 1.0, y + 1.0, z + 1.0}
    others = self.world.players ++ World.mob_list(self.world) ++ self.world.items

    not Enum.any?(others, fn e ->
      e.uuid != self.uuid and World.intersects?(World.box(e), cube)
    end)
  end
end

defmodule Valimc.AI.Mobs.Enderman.LookForPlayer do
  @moduledoc """
  `EndermanLookForPlayerGoal`: the nearest player within its follow range
  who stares at it or whom it is angry at becomes pending; looking at that
  player, after three updates it becomes the target. With a target it
  keeps it unseen; stared at from within four blocks it teleports away,
  and over 16 blocks from its target it teleports toward it every 15
  updates until one lands.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.Target
  alias Valimc.AI.Mobs.Enderman
  alias Valimc.AI.Neutral

  def new,
    do: Map.merge(Target.fields(false), %{pending: nil, aggro: 0, teleport: 0})

  defp inducing?(self, player),
    do: Enderman.stared_by?(self, player) or Neutral.angry_at?(self, player)

  def can_use(state, self) do
    follow = Target.follow(self)

    conditions =
      World.conditions(true,
        range: follow,
        select: fn target, self -> inducing?(self, target) end
      )

    # `getNearestPlayer(conditions, enderman)`: measured from its feet.
    {found, self} = World.nearest_player(self, conditions, self.x, self.y, self.z)
    {found != nil, %{state | pending: World.ref(found)}, self}
  end

  def start(state, self) do
    {%{state | aggro: Mth.reduced(5), teleport: 0},
     %{self | data: %{self.data | stared_at: true}}}
  end

  def stop(state, self), do: Target.stop(%{state | pending: nil}, self)

  def can_continue(%{pending: pending} = state, self) when pending != nil do
    case World.entity(self.world, pending) do
      %{} = player ->
        if inducing?(self, player),
          do: {true, state, Self.look_at_entity(self, player, 10.0, 10.0)},
          else: {false, state, self}

      nil ->
        {false, state, self}
    end
  end

  def can_continue(state, self) do
    target = World.entity(self.world, state.target)
    conditions = World.conditions(true, sight: false)

    case target do
      nil ->
        Target.can_continue(state, self)

      target ->
        case World.test(self, target, conditions) do
          {true, self} -> {true, state, self}
          {false, self} -> Target.can_continue(state, self)
        end
    end
  end

  def tick(state, self) do
    state = if World.target(self) == nil, do: %{state | target: nil}, else: state

    cond do
      state.pending != nil ->
        aggro = state.aggro - 1

        if aggro <= 0 do
          state = %{state | aggro: aggro, target: state.pending, pending: nil}
          {Target.start(state), Self.set_target(self, state.target)}
        else
          {%{state | aggro: aggro}, self}
        end

      state.target != nil ->
        case World.entity(self.world, state.target) do
          nil -> {state, self}
          target -> chase(state, self, target)
        end

      true ->
        {state, self}
    end
  end

  defp chase(state, self, target) do
    distance = World.distance_sq(self, target)

    cond do
      Enderman.stared_by?(self, target) ->
        self = if distance < 16.0, do: elem(Enderman.teleport(self), 1), else: self
        {%{state | teleport: 0}, self}

      distance > 256.0 ->
        waited = state.teleport
        state = %{state | teleport: waited + 1}

        if waited >= Mth.reduced(30) do
          case Enderman.teleport_towards(self, target) do
            {true, self} -> {%{state | teleport: 0}, self}
            {false, self} -> {state, self}
          end
        else
          {state, self}
        end

      true ->
        {state, self}
    end
  end
end
