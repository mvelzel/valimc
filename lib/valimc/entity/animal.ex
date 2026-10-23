defmodule Valimc.Entity.Animal do
  @moduledoc """
  What every farm animal shares (VMC-043c): vanilla's `AgeableMob` and
  `Animal`. Each animal's own code is its module (`Valimc.Entity.Animals.*`):
  a mob family of `Valimc.AI.Mobs` (`Valimc.AI.Kind`) whose shared hooks
  `use Valimc.Entity.Animal` gives (its data and entity data, a baby's
  dimensions, `finalizeSpawn`, `customServerAiStep`, `aiStep` after its
  super, a hurt's lost love, a baby's voice), and this behaviour's own
  parts: its goals, data, offspring, interactions and its part of the tick.
  This module holds the common part and the generated facts (`AnimalOracle
  facts`, `animal_facts.json`: baby dimensions, food, variants and their
  spawn selectors, sound variants, sound ids).

  An animal's age, forced age, age lock, love and the player who caused it
  are its body's data, saved with it (`Age`, `ForcedAge`, `AgeLocked`,
  `InLove`, `LoveCause`); a baby's age is negative and counts up, a parent's
  is positive after breeding and counts down. Breeding, feeding and growing
  draw on the mob's own random where vanilla's do (`Valimc.AI.Self`), so an
  animal's goals keep drawing what vanilla's would.
  """
  use Valimc.Data.Facts, "registry/animal_facts.json"

  alias Valimc.AI.Self
  alias Valimc.Entity.Body
  alias Valimc.Data.Float32
  alias Valimc.Protocol.{Data, ItemTypes}

  @doc "The goals and targets the animal registers (`Valimc.AI.Mobs.registered/1`)."
  @callback goals() :: {list, list}
  @doc "The animal's own data and its defaults (beyond the ageable part)."
  @callback defaults() :: map
  @doc "The animal's own entity data fields of its `data`: `[{field, value, default}]`."
  @callback fields(map) :: list
  @doc "`getBreedOffspring`: the child's own data, drawn from the parent's random."
  @callback offspring(Self.t(), map) :: {map, Self.t()}
  @doc "The animal's part of `aiStep` after the shared one."
  @callback settle(Self.t()) :: Self.t()
  @doc """
  What its loot tables' entity predicates read of it (its components'
  values, a sheep's shearing): `[{name, value}]`.
  """
  @callback properties(map) :: [{String.t(), String.t()}]
  @doc """
  Its own `mobInteract` before the shared one (`Valimc.Entity.Animals.Interaction`):
  `:pass`, `:consume` or `{:ok, body, outcome}`.
  """
  @callback interact(map, map) :: :pass | :consume | {:ok, map, map}
  @doc "A held item's own use on it after the rest passed (`interactLivingEntity`: dye)."
  @callback use_item(map, map) :: :pass | {:ok, map, map}
  @doc "Its own `customServerAiStep`, in place of the shared one (a rabbit's hops)."
  @callback server_ai_step(Self.t()) :: Self.t()
  @doc "Its own part of `finalizeSpawn` (variants, colour, type) before the shared one."
  @callback spawn_part(Self.t(), atom) :: Self.t()
  @doc "`Mob.ate`: what eating a block does to it (a sheep's wool grows back)."
  @callback ate(Self.t()) :: Self.t()
  @optional_callbacks settle: 1,
                      ate: 1,
                      server_ai_step: 1,
                      spawn_part: 2,
                      properties: 1,
                      interact: 2,
                      use_item: 2

  @doc """
  An animal's module (`use Valimc.Entity.Animal, type: name`): a mob family
  of its one type (`Valimc.AI.Kind`) with the hooks every animal shares,
  which it may override.
  """
  defmacro __using__(type: type) do
    quote do
      @behaviour Valimc.AI.Kind
      @behaviour Valimc.Entity.Animal

      @impl Valimc.AI.Kind
      def types, do: [unquote(type)]
      @impl Valimc.AI.Kind
      def goals(_type), do: goals()
      @impl Valimc.AI.Kind
      def data(type), do: Valimc.Entity.Animal.data(type)
      @impl Valimc.AI.Kind
      def values(body), do: Valimc.Entity.Animal.values(body)
      @impl Valimc.AI.Kind
      def dimensions(body), do: Valimc.Entity.Animal.dimensions(body)
      @impl Valimc.AI.Kind
      def finalize(self, reason), do: Valimc.Entity.Animal.finalize(self, reason)
      @impl Valimc.AI.Kind
      def custom_step(self), do: Valimc.Entity.Animal.ai_step(self)
      @impl Valimc.AI.Kind
      def after_ai(self), do: Valimc.Entity.Animal.settle(self)
      # `Animal.actuallyHurt`: love is gone.
      @impl Valimc.AI.Kind
      def hurt(body, _hit), do: %{body | data: Valimc.Entity.Animal.reset_love(body.data)}
      # `getVoicePitch`: a baby's is higher.
      @impl Valimc.AI.Kind
      def voice(_type, data), do: if(data.age < 0, do: 1.5, else: 1.0)
      # `Mob.canBeLeashed`: an animal is no `Enemy`.
      @impl Valimc.AI.Kind
      def leashable?, do: true

      defoverridable types: 0,
                     goals: 1,
                     data: 1,
                     values: 1,
                     dimensions: 1,
                     finalize: 2,
                     custom_step: 1,
                     after_ai: 1,
                     hurt: 2,
                     voice: 2,
                     leashable?: 0
    end
  end

  @modules %{
    "minecraft:cow" => Valimc.Entity.Animals.Cow,
    "minecraft:mooshroom" => Valimc.Entity.Animals.Mooshroom,
    "minecraft:pig" => Valimc.Entity.Animals.Pig,
    "minecraft:sheep" => Valimc.Entity.Animals.Sheep,
    "minecraft:chicken" => Valimc.Entity.Animals.Chicken,
    "minecraft:rabbit" => Valimc.Entity.Animals.Rabbit
  }

  @doc "The module of animal type `type`, or nil."
  def module(type), do: Map.get(@modules, type)

  @doc "The animals' modules (families of `Valimc.AI.Mobs`)."
  def modules, do: Map.values(@modules)

  defp module!(type), do: Map.fetch!(@modules, type)

  @doc "Whether `type` is a modelled animal."
  def animal?(type), do: Map.has_key?(@modules, type)

  @doc "The modelled animal types."
  def types, do: Map.keys(@modules)

  dims = fn [w, h, e] ->
    for bits <- [w, h, e] do
      <<v::float-32>> = <<bits::signed-32>>
      v
    end
    |> List.to_tuple()
  end

  @animals Map.new(@facts["animals"], fn {type, row} ->
             {type,
              %{
                baby: dims.(row["baby"]),
                food: MapSet.new(row["food"], &ItemTypes.id/1)
              }}
           end)

  unless Map.keys(@animals) |> Enum.sort() == Map.keys(@modules) |> Enum.sort(),
    do: raise("animal facts and modules differ")

  @monsters MapSet.new(@facts["monsters"])

  @doc "Whether mobs of `type` are vanilla `Monster`s (what a rabbit avoids)."
  def monster?(type), do: MapSet.member?(@monsters, type)

  @biome_tags Map.new(Data.tags()["minecraft:worldgen/biome"], fn {tag, ids} ->
                {tag, MapSet.new(ids, &Data.registry_name("minecraft:worldgen/biome", &1))}
              end)

  @doc "Whether biome `biome` (a name; nil: unknown, in none) is in biome tag `tag`."
  def biome_in?(nil, _tag), do: false
  def biome_in?(biome, tag), do: MapSet.member?(Map.get(@biome_tags, tag, MapSet.new()), biome)

  @doc "Whether item `id` is food for an animal of `type` (`isFood`)."
  def food?(type, id), do: id != nil and MapSet.member?(@animals[type].food, id)

  @doc """
  The width, height and eye height of an animal body (`getDefaultDimensions`:
  a baby's are its own), else nil (its type's).
  """
  def dimensions(%{type: type, data: %{age: age}}) when age < 0, do: @animals[type].baby
  def dimensions(_body), do: nil

  @variants Map.new(@facts["variants"], fn {registry, list} ->
              {registry,
               for v <- list do
                 {v["name"], for(s <- v["selectors"], do: {s["priority"], s["biomes"]})}
               end}
            end)

  @doc """
  `VariantUtils.selectVariantToSpawn` of variant `registry` in the biome of
  id `biome` (`biome?.(tag)` tells whether it is in a biome tag): the
  variants matching at the highest priority, one picked with `int` (a
  `nextInt(bound)` draw, `Util.getRandomSafe`). `{name, state}`.
  """
  def spawn_variant(registry, biome?, int, state) do
    matching =
      for {name, selectors} <- @variants[registry],
          {priority, tag} <- selectors,
          tag == nil or biome?.(tag),
          do: {priority, name}

    top = matching |> Enum.map(&elem(&1, 0)) |> Enum.max()
    names = for {^top, name} <- matching, do: name
    {n, state} = int.(state, length(names))
    {Enum.at(names, n), state}
  end

  @stew_flowers Map.new(@facts["stew_flowers"], fn {item, effects} ->
                  {item, for([effect, duration] <- effects, do: {effect, duration})}
                end)

  @doc "The flowers a brown mooshroom's stew takes effects from: `item => [{effect, duration}]`."
  def stew_flowers, do: @stew_flowers

  @sound_variants @facts["sound_variants"]
  @sounds @facts["sounds"]

  @doc "The sounds of sound variant `name` of `registry` (`adult`/`baby` sets where it has them)."
  def sound_variant(registry, name), do: @sound_variants[registry][name]

  @doc "The protocol id of sound `name` an animal plays."
  def sound_id(name), do: Map.fetch!(@sounds, name)

  @doc "The network id of variant `name` of registry `registry`."
  def variant_id(registry, name), do: Data.registry_id(registry, name)

  ## Data

  @ageable %{age: 0, forced_age: 0, age_locked: false, in_love: 0, love_cause: nil}

  @doc "The data of a fresh animal of `type`."
  def data(type), do: Map.merge(@ageable, module!(type).defaults())

  @doc "An animal body's entity data fields: the ageable flags, then its own."
  def values(%{type: type, data: data}), do: values(type, data)

  defp values(type, data),
    do:
      [{:ageable_baby, data.age < 0, false}, {:age_locked, data.age_locked, false}] ++
        module!(type).fields(data)

  @doc "`setAge`."
  def set_age(data, age), do: %{data | age: age}

  @doc "`setBaby(true)`: the start of a baby's age."
  def baby(data), do: %{data | age: -24_000}

  @doc "`canAgeUp`: a baby whose age is not locked."
  def can_age_up?(data), do: data.age < 0 and not data.age_locked

  @doc """
  `ageUp(seconds, forced)`: older by `seconds` (never past adult); a forced
  ageing (feeding) counts toward the forced age, which an adult keeps, and
  starts the particle timer. `{data, timer}` from the mind's `timer`.
  """
  def age_up(data, seconds, forced, timer) do
    old = data.age
    age = min(old + seconds * 20, 0)
    data = %{data | age: age}

    {data, timer} =
      if forced do
        {%{data | forced_age: data.forced_age + (age - old)}, if(timer == 0, do: 40, else: timer)}
      else
        {data, timer}
      end

    data = if data.age == 0, do: %{data | age: data.forced_age}, else: data
    {data, timer}
  end

  @doc "`getSpeedUpSecondsWhenFeeding`: a tenth of the baby's time left, in seconds."
  def speed_up_seconds(ticks), do: trunc(Float32.round(div(ticks, 20) * Float32.round(0.1)))

  @doc "`setInLove(player)`: 600 ticks, caused by `player` (a uuid or nil)."
  def set_in_love(data, player),
    do: %{data | in_love: 600, love_cause: player || data.love_cause}

  @doc "`resetLove` (an animal actually hurt loses its love)."
  def reset_love(data), do: %{data | in_love: 0}

  @doc "`canFallInLove`."
  def can_fall_in_love?(data), do: data.in_love <= 0

  @doc "What hurting it leaves in its data (an animal's love is gone)."
  def hurt(type, data), do: if(animal?(type), do: reset_love(data), else: data)

  @doc """
  `body`'s data after its living rules left it `mob`: an animal actually
  hurt (its health changed) loses its love (`Animal.actuallyHurt`).
  """
  def hurt_if(type, %{mob: before, data: data}, mob) do
    if mob.living.health != before.living.health, do: hurt(type, data), else: data
  end

  @doc "`isBaby`: whether a body (or an animal's data) is a baby animal's."
  def baby?(%{type: type, data: data}), do: animal?(type) and data.age < 0
  def baby?(%{age: age}), do: age < 0

  @doc "The sound set of a `kind` (`cow`, `pig`, `chicken`) animal with `data`."
  def sound_set(kind, data) do
    set = sound_variant("minecraft:#{kind}_sound_variant", data.sound_variant)

    cond do
      Map.has_key?(set, "adult") and data.age < 0 -> set["baby"]
      Map.has_key?(set, "adult") -> set["adult"]
      true -> set
    end
  end

  @doc """
  What loot tables read of a body (`Valimc.Blocks.Loot`'s `:properties`): an
  animal's own (a sheep's colour, a chicken's variant), else none.
  """
  def properties(%{type: type, data: data}) do
    module = module(type)

    if module != nil and function_exported?(module, :properties, 1),
      do: apply(module, :properties, [data]),
      else: []
  end

  def properties(_body), do: []

  ## Spawning

  @doc """
  `finalizeSpawn` of an animal (`Valimc.AI.Spawn`): its own part (a variant
  by its biome, a sound variant, a colour or type), then `AgeableMob`'s (a
  lone spawn's group is empty, so no baby) and `Mob`'s.
  """
  def finalize(%Self{type: type} = self, reason) do
    module = module!(type)

    self =
      if function_exported?(module, :spawn_part, 2),
        do: apply(module, :spawn_part, [self, reason]),
        else: self

    Valimc.AI.Spawn.mob(self, reason)
  end

  @doc "The biome where the mob stands (`level.getBiome(blockPosition())`)."
  def biome(%Self{} = self), do: Valimc.AI.World.biome(self.world, Self.block(self))

  @doc """
  A variant of `registry` for the mob's biome (`selectVariantToSpawn`),
  drawn from the level's random: `{name, self}`.
  """
  def pick_variant(%Self{} = self, registry) do
    biome = biome(self)
    spawn_variant(registry, &biome_in?(biome, &1), &Valimc.AI.Spawn.level_int/2, self)
  end

  @doc "`Registry.getRandom` of `registry`'s entries in network order, from the level's random."
  def pick_random(%Self{} = self, registry) do
    names = Data.registries()[registry]
    {n, self} = Valimc.AI.Spawn.level_int(self, length(names))
    {Enum.at(names, n), self}
  end

  @doc """
  `Mob.convertTo(type, ConversionParams.single(...))` of animal `body`
  (`ConversionType.SINGLE`): a new mob of `type` facing and moving as it
  did, keeping its age, effects, absorption, fire, name, persistence, AI
  flag and the player who last hurt it; its health is the new type's.
  """
  def convert(%Body{} = body, type) do
    {:ok, new} = Body.new(type)
    old = body.mob
    data = %{new.data | age: body.data.age, forced_age: body.data.forced_age}

    living = %{
      new.mob.living
      | effects: old.living.effects,
        absorption: old.living.absorption,
        fire_ticks: old.living.fire_ticks
    }

    mob = %{
      new.mob
      | living: living,
        no_ai: old.no_ai,
        persistent: old.persistent,
        hurt_by_player: old.hurt_by_player,
        player_memory: old.player_memory,
        left_handed: old.left_handed
    }

    %{
      new
      | yaw: body.yaw,
        pitch: body.pitch,
        head_yaw: body.head_yaw,
        velocity: body.velocity,
        on_ground: body.on_ground,
        custom_name: body.custom_name,
        data: data,
        mob: mob
    }
  end

  ## Feeding

  @doc """
  `setInLove` on an animal `body` a player (`player`, a uuid or nil) fed:
  600 ticks of love and the hearts event. `{body, events}`.
  """
  def fall_in_love(%{data: data} = body, player),
    do: {%{body | data: set_in_love(data, player)}, [{:event, 18}]}

  @doc """
  A baby animal `body` fed (`ageUp(getSpeedUpSecondsWhenFeeding(-age),
  true)`): a tenth of its time left, and its happy particles' timer.
  """
  def feed_baby(%{data: data, mob: mob} = body) do
    timer = timer(mob)
    {data, timer} = age_up(data, speed_up_seconds(-data.age), true, timer)
    %{body | data: data, mob: put_timer(mob, timer)}
  end

  defp timer(%{ai: %Valimc.AI.Mind{forced_age_timer: timer}}), do: timer
  defp timer(_mob), do: 0

  defp put_timer(%{ai: %Valimc.AI.Mind{} = mind} = mob, timer),
    do: %{mob | ai: %{mind | forced_age_timer: timer}}

  defp put_timer(mob, _timer), do: mob

  ## The tick

  @doc """
  `Animal.customServerAiStep` (after the goals): only an adult stays in love;
  an animal with its own (a rabbit) runs that instead.
  """
  def ai_step(%Self{data: data} = self) do
    shared = if data.age != 0, do: %{self | data: %{data | in_love: 0}}, else: self
    own(self, :server_ai_step, shared)
  end

  @doc """
  `AgeableMob.aiStep` and `Animal.aiStep` after the move: the forced-age and
  age-lock particles' draws, the age counting toward 0, love running out
  with its hearts' draws every ten ticks, then the animal's own part.
  """
  def settle(%Self{} = self) do
    self = forced_age_particles(self)

    self =
      if Valimc.Entity.Mob.alive?(self.mob) do
        data = self.data

        cond do
          can_age_up?(data) -> %{self | data: %{data | age: data.age + 1}}
          data.age > 0 -> %{self | data: %{data | age: data.age - 1}}
          true -> self
        end
      else
        self
      end

    self = age_lock_particles(self)
    self = if self.data.age != 0, do: %{self | data: %{self.data | in_love: 0}}, else: self

    self =
      if self.data.in_love > 0 do
        love = self.data.in_love - 1
        self = %{self | data: %{self.data | in_love: love}}
        if rem(love, 10) == 0, do: hearts(self), else: self
      else
        self
      end

    own(self, :settle, self)
  end

  @doc "`Mob.ate` of the mob (an animal's module's, else nothing)."
  def ate(%Self{} = self), do: own(self, :ate, self)

  # The animal's own optional callback `name` on the mob, else `default`.
  defp own(%Self{type: type} = self, name, default) do
    module = module(type)

    if module != nil and function_exported?(module, name, 1),
      do: apply(module, name, [self]),
      else: default
  end

  # `addParticle(HEART, ...)`: three gaussian speeds, then `getRandomX(1.0)`,
  # `getRandomY()` and `getRandomZ(1.0)`; the particles are the client's.
  defp hearts(self) do
    {_, self} = Self.gaussian(self)
    {_, self} = Self.gaussian(self)
    {_, self} = Self.gaussian(self)
    random_point(self)
  end

  defp random_point(self) do
    {_, self} = Self.double(self)
    {_, self} = Self.double(self)
    {_, self} = Self.double(self)
    self
  end

  # A fed baby's happy-villager particles every fourth tick of its timer.
  defp forced_age_particles(%Self{mind: %{forced_age_timer: timer}} = self) when timer > 0 do
    self = if rem(timer, 4) == 0, do: random_point(self), else: self
    Self.mind(self, &%{&1 | forced_age_timer: timer - 1})
  end

  defp forced_age_particles(self), do: self

  # `makeAgeLockedParticle`: every other tick of its timer.
  defp age_lock_particles(%Self{mind: %{age_lock_timer: timer}} = self) when timer > 0 do
    self = if rem(timer, 2) == 0, do: random_point(self), else: self
    Self.mind(self, &%{&1 | age_lock_timer: timer - 1})
  end

  defp age_lock_particles(self), do: self

  ## Breeding

  @doc """
  `BreedGoal.breed`, `spawnChildFromBreeding` and
  `finalizeSpawnChildFromBreeding` for the mob and its sensed `partner`:
  the child's data from the parent's random (a baby where the parent
  stands), both parents' age 6,000 and love gone, the hearts event, and an
  orb of 1 to 7 while mobs drop loot. The child, the orb and the partner's
  change leave as effects (`{:offspring, type, data, at}`, `{:orb, value,
  at}` where the parent stood, `{:bred, partner}`).
  """
  def breed(%Self{} = self, partner) do
    {child, self} = module!(self.type).offspring(self, partner)
    child = baby(Map.merge(data(self.type), child))

    self = %{self | data: %{self.data | age: 6000, in_love: 0}}

    at = {self.x, self.y, self.z}

    self =
      self
      |> Self.effect({:offspring, self.type, child, at})
      |> Self.effect({:bred, Valimc.AI.World.ref(partner)})
      |> Self.effect({:event, 18})

    if self.world.mob_drops do
      {n, self} = Self.int(self, 7)
      Self.effect(self, {:orb, n + 1, at})
    else
      self
    end
  end

  @doc "What breeding leaves in the partner's data (`setAge(6000)`, `resetLove`)."
  def bred(data), do: %{data | age: 6000, in_love: 0}
end
