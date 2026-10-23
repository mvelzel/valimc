defmodule Valimc.Entity.Animals.Pig do
  @moduledoc """
  A pig (`Pig`): its goals (a carrot on a stick tempts it too), its
  temperature and sound variants (`Valimc.Entity.Animals.Variants`, a
  baby's own sounds). Saddles and riding are VMC-046's.
  """
  use Valimc.Entity.Animal, type: "minecraft:pig"
  alias Valimc.AI.Goals
  alias Valimc.Entity.Animal
  alias Valimc.Entity.Animals.Variants
  alias Valimc.Protocol.ItemTypes

  @carrot_on_a_stick ItemTypes.id("minecraft:carrot_on_a_stick")

  @impl true
  def goals do
    {[
       {0, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(1.25)},
       {3, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(1.0)},
       {4, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.2, &(&1 == @carrot_on_a_stick), false)},
       {4, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.2, &Animal.food?("minecraft:pig", &1), false)},
       {5, "FollowParentGoal", Goals.FollowParent, [], Goals.FollowParent.new(1.1)},
       {6, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {7, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(6.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ], []}
  end

  @impl true
  def defaults, do: Variants.data()

  @impl true
  def fields(data), do: Variants.values("pig", data)

  @impl true
  def offspring(self, partner), do: Variants.offspring(self, partner)

  @impl true
  def spawn_part(self, _reason), do: Variants.finalize("pig", self)

  @impl true
  def properties(data), do: [{"minecraft:pig/variant", data.variant}]

  @impl true
  def ambient_sound(self), do: Animal.sound_id(Variants.sound("pig", self, "ambient"))

  # Its hurt and death sounds are its sound variant's.
  @impl true
  def sound(body, key), do: Variants.combat_sound("pig", body, key)
end
