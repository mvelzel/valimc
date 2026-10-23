defmodule Valimc.AI.Brains.Axolotl do
  @moduledoc """
  An axolotl's brain (`AxolotlAi`, VMC-043e): its sensors and its core,
  idle, fight and play-dead activities with vanilla's behaviours in
  vanilla's order.

  - **Core:** the look and walk sinks; counting down playing dead (back to
    idle when it ends) and the temptation cooldown.
  - **Idle:** now and then looking at a player within six blocks; breeding
    with an axolotl in love (`AnimalMakeLove`); following a player holding
    its food, or (a baby) an adult (one at random); hunting what it may
    attack; finding water within six blocks on land; and with no walk
    target, swimming (in water) or strolling (on land) at random or walking
    to what it looks at.
  - **Fight:** dropping a target it can no longer attack (a player who
    killed it nearby gets Regeneration and loses Mining Fatigue),
    approaching and biting it every 20 ticks; breeding ends it.
  - **Play dead:** hurt in water, it may lie still for 200 ticks with
    Regeneration, unless it breeds.

  Leaving a fight starts a two-minute hunting cooldown. Its sensors: the
  living entities near it, the nearest adult axolotl, who hurt it, what it
  may attack (an always-hostile type in water within eight blocks, or a
  hunt target off cooldown) and a player tempting it with food.
  """
  alias Valimc.AI.{Behavior, Behaviors, Brain, Navigation, Random, Self, Sensors, World}
  alias Valimc.AI.Behaviors.Fight
  alias Valimc.Data.Float32

  @sensors [
    {Sensors.NearestLiving, 20},
    {__MODULE__.Adult, 20},
    {Sensors.HurtBy, 20},
    {__MODULE__.Attackables, 20},
    {__MODULE__.Temptations, 20}
  ]

  @doc "An axolotl's brain, its sensors' countdowns drawn from `random`, its `RunOne` shuffled by `gate`."
  def brain(random, [gate]) do
    core = [
      Behaviors.look_sink(45, 90),
      Behaviors.move_sink(),
      validate_play_dead(),
      count_down(:temptation_cooldown_ticks)
    ]

    idle = [
      {0, look_sometimes(6.0, {30, 60})},
      {1, make_love(Float32.round(0.2), 2)},
      {2, Behavior.run_one([{follow_temptation(), 1}, {baby_follow_adult({5, 16}), 1}], gate)},
      {3, Fight.start_attacking(fn _ -> true end, &find_target/1)},
      {3, try_find_liquid(6, Float32.round(0.15))},
      {4,
       Behavior.try_all_gate([walk_target: :absent], [
          Behaviors.swim_stroll(Float32.round(0.5)),
          Behaviors.stroll(Float32.round(0.15), 10, 7, &(not Self.in_water?(&1))),
          Behaviors.walk_to_look_target(&walks_to_look?/1, &speed/1, 3),
          Behavior.one_shot([], &{Self.in_water?(&1), &1}),
          Behavior.one_shot([], &{&1.on_ground, &1})
        ])}
    ]

    fight = [
      Fight.stop_if_invalid(fn self, _ -> {false, self} end, true, &on_stop_attacking/2),
      Fight.walk_to_target(&chasing/1),
      Fight.melee(20),
      Fight.erase_if(&breeding?/1, :attack_target)
    ]

    play_dead = [
      {0, play_dead()},
      {1, Fight.erase_if(&breeding?/1, :play_dead_ticks)}
    ]

    {brain, random} =
      Brain.new(
        __MODULE__,
        @sensors,
        [
          {:core, 0, core, [], []},
          {:idle, :each, idle, [], []},
          {:fight, 0, fight, [attack_target: :present], [:attack_target]},
          {:play_dead, :each, play_dead, [play_dead_ticks: :present], [:play_dead_ticks]}
        ],
        random
      )

    {brain, random}
  end

  @doc "The `RunOne`'s random, seeded from the mob's uuid (vanilla's is unseeded)."
  def gates(<<a::64, b::64>>), do: [Random.new(Bitwise.bxor(Bitwise.bxor(a, b * 0x5A17), 0x5A17))]

  # `getSpeedModifier`, `getSpeedModifierChasing`.
  defp speed(self),
    do: if(Self.in_water?(self), do: Float32.round(0.5), else: Float32.round(0.15))

  defp chasing(self),
    do: if(Self.in_water?(self), do: Float32.round(0.6), else: Float32.round(0.15))

  @doc "`BehaviorUtils.isBreeding`."
  def breeding?(self), do: Brain.has?(self, :breed_target)

  defp baby?(%Self{data: data}), do: data.age < 0

  # `findNearestValidAttackTarget`: what it may attack, unless breeding.
  defp find_target(self) do
    if breeding?(self),
      do: {nil, self},
      else: {World.entity(self.world, Brain.get(self, :nearest_attackable)), self}
  end

  # `canSetWalkTargetFromLookTarget`: the look target's block is water as
  # much as the axolotl is in water.
  defp walks_to_look?(self) do
    case Brain.get(self, :look_target) do
      nil ->
        false

      target ->
        case Behaviors.block(self, target) do
          nil -> false
          pos -> World.fluid(self.world, pos) == :water == Self.in_water?(self)
        end
    end
  end

  @doc """
  `AxolotlAi.updateActivity` (not while playing dead): play dead, fight or
  idle, the first valid; leaving a fight starts the hunting cooldown; then
  whether it plays dead (`customServerAiStep`).
  """
  def update_activity(self) do
    old = Brain.activity(self)

    self =
      if old != :play_dead do
        self = Brain.first_valid(self, [:play_dead, :fight, :idle])

        if old == :fight and Brain.activity(self) != :fight,
          do: Brain.set(self, :has_hunting_cooldown, true, 2400),
          else: self
      else
        self
      end

    # Its target is its attack target (`getTargetFromBrain`).
    self = Self.put_target(self, Brain.get(self, :attack_target))
    self = Self.put_target(self, World.ref(World.target(self)))
    ticks = Brain.get(self, :play_dead_ticks)
    playing = ticks != nil and ticks > 0
    %{self | data: %{self.data | playing_dead: playing}}
  end

  @doc "`playAmbientSound`: not while playing dead."
  def ambient_sound(%Self{data: %{playing_dead: true}}), do: nil

  def ambient_sound(self) do
    if Self.in_water?(self),
      do: "minecraft:entity.axolotl.idle_water",
      else: "minecraft:entity.axolotl.idle_air"
  end

  @doc "An axolotl picks nothing up."
  def pick_up(self), do: self

  # `Axolotl.onStopAttacking`: a target that died of a player's hit near it
  # (within 20 blocks) leaves that player Regeneration and no Mining Fatigue.
  defp on_stop_attacking(self, target) do
    with %{alive: false} <- target,
         {:player, _} = ref <- Map.get(target, :killed_by),
         %{} = player <- World.entity(self.world, ref),
         true <-
           World.intersects?(World.inflate(Self.box(self), 20.0, 20.0, 20.0), World.box(player)) do
      Self.effect(self, {:effect, ref, [{:support, regen(), mining_fatigue()}]})
    else
      _ -> self
    end
  end

  defp regen, do: Valimc.Data.EffectTypes.id("regeneration")
  defp mining_fatigue, do: Valimc.Data.EffectTypes.id("mining_fatigue")

  ## Behaviours

  @never 2_000_000_000

  # `ValidatePlayDead`: counting down; at zero it forgets who hurt it and
  # goes back to idle.
  defp validate_play_dead do
    Behavior.one_shot([play_dead_ticks: :present, hurt_by_entity: :registered], fn self ->
      ticks = Brain.get(self, :play_dead_ticks)

      if ticks <= 0 do
        self = self |> Brain.erase(:play_dead_ticks) |> Brain.erase(:hurt_by_entity)
        {true, Brain.default_activity(self)}
      else
        {true, Brain.set(self, :play_dead_ticks, ticks - 1)}
      end
    end)
  end

  # `CountDownCooldownTicks(memory)`.
  defp count_down(memory),
    do:
      Behavior.timed(__MODULE__.CountDown, [{memory, :present}], {@never, @never}, %{
        memory: memory
      })

  # `PlayDead` (200 ticks): in water, still, with Regeneration.
  defp play_dead,
    do:
      Behavior.timed(
        __MODULE__.PlayDead,
        [play_dead_ticks: :present, hurt_by_entity: :present],
        {200, 200}
      )

  # `SetEntityLookTargetSometimes.create(PLAYER, maxDist, interval)`.
  defp look_sometimes(distance, interval) do
    max = Float32.round(Float32.round(distance) * Float32.round(distance))

    %{
      Behavior.one_shot([look_target: :absent, nearest_visible_living_entities: :present], nil)
      | trigger: nil
    }
    |> Map.merge(%{kind: __MODULE__.LookSometimes, max: max, interval: interval, until: 0})
  end

  # `AnimalMakeLove(AXOLOTL, speed, close)` (110 ticks at most).
  defp make_love(speed, close),
    do:
      Behavior.timed(
        __MODULE__.MakeLove,
        [
          nearest_visible_living_entities: :present,
          breed_target: :absent,
          walk_target: :registered,
          look_target: :registered,
          is_panicking: :absent
        ],
        {110, 110},
        %{speed: speed, close: close, at: 0}
      )

  # `FollowTemptation(getSpeedModifier)`.
  defp follow_temptation,
    do:
      Behavior.timed(
        __MODULE__.FollowTemptation,
        [
          look_target: :registered,
          walk_target: :registered,
          temptation_cooldown_ticks: :absent,
          tempting_player: :present,
          breed_target: :absent,
          is_panicking: :absent
        ],
        {@never, @never}
      )

  # `BabyFollowAdult.create(range, getSpeedModifierFollowingAdult)`.
  defp baby_follow_adult({min, max}) do
    Behavior.one_shot(
      [nearest_visible_adult: :present, look_target: :registered, walk_target: :absent],
      fn self ->
        adult = World.entity(self.world, Brain.get(self, :nearest_visible_adult))

        cond do
          not baby?(self) or adult == nil ->
            {false, self}

          World.distance_sq(self, adult) < (max + 1) * (max + 1) and
              not (World.distance_sq(self, adult) < min * min) ->
            ref = World.ref(adult)

            self =
              self
              |> Brain.set(:look_target, {:entity, ref, true})
              |> Brain.set(:walk_target, %{
                target: {:entity, ref, false},
                speed: chasing(self),
                close: min - 1
              })

            {true, self}

          true ->
            {false, self}
        end
      end
    )
  end

  # `TryFindLiquid.create(range, speed, AXOLOTL_TRIES_TO_FIND)`: on land,
  # the first water within `range` (not in its own column) with air above,
  # else the first not right beside it; tried again after 40 ticks (22
  # while waiting).
  defp try_find_liquid(range, speed) do
    Behavior.one_shot(
      [attack_target: :absent, walk_target: :absent, look_target: :registered],
      fn self ->
        at = Self.block(self)

        cond do
          World.fluid(self.world, at) == :water ->
            {false, self}

          self.world.time < next_try(self) ->
            {true, put_next_try(self, self.world.time + 22)}

          true ->
            {bx, _, bz} = at

            found =
              World.manhattan(at, range, range, range)
              |> Enum.reduce_while(nil, fn {x, y, z} = pos, found ->
                cond do
                  x == bx and z == bz -> {:cont, found}
                  not liquid_water?(self.world, pos) -> {:cont, found}
                  World.air?(self.world, {x, y + 1, z}) -> {:halt, pos}
                  found == nil and not near?(pos, self, 1.5) -> {:cont, pos}
                  true -> {:cont, found}
                end
              end)

            self =
              case found do
                nil ->
                  self

                {x, y, z} = pos ->
                  block = {:block, pos, {x + 0.5, y + 0.5, z + 0.5}}

                  self
                  |> Brain.set(:look_target, block)
                  |> Brain.set(:walk_target, %{target: block, speed: speed, close: 0})
              end

            {true, put_next_try(self, self.world.time + 40)}
        end
      end
    )
  end

  defp next_try(%Self{mind: %{own: %{find_liquid: t}}}), do: t
  defp next_try(_self), do: 0

  defp put_next_try(self, t),
    do: Self.mind(self, &%{&1 | own: Map.put(&1.own || %{}, :find_liquid, t)})

  defp liquid_water?(world, pos) do
    case World.block(world, pos) do
      nil -> false
      state -> Valimc.Data.Blocks.block_id(state) == Valimc.Data.Blocks.id("water")
    end
  end

  defp near?({x, y, z}, self, d) do
    {dx, dy, dz} = {x + 0.5 - self.x, y + 0.5 - self.y, z + 0.5 - self.z}
    dx * dx + dy * dy + dz * dz < d * d
  end

  ## Timed behaviours' parts

  defmodule CountDown do
    @moduledoc false
    def extra(state, self), do: {true, state, self}
    def start(state, self), do: {state, self}

    def still(state, self) do
      ticks = Brain.get(self, state.memory)
      {ticks != nil and ticks > 0, state, self}
    end

    def tick(state, self),
      do: {state, Brain.set(self, state.memory, Brain.get(self, state.memory) - 1)}

    def stop(state, self), do: {state, Brain.erase(self, state.memory)}
  end

  defmodule PlayDead do
    @moduledoc false
    @regen Valimc.Data.EffectTypes.id("regeneration")

    def extra(state, self), do: {Self.in_water?(self), state, self}

    def start(state, self) do
      self = self |> Brain.erase(:walk_target) |> Brain.erase(:look_target)
      {state, Self.add_effect(self, @regen, [{200, 0, false, true, true}])}
    end

    def still(state, self),
      do: {Self.in_water?(self) and Brain.has?(self, :play_dead_ticks), state, self}

    def tick(state, self), do: {state, self}
    def stop(state, self), do: {state, self}
  end

  defmodule FollowTemptation do
    @moduledoc false
    def extra(state, self), do: {true, state, self}
    def start(state, self), do: {state, self}

    def still(state, self) do
      {Brain.has?(self, :tempting_player) and not Brain.has?(self, :breed_target) and
         not Brain.has?(self, :is_panicking), state, self}
    end

    def tick(state, self) do
      case World.entity(self.world, Brain.get(self, :tempting_player)) do
        nil ->
          {state, self}

        player ->
          ref = World.ref(player)
          self = Brain.set(self, :look_target, {:entity, ref, true})

          self =
            if World.distance_sq(self, player) < 2.5 * 2.5,
              do: Brain.erase(self, :walk_target),
              else:
                Brain.set(self, :walk_target, %{
                  target: {:entity, ref, false},
                  speed:
                    if(Self.in_water?(self), do: Float32.round(0.5), else: Float32.round(0.15)),
                  close: 2
                })

          {state, self}
      end
    end

    def stop(state, self) do
      self =
        self
        |> Brain.set(:temptation_cooldown_ticks, 100)
        |> Brain.erase(:walk_target)
        |> Brain.erase(:look_target)

      {state, self}
    end
  end

  defmodule MakeLove do
    @moduledoc false
    alias Valimc.AI.Brains.Axolotl

    def extra(state, self) do
      {self.data.in_love > 0 and partner(self) != nil, state, self}
    end

    defp partner(self) do
      case Brain.get(self, :nearest_visible_living_entities) do
        %{entities: refs} ->
          Enum.find_value(refs, fn ref ->
            case World.entity(self.world, ref) do
              %{type: "minecraft:axolotl", panicking: false} = other ->
                if can_mate?(self, other), do: other

              _ ->
                nil
            end
          end)

        _ ->
          nil
      end
    end

    # `Animal.canMate`: another adult in love.
    defp can_mate?(self, other),
      do:
        other.uuid != self.uuid and self.data.in_love > 0 and other.in_love > 0 and other.age == 0

    def start(state, self) do
      partner = partner(self)
      ref = World.ref(partner)
      self = Brain.set(self, :breed_target, ref)
      self = remember(self, ref, :breed_target, World.ref(self_entity(self)))
      self = lock_gaze(self, partner, state)
      {n, self} = Self.int(self, 50)
      {%{state | at: self.world.time + 60 + n}, self}
    end

    defp self_entity(self), do: %{kind: :mob, uuid: self.uuid}

    # `BehaviorUtils.lockGazeAndWalkToEachOther`: both look at and walk to
    # each other.
    defp lock_gaze(self, partner, state) do
      ref = World.ref(partner)
      me = {:mob, self.uuid}

      self
      |> Brain.set(:look_target, {:entity, ref, true})
      |> Brain.set(:walk_target, %{
        target: {:entity, ref, false},
        speed: state.speed,
        close: state.close
      })
      |> remember(ref, :look_target, {:entity, me, true})
      |> remember(ref, :walk_target, %{
        target: {:entity, me, false},
        speed: state.speed,
        close: state.close
      })
    end

    # A memory of the partner's set at once (nil erases it), as vanilla's
    # behaviour sets it.
    defp remember(self, {:mob, uuid}, key, value),
      do:
        Self.effect(
          self,
          {:remote, uuid,
           fn mind -> %Self{mind: mind} |> Brain.set(key, value) |> Map.fetch!(:mind) end}
        )

    def still(state, self) do
      case World.entity(self.world, Brain.get(self, :breed_target)) do
        %{type: "minecraft:axolotl", alive: true} = partner ->
          {visible, self} = Sensors.visible_contains?(self, partner)

          ok =
            can_mate?(self, partner) and visible and self.world.time <= state.at and
              not Brain.has?(self, :is_panicking) and not partner.panicking

          {ok, state, self}

        _ ->
          {false, state, self}
      end
    end

    def tick(state, self) do
      partner = World.entity(self.world, Brain.get(self, :breed_target))
      self = lock_gaze(self, partner, state)

      if World.distance_sq(self, partner) < 9.0 and self.world.time >= state.at do
        self = Valimc.Entity.Animal.breed(self, partner)
        ref = World.ref(partner)
        self = self |> Brain.erase(:breed_target) |> remember(ref, :breed_target, nil)
        {state, self}
      else
        {state, self}
      end
    end

    def stop(state, self) do
      self =
        self
        |> Brain.erase(:breed_target)
        |> Brain.erase(:walk_target)
        |> Brain.erase(:look_target)

      {%{state | at: 0}, Axolotl.breeding_done(self)}
    end
  end

  @doc false
  def breeding_done(self), do: self

  defmodule LookSometimes do
    @moduledoc false
    @behaviour Valimc.AI.Behavior

    def try_start(b, self) do
      if Brain.conditions?(self, b.conditions) do
        {target, self} =
          Sensors.visible_closest(self, fn e ->
            e.kind == :player and World.distance_sq(self, e) <= b.max
          end)

        if target == nil do
          {false, b, self}
        else
          # `Ticker.tickDownAndCheck` on the level's random.
          {ok, b, self} =
            if b.until == 0 do
              {min, max} = b.interval
              {n, self} = Behavior.level_int(self, max - min + 1)
              {false, %{b | until: min + n - 1}, self}
            else
              until = b.until - 1
              {until == 0, %{b | until: until}, self}
            end

          if ok,
            do:
              {true, %{b | running: true},
               Brain.set(self, :look_target, {:entity, World.ref(target), true})},
            else: {false, b, self}
        end
      else
        {false, b, self}
      end
    end

    def tick_or_stop(b, self), do: {%{b | running: false}, self}
    def stop(b, self), do: {%{b | running: false}, self}
  end

  ## Sensors

  defmodule Adult do
    @moduledoc "`AdultSensor`: the nearest visible adult of its own type."
    def scan(%Self{} = self) do
      if Brain.has?(self, :nearest_visible_living_entities) do
        {adult, self} =
          Sensors.visible_closest(
            self,
            &(Map.get(&1, :type) == self.type and Map.get(&1, :age, 0) >= 0)
          )

        Brain.set(self, :nearest_visible_adult, World.ref(adult))
      else
        self
      end
    end
  end

  defmodule Attackables do
    @moduledoc """
    `AxolotlAttackablesSensor`: the nearest visible entity within eight
    blocks in water that it always fights, or hunts when off cooldown, and
    may attack.
    """
    @hostile MapSet.new(
               Valimc.Protocol.Data.tags()["minecraft:entity_type"][
                 "minecraft:axolotl_always_hostiles"
               ] || []
             )
    @hunt MapSet.new(
            Valimc.Protocol.Data.tags()["minecraft:entity_type"]["minecraft:axolotl_hunt_targets"] ||
              []
          )

    def scan(%Self{} = self) do
      if Brain.has?(self, :nearest_visible_living_entities) do
        hunting = not Brain.has?(self, :has_hunting_cooldown)

        candidates =
          for e <- Brain.get(self, :nearest_visible_living_entities).entities,
              entity = World.entity(self.world, e),
              entity != nil,
              do: entity

        {found, self} =
          Enum.reduce_while(candidates, {nil, self}, fn e, {nil, self} ->
            id = type_id(e)

            if World.distance_sq(self, e) <= 64.0 and in_water?(e) and
                 (MapSet.member?(@hostile, id) or (hunting and MapSet.member?(@hunt, id))) do
              {visible, self} = Sensors.visible_contains?(self, e)

              if visible do
                case Sensors.attackable?(self, e) do
                  {true, self} -> {:halt, {e, self}}
                  {false, self} -> {:cont, {nil, self}}
                end
              else
                {:cont, {nil, self}}
              end
            else
              {:cont, {nil, self}}
            end
          end)

        Brain.set(self, :nearest_attackable, World.ref(found))
      else
        self
      end
    end

    defp type_id(%{kind: :mob, type: type}), do: Valimc.Data.EntityTypes.id(type)
    defp type_id(_), do: nil

    defp in_water?(%{in_water: in_water}), do: in_water
    defp in_water?(_), do: false
  end

  defmodule Temptations do
    @moduledoc "`TemptingSensor.forAnimal`: the nearest player holding its food (seen or not)."
    def scan(%Self{} = self) do
      range = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:tempt_range")
      conditions = World.conditions(false, range: range, sight: false)

      {players, self} =
        Enum.reduce(self.world.players, {[], self}, fn p, {acc, self} ->
          {ok, self} = World.test(self, p, conditions)

          food =
            Valimc.Entity.Animal.food?(self.type, p.equipment[:mainhand]) or
              Valimc.Entity.Animal.food?(self.type, p.equipment[:offhand])

          if ok and food and p.mode != :spectator, do: {[p | acc], self}, else: {acc, self}
        end)

      case players |> Enum.reverse() |> Enum.sort_by(&World.distance_sq(self, &1)) do
        [] -> Brain.erase(self, :tempting_player)
        [p | _] -> Brain.set(self, :tempting_player, World.ref(p))
      end
    end
  end

  _ = Navigation
end
