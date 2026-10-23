defmodule Valimc.AI.Sensors do
  @moduledoc """
  Vanilla's brain sensors (VMC-041a2), each a `scan/1` over the mob that
  sets its memories, run by `Valimc.AI.Brain` at its scan rate:

  - `NearestLiving` (`NearestLivingEntitySensor`): living entities within
    the follow range, nearest first, and the visible ones among them, whose
    sight is tested once and cached until the next scan.
  - `Players` (`PlayerSensor`): players within the follow range, the nearest
    targetable and attackable ones.
  - `Items` (`NearestItemSensor`): the nearest item it wants, in sight,
    within 32 blocks.
  - `HurtBy` (`HurtBySensor`): the last damage within 40 ticks and who dealt it.
  - `Piglin` (`PiglinSpecificSensor`): the players it would attack (no gold
    armor) and those holding what it loves, adult piglins near and in sight.

  Visibility is `Sensor.isEntityTargetable`: non-combat targeting within
  the follow range, in sight.
  """
  alias Valimc.AI.{Brain, Self, World}

  @doc "`Sensor.isEntityTargetable(body, target)`."
  def targetable?(%Self{} = self, target) do
    invisible = Brain.get(self, :attack_target) != World.ref(target)
    conditions = World.conditions(false, range: follow(self), invisible: invisible)
    World.test(self, target, conditions)
  end

  @doc "`Sensor.isEntityAttackable(body, target)`."
  def attackable?(%Self{} = self, target) do
    invisible = Brain.get(self, :attack_target) != World.ref(target)
    conditions = World.conditions(true, range: follow(self), invisible: invisible)
    World.test(self, target, conditions)
  end

  defp follow(self), do: Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:follow_range")

  @doc """
  `NearestVisibleLivingEntities.findClosest`: the first of the memory's
  entities `filter` takes and the mob sees (its sight cached in the
  memory). `{entity | nil, self}`.
  """
  def visible_closest(self, filter) do
    case Brain.get(self, :nearest_visible_living_entities) do
      nil ->
        {nil, self}

      %{entities: refs} ->
        Enum.reduce_while(refs, {nil, self}, fn ref, {nil, self} ->
          case World.entity(self.world, ref) do
            nil ->
              {:cont, {nil, self}}

            entity ->
              if filter.(entity) do
                case visible?(self, entity) do
                  {true, self} -> {:halt, {entity, self}}
                  {false, self} -> {:cont, {nil, self}}
                end
              else
                {:cont, {nil, self}}
              end
          end
        end)
    end
  end

  @doc "`NearestVisibleLivingEntities.findAll` of every entity: `{entities, self}`."
  def visible_all(self) do
    case Brain.get(self, :nearest_visible_living_entities) do
      nil ->
        {[], self}

      %{entities: refs} ->
        {seen, self} =
          Enum.reduce(refs, {[], self}, fn ref, {acc, self} ->
            case World.entity(self.world, ref) do
              nil ->
                {acc, self}

              entity ->
                case visible?(self, entity) do
                  {true, self} -> {[entity | acc], self}
                  {false, self} -> {acc, self}
                end
            end
          end)

        {Enum.reverse(seen), self}
    end
  end

  @doc "`NearestVisibleLivingEntities.contains(entity)`."
  def visible_contains?(self, entity) do
    case Brain.get(self, :nearest_visible_living_entities) do
      %{entities: refs} ->
        if World.ref(entity) in refs, do: visible?(self, entity), else: {false, self}

      nil ->
        {false, self}
    end
  end

  # The memory's sight cache: tested once a scan.
  defp visible?(self, entity) do
    %{seen: seen} = memory = Brain.get(self, :nearest_visible_living_entities)
    ref = World.ref(entity)

    case seen do
      %{^ref => visible} ->
        {visible, self}

      _ ->
        {visible, self} = targetable?(self, entity)
        memory = %{memory | seen: Map.put(seen, ref, visible)}
        {visible, Brain.set(self, :nearest_visible_living_entities, memory)}
    end
  end

  defmodule NearestLiving do
    @moduledoc false
    def scan(%Self{world: world} = self) do
      follow = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:follow_range")
      box = World.inflate(Self.box(self), follow, follow, follow)

      living =
        (world.players ++ World.mob_list(world))
        |> Enum.filter(
          &(&1.uuid != self.uuid and &1.alive and World.intersects?(World.box(&1), box))
        )
        |> Enum.sort_by(&World.distance_sq(self, &1))
        |> Enum.map(&World.ref/1)

      self
      |> Brain.set(:nearest_living_entities, living)
      |> Brain.set(:nearest_visible_living_entities, %{entities: living, seen: %{}})
    end
  end

  defmodule Players do
    @moduledoc false
    alias Valimc.AI.Sensors

    def scan(%Self{world: world} = self) do
      follow = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:follow_range")

      players =
        world.players
        |> Enum.filter(&(&1.mode != :spectator and World.distance_sq(self, &1) < follow * follow))
        |> Enum.sort_by(&World.distance_sq(self, &1))

      {visible, self} =
        Enum.reduce(players, {[], self}, fn p, {acc, self} ->
          case Sensors.targetable?(self, p) do
            {true, self} -> {[p | acc], self}
            {false, self} -> {acc, self}
          end
        end)

      visible = Enum.reverse(visible)

      {attackable, self} =
        Enum.reduce(visible, {[], self}, fn p, {acc, self} ->
          case Sensors.attackable?(self, p) do
            {true, self} -> {[p | acc], self}
            {false, self} -> {acc, self}
          end
        end)

      attackable = Enum.reverse(attackable)

      self
      |> Brain.set(:nearest_players, Enum.map(players, &World.ref/1))
      |> Brain.set(:nearest_visible_player, World.ref(List.first(visible)))
      |> Brain.set(:nearest_visible_attackable_players, Enum.map(attackable, &World.ref/1))
      |> Brain.set(:nearest_visible_attackable_player, World.ref(List.first(attackable)))
    end
  end

  defmodule Items do
    @moduledoc false
    alias Valimc.AI.Brains.Piglin

    def scan(%Self{world: world} = self) do
      box = World.inflate(Self.box(self), 32.0, 16.0, 32.0)

      wanted =
        world.items
        |> Enum.filter(&(&1.count > 0 and World.intersects?(World.box(&1), box)))
        |> Enum.sort_by(&World.distance_sq(self, &1))
        |> Enum.find(fn item ->
          Piglin.wants?(self, item) and World.distance_sq(self, item) < 1024.0 and
            World.line_of_sight?(self, item)
        end)

      Brain.set(self, :nearest_visible_wanted_item, World.ref(wanted))
    end
  end

  defmodule HurtBy do
    @moduledoc false
    def scan(%Self{mind: mind} = self) do
      self =
        case mind.damage do
          {type, tick, attacker} when mind.tick - tick <= 40 ->
            self = Brain.set(self, :hurt_by, type)
            if attacker, do: Brain.set(self, :hurt_by_entity, attacker), else: self

          _ ->
            Brain.erase(self, :hurt_by)
        end

      case Brain.get(self, :hurt_by_entity) do
        nil ->
          self

        ref ->
          case World.entity(self.world, ref) do
            %{alive: true} -> self
            _ -> Brain.erase(self, :hurt_by_entity)
          end
      end
    end
  end
end
