defmodule Valimc.Entity.Body do
  @moduledoc """
  The record of every entity kind beyond items and XP orbs (VMC-043a): one
  schema for living types (kind `:mob`, with a `Valimc.Entity.Mob`) and the
  rest (kind `:object`). A body holds its type, rotation and head yaw, motion,
  its type's own data (a primed TNT's fuse and block) and, for a mob, its
  living part. Its position and uuid are the store entry's, as for every kind.

  Only modelled types (`modelled?/1`) are made: their entity data is known
  value by value, so what a client is sent is what vanilla sends. Mob
  families (VMC-043b–e) and world effects (VMC-050a) add theirs. Generation
  makes a body of any type (`generated/3`, VMC-042b): one not modelled yet
  is inert, its type's data at the client's defaults, and keeps what
  generation gave it (`preserved`) for its family.

  `values/2` gives every modelled entity data field with its value and
  vanilla's default; a spawn sends those that differ (vanilla's
  `getNonDefaultValues`), a tracker those that changed.
  """
  alias Valimc.Data.{Blocks, EntityTypes}
  alias Valimc.Entity.{Mob, Projectile}
  alias Valimc.Protocol.{EntityPackets, Packets}

  defstruct type: nil,
            yaw: 0.0,
            pitch: 0.0,
            head_yaw: 0.0,
            velocity: {0.0, 0.0, 0.0},
            on_ground: false,
            no_gravity: false,
            data: %{},
            mob: nil,
            # A name tag's text component (VMC-042a), as items keep theirs.
            custom_name: nil,
            # What generation gave it beyond type, position and yaw, as SNBT
            # (VMC-042b: a template's entity NBT, a minecart's loot table, a
            # frame's item), kept until its family reads it.
            preserved: nil,
            # Ticks before a portal takes the body again (VMC-026d, `portalCooldown`).
            portal_cooldown: 0

  @tnt "minecraft:tnt"
  @falling "minecraft:falling_block"
  @chicken "minecraft:chicken"
  @cloud "minecraft:area_effect_cloud"
  @frames ["minecraft:item_frame", "minecraft:glow_item_frame"]
  # An egg's chickens and an ender pearl's endermites (VMC-037o) are bodies
  # with their type's data; their families' behaviour is VMC-043d's and 043b's.
  @modelled MapSet.new(
              ["minecraft:zombie", @chicken, "minecraft:endermite", @tnt, @falling, @cloud] ++
                Projectile.types() ++ Valimc.AI.Mobs.Zombie.types()
            )
  @plain for name <- EntityTypes.names(),
             EntityTypes.living?(name) and EntityTypes.fetch(name).category != :misc,
             into: MapSet.new(),
             do: name

  @doc """
  Whether type `type` is modelled (it can be summoned and stored): the types
  above, and every living type of a spawning category as a plain mob (its
  own entity data at vanilla's defaults, VMC-042a) until its family models
  what `finalizeSpawn` gives it.
  """
  def modelled?(type), do: MapSet.member?(@modelled, type) or MapSet.member?(@plain, type)

  def modelled, do: @modelled

  @doc "The store kind of type `type`: `:mob` for a living type, else `:object`."
  def kind(type), do: if(EntityTypes.living?(type), do: :mob, else: :object)

  @doc "A fresh body of modelled type `type`, as `/summon` makes it."
  def new(type) do
    if modelled?(type) do
      body = %__MODULE__{type: type, data: data(type)}
      {:ok, if(kind(type) == :mob, do: %{body | mob: Mob.new(type)}, else: body)}
    else
      {:error, :unmodelled_type}
    end
  end

  @doc """
  A fresh body of modelled type `type` that enters the world for `reason`
  (`:natural`, `:spawner`, `:command`, `:chunk_generation`, ...): a mob
  finishes its spawn (`finalizeSpawn`, VMC-043b) on its first tick.
  """
  def spawned(type, reason) do
    with {:ok, %__MODULE__{mob: %Mob{} = mob} = body} <- new(type),
         do: {:ok, %{body | mob: %{mob | finalize: reason}}}
  end

  @doc """
  A body of any entity type `type` that generation added (VMC-042b): as
  `new/1` makes a modelled type's, else inert with no data of its own;
  `preserved` (SNBT or nil) is kept with it, and `persistent` makes a mob's
  `PersistenceRequired`.
  """
  def generated(type, preserved, persistent) do
    if EntityTypes.fetch(type) == nil do
      {:error, :unknown_type}
    else
      body = %__MODULE__{type: type, data: data(type), preserved: preserved}

      body =
        if kind(type) == :mob,
          do: %{body | mob: %{Mob.new(type) | persistent: persistent}},
          else: body

      {:ok, body}
    end
  end

  @doc """
  A primed TNT as `new PrimedTnt` makes it (VMC-050a): `fuse` ticks, a hop of
  0.2 up and 0.02 in a random direction.
  """
  def primed_tnt(fuse) when is_integer(fuse) and fuse > 0 do
    {:ok, body} = new(@tnt)
    angle = :rand.uniform() * Valimc.Data.Float32.round(:math.pi() * 2)

    velocity =
      {-:math.sin(angle) * 0.02, Valimc.Data.Float32.round(0.2), -:math.cos(angle) * 0.02}

    %{body | velocity: velocity, data: %{body.data | fuse: fuse}}
  end

  @doc """
  A falling block of `state` that left cell `start` (VMC-050a2,
  `FallingBlockEntity.fall`): still, its time at 0; an anvil hurts what it
  lands on.
  """
  def falling_block(state, {_, _, _} = start) do
    {:ok, body} = new(@falling)
    anvil = Blocks.class(state) == "AnvilBlock"
    %{body | data: %{body.data | block_state: state, start: start, hurts: anvil}}
  end

  @doc """
  The type's spawn data (`getAddEntityPacket`): a falling block's state, a
  frame's facing, a projectile's owner, else 0.
  """
  def spawn_data(%__MODULE__{type: @falling, data: %{block_state: state}}), do: state

  # A hanging frame's facing (its 3D value) from its yaw, `get2DDataValue * 90`.
  def spawn_data(%__MODULE__{type: type, yaw: yaw}) when type in @frames,
    do: elem({3, 4, 2, 5}, Integer.mod(round(yaw / 90), 4))

  def spawn_data(%__MODULE__{type: type} = body),
    do: if(Projectile.projectile?(type), do: Projectile.spawn_data(body), else: 0)

  # A type's own data and its defaults (`PrimedTnt.defineSynchedData`,
  # `FallingBlockEntity`'s fields: its state, ticks fallen, fall distance,
  # start cell, whether it hurts what it lands on, drops an item where it
  # cannot land, or breaks without one).
  defp data(@tnt), do: %{fuse: 80, block_state: Blocks.default_state("tnt")}

  defp data(@falling),
    do: %{
      block_state: Blocks.default_state("sand"),
      time: 0,
      fall_distance: 0.0,
      start: {0, 0, 0},
      hurts: false,
      drops: true,
      cancel_drop: false
    }

  # `AgeableMob`'s age: negative while a baby (an egg's chicks are -24000);
  # whether it is a chicken jockey's (VMC-043b: it stays, worth 10 XP).
  defp data(@chicken), do: %{age: 0, jockey: false}
  defp data(@cloud), do: Valimc.Entity.EffectCloud.data()

  # A mob family's own (VMC-043b–e: a zombie's baby flag), a projectile's.
  defp data(type) do
    case Valimc.AI.Mobs.data(type) do
      nil -> if Projectile.projectile?(type), do: Projectile.data(type), else: %{}
      data -> data
    end
  end

  @doc "The fields a record saves of `body` (position and uuid are the entry's)."
  def record(%__MODULE__{} = body) do
    record = %{
      type: body.type,
      rotation: {body.yaw, body.pitch, body.head_yaw},
      velocity: body.velocity,
      on_ground: body.on_ground,
      no_gravity: body.no_gravity,
      data: body.data
    }

    record =
      if body.custom_name, do: Map.put(record, :custom_name, body.custom_name), else: record

    record = if body.preserved, do: Map.put(record, :preserved, body.preserved), else: record

    record =
      if body.portal_cooldown > 0,
        do: Map.put(record, :portal_cooldown, body.portal_cooldown),
        else: record

    if body.mob, do: Map.put(record, :mob, Mob.record(body.mob)), else: record
  end

  @doc "The body of a record, or `{:error, :invalid_body}`."
  def restore(
        %{
          type: type,
          rotation: {yaw, pitch, head},
          velocity: {vx, vy, vz},
          on_ground: on_ground,
          no_gravity: no_gravity,
          data: data
        } = record
      ) do
    preserved = Map.get(record, :preserved)

    with true <- EntityTypes.fetch(type) != nil,
         true <- Enum.all?([yaw, pitch, head, vx, vy, vz], &is_float/1),
         true <- preserved == nil or is_binary(preserved),
         true <- is_boolean(on_ground) and is_boolean(no_gravity),
         true <- is_map(data) and Map.keys(data) == Map.keys(data(type)),
         cooldown = Map.get(record, :portal_cooldown, 0),
         true <- is_integer(cooldown) and cooldown in 0..32_767,
         {:ok, mob} <- restore_mob(type, Map.get(record, :mob)) do
      {:ok,
       %__MODULE__{
         type: type,
         yaw: yaw,
         pitch: pitch,
         head_yaw: head,
         velocity: {vx, vy, vz},
         on_ground: on_ground,
         no_gravity: no_gravity,
         data: data,
         mob: mob,
         custom_name: Map.get(record, :custom_name),
         preserved: preserved,
         portal_cooldown: cooldown
       }}
    else
      _ -> {:error, :invalid_body}
    end
  end

  def restore(_record), do: {:error, :invalid_body}

  defp restore_mob(type, nil), do: if(kind(type) == :object, do: {:ok, nil}, else: :error)
  defp restore_mob(type, record), do: if(kind(type) == :mob, do: Mob.restore(type, record))

  @doc "Whether the body is alive (a mob with health, or any other body)."
  def alive?(%__MODULE__{mob: nil}), do: true
  def alive?(%__MODULE__{mob: mob}), do: Mob.alive?(mob)

  @doc """
  One tick of the body's timers: `{body, events, done}`. Its portal cooldown
  runs down (`processPortalCooldown`). A dying mob's
  timers run until its death animation ends (`done`), with the poof (entity
  event 60) one tick before it is removed, so observers still track it. A
  primed TNT is inert until VMC-050a.
  """
  def tick(%__MODULE__{portal_cooldown: cooldown} = body) when cooldown > 0,
    do: tick_timers(%{body | portal_cooldown: cooldown - 1})

  def tick(body), do: tick_timers(body)

  defp tick_timers(%__MODULE__{mob: nil} = body), do: {body, [], false}

  defp tick_timers(%__MODULE__{mob: mob} = body) do
    {next, done} = Mob.tick(mob)
    health = next.living.health
    events = if health.value <= 0 and health.death_ticks == 19, do: [{:event, 60}], else: []
    {%{body | mob: next}, events, done}
  end

  @doc """
  `/kill`: a mob dies (`{:dying, body, events}`: the hurt and death events,
  then its death animation), any other body is removed (`:remove`).
  """
  def kill(%__MODULE__{mob: nil}), do: :remove

  def kill(%__MODULE__{mob: mob} = body) do
    case Mob.kill(mob) do
      {:ok, mob} -> {:dying, %{body | mob: mob}, [{:damage, :generic_kill}, {:event, 3}]}
      :ignored -> :ignored
    end
  end

  @doc """
  A hit of `amount` from damage type `source` with no attacker (explosions
  and falling blocks, VMC-050a): `{body, events}` through the one hurt path
  (`Entity.Combat.hurt_body/3`); other bodies take no damage.
  """
  def hurt(%__MODULE__{} = body, source, amount) do
    case Valimc.Entity.Combat.hurt_body(body, nil, %{
           source: Valimc.Living.DamageSource.new(source),
           amount: amount
         }) do
      :ignored -> {body, []}
      {body, events, _} -> {body, events}
    end
  end

  @doc """
  A name tag used on a living body (`NameTagItem.interactLivingEntity`): its
  custom name, and persistence for a mob (`setPersistenceRequired`).
  """
  def name(%__MODULE__{mob: %Mob{} = mob} = body, name),
    do: %{body | custom_name: name, mob: %{mob | persistent: true}}

  @doc "`Entity.push`: the body's velocity plus `impulse`."
  def push(%__MODULE__{velocity: {x, y, z}} = body, {dx, dy, dz}),
    do: %{body | velocity: {x + dx, y + dy, z + dz}}

  @doc """
  The packet of an event a body's change returned, for entity `id` at
  `entity`'s position (a sound's), encoded once.
  """
  def event_packet(id, event, entity \\ nil)
  def event_packet(id, {:event, event}, _), do: binary(EntityPackets.entity_event(id, event))
  def event_packet(id, {:damage, source}, _), do: binary(Packets.damage_event(id, source))

  def event_packet(id, {:swing, hand}, _) when hand in [:main_hand, :off_hand],
    do:
      binary(
        Valimc.Protocol.Packets.packet("swing_animation", [
          Valimc.Protocol.Wire.varint(id),
          Valimc.AI.Facts.swing_fields(hand)
        ])
      )

  def event_packet(_id, {:sound, name, source, volume, pitch, seed}, %{x: x, y: y, z: z}),
    do: binary(Valimc.Protocol.CombatPackets.sound(name, source, {x, y, z}, volume, pitch, seed))

  # A sound where the mob was (a shulker's teleport, VMC-043e).
  def event_packet(_id, {:sound_at, name, source, position, volume, pitch}, _) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    binary(Valimc.Protocol.CombatPackets.sound(name, source, position, volume, pitch, seed))
  end

  def event_packet(id, {:damage, source, cause, direct, position}, _),
    do: binary(Packets.damage_event(id, source, cause, direct, position))

  @doc """
  Every modelled entity data field of `body`: `[{field, value, default}]`,
  in index order.
  """
  def values(%__MODULE__{} = body) do
    common = [
      {:shared_flags, shared_flags(body), 0},
      {:air_supply, air(body), 300},
      {:custom_name, body.custom_name, nil},
      {:no_gravity, body.no_gravity, false},
      {:pose, pose(body), :standing},
      {:frozen_ticks, frozen(body), 0}
    ]

    common ++ own(body)
  end

  defp own(%__MODULE__{mob: %Mob{living: living} = mob} = body),
    do:
      [
        {:living_flags, 0, 0},
        {:health, living.health.value, 1.0},
        {:mob_flags, mob_flags(mob), 0}
      ] ++ ageable(body) ++ family(body) ++ Valimc.AI.Mobs.values(body)

  defp own(%__MODULE__{type: @tnt, data: data}),
    do: [
      {:tnt_fuse, data.fuse, 80},
      {:tnt_block_state, data.block_state, Blocks.default_state("tnt")}
    ]

  defp own(%__MODULE__{type: @falling, data: data}),
    do: [{:falling_block_start_pos, data.start, {0, 0, 0}}]

  defp own(%__MODULE__{type: @cloud} = body), do: Valimc.Entity.EffectCloud.values(body)
  defp own(%__MODULE__{} = body), do: Projectile.values(body)

  defp ageable(%__MODULE__{type: @chicken, data: %{age: age}}),
    do: [{:ageable_baby, age < 0, false}]

  defp ageable(_body), do: []

  # A family's own values (VMC-043d): a blaze's charged flag.
  defp family(%__MODULE__{type: "minecraft:blaze", mob: mob}),
    do: [{:blaze_flags, if(Valimc.AI.Mobs.Blaze.charged?(mob.ai), do: 1, else: 0), 0}]

  defp family(_body), do: []

  # `Mob.setNoAi` (bit 0), `setLeftHanded` (bit 1) and `setAggressive`
  # (bit 2): a zombie raising its arms (VMC-041a).
  defp mob_flags(%Mob{} = mob) do
    no_ai = if mob.no_ai, do: 1, else: 0
    left = if mob.left_handed, do: 2, else: 0
    aggressive = if match?(%{aggressive: true}, mob.ai), do: 4, else: 0
    no_ai + left + aggressive
  end

  @doc """
  The body's dimensions, `{width, height, eye height}` as floats
  (`getDimensions`): its type's, or what its family changes (a baby's,
  VMC-043b).
  """
  def dimensions(%__MODULE__{type: type} = body) do
    case Valimc.AI.Mobs.dimensions(body) do
      nil ->
        facts = EntityTypes.fetch(type)

        {Valimc.Data.Float32.round(facts.width), Valimc.Data.Float32.round(facts.height),
         Valimc.Data.Float32.round(facts.eye_height)}

      dimensions ->
        dimensions
    end
  end

  # Vanilla's on-fire flag (bit 0) for a burning body that is not fire immune.
  defp shared_flags(%__MODULE__{mob: %Mob{living: %{fire_ticks: ticks}}, type: type})
       when ticks > 0,
       do: if(EntityTypes.fetch(type).fire_immune, do: 0, else: 1)

  defp shared_flags(%__MODULE__{mob: nil, data: %{fire: _}} = body),
    do: if(Projectile.burning?(body), do: 1, else: 0)

  defp shared_flags(_body), do: 0

  defp air(%__MODULE__{mob: %Mob{living: living}}), do: living.air_supply
  defp air(_body), do: 300

  defp frozen(%__MODULE__{mob: %Mob{living: living}}), do: living.freezing.frozen_ticks
  defp frozen(_body), do: 0

  defp pose(%__MODULE__{mob: %Mob{living: %{health: %{value: value}}}}) when value <= 0,
    do: :dying

  defp pose(_body), do: :standing

  @doc """
  What observers are shown of `body` beyond its motion: its entity data
  values, a mob's attribute overrides and equipment. Equal shown parts send
  equal packets, so a body that only moved keeps its encoded ones.
  """
  def shown(%__MODULE__{mob: nil} = body), do: {values(body), nil, nil}
  def shown(%__MODULE__{mob: mob} = body), do: {values(body), mob.attributes, mob.equipment}

  @doc """
  What an observer that starts tracking entity `id` is sent after its spawn
  (`ServerEntity.sendPairingData`): its non-default entity data, a mob's
  synced attributes and its equipment.
  """
  def pairing(id, %__MODULE__{} = body) do
    data =
      for {field, value, default} <- values(body), value != default, do: {field, value}

    data = if data == [], do: [], else: [EntityPackets.metadata(id, data)]

    living =
      case body.mob do
        nil ->
          []

        mob ->
          equipment = Mob.equipment_changes(mob.equipment, %{})

          [Packets.attributes(id, Mob.synced(body.type, mob.attributes))] ++
            if(equipment == [], do: [], else: [EntityPackets.equipment(id, equipment)])
      end

    Enum.map(data ++ living, &binary/1)
  end

  @doc """
  The packets of what changed from `old` to `new` (entity data, attributes,
  equipment), for observers already tracking entity `id`.
  """
  def changes(_id, %__MODULE__{} = same, %__MODULE__{} = same), do: []

  def changes(id, %__MODULE__{} = old, %__MODULE__{} = new) do
    if shown(old) == shown(new), do: [], else: shown_changes(id, old, new)
  end

  defp shown_changes(id, old, new) do
    old_values = values(old)

    data =
      for {{field, value, _}, {_, before, _}} <- Enum.zip(values(new), old_values),
          value != before,
          do: {field, value}

    data = if data == [], do: [], else: [EntityPackets.metadata(id, data)]

    living =
      case {old.mob, new.mob} do
        {%Mob{} = a, %Mob{} = b} ->
          attributes = Mob.synced(new.type, b.attributes)

          changed =
            attributes -- Mob.synced(old.type, a.attributes)

          equipment = Mob.equipment_changes(b.equipment, a.equipment)

          if(changed == [], do: [], else: [Packets.attributes(id, changed)]) ++
            if equipment == [], do: [], else: [EntityPackets.equipment(id, equipment)]

        _ ->
          []
      end

    Enum.map(data ++ living, &binary/1)
  end

  defp binary({id, payload}), do: {id, IO.iodata_to_binary(payload)}
end
