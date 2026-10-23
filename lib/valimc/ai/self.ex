defmodule Valimc.AI.Self do
  @moduledoc """
  One mob as its AI sees and changes it during its tick: its identity and
  type, position, rotations and ground flag, its `Entity.Mob` (living state,
  equipment, attributes, travel state), its mind, its type's AI facts and
  what the owner lets it read (`Valimc.AI.World`). Goals take and return
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
    :mob,
    :mind,
    :facts,
    :width,
    :height,
    :eye,
    :world,
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

  @doc "`nextInt(bound)` of the mob's random."
  def int(self, bound), do: draw(self, &Random.int(&1, bound))
  @doc "`nextFloat()` of the mob's random."
  def float(self), do: draw(self, &Random.float/1)
  @doc "`nextDouble()` of the mob's random."
  def double(self), do: draw(self, &Random.double/1)

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
  through the type's own override when it has one (`Mobs.on_target/1`: a
  zombified piglin draws its anger sound and alert delays).
  """
  def set_target(%__MODULE__{type: type} = self, target) do
    case Valimc.AI.Mobs.on_target(type) do
      nil -> put_target(self, target)
      module -> module.set_target(self, target)
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
