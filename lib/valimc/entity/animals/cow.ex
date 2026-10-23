defmodule Valimc.Entity.Animals.Cow do
  @moduledoc """
  A cow (`Cow`, `AbstractCow`): its goals, its temperature and sound
  variants (`Valimc.Entity.Animals.Variants`); milking is `interact/3`'s.
  """
  use Valimc.Entity.Animal, type: "minecraft:cow"
  alias Valimc.AI.Goals
  alias Valimc.Entity.Animal
  alias Valimc.Entity.Animals.{Interaction, Variants}

  @impl true
  def goals, do: goals("minecraft:cow")

  @doc "`AbstractCow.registerGoals` for a cow of `type` (a mooshroom's too)."
  def goals(type) do
    {[
       {0, "FloatGoal", Goals.Float, [:jump], %{}},
       {1, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(2.0)},
       {2, "BreedGoal", Goals.Breed, [:move, :look], Goals.Breed.new(1.0)},
       {3, "TemptGoal", Goals.Tempt, [:move, :look],
        Goals.Tempt.new(1.25, &Animal.food?(type, &1), false)},
       {4, "FollowParentGoal", Goals.FollowParent, [], Goals.FollowParent.new(1.25)},
       {5, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {6, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(6.0)},
       {7, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ], []}
  end

  @impl true
  def defaults, do: Variants.data()

  @impl true
  def fields(data), do: Variants.values("cow", data)

  @impl true
  def offspring(self, partner), do: Variants.offspring(self, partner)

  @impl true
  def spawn_part(self, _reason), do: Variants.finalize("cow", self)

  @impl true
  def properties(data), do: [{"minecraft:cow/variant", data.variant}]

  @impl true
  def ambient_sound(self), do: Animal.sound_id(Variants.sound("cow", self, "ambient"))

  # Its hurt and death sounds are its sound variant's.
  @impl true
  def sound(body, key), do: Variants.combat_sound("cow", body, key)

  @impl true
  def interact(body, request), do: milk(body, request)

  @bucket Valimc.Protocol.ItemTypes.id("minecraft:bucket")
  @milk_sound "minecraft:entity.cow.milk"

  @doc """
  `AbstractCow.mobInteract`: an adult cow (or mooshroom) fills a bucket with
  milk; the player hears its own milking, the others hear it at the player.
  """
  def milk(%{data: %{age: age}} = body, %{item: %Valimc.Protocol.ItemStack{item_id: @bucket}})
      when age >= 0 do
    {:ok, body,
     Interaction.outcome(
       hand: {:fill, Valimc.Protocol.ItemStack.new("minecraft:milk_bucket")},
       others: {Animal.sound_id(@milk_sound), "player", 1.0, 1.0, :player}
     )}
  end

  def milk(_body, _request), do: :pass
end
