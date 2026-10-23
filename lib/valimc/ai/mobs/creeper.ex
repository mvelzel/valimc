defmodule Valimc.AI.Mobs.Creeper do
  @moduledoc """
  Creepers (VMC-043b4), as vanilla's `Creeper`:

  - **Goals**: floating, swelling at a target within three blocks it sees
    (`SwellGoal`), fleeing ocelots and cats, chasing (its "hits" do
    nothing), wandering and looking around; the player as its target, then
    whoever hurt it.
  - **Swelling** (`tick` before the rest): its fuse counts up while it
    swells (a lit one always does) and down otherwise; the hiss as it
    starts; at 30 it explodes (`{:explode, ...}`): power 3, twice that when
    charged, breaking blocks only while mobs may grief; it is gone.
  - **Lighting** (`mobInteract`): flint and steel or a fire charge lights
    it, worn or used up.
  - Its own data: the swell direction, charged and lit flags, the fuse and
    the explosion's radius.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Self}
  alias Valimc.Data.{Float32, HostileFacts}
  alias Valimc.Entity.Animals.Interaction
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @creeper "minecraft:creeper"

  @impl true
  def types, do: [@creeper]

  @impl true
  def goals(_type) do
    {[
       {1, "FloatGoal", Goals.Float, [:jump], %{}},
       {2, "SwellGoal", __MODULE__.Swell, [:move], __MODULE__.Swell.new()},
       {3, "AvoidEntityGoal", Goals.AvoidEntity, [:move],
        Goals.AvoidEntity.new(&(&1.kind == :mob and &1.type == "minecraft:ocelot"), 6.0, 1.0, 1.2)},
       {3, "AvoidEntityGoal", Goals.AvoidEntity, [:move],
        Goals.AvoidEntity.new(&(&1.kind == :mob and &1.type == "minecraft:cat"), 6.0, 1.0, 1.2)},
       {4, "MeleeAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, false)},
       {5, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(0.8, water_avoiding: true)},
       {6, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {6, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       {1, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true)},
       {2, "HurtByTargetGoal", Goals.HurtByTarget, [:target], Goals.HurtByTarget.new()}
     ]}
  end

  @impl true
  def data(_type),
    do: %{swell: 0, swell_dir: -1, powered: false, ignited: false, max_swell: 30, radius: 3}

  @impl true
  def values(%{data: data}) do
    [
      {:creeper_swell_dir, data.swell_dir, -1},
      {:creeper_powered, data.powered, false},
      {:creeper_ignited, data.ignited, false}
    ]
  end

  @igniters MapSet.new(
              Valimc.Protocol.Data.tags()["minecraft:item"]["minecraft:creeper_igniters"]
            )
  @fire_charge ItemTypes.id("fire_charge")

  @doc """
  `Creeper.mobInteract`: an igniter lights it (the others hear the item at
  the creeper, pitched from its random); flint and steel wears, a fire
  charge is used up.
  """
  @impl true
  def mob_interact(%{data: data} = body, %{item: %ItemStack{item_id: id}}) do
    if MapSet.member?(@igniters, id) and Valimc.Entity.Mob.alive?(body.mob) do
      {f, body} = Interaction.draw(body, &Valimc.AI.Random.float/1)
      pitch = Float32.round(Float32.round(f * Float32.round(0.4)) + Float32.round(0.8))
      name = if id == @fire_charge, do: "item.firecharge.use", else: "item.flintandsteel.use"
      source = Valimc.Protocol.CombatPackets.mob_sounds(body.type)["sound_source"]
      sound = {HostileFacts.sound_id("minecraft:" <> name), source, 1.0, pitch, :animal}
      damageable = ItemTypes.item(id)["max_damage"] != nil

      {:ok, %{body | data: %{data | ignited: true}},
       Interaction.outcome(
         hand: if(damageable, do: {:wear, 1}, else: {:use, 1}),
         swing: true,
         others: sound
       )}
    else
      :pass
    end
  end

  def mob_interact(_body, _request), do: :pass

  @doc "`Creeper.doHurtTarget`: its melee hits do nothing."
  @impl true
  def harmless?, do: true

  # `playSound(CREEPER_PRIMED, 1.0, 0.5)`: at the creeper, its seed the level's.
  defp primed(self) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    source = Valimc.Protocol.CombatPackets.mob_sounds(self.type)["sound_source"]
    Self.effect(self, {:sound, "minecraft:entity.creeper.primed", source, 1.0, 0.5, seed})
  end

  @doc """
  `Creeper.tick` before the rest of its tick: a lit creeper swells; the
  hiss as it starts; the fuse moves by the swell direction (never below 0)
  and at its end the creeper explodes, which ends its tick.
  """
  @impl true
  def tick_start(%Self{data: data, mob: mob} = self) do
    if Valimc.Entity.Mob.alive?(mob) do
      data = if data.ignited, do: %{data | swell_dir: 1}, else: data

      self =
        if data.swell_dir > 0 and data.swell == 0,
          do: primed(self),
          else: self

      swell = max(data.swell + data.swell_dir, 0)

      if swell >= data.max_swell do
        radius = data.radius * if(data.powered, do: 2.0, else: 1.0)

        %{self | data: %{data | swell: data.max_swell}}
        |> Self.effect(
          {:explode, %{center: {self.x, self.y, self.z}, radius: radius, powered: data.powered}}
        )
        |> Self.effect(:discard)
      else
        %{self | data: %{data | swell: swell}}
      end
    else
      self
    end
  end
end

defmodule Valimc.AI.Mobs.Creeper.Swell do
  @moduledoc """
  `SwellGoal`: a creeper about to explode, or with a living target within
  three blocks, stops and swells while the target stays within seven blocks
  and in sight, else lets its fuse fall back.
  """
  use Valimc.AI.Goal

  def new, do: %{target: nil}

  def can_use(state, self) do
    target = World.target(self)

    use =
      self.data.swell_dir > 0 or
        (target != nil and target.alive and World.distance_sq(self, target) < 9.0)

    {use, state, self}
  end

  def start(state, self),
    do: {%{state | target: World.ref(World.target(self))}, Navigation.stop(self)}

  def stop(state, self), do: {%{state | target: nil}, self}
  def every_tick?(_state), do: true

  def tick(state, self) do
    target = World.entity(self.world, state.target)

    {dir, self} =
      cond do
        target == nil or not target.alive ->
          {-1, self}

        World.distance_sq(self, target) > 49.0 ->
          {-1, self}

        true ->
          case World.sees?(self, target) do
            {true, self} -> {1, self}
            {false, self} -> {-1, self}
          end
      end

    {state, %{self | data: %{self.data | swell_dir: dir}}}
  end
end
