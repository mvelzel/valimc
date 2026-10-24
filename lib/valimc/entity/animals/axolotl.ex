defmodule Valimc.Entity.Animals.Axolotl do
  @moduledoc """
  An axolotl (`Axolotl`): an amphibious animal with a brain
  (`Valimc.AI.Brains.Axolotl`). It swims by the smooth swimming controls
  (in water a tenth of its speed, on land half), travels in water at its
  own speed with 0.9 drag, and dries out on land (6000 ticks of air; water
  or rain refills it, then it is hurt by drying out). Hurt in water it may
  play dead (`playing_dead`): its controls stop and enemies no longer see
  it. Its variant (lucy, wild, gold, cyan; blue one in 1200 born) comes with
  its spawn; it is fed tropical fish (in a bucket).
  """
  use Valimc.Entity.Animal, type: "minecraft:axolotl"
  alias Valimc.AI.{Brain, Self, SmoothSwimming}
  alias Valimc.Data.Float32

  @type_name "minecraft:axolotl"
  @commons [0, 1, 2, 3]
  def common_variants, do: @commons
  @blue 4
  @controls %{max_x: 85.0, max_y: 10.0, in_water: 0.1, out: 0.5, gravity: false}

  @impl true
  def goals, do: {[], []}

  @doc "Its brain."
  @impl true
  def brain, do: Valimc.AI.Brains.Axolotl

  @impl true
  def defaults, do: %{variant: 0, playing_dead: false, from_bucket: false}

  @doc "`Axolotl.finalizeSpawn` returns immediately for a bucket release."
  @impl Valimc.AI.Kind
  def finalize(self, :bucket), do: self
  def finalize(self, reason), do: super(self, reason)

  @impl true
  def fields(data),
    do: [
      {:axolotl_variant, data.variant, 0},
      {:axolotl_playing_dead, data.playing_dead, false},
      {:axolotl_from_bucket, data.from_bucket, false}
    ]

  @impl true
  def properties(data),
    do: [{"minecraft:axolotl/variant", Enum.at(~w(lucy wild gold cyan blue), data.variant)}]

  @doc """
  `getBreedOffspring`: a blue one time in 1200, else either parent's
  variant. (The child's `setPersistenceRequired` is not kept yet.)
  """
  @impl true
  def offspring(%Self{} = self, partner) do
    {n, self} = Self.int(self, 1200)

    if n == 0 do
      {_, self} = Self.int(self, 1)
      {%{variant: @blue}, self}
    else
      {mine, self} = Self.boolean(self)
      {%{variant: if(mine, do: self.data.variant, else: partner.data.variant)}, self}
    end
  end

  @doc """
  `finalizeSpawn`: two common variants for its group, one of them its own
  (each from the level's random). (A group's later babies come with group
  data ValiMC's spawns do not keep.)
  """
  @impl true
  def spawn_part(%Self{} = self, _reason) do
    {a, self} = Valimc.AI.Spawn.level_int(self, length(@commons))
    {b, self} = Valimc.AI.Spawn.level_int(self, length(@commons))
    {i, self} = Valimc.AI.Spawn.level_int(self, 2)

    %{
      self
      | data: %{self.data | variant: Enum.at([Enum.at(@commons, a), Enum.at(@commons, b)], i)}
    }
  end

  # ---- its controls

  @impl true
  def navigation, do: {:amphibious, []}

  @impl true
  # Its travel when its AI does not choose one (dead, `NoAI`).
  def motion, do: [fluid_pushed: false, travel: {:dolphin, false}]

  @impl true
  def swim_sound, do: "minecraft:entity.axolotl.swim"

  @impl true
  def max_air, do: 6000

  @doc "`AxolotlMoveControl`: smooth swimming, held while it plays dead."
  @impl true
  def move_control(%Self{data: %{playing_dead: true}, mob: mob} = self),
    do: travel(%{self | mob: %{mob | motion: %{mob.motion | set: :hold}}})

  def move_control(self), do: self |> SmoothSwimming.move(@controls) |> travel()

  # `travelInWater`: at its speed, 0.9 drag, no sinking.
  defp travel(%Self{mob: mob} = self),
    do: %{self | mob: %{mob | motion: %{mob.motion | travel: {:dolphin, false}}}}

  @doc "`AxolotlLookControl`: smooth swimming (20), still while it plays dead."
  @impl true
  def look_control(%Self{data: %{playing_dead: true}} = self), do: self
  def look_control(self), do: SmoothSwimming.look(self, 20.0)

  @doc "`customServerAiStep` is its brain's (no animal love reset)."
  @impl true
  def custom_step(self), do: self

  # ---- air

  @doc "`isInWaterOrRain`."
  @impl true
  def wet?(%Self{world: world} = self) do
    Self.in_water?(self) or
      (world.rain != nil and world.rain.({self.x, self.y, self.z}, self.y + self.height))
  end

  @doc """
  `Axolotl.handleAirSupply`: wet, full; dry, a tick less, then hurt by
  drying out at -20.
  """
  @impl true
  def air(_air, true), do: {6000, 0.0}
  def air(air, false) when air - 1 <= -20, do: {0, 2.0}
  def air(air, false), do: {air - 1, 0.0}

  # ---- hurts

  @doc "`canBeSeenAsEnemy`: not while playing dead."
  @impl true
  def hidden?(%{data: data}), do: data.playing_dead

  @doc """
  `Axolotl.hurtServer` before its super: in water, hit by something, one
  time in three (with a hit greater than a draw of 0 to 2, or below half
  its health) and surviving it, it plays dead for 200 ticks.
  """
  @impl true
  def before_hurt(%{mob: %{ai: %Valimc.AI.Mind{} = mind} = mob} = body, hit) do
    if mob.no_ai do
      body
    else
      self = %Self{type: @type_name, mob: mob, mind: mind, data: body.data}
      {a, self} = Self.int(self, 3)

      {dies?, self} =
        if a == 0 do
          health = mob.living.health.value
          max = Valimc.Entity.Mob.value(@type_name, mob, "minecraft:max_health")
          {b, self} = Self.int(self, 3)

          plays =
            (b < hit.amount or Float32.round(health / max) < 0.5) and hit.amount < health and
              mob.motion.water > 0.0 and (hit[:attacker] != nil or hit[:direct] != nil) and
              not body.data.playing_dead

          {plays, self}
        else
          {false, self}
        end

      self = if dies?, do: Brain.set(self, :play_dead_ticks, 200), else: self
      %{body | mob: %{mob | ai: self.mind}}
    end
  end

  def before_hurt(body, _hit), do: body

  @doc "`playAttackSound`."
  @impl true
  def hit(self, _target), do: Valimc.AI.play(self, "minecraft:entity.axolotl.attack")
end
