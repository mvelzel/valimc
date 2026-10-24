defmodule Valimc.AI.Brains.Villager do
  @moduledoc """
  A villager's brain (`Villager`, `VillagerGoalPackages`, VMC-044a1): its
  sensors, and the core, idle, work, meet, rest, panic and (a baby's) play
  activities with vanilla's behaviours at vanilla's priorities, the daily
  schedule (`villager_activity`) choosing among them.

  - **Core:** swimming, doors, the look and walk sinks, panic at a hostile
    or when hurt, waking at day, keeping its job site and potential job
    site valid, the job site competition, claiming a job site (a potential
    one first), walking to it, yielding it to a villager that holds that
    trade, claiming a bed and the meeting point, taking the profession of its
    job site and losing it with it.
  - **Idle, work, meet, rest, panic, play:** as vanilla's packages, with
    looks and walks shuffled by their own randoms.

  Trading (showing trades, following a trading player, gifts to a hero,
  villagers trading items), breeding, bells' raids and hiding, and farming
  (harvesting, bone meal, composting) are VMC-044's: their behaviours keep
  their places and never start. Gossip and golems are VMC-044a2's.

  A villager's POI memories (home, job site, potential job site, meeting
  point) and when it last slept, woke and worked are saved with it
  (`saved/1`).
  """
  alias Valimc.AI
  alias Valimc.AI.{Behavior, Behaviors, Brain, Navigation, Pois, Random, Self, Villagers, World}
  alias Valimc.AI.Behaviors.Poi
  alias Valimc.Data.{Blocks, Float32}
  alias Valimc.Protocol.Data

  @speed 0.5
  @block_tags Data.tags()["minecraft:block"]
  @sleep_beds MapSet.new(@block_tags["minecraft:villagers_can_sleep_on_bed"])
  @jump_beds MapSet.new(@block_tags["minecraft:villager_babies_can_jump_on_bed"])

  @doc "Whether villagers sleep on `state` (`VILLAGERS_CAN_SLEEP_ON_BED`)."
  def sleeps_on?(state), do: MapSet.member?(@sleep_beds, Blocks.block_id(state))

  @doc "A bed state's `occupied`."
  def occupied?(state), do: property(state, "occupied") == "true"

  defp property(state, key) do
    case List.keyfind(Blocks.properties(state), key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @doc "The memories a villager's record saves (`MemoryModuleType.canSerialize`)."
  def saved,
    do: [
      :home,
      :job_site,
      :potential_job_site,
      :meeting_point,
      :last_slept,
      :last_woken,
      :last_worked_at_poi,
      :golem_detected_recently
    ]

  @sensors [
    {Valimc.AI.Sensors.NearestLiving, 20},
    {Valimc.AI.Sensors.Players, 20},
    {Valimc.AI.Sensors.Items, 20},
    {__MODULE__.NearestBed, 20},
    {Valimc.AI.Sensors.HurtBy, 20},
    {__MODULE__.Hostiles, 20},
    {__MODULE__.Babies, 20},
    {__MODULE__.SecondaryPois, 40},
    {__MODULE__.Golems, 200}
  ]

  @doc """
  A villager's brain for its `data` (profession, baby), its sensors'
  countdowns drawn from `random` and its gates shuffled by `gates` (from
  `gates/2`, by key): `{brain, random}`.
  """
  def brain(random, gates, data \\ Valimc.Entity.Villager.data(), order \\ %{}) do
    profession = data.profession
    baby = data.age < 0
    g = fn key -> Map.get(gates, key) || Random.new(:erlang.phash2(key)) end

    activities =
      if(baby,
        do: [{:play, :each, play(g), [], []}],
        else: [{:work, :each, work(profession, g), [job_site: :present], []}]
      ) ++
        [
          {:core, :each, core(profession), [], []},
          {:meet, :each, meet(g), [meeting_point: :present], []},
          {:rest, :each, rest(g), [], []},
          {:idle, :each, idle(g), [], []},
          {:panic, :each, panic(g), [], []}
        ]

    Brain.new(__MODULE__, @sensors, activities, random, order)
  end

  @doc """
  The keys of a villager brain's gates, `"priority:activity:index:0"` (the
  behaviour's place among its activity's at that priority), in the order
  vanilla's brain lists them, followed by its independent roofed-walk shuffle.
  """
  def gate_keys(baby) do
    work_or_play = if baby, do: ["5:play:0:0", "5:play:1:0"], else: ["5:work:0:0", "5:work:1:0"]

    work_or_play ++
      [
        "2:meet:0:0",
        "3:meet:2:0",
        "5:meet:0:0",
        "5:rest:0:0",
        "5:rest:1:0",
        "2:idle:0:0",
        "3:idle:3:0",
        "3:idle:4:0",
        "5:idle:0:0",
        "5:panic:0:0",
        "inside_brownian_walk"
      ]
  end

  @doc "A fresh villager's gate randoms, by key, from its uuid."
  def gates(<<a::64, b::64>>, baby \\ false) do
    for {key, i} <- Enum.with_index(gate_keys(baby)),
        into: %{},
        do: {key, Random.new(Bitwise.bxor(a + i * 0x9E37_79B9, b))}
  end

  ## Activity packages

  defp core(profession) do
    held = &Villagers.profession(profession_of(&1)).held
    acquirable = &Villagers.profession(profession_of(&1)).acquirable

    [
      {0, Behaviors.swim(0.8)},
      {0, Behaviors.interact_with_door()},
      {0, Behaviors.look_sink(45, 90)},
      {0, panic_trigger()},
      {0, wake_up()},
      {0, Behavior.one_shot([heard_bell_time: :present], fn self -> {false, self} end)},
      {0, set_raid_status()},
      {0, Poi.validate(held, :job_site)},
      {0, Poi.validate(acquirable, :potential_job_site)},
      {1, Behaviors.move_sink()},
      {2, competitor_scan()},
      {3, Behavior.inert("LookAndFollowTradingPlayerSink")},
      {5, Behaviors.go_to_wanted_item(fn _ -> true end, @speed, false, 4)},
      {6,
       Poi.acquire(
         fn self -> Villagers.profession(profession_of(self)).acquirable end,
         :job_site,
         :potential_job_site,
         adult: true
       )},
      {7, go_to_potential_job_site(@speed)},
      {8, yield_job_site(@speed)},
      {10,
       Poi.acquire(["minecraft:home"], :home, :home,
         event: 14,
         valid: fn self, pos -> free_bed?(self, pos) end
       )},
      {10,
       Poi.acquire(["minecraft:meeting"], :meeting_point, :meeting_point, adult: true, event: 14)},
      {10, assign_profession()},
      {10, reset_profession()}
    ]
    |> tap(fn _ -> profession end)
  end

  defp work(profession, g) do
    farmer = profession == "minecraft:farmer"

    [
      minimal_look(g.("5:work:0:0")),
      {5,
       Behavior.run_one(
         [
           {work_at_poi(), 7},
           {Poi.stroll_around(:job_site, 0.4, 4), 2},
           {Poi.stroll_to(:job_site, 0.4, 1, 10), 5},
           {Poi.stroll_to_list(:secondary_job_site, @speed, 1, 6, :job_site), 5},
           {Behavior.inert("HarvestFarmland"), if(farmer, do: 2, else: 5)},
           {Behavior.inert("UseBonemeal"), if(farmer, do: 4, else: 7)}
         ],
         g.("5:work:1:0")
       )},
      {10, Behavior.inert("ShowTradesToPlayer")},
      {10, Behaviors.look_and_interact(:player, 4)},
      {2, Poi.walk_to_memory(:job_site, @speed, 9, 100, 1200)},
      {3, Behavior.inert("GiveGiftToHero")},
      {99, update_schedule()}
    ]
  end

  defp play(g) do
    [
      {0, Behaviors.move_sink(80, 120)},
      full_look(g.("5:play:1:0")),
      {5, Behavior.inert("PlayTagWithOtherKids")},
      {5,
       Behavior.run_one(
         [
           {Behaviors.interact_with("minecraft:villager", 8, @speed, 2), 2},
           {Behaviors.interact_with("minecraft:cat", 8, @speed, 2), 1},
           {Poi.village_stroll(@speed), 1},
           {Behaviors.walk_to_look_target(fn _ -> true end, @speed, 2), 1},
           {jump_on_bed(@speed), 2},
           {Behavior.do_nothing(20, 40), 2}
         ],
         g.("5:play:0:0"),
         visible_villager_babies: :absent
       )},
      {99, update_schedule()}
    ]
  end

  defp rest(g) do
    [
      {2, Poi.walk_to_memory(:home, @speed, 1, 150, 1200)},
      {3, Poi.validate(["minecraft:home"], :home)},
      {3, sleep_in_bed()},
      {5,
       Behavior.run_one(
         [
           {Poi.walk_to_closest_home(@speed), 1},
           {brownian_walk(@speed, g.("inside_brownian_walk")), 4},
           {Poi.go_to_village(@speed, 4), 2},
           {Behavior.do_nothing(20, 40), 2}
         ],
         g.("5:rest:0:0"),
         home: :absent
       )},
      minimal_look(g.("5:rest:1:0")),
      {99, update_schedule()}
    ]
  end

  defp meet(g) do
    [
      {2,
       Behavior.trigger_gate(
         [{Poi.stroll_around(:meeting_point, 0.4, 40), 2}, {socialize_at_bell(), 2}],
         g.("2:meet:0:0")
       )},
      {10, Behavior.inert("ShowTradesToPlayer")},
      {10, Behaviors.look_and_interact(:player, 4)},
      {2, Poi.walk_to_memory(:meeting_point, @speed, 6, 100, 200)},
      {3, Behavior.inert("GiveGiftToHero")},
      {3, Poi.validate(["minecraft:meeting"], :meeting_point)},
      {3,
       Behavior.gate(
         [{trade_with_villager(), 1}],
         g.("3:meet:2:0"),
         [],
         [:interaction_target],
         :ordered
       )},
      full_look(g.("5:meet:0:0")),
      {99, update_schedule()}
    ]
  end

  defp idle(g) do
    [
      {2,
       Behavior.run_one(
         [
           {Behaviors.interact_with("minecraft:villager", 8, @speed, 2), 2},
           {Behaviors.interact_with("minecraft:villager", 8, @speed, 2,
              memory: :breed_target,
              self: &can_breed?/1,
              target: &can_breed?/1
            ), 1},
           {Behaviors.interact_with("minecraft:cat", 8, @speed, 2), 1},
           {Poi.village_stroll(@speed), 1},
           {Behaviors.walk_to_look_target(fn _ -> true end, @speed, 2), 1},
           {jump_on_bed(@speed), 1},
           {Behavior.do_nothing(30, 60), 1}
         ],
         g.("2:idle:0:0")
       )},
      {3, Behavior.inert("GiveGiftToHero")},
      {3, Behaviors.look_and_interact(:player, 4)},
      {3, Behavior.inert("ShowTradesToPlayer")},
      {3,
       Behavior.gate(
         [{trade_with_villager(), 1}],
         g.("3:idle:3:0"),
         [],
         [:interaction_target],
         :ordered
       )},
      {3,
       Behavior.gate(
         [{Behavior.inert("VillagerMakeLove"), 1}],
         g.("3:idle:4:0"),
         [],
         [:breed_target],
         :ordered
       )},
      full_look(g.("5:idle:0:0")),
      {99, update_schedule()}
    ]
  end

  defp panic(g) do
    runaway = Float32.round(Float32.round(@speed) * 1.5)

    [
      {0, calm_down()},
      {1, Behaviors.walk_away_from(:nearest_hostile, runaway, 6, false)},
      {1, Behaviors.walk_away_from(:hurt_by_entity, runaway, 6, false)},
      {3, Poi.village_stroll(runaway, 2, 2)},
      minimal_look(g.("5:panic:0:0"))
    ]
  end

  defp full_look(random),
    do:
      {5,
       Behavior.run_one(
         [
           {Behaviors.look_target(&Behaviors.is?(&1, "minecraft:cat"), 8.0), 8},
           {Behaviors.look_target(&Behaviors.is?(&1, "minecraft:villager"), 8.0), 2},
           {Behaviors.look_target(&Behaviors.is?(&1, :player), 8.0), 2},
           {Behaviors.look_target(&category?(&1, :creature), 8.0), 1},
           {Behaviors.look_target(&category?(&1, :water_creature), 8.0), 1},
           {Behaviors.look_target(&category?(&1, :axolotls), 8.0), 1},
           {Behaviors.look_target(&category?(&1, :underground_water_creature), 8.0), 1},
           {Behaviors.look_target(&category?(&1, :water_ambient), 8.0), 1},
           {Behaviors.look_target(&category?(&1, :monster), 8.0), 1},
           {Behavior.do_nothing(30, 60), 2}
         ],
         random
       )}

  defp minimal_look(random),
    do:
      {5,
       Behavior.run_one(
         [
           {Behaviors.look_target(&Behaviors.is?(&1, "minecraft:villager"), 8.0), 2},
           {Behaviors.look_target(&Behaviors.is?(&1, :player), 8.0), 2},
           {Behavior.do_nothing(30, 60), 8}
         ],
         random
       )}

  defp category?(%{kind: :mob, type: type}, category),
    do: Valimc.Data.EntityTypes.fetch(type).category == category

  defp category?(_entity, _category), do: false

  # `AgeableMob::canBreed` of a villager: food it has none of yet (VMC-044).
  defp can_breed?(_entity), do: false

  ## Data

  @doc "The villager's profession."
  def profession_of(%Self{data: data}), do: data.profession

  defp baby?(%Self{data: data}), do: data.age < 0

  defp sleeping?(%Self{data: data}), do: data.sleeping != nil

  ## Core behaviours

  # `UpdateActivityFromSchedule`.
  defp update_schedule,
    do: Behavior.one_shot([], fn self -> {true, schedule(self)} end)

  @doc "`updateActivityFromSchedule` at the day's scheduled activity."
  def schedule(self),
    do: Brain.update_from_schedule(self, Villagers.scheduled(self.world.day, baby?(self)))

  # `SetRaidStatus`: one in 20 ticks it looks for a raid (there are none yet).
  defp set_raid_status do
    Behavior.one_shot([], fn self ->
      {n, self} = Behavior.level_int(self, 20)
      {n == 0, self}
    end)
  end

  defmodule PanicTrigger do
    @moduledoc false
    alias Valimc.AI.Brain

    def extra(state, self), do: {true, state, self}

    def start(state, self) do
      self =
        if scared?(self) do
          self =
            if Brain.active?(self, :panic),
              do: self,
              else:
                Enum.reduce(
                  [:path, :walk_target, :look_target, :breed_target, :interaction_target],
                  self,
                  &Brain.erase(&2, &1)
                )

          Brain.set_active_if_possible(self, :panic)
        else
          self
        end

      {state, self}
    end

    def still(state, self), do: {scared?(self), state, self}

    # Every 100 ticks a panicking villager asks for a golem (three must agree).
    def tick(state, self) do
      if rem(self.world.time, 100) == 0,
        do: {state, Valimc.AI.Brains.Villager.spawn_golem_if_needed(self, 3)},
        else: {state, self}
    end

    def stop(state, self), do: {state, self}

    defp scared?(self), do: Brain.has?(self, :hurt_by) or Brain.has?(self, :nearest_hostile)
  end

  defp panic_trigger, do: Behavior.timed(PanicTrigger, [], {60, 60})

  # `VillagerCalmDown`.
  defp calm_down do
    Behavior.one_shot(
      [hurt_by: :registered, hurt_by_entity: :registered, nearest_hostile: :registered],
      fn self ->
        attacker = World.entity(self.world, Brain.get(self, :hurt_by_entity))

        scared =
          Brain.has?(self, :hurt_by) or Brain.has?(self, :nearest_hostile) or
            (attacker != nil and World.distance_sq(self, attacker) <= 36.0)

        if scared do
          {true, self}
        else
          {true, self |> Brain.erase(:hurt_by) |> Brain.erase(:hurt_by_entity) |> schedule()}
        end
      end
    )
  end

  # `WakeUp`.
  defp wake_up do
    Behavior.one_shot([], fn self ->
      if not Brain.active?(self, :rest) and sleeping?(self),
        do: {true, stop_sleeping(self)},
        else: {false, self}
    end)
  end

  # `PoiCompetitorScan`: of the villagers that hold its job site with a
  # profession for it, the one with less experience loses it (ties lose to
  # the later one).
  defp competitor_scan do
    Behavior.one_shot([job_site: :present, nearest_living_entities: :present], fn self ->
      {_, pos} = job = Brain.get(self, :job_site)

      case Pois.type_at(self.world, pos) do
        nil ->
          {true, self}

        type ->
          rivals =
            for ref <- Brain.get(self, :nearest_living_entities),
                %{kind: :mob, type: "minecraft:villager", alive: true} = v <- [
                  World.entity(self.world, ref)
                ],
                v.uuid != self.uuid,
                match?(%{job_site: {^job, _}}, v.memories || %{}),
                Villagers.holds?(v.data.profession, type),
                do: v

          {true, compete(self, rivals)}
      end
    end)
  end

  # `reduce(body, selectWinner)`: the loser of each pair forgets the job site.
  defp compete(self, rivals) do
    {_, self} =
      Enum.reduce(rivals, {:self, self}, fn rival, {winner, self} ->
        winner_xp = if winner == :self, do: self.data.xp, else: winner.data.xp

        if winner_xp > rival.data.xp do
          {winner, remote(self, rival.uuid, &Brain.erase(&1, :job_site))}
        else
          self =
            if winner == :self,
              do: Brain.erase(self, :job_site),
              else: remote(self, winner.uuid, &Brain.erase(&1, :job_site))

          {rival, self}
        end
      end)

    self
  end

  defmodule GoToJobSite do
    @moduledoc false
    alias Valimc.AI.{Behaviors, Brain}
    alias Valimc.AI.Behaviors.Poi

    def extra(state, self) do
      ok = Brain.activity(self) in [:idle, :work, :play, nil]
      {ok, state, self}
    end

    def start(state, self), do: {state, self}
    def still(state, self), do: {Brain.has?(self, :potential_job_site), state, self}

    def tick(%{speed: speed} = state, self) do
      {_, pos} = Brain.get(self, :potential_job_site)
      {state, Behaviors.walk_and_look(self, pos, speed, 1)}
    end

    def stop(state, self), do: {state, Poi.release(self, :potential_job_site)}
  end

  # `GoToPotentialJobSite(speed)`: 1200 ticks.
  defp go_to_potential_job_site(speed),
    do:
      Behavior.timed(GoToJobSite, [potential_job_site: :present], {1200, 1200}, %{
        speed: Float32.round(speed)
      })

  # `YieldJobSite`: an unemployed adult gives its potential job site to a
  # villager near whose trade holds it and who has none, or walks there.
  defp yield_job_site(speed) do
    Behavior.one_shot(
      [
        potential_job_site: :present,
        job_site: :absent,
        nearest_living_entities: :present,
        walk_target: :registered,
        look_target: :registered
      ],
      fn self ->
        cond do
          baby?(self) ->
            {false, self}

          profession_of(self) != "minecraft:none" ->
            {false, self}

          true ->
            {_, pos} = Brain.get(self, :potential_job_site)

            case Pois.type_at(self.world, pos) do
              nil -> {true, self}
              type -> {true, yield(self, pos, type, speed)}
            end
        end
      end
    )
  end

  defp yield(self, pos, type, speed) do
    candidate =
      Enum.find_value(Brain.get(self, :nearest_living_entities), fn ref ->
        case World.entity(self.world, ref) do
          %{kind: :mob, type: "minecraft:villager", alive: true} = v when v.uuid != self.uuid ->
            if wants?(self, v, type, pos), do: v

          _ ->
            nil
        end
      end)

    case candidate do
      nil ->
        self

      v ->
        self = self |> Brain.erase(:walk_target) |> Brain.erase(:look_target)
        self = Poi.release(self, :potential_job_site) |> Pois.take(pos)

        global = Poi.global(self, pos)

        if Map.has_key?(v.memories || %{}, :job_site),
          do: self,
          else:
            remote(self, v.uuid, fn other ->
              other
              |> Behaviors.walk_and_look(pos, speed, 1)
              |> Brain.set(:potential_job_site, global)
            end)
    end
  end

  # `nearbyWantsJobsite` (its path to the POI is a search vanilla runs at
  # once: the nearby villager's own reach is not known here, so one without
  # a job site wants it when it stands within its search's range).
  defp wants?(self, v, type, pos) do
    memories = v.memories || %{}

    cond do
      Map.has_key?(memories, :potential_job_site) ->
        false

      not Villagers.holds?(v.data.profession, type) ->
        false

      true ->
        case memories do
          %{job_site: {{_, job}, _}} -> job == pos
          _ -> Pois.dist_sq(pos, {floor(v.x), floor(v.y), floor(v.z)}) <= 48 * 48
        end
    end
    |> tap(fn _ -> self end)
  end

  # `AssignProfessionFromJobSite`: within 2 blocks of the potential job site
  # it becomes its job site (entity event 14); an unemployed villager takes
  # the first profession holding it, and its brain is made again.
  defp assign_profession do
    Behavior.one_shot([potential_job_site: :present, job_site: :registered], fn self ->
      {_, pos} = global = Brain.get(self, :potential_job_site)

      if Pois.near_center?(pos, {self.x, self.y, self.z}, 2.0) do
        self =
          self
          |> Brain.erase(:potential_job_site)
          |> Brain.set(:job_site, global)
          |> Self.effect({:event, 14})

        if profession_of(self) != "minecraft:none" do
          {true, self}
        else
          case Pois.type_at(self.world, pos) &&
                 Villagers.profession_for(Pois.type_at(self.world, pos)) do
            nil -> {true, self}
            profession -> {true, refresh(%{self | data: %{self.data | profession: profession}})}
          end
        end
      else
        {false, self}
      end
    end)
  end

  # `ResetProfession`: without a job site, an inexperienced villager of a
  # trade (not a nitwit) loses it.
  defp reset_profession do
    Behavior.one_shot([job_site: :absent], fn self ->
      data = self.data

      if data.profession not in ["minecraft:none", "minecraft:nitwit"] and data.xp == 0 and
           data.level <= 1 do
        {true, refresh(%{self | data: %{data | profession: "minecraft:none"}})}
      else
        {false, self}
      end
    end)
  end

  # `Villager.refreshBrain`: every behaviour stops, the brain is made again
  # with the memories it had, and the schedule picks the activity.
  defp refresh(%Self{mind: %{brain: brain}} = self) do
    self = stop_all(self)
    {fresh, random} = brain(self.mind.random, refresh_gates(self), self.data, brain.order)
    rest = with [_ | rest] <- brain.refresh, do: rest
    fresh = %{fresh | memories: self.mind.brain.memories, refresh: rest, order: brain.order}
    self = Self.mind(self, &%{&1 | brain: fresh, random: random})
    schedule(self)
  end

  # A remade brain's gates: the ones the brain was given for it (an
  # oracle's seeds), else the mob's own.
  defp refresh_gates(%Self{mind: %{brain: brain}} = self) do
    case brain.refresh do
      [gates | _] -> gates
      _ -> gates(self.uuid, baby?(self))
    end
  end

  defp stop_all(%Self{mind: %{brain: brain}} = self) do
    Enum.reduce(0..(tuple_size(brain.behaviors) - 1)//1, self, fn index, self ->
      b = elem(self.mind.brain.behaviors, index)

      if b.running do
        {b, self} = b.kind.stop(b, self)
        put_behavior(self, index, b)
      else
        self
      end
    end)
  end

  defp put_behavior(self, index, b),
    do:
      Self.mind(self, fn mind ->
        %{mind | brain: %{mind.brain | behaviors: put_elem(mind.brain.behaviors, index, b)}}
      end)

  # A change to another mob's brain (vanilla's behaviours set its memories
  # at once): it applies before that mob's tick or after this tick's.
  defp remote(self, uuid, fun),
    do:
      Self.effect(
        self,
        {:remote, uuid, fn mind -> %Self{mind: mind} |> fun.() |> Map.fetch!(:mind) end}
      )

  # `validateBedPoi`: a bed villagers sleep on that no one lies in.
  defp free_bed?(self, pos) do
    case World.block(self.world, pos) do
      nil -> false
      state -> sleeps_on?(state) and not occupied?(state)
    end
  end

  ## Gossip and golems

  defmodule TradeWithVillager do
    @moduledoc false
    alias Valimc.AI.{Brain, Sensors, World}
    alias Valimc.AI.Brains.Villager

    # `TradeWithVillager`: with a villager it sees as its interaction
    # target, both look at and walk to each other; close, they gossip (and
    # would trade items, which needs the inventory of VMC-044).
    def extra(state, self) do
      {ok, self} = valid(self)
      {ok, state, self}
    end

    def start(state, self), do: {state, Villager.lock_gaze(self, target(self))}

    def still(state, self) do
      {ok, self} = valid(self)
      {ok, state, self}
    end

    def tick(state, self) do
      other = target(self)

      if World.distance_sq(self, other) > 5.0 do
        {state, self}
      else
        {state, self |> Villager.lock_gaze(other) |> Villager.gossip(other)}
      end
    end

    def stop(state, self), do: {state, Brain.erase(self, :interaction_target)}

    defp target(self), do: World.entity(self.world, Brain.get(self, :interaction_target))

    # `BehaviorUtils.targetIsValid`: a living villager it sees.
    defp valid(self) do
      case target(self) do
        %{kind: :mob, type: "minecraft:villager", alive: true} = v ->
          Sensors.visible_contains?(self, v)

        _ ->
          {false, self}
      end
    end
  end

  defp trade_with_villager,
    do:
      Behavior.timed(
        TradeWithVillager,
        [interaction_target: :present, nearest_visible_living_entities: :present],
        {60, 60}
      )

  @doc """
  `BehaviorUtils.lockGazeAndWalkToEachOther(body, other, 0.5, 2)`: each looks
  at the other's eyes and walks to it (the other's memories change remotely).
  """
  def lock_gaze(self, other) do
    speed = Float32.round(0.5)
    mine = World.ref(other)
    theirs = {:mob, self.uuid}

    self
    |> Brain.set(:look_target, {:entity, mine, true})
    |> Brain.set(:walk_target, %{target: {:entity, mine, false}, speed: speed, close: 2})
    |> remote(other.uuid, fn o ->
      o
      |> Brain.set(:look_target, {:entity, theirs, true})
      |> Brain.set(:walk_target, %{target: {:entity, theirs, false}, speed: speed, close: 2})
    end)
  end

  @doc """
  `Villager.gossip(level, other, now)`: once in 1200 ticks for both, they
  share gossip (their reputations are VMC-044's, so none yet) and it asks
  for a golem (five must agree).
  """
  def gossip(%Self{world: world} = self, other) do
    now = world.time
    mine = Brain.get(self, :last_gossip) || 0

    theirs =
      (other.memories && match?(%{last_gossip: _}, other.memories) &&
         elem(other.memories.last_gossip, 0)) || 0

    if (now < mine or now >= mine + 1200) and (now < theirs or now >= theirs + 1200) do
      self
      |> Brain.set(:last_gossip, now)
      |> remote(other.uuid, &Brain.set(&1, :last_gossip, now))
      |> spawn_golem_if_needed(5)
    else
      self
    end
  end

  @doc """
  `Villager.spawnGolemIfNeeded(level, now, agree)`: a villager that wants a
  golem (it slept within a day and saw none lately), with `agree` of the
  (at most five first) villagers within 10 blocks wanting one too, summons
  one 8 blocks around it (ten tries from the level's random); then every
  villager there has seen a golem (599 ticks).
  """
  def spawn_golem_if_needed(%Self{world: world} = self, agree) do
    now = world.time

    if own_wants_golem?(self, now) do
      box = World.inflate(Self.box(self), 10.0, 10.0, 10.0)
      near = World.mobs_in(self, ["minecraft:villager"], box)

      wanting =
        near
        |> Enum.filter(fn v ->
          if v.uuid == self.uuid, do: own_wants_golem?(self, now), else: wants_golem?(v, now)
        end)
        |> Enum.take(5)

      if length(wanting) >= agree do
        case golem_spot(self) do
          {nil, self} ->
            self

          {golem, self} ->
            Enum.reduce(near, summon(self, golem), fn v, self ->
              if v.uuid == self.uuid,
                do: Brain.set(self, :golem_detected_recently, true, 599),
                else: remote(self, v.uuid, &Brain.set(&1, :golem_detected_recently, true, 599))
            end)
        end
      else
        self
      end
    else
      self
    end
  end

  defp own_wants_golem?(self, now) do
    not Brain.has?(self, :golem_detected_recently) and
      case Brain.get(self, :last_slept) do
        nil -> false
        at -> now - at < 24_000
      end
  end

  defp summon(self, golem), do: Self.effect(self, {:spawn, "minecraft:iron_golem", golem})

  # `EntityType.create` and `Mob.finalizeSpawn` of a golem at a spot, drawn
  # from the level's random as vanilla draws them (even for one it then
  # discards): its yaw, follow range bonus and handedness.
  defp made({x, y, z}, self) do
    {yaw, self} = Behavior.level_float(self)
    {a, self} = Valimc.AI.Spawn.level_double(self)
    {b, self} = Valimc.AI.Spawn.level_double(self)
    {left, self} = Behavior.level_float(self)

    {%{
       summoned: true,
       position: {x + 0.5, y * 1.0, z + 0.5},
       yaw: Float32.round(wrap(Float32.round(yaw * 360.0))),
       follow_bonus: 0.11485000000000001 * (a - b),
       left_handed: left < Float32.round(0.05)
     }, self}
  end

  # `SpawnUtil.trySpawnMob(IRON_GOLEM, MOB_SUMMONED, level, pos, 10, 8, 6,
  # LEGACY_IRON_GOLEM, false)`: a golem made on a spot it may stand on, kept
  # where nothing obstructs it.
  defp golem_spot(self) do
    {sx, sy, sz} = Self.block(self)

    Enum.reduce_while(1..10, {nil, self}, fn _, {nil, self} ->
      {dx, self} = Behavior.level_int(self, 17)
      {dz, self} = Behavior.level_int(self, 17)
      {x, z} = {sx + dx - 8, sz + dz - 8}

      case down_to_spot(self, {x, sy + 6, z}) do
        nil ->
          {:cont, {nil, self}}

        pos ->
          {golem, self} = made(pos, self)
          if fits_golem?(self, pos), do: {:halt, {golem, self}}, else: {:cont, {nil, self}}
      end
    end)
  end

  # `moveToPossibleSpawnPosition`: down from 6 above to 6 below, the first
  # block the strategy stands it on, one above it.
  defp down_to_spot(self, {x, y, z}) do
    above = World.block(self.world, {x, y, z})

    Enum.reduce_while(6..-6//-1, {above, y}, fn _, {above, y} ->
      y = y - 1
      state = World.block(self.world, {x, y, z})

      cond do
        state == nil -> {:halt, nil}
        golem_stands_on?(state, above) -> {:halt, {x, y + 1, z}}
        true -> {:cont, {state, y}}
      end
    end)
    |> case do
      {_, _} -> nil
      result -> result
    end
  end

  @golem_refuse MapSet.new(
                  for name <-
                        ~w(cobweb cactus glass_pane conduit ice tnt glowstone beacon sea_lantern frosted_ice tinted_glass glass),
                      do: Blocks.block_id(Blocks.default_state(name))
                )
  @leaves MapSet.new(@block_tags["minecraft:leaves"])
  @powder_snow Blocks.block_id(Blocks.default_state("powder_snow"))

  # `SpawnUtil.Strategy.LEGACY_IRON_GOLEM`.
  defp golem_stands_on?(state, above) do
    block = Blocks.block_id(state)
    class = Blocks.class(state)

    cond do
      MapSet.member?(@golem_refuse, block) ->
        false

      class in ["StainedGlassPaneBlock", "StainedGlassBlock"] ->
        false

      MapSet.member?(@leaves, block) ->
        false

      true ->
        above_ok =
          above != nil and
            (Valimc.Data.BlockFacts.air?(above) or Valimc.Data.BlockFacts.flag?(above, :liquid))

        above_ok and (Valimc.Data.BlockFacts.flag?(state, :solid) or block == @powder_snow)
    end
  end

  # `checkSpawnRules` (a golem's walk value is 0) and `checkSpawnObstruction`:
  # a floor it stands on, two empty spawn cells above, and no living thing
  # in its way.
  defp fits_golem?(self, {x, y, z} = pos) do
    below = World.block(self.world, {x, y - 1, z})

    below != nil and Valimc.Data.BlockFacts.flag?(below, :collision_up) and
      Enum.all?([{x, y + 1, z}, {x, y + 2, z}], &empty_spawn?(self, &1, true)) and
      empty_spawn?(self, pos, false) and unobstructed?(self, pos)
  end

  @no_spawn MapSet.new(@block_tags["minecraft:prevent_mob_spawning_inside"])
  @dangerous MapSet.new(
               for name <-
                     ~w(wither_rose sweet_berry_bush cactus powder_snow fire soul_fire lava magma_block),
                   do: Blocks.block_id(Blocks.default_state(name))
             )

  # `NaturalSpawner.isValidEmptySpawnBlock` for an iron golem.
  defp empty_spawn?(self, pos, fluid) do
    case World.block(self.world, pos) do
      nil ->
        false

      state ->
        not Valimc.Data.BlockFacts.flag?(state, :full_collision) and
          not Valimc.Data.BlockFacts.flag?(state, :signal_source) and
          (not fluid or Valimc.Data.BlockFacts.fluid(state).kind == :empty) and
          not MapSet.member?(@no_spawn, Blocks.block_id(state)) and
          not MapSet.member?(@dangerous, Blocks.block_id(state)) and
          not burning?(state)
    end
  end

  # `NodeEvaluator.isBurningBlock`'s campfires and lava cauldrons.
  defp burning?(state) do
    name = Blocks.name(Blocks.block_id(state))

    (name in ["campfire", "soul_campfire"] and property(state, "lit") == "true") or
      name == "lava_cauldron"
  end

  # `level.isUnobstructed(golem)`: no living mob's box meets the golem's.
  defp unobstructed?(self, {x, y, z}) do
    box = {x + 0.5 - 0.7, y * 1.0, z + 0.5 - 0.7, x + 0.5 + 0.7, y + 2.7, z + 0.5 + 0.7}

    not Enum.any?(self.world.mobs ++ self.world.players, fn m ->
      m.alive and World.intersects?(World.box(m), box)
    end)
  end

  ## Work, meet and rest

  defmodule WorkAtPoi do
    @moduledoc false
    alias Valimc.AI.{Behavior, Brain, Pois}

    def extra(state, self) do
      now = self.world.time

      if now - state.last_check < 300 do
        {false, state, self}
      else
        {n, self} = Behavior.level_int(self, 2)

        if n != 0 do
          {false, state, self}
        else
          state = %{state | last_check: now}
          {near?(self), state, self}
        end
      end
    end

    def start(state, self) do
      {_, pos} = Brain.get(self, :job_site)
      {x, y, z} = pos

      self =
        self
        |> Brain.set(:last_worked_at_poi, self.world.time)
        |> Brain.set(:look_target, {:block, pos, {x + 0.5, y + 0.5, z + 0.5}})

      # `playWorkSound` (a nitwit's or an unemployed one's is none).
      case Valimc.AI.Villagers.profession(self.data.profession).work_sound do
        nil -> {state, self}
        sound -> {state, Valimc.AI.make_sound(self, Valimc.AI.Villagers.sound_id(sound))}
      end
    end

    def still(state, self), do: {Brain.has?(self, :job_site) and near?(self), state, self}
    def tick(state, self), do: {state, self}
    def stop(state, self), do: {state, self}

    defp near?(self) do
      case Brain.get(self, :job_site) do
        {dimension, pos} ->
          dimension == self.world.dimension and
            Pois.near_center?(pos, {self.x, self.y, self.z}, 1.73)

        nil ->
          false
      end
    end
  end

  defp work_at_poi,
    do:
      Behavior.timed(WorkAtPoi, [job_site: :present, look_target: :registered], {60, 60}, %{
        last_check: 0
      })

  # `SocializeAtBell`: near the bell, now and then, a villager it sees.
  defp socialize_at_bell do
    Behavior.one_shot(
      [
        walk_target: :registered,
        look_target: :registered,
        meeting_point: :present,
        nearest_visible_living_entities: :present,
        interaction_target: :absent
      ],
      fn self ->
        {n, self} = Behavior.level_int(self, 100)
        {dimension, pos} = Brain.get(self, :meeting_point)

        with 0 <- n,
             true <- dimension == self.world.dimension,
             true <- Pois.near_center?(pos, {self.x, self.y, self.z}, 4.0),
             {%{}, self} <-
               Valimc.AI.Sensors.visible_closest(self, &Behaviors.is?(&1, "minecraft:villager")) do
          {mob, self} =
            Valimc.AI.Sensors.visible_closest(self, fn e ->
              Behaviors.is?(e, "minecraft:villager") and World.distance_sq(self, e) <= 32.0
            end)

          self =
            if mob do
              ref = World.ref(mob)

              self
              |> Brain.set(:interaction_target, ref)
              |> Brain.set(:look_target, {:entity, ref, true})
              |> Brain.set(:walk_target, %{
                target: {:entity, ref, false},
                speed: Float32.round(0.3),
                close: 1
              })
            else
              self
            end

          {true, self}
        else
          {_, %Self{} = self} -> {false, self}
          _ -> {false, self}
        end
      end
    )
  end

  # `InsideBrownianWalk`: under a roof, a random neighbouring block it can
  # stand on under it too.
  defp brownian_walk(speed, random) do
    Behavior.one_shot([walk_target: :absent], random, fn self, random ->
      {x, y, z} = block = Self.block(self)

      if sky?(self, block) do
        {false, self, random}
      else
        cells = for dz <- -1..1, dy <- -1..1, dx <- -1..1, do: {x + dx, y + dy, z + dz}
        {cells, random} = shuffle(cells, random)

        target =
          Enum.find(cells, fn cell -> not sky?(self, cell) and stands_on?(self, cell) end)

        self =
          if target && World.fits?(self.world, Self.box(self)),
            do:
              Brain.set(self, :walk_target, %{
                target: {:block, target, center(target)},
                speed: Float32.round(speed),
                close: 0
              }),
            else: self

        {true, self, random}
      end
    end)
  end

  defp center({x, y, z}), do: {x + 0.5, y + 0.5, z + 0.5}

  # `Collections.shuffle` uses a separate RNG, not the level or mob random.
  # Keep that independent stream in this existing one-shot's owned state.
  defp shuffle(list, random) do
    tuple = List.to_tuple(list)

    {tuple, random} =
      Enum.reduce((tuple_size(tuple) - 1)..1//-1, {tuple, random}, fn i, {t, random} ->
        {j, random} = Random.int(random, i + 1)
        a = elem(t, i)
        {put_elem(put_elem(t, i, elem(t, j)), j, a), random}
      end)

    {Tuple.to_list(tuple), random}
  end

  # `canSeeSky`: no sky source above (a column's lowest sky source).
  defp sky?(%Self{world: world}, pos), do: World.sky?(world, pos)

  # `loadedAndEntityCanStandOn`: a block whose top face is sturdy for the mob.
  defp stands_on?(self, {x, y, z}) do
    case World.block(self.world, {x, y, z}) do
      nil -> false
      state -> Valimc.Data.BlockFacts.flag?(state, :sturdy_up)
    end
  end

  ## Sleeping

  defmodule Sleep do
    @moduledoc false
    alias Valimc.AI.{Brain, Pois, World}
    alias Valimc.AI.Brains.Villager

    def extra(state, self) do
      {dimension, pos} = Brain.get(self, :home)

      woken =
        case Brain.get(self, :last_woken) do
          nil -> false
          at -> (t = self.world.time - at) > 0 and t < 100
        end

      bed = World.block(self.world, pos)

      ok =
        dimension == self.world.dimension and not woken and
          Pois.near_center?(pos, {self.x, self.y, self.z}, 2.0) and bed != nil and
          Villager.sleeps_on?(bed) and not Villager.occupied?(bed)

      {ok, state, self}
    end

    def start(state, self) do
      if self.world.time > state.next do
        {_, pos} = Brain.get(self, :home)

        self =
          case Brain.get(self, :doors_to_close) do
            nil -> self
            doors -> Valimc.AI.Behaviors.close_doors(self, nil, nil, doors)
          end

        {slept, self} = Villager.start_sleeping(self, pos)
        self = if slept, do: Brain.set(self, :last_slept, self.world.time), else: self

        {state, self |> Brain.erase(:walk_target) |> Brain.erase(:cant_reach_walk_target_since)}
      else
        {state, self}
      end
    end

    def still(state, self) do
      case Brain.get(self, :home) do
        {_, {_, by, _} = pos} ->
          {Brain.active?(self, :rest) and self.y > by + 0.4 and
             Pois.near_center?(pos, {self.x, self.y, self.z}, 1.14), state, self}

        nil ->
          {false, state, self}
      end
    end

    def tick(state, self), do: {state, self}

    def stop(state, self) do
      if self.data.sleeping != nil,
        do: {%{state | next: self.world.time + 40}, Villager.stop_sleeping(self)},
        else: {state, self}
    end
  end

  defp sleep_in_bed,
    do:
      Behavior.timed(
        Sleep,
        [
          home: :present,
          last_woken: :registered,
          last_slept: :registered,
          walk_target: :registered,
          cant_reach_walk_target_since: :registered
        ],
        :forever,
        %{next: 0}
      )

  @bed_height 0.5625
  @facings %{"north" => :north, "south" => :south, "west" => :west, "east" => :east}

  @doc """
  `LivingEntity.startSleeping(bed)`: it lies on the bed (its centre, the
  bed's height and 0.125 up, still), the bed's `occupied` set
  (`{:bed, head, true}`, the owner's), and its pose and sleeping place.
  `{slept, self}`.
  """
  def start_sleeping(%Self{} = self, {x, y, z} = bed) do
    case World.block(self.world, bed) do
      state when is_integer(state) ->
        if bed_block?(state) do
          position = {x + 0.5, y + @bed_height + 0.125, z + 0.5}

          self =
            self
            |> at(position)
            |> Map.put(:velocity, {0.0, 0.0, 0.0})
            |> Self.effect({:bed, bed, true})

          {true, %{self | data: %{self.data | sleeping: bed}}}
        else
          {false, self}
        end

      _ ->
        {false, self}
    end
  end

  defp bed_block?(state), do: Blocks.class(state) in ["BedBlock"]

  defp at(self, {x, y, z}), do: %{self | x: x, y: y, z: z}

  @doc """
  `Villager.stopSleeping`: off the bed (its `occupied` cleared, standing up
  where the bed lets it, facing the bed), standing, and when it woke.
  """
  def stop_sleeping(%Self{data: %{sleeping: bed}} = self) when bed != nil do
    self =
      case World.block(self.world, bed) do
        state when is_integer(state) ->
          if bed_block?(state) do
            facing = Map.fetch!(@facings, property(state, "facing"))
            {bx, by, bz} = bed

            {sx, sy, sz} =
              stand =
              case self.world.stand_up do
                nil -> nil
                fun -> fun.(self.type, bed, facing, self.yaw)
              end || {bx + 0.5, by + 1 + 0.1, bz + 0.5}

            {lx, _, lz} = {bx + 0.5 - sx, by - sy, bz + 0.5 - sz}
            yaw = look_yaw(lx, lz)

            %{self | yaw: yaw, pitch: 0.0}
            |> at(stand)
            |> Self.effect({:bed, bed, false})
          else
            self
          end

        _ ->
          self
      end

    %{self | data: %{self.data | sleeping: nil}}
    |> Brain.set(:last_woken, self.world.time)
  end

  def stop_sleeping(self), do: self

  # `(float)Mth.wrapDegrees(Mth.atan2(z, x) * RAD_TO_DEG - 90)` of the
  # normalized direction to the bed (normalizing keeps its angle).
  defp look_yaw(x, z) do
    angle = AI.Mth.atan2(z, x) * 57.2957763671875 - 90.0
    Float32.round(wrap(angle))
  end

  defp wrap(degrees) do
    d = :math.fmod(degrees, 360.0)

    cond do
      d >= 180.0 -> d - 360.0
      d < -180.0 -> d + 360.0
      true -> d
    end
  end

  ## Babies

  defmodule JumpOnBed do
    @moduledoc false
    alias Valimc.AI.{Behavior, Brain, Self, World}
    alias Valimc.AI.Brains.Villager

    def extra(state, self), do: {baby?(self) and near_bed?(self), state, self}

    def start(state, self) do
      case Brain.get(self, :nearest_bed) do
        nil ->
          {state, self}

        {x, y, z} = bed ->
          {n, self} = Behavior.level_int(self, 4)

          self =
            Brain.set(self, :walk_target, %{
              target: {:block, bed, {x + 0.5, y + 0.5, z + 0.5}},
              speed: state.speed,
              close: 0
            })

          {%{state | bed: bed, reach: 100, jumps: 3 + n, cooldown: 0}, self}
      end
    end

    def still(state, self) do
      ok =
        baby?(self) and state.bed != nil and jumpable?(self, state.bed) and
          not (not over_bed?(self) and state.reach <= 0) and
          not (over_bed?(self) and state.jumps <= 0)

      {ok, state, self}
    end

    def tick(state, self) do
      cond do
        not over_bed?(self) ->
          {%{state | reach: state.reach - 1}, self}

        state.cooldown > 0 ->
          {%{state | cooldown: state.cooldown - 1}, self}

        jumpable?(self, Self.block(self)) ->
          {%{state | jumps: state.jumps - 1, cooldown: 5}, Self.jump(self)}

        true ->
          {state, self}
      end
    end

    def stop(state, self), do: {%{state | bed: nil, reach: 0, jumps: 0, cooldown: 0}, self}

    defp baby?(self), do: self.data.age < 0

    defp near_bed?(self), do: over_bed?(self) or Brain.has?(self, :nearest_bed)

    defp over_bed?(self) do
      {x, y, z} = Self.block(self)
      jumpable?(self, {x, y, z}) or jumpable?(self, {x, y - 1, z})
    end

    defp jumpable?(self, pos) do
      case World.block(self.world, pos) do
        nil -> false
        state -> Villager.jumps_on?(state)
      end
    end
  end

  @doc "Whether babies jump on `state` (`VILLAGER_BABIES_CAN_JUMP_ON_BED`)."
  def jumps_on?(state), do: MapSet.member?(@jump_beds, Blocks.block_id(state))

  defp jump_on_bed(speed),
    do:
      Behavior.timed(JumpOnBed, [nearest_bed: :present, walk_target: :absent], :forever, %{
        speed: Float32.round(speed),
        bed: nil,
        reach: 0,
        jumps: 0,
        cooldown: 0
      })

  @doc """
  `Villager.wantsToSpawnGolem` of a sensed villager: it slept within a day
  and has seen no golem lately.
  """
  def wants_golem?(%{memories: memories}, now) when is_map(memories) do
    case memories do
      %{golem_detected_recently: _} -> false
      %{last_slept: {at, _}} -> now - at < 24_000
      _ -> false
    end
  end

  def wants_golem?(_mob, _now), do: false

  ## The mob's hooks

  @doc "`registerBrainGoals` when a villager is made: the schedule picks its activity."
  def started(self), do: schedule(self)

  @doc """
  `Villager.customServerAiStep` after the brain: one in a hundred ticks it
  looks for a raid (none yet), drawn from its random.
  """
  def update_activity(self) do
    {_, self} = Self.int(self, 100)
    self
  end

  @doc "`Villager.getAmbientSound`: none asleep (trading is VMC-044's)."
  def ambient_sound(self),
    do: if(sleeping?(self), do: nil, else: "minecraft:entity.villager.ambient")

  @doc "`Villager.wantsToPickUp`: its inventory is VMC-044's, so nothing yet."
  def wants?(_self, _item), do: false

  @doc """
  After the move: `AgeableMob.aiStep`'s ageing (a baby growing up makes its
  brain again) and `Villager.tick`'s unhappy counter.
  """
  def pick_up(%Self{data: data} = self) do
    age = data.age

    {age, grown} =
      cond do
        age < 0 -> {age + 1, age + 1 == 0}
        age > 0 -> {age - 1, false}
        true -> {0, false}
      end

    self = %{self | data: %{data | age: age, unhappy: max(data.unhappy - 1, 0)}}
    if grown, do: refresh(self), else: self
  end

  ## Sensors

  defmodule NearestBed do
    @moduledoc false
    alias Valimc.AI.{Behavior, Brain, Navigation, Pois, Self}

    # `NearestBedSensor`: a baby looks for a bed it can reach (five a try).
    def scan(%Self{data: %{age: age}} = self) when age >= 0, do: self

    def scan(self) do
      {n, self} = Behavior.level_int(self, 20)
      last = self.world.time + n
      cache = Brain.get(self, :__bed_cache) || %{}

      {pois, {cache, tried}} =
        self.world
        |> Pois.in_range(["minecraft:home"], Self.block(self), 48, :any)
        |> Enum.flat_map_reduce({cache, 0}, fn {_, pos} = poi, {cache, tried} ->
          cond do
            Map.has_key?(cache, pos) -> {[], {cache, tried}}
            tried + 1 >= 5 -> {[], {cache, tried + 1}}
            true -> {[poi], {Map.put(cache, pos, last + 40), tried + 1}}
          end
        end)

      {path, self} =
        if pois == [],
          do: {nil, self},
          else: Navigation.path_to_any(self, Enum.map(pois, &elem(&1, 1)), 1)

      cond do
        is_map(path) and Map.get(path, :reached) == true and
            Pois.type_at(self.world, path.target) != nil ->
          self |> Brain.set(:nearest_bed, path.target) |> Brain.set(:__bed_cache, cache)

        tried < 5 ->
          Brain.set(self, :__bed_cache, for({p, t} <- cache, t >= last, into: %{}, do: {p, t}))

        true ->
          Brain.set(self, :__bed_cache, cache)
      end
    end
  end

  defmodule Hostiles do
    @moduledoc false
    alias Valimc.AI.{Brain, Sensors, World}

    @distances %{
      "minecraft:drowned" => 8.0,
      "minecraft:evoker" => 12.0,
      "minecraft:husk" => 8.0,
      "minecraft:illusioner" => 12.0,
      "minecraft:pillager" => 15.0,
      "minecraft:ravager" => 12.0,
      "minecraft:vex" => 8.0,
      "minecraft:vindicator" => 10.0,
      "minecraft:zoglin" => 10.0,
      "minecraft:zombie" => 8.0,
      "minecraft:zombie_villager" => 8.0
    }

    @doc false
    def hostile?(type), do: Map.has_key?(@distances, type)

    # `VillagerHostilesSensor`: the nearest visible hostile within its distance.
    def scan(self) do
      {hostile, self} =
        Sensors.visible_closest(self, fn
          %{kind: :mob, type: type} = mob ->
            case @distances do
              %{^type => d} -> World.distance_sq(self, mob) <= d * d
              _ -> false
            end

          _ ->
            false
        end)

      Brain.set(self, :nearest_hostile, World.ref(hostile))
    end
  end

  defmodule Babies do
    @moduledoc false
    alias Valimc.AI.{Brain, Sensors, World}

    # `VillagerBabiesSensor`.
    def scan(self) do
      {seen, self} = Sensors.visible_all(self)

      babies =
        for %{kind: :mob, type: "minecraft:villager", data: %{age: age}} = m <- seen,
            age < 0,
            do: World.ref(m)

      Brain.set(self, :visible_villager_babies, babies)
    end
  end

  defmodule SecondaryPois do
    @moduledoc false
    alias Valimc.AI.{Brain, Self, Villagers, World}

    # `SecondaryPoiSensor`: its trade's secondary blocks 4 around and 2 up and down.
    def scan(self) do
      blocks = Villagers.profession(self.data.profession).secondary
      {cx, cy, cz} = Self.block(self)

      sites =
        if blocks == [] do
          []
        else
          for x <- -4..4,
              y <- -2..2,
              z <- -4..4,
              state = World.block(self.world, {cx + x, cy + y, cz + z}),
              state != nil and
                Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(state)) in blocks,
              do: {self.world.dimension, {cx + x, cy + y, cz + z}}
        end

      if sites == [],
        do: Brain.erase(self, :secondary_job_site),
        else: Brain.set(self, :secondary_job_site, sites)
    end
  end

  defmodule Golems do
    @moduledoc false
    alias Valimc.AI.{Brain, World}

    # `GolemSensor`: an iron golem among the living near it.
    def scan(self) do
      golem =
        Enum.any?(Brain.get(self, :nearest_living_entities) || [], fn ref ->
          match?(%{type: "minecraft:iron_golem"}, World.entity(self.world, ref))
        end)

      if golem, do: Brain.set(self, :golem_detected_recently, true, 599), else: self
    end
  end
end
