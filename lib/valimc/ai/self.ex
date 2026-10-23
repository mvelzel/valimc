defmodule Valimc.AI.Self do
  @moduledoc """
  One mob as its AI sees and changes it during its tick: its identity and
  type, position, rotations, motion and ground flag, its `Entity.Mob`
  (living state, equipment, attributes, travel state), its type's own
  entity data (`Valimc.AI.Kind`), its mind, its type's AI facts and what
  the owner lets it read (`Valimc.AI.World`). Goals take and return
  it; what leaves the mob (attacks, sounds, swings, alerts) collects in
  `effects`, newest first.
  """
  alias Valimc.AI.{Mind, Random}
  alias Valimc.Entity.MobMotion

  defstruct [
    :id,
    :uuid,
    :type,
    :x,
    :y,
    :z,
    :yaw,
    :pitch,
    :head,
    :on_ground,
    :velocity,
    :mob,
    :mind,
    :facts,
    :width,
    :height,
    :eye,
    :world,
    # The body's own data (`Body.data`: a zombie's baby flag, VMC-043b; an
    # animal's age and love, VMC-043c).
    data: %{},
    effects: []
  ]

  @type t :: %__MODULE__{}

  @doc "`getEyeY`."
  def eye_y(%__MODULE__{y: y, eye: eye}), do: y + eye

  @doc "`blockPosition`."
  def block(%__MODULE__{x: x, y: y, z: z}), do: {floor(x), floor(y), floor(z)}

  @doc "`distanceToSqr` to a point."
  def distance_sq(%__MODULE__{x: x, y: y, z: z}, {px, py, pz}) do
    {dx, dy, dz} = {x - px, y - py, z - pz}
    dx * dx + dy * dy + dz * dz
  end

  @doc "The mob's bounding box."
  def box(%__MODULE__{x: x, y: y, z: z, width: w, height: h}) do
    half = w / 2.0
    {x - half, y, z - half, x + half, y + h, z + half}
  end

  @doc """
  `Entity.spawnSprintParticle`: over a block that renders, the particle's
  place draws twice (the server sends no particle).
  """
  def sprint_particle(%__MODULE__{} = self) do
    {x, y, z} = {floor(self.x), floor(self.y - 0.2), floor(self.z)}

    case Valimc.AI.World.block(self.world, {x, y, z}) do
      state when is_integer(state) ->
        if Valimc.Data.BlockFacts.flag?(state, :invisible) do
          self
        else
          {_, self} = double(self)
          {_, self} = double(self)
          self
        end

      nil ->
        self
    end
  end

  @doc "`nextInt(bound)` of the mob's random."
  def int(self, bound), do: draw(self, &Random.int(&1, bound))
  @doc "`nextFloat()` of the mob's random."
  def float(self), do: draw(self, &Random.float/1)
  @doc "`nextDouble()` of the mob's random."
  def double(self), do: draw(self, &Random.double/1)
  @doc "`nextBoolean()` of the mob's random."
  def boolean(self), do: draw(self, &Random.boolean/1)

  @doc """
  `nextGaussian()` (`MarsagliaPolarGaussian`): a pair drawn at once, the
  second held back in the mind for the next call.
  """
  def gaussian(%__MODULE__{mind: %{gaussian: held} = mind} = self) when held != nil,
    do: {held, %{self | mind: %{mind | gaussian: nil}}}

  def gaussian(self) do
    {v1, self} = double(self)
    {v2, self} = double(self)
    {v1, v2} = {2 * v1 - 1, 2 * v2 - 1}
    s = v1 * v1 + v2 * v2

    if s >= 1 or s == 0 do
      gaussian(self)
    else
      multiplier = :math.sqrt(-2 * :math.log(s) / s)
      {v1 * multiplier, mind(self, &%{&1 | gaussian: v2 * multiplier})}
    end
  end

  defp draw(%__MODULE__{mind: mind} = self, fun) do
    {value, random} = fun.(mind.random)
    {value, %{self | mind: %{mind | random: random}}}
  end

  @doc "Put a change into the mind."
  def mind(%__MODULE__{mind: mind} = self, fun), do: %{self | mind: fun.(mind)}

  @doc "Record an effect that leaves the mob."
  def effect(%__MODULE__{effects: effects} = self, effect),
    do: %{self | effects: [effect | effects]}

  @doc """
  `Mob.setTarget` (`asValidTarget` is the reader's, `World.target/2`),
  through the type's own override when it has one (`Valimc.AI.Kind`'s
  `set_target/2`: a zombified piglin draws its anger sound and alert
  delays).
  """
  def set_target(%__MODULE__{type: type} = self, target) do
    case Valimc.AI.Mobs.hook(type, :set_target, [self, target], nil) do
      nil -> put_target(self, target)
      self -> self
    end
  end

  @doc "`Mob.setTarget` itself: the mind keeps `target`."
  def put_target(self, target), do: mind(self, &%{&1 | target: target})

  @doc "`Mob.setAggressive`."
  def set_aggressive(self, aggressive), do: mind(self, &%{&1 | aggressive: aggressive})

  @doc "`MoveControl.setWantedPosition`."
  def move_to(%__MODULE__{mob: mob} = self, target, speed),
    do: %{self | mob: %{mob | motion: MobMotion.move_to(mob.motion, target, speed)}}

  @doc "`MoveControl.setWait`."
  def wait(%__MODULE__{mob: mob} = self),
    do: %{self | mob: %{mob | motion: %{mob.motion | control: :wait}}}

  @doc "`LivingEntity.getSpeed` (what the move control last set)."
  def speed(%__MODULE__{mob: mob}), do: mob.motion.speed

  @doc "`MoveControl.strafe(forwards, right)` (its speed modifier 0.25), VMC-043b."
  def strafe(%__MODULE__{mob: mob} = self, forward, right) do
    control =
      {:strafe, Valimc.Data.Float32.round(forward), Valimc.Data.Float32.round(right), 0.25}

    %{self | mob: %{mob | motion: %{mob.motion | control: control}}}
  end

  @doc """
  `Mob.lookAt(entity, yMax, xMax)`: the mob's own yaw and pitch turned
  toward `target` (its eyes, or the middle of its box when it has none) by at
  most the limits (VMC-043b).
  """
  def look_at_entity(%__MODULE__{} = self, target, y_max, x_max) do
    alias Valimc.AI.Mth
    {xd, zd} = {target.x - self.x, target.z - self.z}

    yd =
      case target do
        %{kind: kind, eye: eye} when kind in [:player, :mob] -> target.y + eye - eye_y(self)
        %{height: h} -> target.y + h / 2.0 - eye_y(self)
      end

    sd = :math.sqrt(xd * xd + zd * zd)
    pitch = Mth.rotate_towards(self.pitch, Mth.pitch(yd, sd), x_max)
    yaw = Mth.rotate_towards(self.yaw, Mth.yaw(xd, zd), y_max)

    %{self | pitch: min(max(java_rem(pitch), -90.0), 90.0), yaw: yaw}
  end

  # `setXRot`'s `x % 360.0F` (the dividend's sign).
  defp java_rem(x), do: Valimc.Data.Float32.round(:math.fmod(x, 360.0))

  @doc "`isHolding(item)`: the item id in either hand."
  def holding?(%__MODULE__{mob: mob}, item),
    do:
      match?(%{item_id: ^item}, mob.equipment[:mainhand]) or
        match?(%{item_id: ^item}, mob.equipment[:offhand])

  @doc "`startUsingItem(hand)`: a held item, unless it uses one already."
  def start_using(%__MODULE__{mob: %{using: nil} = mob} = self, hand) do
    slot = if hand == :off_hand, do: :offhand, else: :mainhand
    if mob.equipment[slot], do: %{self | mob: %{mob | using: {hand, 0}}}, else: self
  end

  def start_using(self, _hand), do: self

  @doc "`stopUsingItem`."
  def stop_using(%__MODULE__{mob: mob} = self), do: %{self | mob: %{mob | using: nil}}

  @doc "`getTicksUsingItem` (0 when it uses nothing)."
  def ticks_using(%__MODULE__{mob: %{using: {_, ticks}}}), do: ticks
  def ticks_using(_self), do: 0

  @doc "`isUsingItem`."
  def using?(%__MODULE__{mob: mob}), do: mob.using != nil

  @haste Valimc.Data.EffectTypes.id("haste")
  @conduit Valimc.Data.EffectTypes.id("conduit_power")
  @fatigue Valimc.Data.EffectTypes.id("mining_fatigue")

  @doc """
  `LivingEntity.swing`: an arm swing (a `{:swing, hand}` effect) unless one
  is in its first half (`SwingState.startIfAble`); six ticks long, shorter
  with Haste or Conduit Power and longer with Mining Fatigue.
  """
  def swing(%__MODULE__{mind: mind} = self, hand \\ :main_hand) do
    case mind.swing do
      {duration, ticks} when ticks <= div(duration, 2) and ticks > 0 ->
        self

      _ ->
        self
        |> mind(&%{&1 | swing: {swing_duration(self.mob), 0}})
        |> effect({:swing, hand})
    end
  end

  defp swing_duration(%{living: %{effects: effects}}) do
    amplifier = fn id ->
      case effects[id] do
        [{_, amplifier, _, _, _} | _] -> amplifier
        _ -> nil
      end
    end

    case {amplifier.(@haste), amplifier.(@conduit), amplifier.(@fatigue)} do
      {nil, nil, nil} -> 6
      {nil, nil, fatigue} -> 6 + (1 + fatigue) * 2
      {haste, conduit, _} -> 6 - (1 + max(haste || 0, conduit || 0))
    end
  end

  defp swing_duration(_mob), do: 6

  @doc "`SwingState.tick` (each base tick): a swing past its length ends."
  def swing_tick({duration, ticks}) when ticks > duration, do: nil
  def swing_tick({duration, ticks}), do: {duration, ticks + 1}
  def swing_tick(nil), do: nil

  @doc "`JumpControl.jump`."
  def jump(self), do: mind(self, &%{&1 | jump: true})

  @doc "`LookControl.setLookAt(x, y, z, yMax, xMax)`."
  def look_at(self, {x, y, z}, y_max, x_max),
    do: mind(self, &%{&1 | look: %{x: x, y: y, z: z, y_max: y_max, x_max: x_max, cooldown: 2}})

  @doc "`LookControl.setLookAt(x, y, z)` at the mob's own head speed and pitch limit."
  def look_at(%__MODULE__{facts: facts} = self, point),
    do: look_at(self, point, facts.head_rot_speed, facts.max_head_x_rot)

  @doc "`isInWater` (the fluid the last move left)."
  def in_water?(%__MODULE__{mob: mob}), do: mob.motion.water > 0.0

  @doc "`isInLava`."
  def in_lava?(%__MODULE__{mob: mob}), do: mob.motion.lava > 0.0

  @doc "`isInLiquid`."
  def in_liquid?(self), do: in_water?(self) or in_lava?(self)

  @doc "`getFluidJumpThreshold`."
  def jump_threshold(%__MODULE__{eye: eye}), do: if(eye < 0.4, do: 0.0, else: 0.4)

  @doc "A mind for a fresh mob: its random seeded from its uuid."
  def fresh(uuid), do: %Mind{random: Random.new(uuid)}
end
