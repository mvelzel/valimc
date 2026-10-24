defmodule Valimc.AI.Mobs.Squid do
  @moduledoc """
  Squid and glow squid (`Squid`, `GlowSquid`). A squid moves only by its
  motion: its tentacles beat on a cycle, and late in each stroke in water it
  takes its movement vector (a random heading from `SquidRandomMovementGoal`,
  or away from what hurt it, `SquidFleeGoal`), otherwise slowing by a
  tenth; its body turns toward its motion. Out of water it falls and drifts
  only down, and loses air like a fish. Hurt by a living thing it squirts
  ink. A glow squid darkens for five seconds when hurt, and draws its glow
  particle's place every tick.

  Its tentacle cycle, rotations and movement vector are its own state
  (`Mind.own`, unsaved as in vanilla).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Facts, Random, Self, World}
  alias Valimc.Data.{BlockFacts, Float32}

  @squid "minecraft:squid"
  @glow "minecraft:glow_squid"
  @pi Float32.round(:math.pi())
  @two_pi Float32.round(:math.pi() * 2)
  @deg 57.2957763671875
  @f &Float32.round/1

  @impl true
  def types, do: [@squid, @glow]

  @doc "A dying one still runs its own tick (it flops)."
  @impl true
  def dying?, do: true

  @impl true
  def goals(_type),
    do:
      {[
         {0, "SquidRandomMovementGoal", __MODULE__.RandomMovement, [], %{}},
         {1, "SquidFleeGoal", __MODULE__.Flee, [], %{ticks: 0}}
       ], []}

  @impl true
  def motion, do: [fluid_pushed: false, travel: {:squid, false}, emission: :events]

  @impl true
  def data(@glow), do: Map.put(Valimc.Entity.Animal.ageable_data(), :dark, 0)
  def data(_type), do: Valimc.Entity.Animal.ageable_data()

  @impl true
  def values(%{type: type, data: data}) do
    baby = [{:ageable_baby, data.age < 0, false}, {:age_locked, data.age_locked, false}]
    if type == @glow, do: baby ++ [{:glow_squid_dark_ticks, data.dark, 0}], else: baby
  end

  @impl true
  def dimensions(%{type: type, data: %{age: age}}) when age < 0,
    do: Valimc.Entity.Animal.water_ageable(type).baby

  def dimensions(_body), do: nil

  @impl true
  def voice(_type, data), do: Valimc.Entity.Animal.voice(data)

  @impl true
  defdelegate air(air, in_water), to: Valimc.AI.Mobs.Fish

  @doc "Its own state: the tentacle cycle, rotations and movement vector."
  def own(%{own: %{tentacle: _} = own}), do: own

  def own(_mind) do
    # Drawn in vanilla's constructor, before the random a mob is given here.
    speed = @f.(@f.(1.0 / @f.(@f.(:rand.uniform()) + 1.0)) * @f.(0.2))

    %{
      tentacle: 0.0,
      tentacle_speed: speed,
      rotate_speed: 0.0,
      x_rot: 0.0,
      z_rot: 0.0,
      movement: {0.0, 0.0, 0.0},
      in_water: false
    }
  end

  @doc "Change its own state."
  def put(self, changes), do: Self.mind(self, &%{&1 | own: Map.merge(own(&1), changes)})

  # `wasTouchingWater` as its tick began, for its `aiStep` after the move.
  @impl true
  def before_ai(self), do: put(self, %{in_water: Self.in_water?(self)})

  @doc """
  `Squid.aiStep` after its super (and `AgeableMob`'s ageing): the tentacle
  cycle, the stroke's motion, the body's turn; a glow squid's dark ticks and
  glow particle draws.
  """
  @impl true
  def after_ai(%Self{} = self) do
    self = Valimc.Entity.Animal.settle_ageable(self)
    o = own(self.mind)
    tentacle = @f.(o.tentacle + o.tentacle_speed)

    {tentacle, speed, self} =
      if tentacle > :math.pi() * 2 do
        tentacle = @f.(tentacle - @two_pi)
        {n, self} = Self.int(self, 10)

        {speed, self} =
          if n == 0 do
            {f, self} = Self.float(self)
            {@f.(@f.(1.0 / @f.(f + 1.0)) * @f.(0.2)), self}
          else
            {o.tentacle_speed, self}
          end

        {tentacle, speed, Self.effect(self, {:event, 19})}
      else
        {tentacle, o.tentacle_speed, self}
      end

    o = %{o | tentacle: tentacle, tentacle_speed: speed}

    {o, self} =
      if o.in_water, do: stroke(o, self), else: fall(o, self)

    self = put(self, o)
    if self.type == @glow, do: glow(self), else: self
  end

  defp stroke(o, self) do
    {o, self} =
      if o.tentacle < @pi do
        scale = @f.(o.tentacle / @pi)

        if scale > 0.75,
          do: {%{o | rotate_speed: 1.0}, %{self | velocity: o.movement}},
          else: {%{o | rotate_speed: @f.(o.rotate_speed * @f.(0.8))}, self}
      else
        {vx, vy, vz} = self.velocity

        {%{o | rotate_speed: @f.(o.rotate_speed * @f.(0.99))},
         %{self | velocity: {vx * 0.9, vy * 0.9, vz * 0.9}}}
      end

    {mx, my, mz} = self.velocity
    horizontal = :math.sqrt(mx * mx + mz * mz)
    body = self.mind.body_yaw
    turn = @f.(@f.(-@f.(Valimc.AI.Mth.atan2(mx, mz)) * @f.(@deg)) - body)
    body = @f.(body + @f.(turn * @f.(0.1)))
    z_rot = @f.(o.z_rot + @f.(@f.(@pi * o.rotate_speed) * @f.(1.5)))
    pitch = @f.(@f.(-@f.(Valimc.AI.Mth.atan2(horizontal, my)) * @f.(@deg)) - o.x_rot)
    x_rot = @f.(o.x_rot + @f.(pitch * @f.(0.1)))
    self = Self.mind(%{self | yaw: body}, &%{&1 | body_yaw: body})
    {%{o | z_rot: z_rot, x_rot: x_rot}, self}
  end

  # Out of water it only falls (or rises with Levitation), by its air drag.
  defp fall(o, self) do
    {_, vy, _} = self.velocity

    levitation =
      Valimc.Living.Attributes.amplifier(
        self.mob.living.effects,
        Valimc.Data.EffectTypes.id("levitation")
      )

    yd =
      if levitation,
        do: 0.05 * (levitation + 1),
        else: vy - Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:gravity")

    modifier = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:air_drag_modifier")
    drag = @f.(min(1.0, max(0.0, @f.(1.0 - @f.(@f.(1.0 - @f.(0.98)) * @f.(modifier))))))
    x_rot = @f.(o.x_rot + @f.(@f.(-90.0 - o.x_rot) * @f.(0.02)))
    {%{o | x_rot: x_rot}, %{self | velocity: {0.0, yd * drag, 0.0}}}
  end

  # `GlowSquid.aiStep`: its dark ticks run out; its glow particle's place is
  # drawn (`getRandomX`, `getRandomY`, `getRandomZ`) though the server
  # shows nothing.
  defp glow(%Self{data: data} = self) do
    self = if data.dark > 0, do: %{self | data: %{data | dark: data.dark - 1}}, else: self
    {_, self} = Self.double(self)
    {_, self} = Self.double(self)
    {_, self} = Self.double(self)
    self
  end

  # ---- its hurts

  @doc """
  `Squid.hurtServer`: hurt by a living thing it squirts ink, its squirt
  sound and thirty ink particles below and behind it (`{body, events}`); a
  glow squid darkens for 100 ticks.
  """
  @impl true
  def hurt(%{type: type, mob: %{ai: %Valimc.AI.Mind{} = mind} = mob} = body, _hit) do
    body = if type == @glow, do: %{body | data: %{body.data | dark: 100}}, else: body

    if mind.hurt_by == nil do
      body
    else
      squirt =
        if type == @glow,
          do: "minecraft:entity.glow_squid.squirt",
          else: "minecraft:entity.squid.squirt"

      {pitch, mind} = Valimc.AI.voice(mind, nil)
      sound = {:sound, Facts.sound_id(squirt), "neutral", Facts.mob(type).volume, pitch, seed()}
      o = own(mind)
      ink = if type == @glow, do: "minecraft:glow_squid_ink", else: "minecraft:squid_ink"
      scale = if body.data.age < 0, do: @f.(0.1), else: @f.(0.3)
      rotate = rotation(o.x_rot, mind.body_yaw)

      {particles, random} =
        Enum.map_reduce(1..30, mind.random, fn _, r ->
          {a, r} = Random.float(r)
          {b, r} = Random.float(r)
          {c, r} = Random.float(r)
          {dx, dy, dz} = rotate.({a * 0.6 - 0.3, -1.0, b * 0.6 - 0.3})
          k = @f.(scale + @f.(c * 2.0))

          {{:particles, ink, {:at, rotate.({0.0, -1.0, 0.0}), 0.5}, {dx * k, dy * k, dz * k}, 0.1,
            0}, r}
        end)

      {%{body | mob: %{mob | ai: %{mind | random: random}}}, [sound | particles]}
    end
  end

  def hurt(body, _hit), do: body

  # `rotateVector`: about x by its body pitch, then y by its body yaw.
  defp rotation(x_rot, body_yaw) do
    {xs, xc} = {:math.sin(x_rot * :math.pi() / 180), :math.cos(x_rot * :math.pi() / 180)}
    {ys, yc} = {:math.sin(-body_yaw * :math.pi() / 180), :math.cos(-body_yaw * :math.pi() / 180)}

    fn {x, y, z} ->
      {y1, z1} = {y * xc + z * xs, z * xc - y * xs}
      {x * yc + z1 * ys, y1, z1 * yc - x * ys}
    end
  end

  defp seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end

  @doc "Whether a block holds water or is air (`SquidFleeGoal`'s test)."
  def fleeable(world, cell) do
    case World.block(world, cell) do
      nil ->
        :no

      state ->
        cond do
          BlockFacts.air?(state) -> :air
          BlockFacts.fluid(state).kind == :water -> :water
          true -> :no
        end
    end
  end

  @doc "`hasMovementVector`."
  def moving?({x, y, z}), do: x * x + y * y + z * z > @f.(1.0e-5)
end

defmodule Valimc.AI.Mobs.Squid.RandomMovement do
  @moduledoc """
  `SquidRandomMovementGoal`: always running; idle for over 100 ticks the
  squid stops, else now and then (one update in 25), or when out of water
  or without one, it picks a new heading: a fifth of a block a tick
  around, a tenth up or down.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Squid
  alias Valimc.Data.Float32

  @two_pi Float32.round(:math.pi() * 2)

  def can_use(state, self), do: {true, state, self}

  def tick(state, self) do
    own = Squid.own(self.mind)

    cond do
      self.mind.no_action > 100 ->
        {state, Squid.put(self, %{movement: {0.0, 0.0, 0.0}})}

      true ->
        {n, self} = Self.int(self, Mth.reduced(50))

        if n == 0 or not own.in_water or not Squid.moving?(own.movement) do
          {a, self} = Self.float(self)
          angle = Float32.round(a * @two_pi)
          {b, self} = Self.float(self)
          f = &Float32.round/1
          x = f.(Valimc.Data.Mth.cos(angle) * f.(0.2))
          y = f.(f.(-0.1) + f.(b * f.(0.2)))
          z = f.(Valimc.Data.Mth.sin(angle) * f.(0.2))
          {state, Squid.put(self, %{movement: {x, y, z}})}
        else
          {state, self}
        end
    end
  end
end

defmodule Valimc.AI.Mobs.Squid.Flee do
  @moduledoc """
  `SquidFleeGoal`: in water, within ten blocks of what last hurt it, the
  squid heads away from it every tick, faster the closer it is (vanilla
  leaves the heading unnormalized), flat where the way is air.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Mobs.Squid

  def can_use(state, self) do
    case attacker(self) do
      nil -> {false, state, self}
      a -> {Squid.own(self.mind).in_water and World.distance_sq(self, a) < 100.0, state, self}
    end
  end

  defp attacker(%Self{mind: %{hurt_by: {ref, _}}} = self), do: World.entity(self.world, ref)
  defp attacker(_self), do: nil

  def start(state, self), do: {%{state | ticks: 0}, self}

  def every_tick?(_state), do: true

  def tick(state, self) do
    state = %{state | ticks: state.ticks + 1}

    case attacker(self) do
      nil ->
        {state, self}

      a ->
        flee = {self.x - a.x, self.y - a.y, self.z - a.z}
        {fx, fy, fz} = flee
        cell = Mth.block({self.x + fx, self.y + fy, self.z + fz})

        case Squid.fleeable(self.world, cell) do
          :no ->
            {state, self}

          way ->
            length = :math.sqrt(fx * fx + fy * fy + fz * fz)

            {fx, fy, fz} =
              if length > 0.0 do
                speed = if length > 5.0, do: 3.0 - (length - 5.0) / 5.0, else: 3.0
                if speed > 0.0, do: {fx * speed, fy * speed, fz * speed}, else: flee
              else
                flee
              end

            fy = if way == :air, do: fy - fy, else: fy
            {state, Squid.put(self, %{movement: {fx / 20.0, fy / 20.0, fz / 20.0}})}
        end
    end
  end
end
