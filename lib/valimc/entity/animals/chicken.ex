defmodule Valimc.Entity.Animals.Chicken do
  @moduledoc """
  A chicken (`Chicken`): its goals, its temperature and sound variants
  (`Valimc.Entity.Animals.Variants`, a chick's own sounds), its slow fall
  (falling, it keeps 0.6 of its downward speed each tick), whether it is a
  jockey's (`IsChickenJockey`) and the ticks before it lays (`EggLayTime`,
  6,000 to 11,999).
  """
  use Valimc.Entity.Animal, type: "minecraft:chicken"
  alias Valimc.AI.{Goals, Self}
  alias Valimc.Data.Float32
  alias Valimc.Entity.Animal
  alias Valimc.Entity.Animals.Variants

  @impl true
  def goals do
    {[
       {0, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.4)},
       {2, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(1.0)},
       {3, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.0, &Animal.food?("minecraft:chicken", &1), false)},
       {4, "FollowParentGoal", Goals.FollowParent, [], Goals.FollowParent.new(1.1)},
       {5, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {6, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(6.0)},
       {7, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ], []}
  end

  # The constructor's `random.nextInt(6000) + 6000`, from a random vanilla
  # never seeds.
  @impl true
  def defaults,
    do: Map.merge(Variants.data(), %{egg_time: 5999 + :rand.uniform(6000), jockey: false})

  @impl true
  def fields(data), do: Variants.values("chicken", data)

  @impl true
  def offspring(self, partner), do: Variants.offspring(self, partner)

  @impl true
  def spawn_part(self, _reason), do: Variants.finalize("chicken", self)

  @impl true
  def properties(data), do: [{"minecraft:chicken/variant", data.variant}]

  @impl true
  def ambient_sound(self), do: Animal.sound_id(Variants.sound("chicken", self, "ambient"))

  # Its hurt and death sounds are its sound variant's.
  @impl true
  def sound(body, key), do: Variants.combat_sound("chicken", body, key)

  # `Chicken.aiStep` after the move: a falling chicken slows; a living hen
  # (not a chick, not a jockey's) lays when its time runs out.
  @impl true
  def settle(%Self{} = self), do: self |> slow_fall() |> lay()

  defp slow_fall(%Self{on_ground: false, velocity: {x, y, z}} = self) when y < 0.0,
    do: %{self | velocity: {x, y * 0.6, z}}

  defp slow_fall(self), do: self

  @egg_sound "minecraft:entity.chicken.egg"

  # `dropFromGiftLootTable(CHICKEN_LAY)` (the owner drops the variant's egg,
  # `{:lay}`; its item's launch draws on the level's random), the egg sound
  # and the next egg's time.
  defp lay(%Self{data: %{jockey: false, age: age} = data} = self) when age >= 0 do
    if data.egg_time - 1 <= 0 do
      {[a, b], world} = level_doubles(self.world)
      self = %{self | world: world}
      self = Self.effect(self, {:lay, {a * 0.2 - 0.1, 0.2, b * 0.2 - 0.1}})
      {f, self} = Self.float(self)
      {g, self} = Self.float(self)
      pitch = Float32.round(Float32.round(Float32.round(f - g) * Float32.round(0.2)) + 1.0)
      <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
      source = Valimc.Protocol.CombatPackets.mob_sounds("minecraft:chicken")["sound_source"]
      self = Self.effect(self, {:sound, Animal.sound_id(@egg_sound), source, 1.0, pitch, seed})
      {n, self} = Self.int(self, 6000)
      %{self | data: %{self.data | egg_time: n + 6000}}
    else
      %{self | data: %{data | egg_time: data.egg_time - 1}}
    end
  end

  defp lay(self), do: self

  defp level_doubles(world) do
    {a, random} = Valimc.AI.Random.double(world.random)
    {b, random} = Valimc.AI.Random.double(random)
    {[a, b], %{world | random: random}}
  end
end
