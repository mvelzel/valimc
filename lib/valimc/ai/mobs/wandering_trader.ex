defmodule Valimc.AI.Mobs.WanderingTrader do
  @moduledoc """
  `WanderingTrader` (VMC-044a4): it drinks a potion of invisibility when it
  is dark and it is not invisible, and milk when it is bright and it is
  (`UseItemGoal`, with their sounds), flees zombies and illagers, panics
  when hurt, walks to its wander target and back toward its home, strolls
  and looks at players and mobs. Its despawn delay counts down and it goes
  when it runs out. It offers no trades yet (VMC-044), so its trading goals
  never start.

  Its own data: the despawn delay, the wander target, whether it shows as
  invisible (`isInvisible`, which vanilla updates as its data syncs after
  the tick), its unhappy counter and age. Its home is its mob's (`Mob.home`).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Self, World}
  alias Valimc.Data.Float32
  alias Valimc.Protocol.{ItemStack, ItemTypes, PotionContents}

  @type_name "minecraft:wandering_trader"
  @invisibility Valimc.Data.EffectTypes.id("invisibility")
  # `Zombie.class` (husks, drowned, zombie villagers and zombified piglins
  # are zombies) and the illagers and zoglins it flees.
  @zombies ~w(minecraft:zombie minecraft:husk minecraft:drowned minecraft:zombie_villager minecraft:zombified_piglin)
  @flees [
    {@zombies, 8.0},
    {["minecraft:evoker"], 12.0},
    {["minecraft:vindicator"], 8.0},
    {["minecraft:vex"], 8.0},
    {["minecraft:pillager"], 15.0},
    {["minecraft:illusioner"], 12.0},
    {["minecraft:zoglin"], 10.0}
  ]

  @impl true
  def types, do: [@type_name]

  @impl true
  def goals(_type) do
    potion = %{
      ItemStack.new("minecraft:potion")
      | components: %{
          "minecraft:potion_contents" => %{
            PotionContents.empty()
            | potion: Valimc.Data.PotionTypes.id("minecraft:invisibility")
          }
        }
    }

    milk = ItemStack.new("minecraft:milk_bucket")

    avoid =
      for {types, distance} <- @flees do
        {1, "AvoidEntityGoal", Goals.AvoidEntity, [:move],
         Goals.AvoidEntity.new(&(&1.kind == :mob and &1.type in types), distance, 0.5, 0.5)}
      end

    {[
       {0, "FloatGoal", Goals.Float, [:jump], %{}},
       {0, "UseItemGoal", Goals.UseItem, [],
        Goals.UseItem.new(potion, "minecraft:entity.wandering_trader.disappeared", &dark_seen?/1)},
       {0, "UseItemGoal", Goals.UseItem, [],
        Goals.UseItem.new(milk, "minecraft:entity.wandering_trader.reappeared", &bright_unseen?/1)},
       {1, "TradeWithPlayerGoal", Goals.Idle, [:move, :jump],
        Goals.Idle.new("TradeWithPlayerGoal")}
     ] ++
       avoid ++
       [
         {1, "PanicGoal", Goals.Panic, [:move], Goals.Panic.new(0.5)},
         {1, "LookAtTradingPlayerGoal", Goals.Idle, [:look],
          Goals.Idle.new("LookAtTradingPlayerGoal")},
         {2, "WanderToPositionGoal", __MODULE__.WanderToPosition, [:move],
          __MODULE__.WanderToPosition.new(2.0, 0.35)},
         {4, "MoveTowardsRestrictionGoal", Goals.MoveTowardsRestriction, [:move],
          Goals.MoveTowardsRestriction.new(0.35)},
         {8, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
          Goals.RandomStroll.new(0.35, water_avoiding: true)},
         {9, "InteractGoal", Goals.LookAtPlayer, [:move, :look],
          Goals.LookAtPlayer.new(3.0, Float32.round(1.0))},
         {10, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look],
          Goals.LookAtPlayer.new(8.0, 0.02, types: fn _ -> true end)}
       ], []}
  end

  # `isDarkOutside` and not invisible; `isBrightOutside` and invisible.
  defp dark_seen?(%Self{} = self), do: dark?(self.world) and not self.data.invisible
  defp bright_unseen?(%Self{} = self), do: self.world.bright and self.data.invisible

  defp dark?(%World{} = world),
    do: not world.bright and not Valimc.Data.SleepFacts.dimension(world.dimension).fixed_time

  @impl true
  def data(_type),
    do: %{despawn_delay: 0, wander_target: nil, invisible: false, unhappy: 0, age: 0}

  @impl true
  def values(%{data: data}),
    do: [
      {:ageable_baby, data.age < 0, false},
      {:villager_unhappy, data.unhappy, 0}
    ]

  @doc "`getConsumeSound`: its own drinking sounds."
  @impl true
  def consume_sound(_self, %ItemStack{item_id: id}) do
    if id == ItemTypes.id("minecraft:milk_bucket"),
      do: "minecraft:entity.wandering_trader.drink_milk",
      else: "minecraft:entity.wandering_trader.drink_potion"
  end

  @doc """
  `WanderingTrader.aiStep` after its super (`maybeDespawn`): its despawn
  delay counts down, and it goes as it reaches 0.
  """
  @impl true
  def after_ai(%Self{data: %{despawn_delay: delay} = data} = self) when delay > 0 do
    self = %{self | data: %{data | despawn_delay: delay - 1}}
    if delay - 1 == 0, do: Self.effect(self, :discard), else: self
  end

  def after_ai(self), do: self

  @doc "`updateInvisibilityStatus` as its data syncs after the tick."
  @impl true
  def after_tick(%Self{data: data, mob: mob} = self),
    do: %{self | data: %{data | invisible: Map.has_key?(mob.living.effects, @invisibility)}}

  # `canBeLeashed`: an `AbstractVillager` is not.
  @impl true
  def leashable?, do: false
end

defmodule Valimc.AI.Mobs.WanderingTrader.WanderToPosition do
  @moduledoc """
  `WanderingTrader.WanderToPositionGoal`: while its wander target is
  farther than `stop` from it, each time its navigation is done it walks to
  it, or ten blocks its way while it is more than ten away; stopping
  forgets the target.
  """
  use Valimc.AI.Goal

  def new(stop, speed), do: %{stop: stop * 1.0, speed: speed * 1.0}

  def can_use(state, %Self{data: %{wander_target: target}} = self),
    do: {target != nil and far?(self, target, state.stop), state, self}

  def stop(state, %Self{data: data} = self),
    do: {state, Navigation.stop(%{self | data: %{data | wander_target: nil}})}

  def tick(state, %Self{data: %{wander_target: {tx, ty, tz} = target}} = self) do
    if Navigation.done?(self.mind.navigation) do
      to =
        if far?(self, target, 10.0) do
          {dx, dy, dz} = {tx - self.x, ty - self.y, tz - self.z}
          length = :math.sqrt(dx * dx + dy * dy + dz * dz)

          {dx, dy, dz} =
            if length < 1.0e-5, do: {0.0, 0.0, 0.0}, else: {dx / length, dy / length, dz / length}

          {dx * 10.0 + self.x, dy * 10.0 + self.y, dz * 10.0 + self.z}
        else
          {tx * 1.0, ty * 1.0, tz * 1.0}
        end

      {_, self} = Navigation.move_to(self, to, state.speed)
      {state, self}
    else
      {state, self}
    end
  end

  def tick(state, self), do: {state, self}

  # `!pos.closerToCenterThan(position, distance)`.
  defp far?(self, {x, y, z}, distance) do
    {dx, dy, dz} = {x + 0.5 - self.x, y + 0.5 - self.y, z + 0.5 - self.z}
    dx * dx + dy * dy + dz * dz >= distance * distance
  end
end
