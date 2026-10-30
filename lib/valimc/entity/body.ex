defmodule Valimc.Entity.Body do
  @moduledoc """
  The record of every entity kind beyond items and XP orbs (VMC-043a): one
  schema for living types (kind `:mob`, with a `Valimc.Entity.Mob`) and the
  rest (kind `:object`). A body holds its type, rotation and head yaw, motion,
  its type's own data (a primed TNT's fuse and block) and, for a mob, its
  living part. Its position and uuid are the store entry's, as for every kind.

  Only modelled types (`modelled?/1`) are made: their entity data is known
  value by value, so what a client is sent is what vanilla sends. A mob's
  body is only the record its section starts from (VMC-081d): a fresh one
  is its family's (`Native.mob_section_fresh/1`), and once stored it lives
  in its section. Generation makes a body of any type (`generated/3`,
  VMC-042b): one not modelled yet is inert, its type's data at the client's
  defaults, and keeps what generation gave it (`preserved`).

  `values/1` gives every modelled entity data field of a body that is not a
  mob with its value and vanilla's default; a spawn sends those that differ
  (vanilla's `getNonDefaultValues`), a tracker those that changed.
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
  @cloud "minecraft:area_effect_cloud"
  @frames ["minecraft:item_frame", "minecraft:glow_item_frame"]
  @villager "minecraft:villager"
  # A fence knot mobs are leashed to (VMC-043c3).
  @knot "minecraft:leash_knot"
  @crystal "minecraft:end_crystal"
  @dragon "minecraft:ender_dragon"
  @modelled MapSet.new(
              [@tnt, @falling, @cloud, @knot, @crystal, @villager, "minecraft:iron_golem"] ++
                Projectile.types()
            )
  @plain for name <- EntityTypes.names(),
             EntityTypes.living?(name) and EntityTypes.fetch(name).category != :misc,
             into: MapSet.new(),
             do: name

  @doc """
  Whether type `type` is modelled (it can be summoned and stored): the types
  above, and every living type of a spawning category (VMC-042a).
  """
  def modelled?(type), do: MapSet.member?(@modelled, type) or MapSet.member?(@plain, type)

  def modelled, do: @modelled

  @doc "The store kind of type `type`: `:mob` for a living type, else `:object`."
  def kind(type), do: if(EntityTypes.living?(type), do: :mob, else: :object)

  @doc "A fresh body of modelled type `type`, as `/summon` makes it."
  def new(type) do
    cond do
      not modelled?(type) -> {:error, :unmodelled_type}
      kind(type) == :mob -> {:ok, fresh(type)}
      true -> {:ok, %__MODULE__{type: type, data: data(type)}}
    end
  end

  # A fresh mob as its family makes it (VMC-081d): its data, full health,
  # its family's air and motion. A chicken's first egg comes after
  # `random.nextInt(6000) + 6000` ticks of a random vanilla never seeds.
  defp fresh(type) do
    {:ok, body} = restore(fresh_record(type))

    case body.data do
      %{egg_time: _} -> %{body | data: %{body.data | egg_time: 5999 + :rand.uniform(6000)}}
      _ -> body
    end
  end

  defp fresh_record(type) do
    case :persistent_term.get({__MODULE__, :fresh, type}, nil) do
      nil ->
        Valimc.Entity.MobFacts.install!()
        {:ok, record} = Valimc.Native.mob_section_fresh(type)
        :persistent_term.put({__MODULE__, :fresh, type}, record)
        record

      record ->
        record
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
  `InfestedBlock.spawnInfestation` (VMC-043b6): the record of a silverfish
  coming out of the infested block at `{x, y, z}`, at its bottom centre,
  facing south (no spawn of its own to finish).
  """
  def infestation({x, y, z}) do
    {:ok, body} = new("minecraft:silverfish")

    Valimc.Entity.Store.body_record(
      body,
      :crypto.strong_rand_bytes(16),
      {x + 0.5, y * 1.0, z + 0.5}
    )
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
      body =
        if kind(type) == :mob do
          body = fresh(type)
          %{body | preserved: preserved, mob: %{body.mob | persistent: persistent}}
        else
          %__MODULE__{type: type, data: data(type), preserved: preserved}
        end

      {:ok, generated_data(body)}
    end
  end

  # A villager reads what generation gave it (VMC-044a1).
  defp generated_data(%__MODULE__{type: @villager, preserved: preserved} = body),
    do: %{
      body
      | data: Valimc.Entity.Villager.from_preserved(preserved, body.data),
        preserved: nil
    }

  defp generated_data(%__MODULE__{type: @crystal, preserved: preserved} = body),
    do: %{body | data: Valimc.Entity.EndCrystal.from_preserved(preserved), preserved: nil}

  defp generated_data(%__MODULE__{type: @dragon, preserved: preserved} = body),
    do: %{body | data: Valimc.Entity.Dragon.from_preserved(preserved, body.data), preserved: nil}

  defp generated_data(body), do: body

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

  @doc "Whether `type` is a fence knot (VMC-043c3)."
  def knot?(type), do: type == @knot

  @doc """
  The type's spawn data (`getAddEntityPacket`): a falling block's state, a
  frame's facing, a projectile's owner, else 0.
  """
  def spawn_data(%Valimc.Entity.NativeBody{}), do: 0
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

  defp data(@cloud), do: Valimc.Entity.EffectCloud.data()
  defp data(@crystal), do: Valimc.Entity.EndCrystal.data()
  # The game tick it was made at (`BlockAttachedEntity.ticksSinceLastCheck`
  # counts from it).
  defp data(@knot), do: %{since: 0}

  # A projectile's.
  defp data(type), do: if(Projectile.projectile?(type), do: Projectile.data(type), else: %{})

  # The keys a record's data holds: a mob's family's (VMC-081d).
  defp data_keys(type) do
    data = if kind(type) == :mob, do: fresh_record(type).data, else: data(type)
    Map.keys(data)
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
    data = restore_data(type, data)

    with true <- EntityTypes.fetch(type) != nil,
         true <- Enum.all?([yaw, pitch, head, vx, vy, vz], &is_float/1),
         true <- preserved == nil or is_binary(preserved),
         true <- is_boolean(on_ground) and is_boolean(no_gravity),
         true <- is_map(data) and Map.keys(data) == data_keys(type),
         true <- valid_water_age?(type, data),
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

  # VMC-043e10 adds AgeableMob fields to already stored ocean mobs.
  # Only their exact former shape is migrated; all other validation remains.
  defp restore_data(type, data)
       when type in ["minecraft:dolphin", "minecraft:squid", "minecraft:glow_squid"] and
              is_map(data) do
    old_keys =
      case type do
        "minecraft:dolphin" -> [:got_fish, :moistness, :treasure]
        "minecraft:squid" -> [:age]
        "minecraft:glow_squid" -> [:age, :dark]
      end

    if Enum.sort(Map.keys(data)) == Enum.sort(old_keys),
      do: Map.merge(%{age: 0, forced_age: 0, age_locked: false}, data),
      else: data
  end

  defp restore_data(_type, data), do: data

  defp valid_water_age?(type, data)
       when type in ["minecraft:dolphin", "minecraft:squid", "minecraft:glow_squid"],
       do: is_integer(data.age) and is_integer(data.forced_age) and is_boolean(data.age_locked)

  defp valid_water_age?(_type, _data), do: true

  defp restore_mob(type, nil), do: if(kind(type) == :object, do: {:ok, nil}, else: :error)
  defp restore_mob(type, record), do: if(kind(type) == :mob, do: Mob.restore(type, record))

  @doc "Whether the body is alive (a mob with health, or any other body)."
  def alive?(%Valimc.Entity.NativeBody{alive: alive}), do: alive
  def alive?(%__MODULE__{mob: nil}), do: true
  def alive?(%__MODULE__{mob: mob}), do: Mob.alive?(mob)

  @doc """
  `ticks` ticks of the body's timers: its portal cooldown runs down
  (`processPortalCooldown`); a mob's timers are its section's.
  """
  def tick(%__MODULE__{portal_cooldown: cooldown} = body, ticks),
    do: %{body | portal_cooldown: max(cooldown - ticks, 0)}

  @doc "`/kill` of a body that is not a mob: it is removed."
  def kill(%__MODULE__{}), do: :remove

  @doc """
  A hit of `amount` from damage type `source` with no attacker (explosions
  and falling blocks, VMC-050a) on a body that is not a mob: no damage.
  """
  def hurt(%__MODULE__{} = body, _source, _amount), do: {body, []}

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
        Packets.packet("swing_animation", [
          Valimc.Protocol.Wire.varint(id),
          Valimc.Data.AiFacts.swing_fields(hand)
        ])
      )

  def event_packet(_id, {:sound, name, source, volume, pitch, seed}, %{x: x, y: y, z: z}),
    do: binary(Valimc.Protocol.CombatPackets.sound(name, source, {x, y, z}, volume, pitch, seed))

  # Particles at a point relative to the body (`{:at, offset, up}`: its
  # position plus `offset`, `up` higher), or at a point (a squid's ink).
  def event_packet(_id, {:particles, name, {:at, {ox, oy, oz}, up}, delta, speed, count}, %{
        x: x,
        y: y,
        z: z
      }),
      do:
        binary(
          Valimc.Protocol.CombatPackets.particles(
            name,
            {x + ox, y + oy + up, z + oz},
            delta,
            speed,
            count
          )
        )

  # Absolute particles from an owner-local actor (the dragon's death).
  def event_packet(_id, {:particles, name, {_, _, _} = at, delta, speed, count}, _),
    do: binary(Valimc.Protocol.CombatPackets.particles(name, at, delta, speed, count))

  # A sound where the mob was (a shulker's teleport, VMC-043e).
  def event_packet(_id, {:sound_at, name, source, position, volume, pitch}, _) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    binary(Valimc.Protocol.CombatPackets.sound(name, source, position, volume, pitch, seed))
  end

  # A sound at the centre of the block the body stands in (VMC-043c: a
  # golden dandelion's).
  def event_packet(_id, {:sound_block, name, source, volume, pitch, seed}, %{x: x, y: y, z: z}) do
    at = {Float.floor(x) + 0.5, Float.floor(y) + 0.5, Float.floor(z) + 0.5}
    binary(Valimc.Protocol.CombatPackets.sound(name, source, at, volume, pitch, seed))
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
      {:air_supply, 300, 300},
      {:custom_name, body.custom_name, nil},
      {:no_gravity, body.no_gravity, false},
      {:pose, :standing, :standing},
      {:frozen_ticks, 0, 0}
    ]

    common ++ own(body)
  end

  defp own(%__MODULE__{type: @tnt, data: data}),
    do: [
      {:tnt_fuse, data.fuse, 80},
      {:tnt_block_state, data.block_state, Blocks.default_state("tnt")}
    ]

  defp own(%__MODULE__{type: @falling, data: data}),
    do: [{:falling_block_start_pos, data.start, {0, 0, 0}}]

  defp own(%__MODULE__{type: @cloud} = body), do: Valimc.Entity.EffectCloud.values(body)
  defp own(%__MODULE__{type: @crystal} = body), do: Valimc.Entity.EndCrystal.values(body)
  defp own(%__MODULE__{type: @knot}), do: []
  defp own(%__MODULE__{} = body), do: Projectile.values(body)

  @doc """
  The body's dimensions, `{width, height, eye height}` as floats
  (`getDimensions`): its type's, or what its family changes (a baby's,
  VMC-043b).
  """
  def dimensions(%Valimc.Entity.NativeBody{dimensions: dimensions}), do: dimensions

  def dimensions(%__MODULE__{type: type}) do
    facts = EntityTypes.fetch(type)

    {Valimc.Data.Float32.round(facts.width), Valimc.Data.Float32.round(facts.height),
     Valimc.Data.Float32.round(facts.eye_height)}
  end

  @doc "The body's physical bounding box (a mob's row's, `NativeBody.box/2`)."
  def box(%Valimc.Entity.NativeBody{} = body, position),
    do: Valimc.Entity.NativeBody.box(body, position)

  def box(%__MODULE__{type: @knot}, {x, y, z}),
    do: {x + 0.3125, y + 0.375, z + 0.3125, x + 0.6875, y + 0.875, z + 0.6875}

  def box(%__MODULE__{} = body, {x, y, z}) do
    {w, h, _} = dimensions(body)
    {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}
  end

  # Vanilla's on-fire flag (bit 0) for a burning projectile.
  defp shared_flags(%__MODULE__{data: %{fire: _}} = body),
    do: if(Projectile.burning?(body), do: 1, else: 0)

  defp shared_flags(_body), do: 0

  @doc """
  What observers are shown of `body` beyond its motion: its entity data
  values, a mob's attribute overrides and equipment. Equal shown parts send
  equal packets, so a body that only moved keeps its encoded ones.
  """
  def shown(%Valimc.Entity.NativeBody{shown: shown}), do: shown
  def shown(%__MODULE__{} = body), do: {values(body), nil, nil, nil}

  @doc """
  What an observer that starts tracking entity `id` is sent after its spawn
  (`ServerEntity.sendPairingData`): its non-default entity data (a mob's
  synced attributes and equipment too, `NativeBody.pairing/2`).
  """
  def pairing(id, %Valimc.Entity.NativeBody{} = body),
    do: Valimc.Entity.NativeBody.pairing(id, body)

  def pairing(id, %__MODULE__{} = body) do
    data =
      for {field, value, default} <- values(body), value != default, do: {field, value}

    if data == [], do: [], else: [binary(EntityPackets.metadata(id, data))]
  end

  @doc """
  The packets of what changed from `old` to `new` (entity data, a mob's
  attributes and equipment) once what they show differs, for observers
  already tracking entity `id`.
  """
  def shown_changes(id, %Valimc.Entity.NativeBody{} = old, %Valimc.Entity.NativeBody{} = new),
    do: Valimc.Entity.NativeBody.shown_changes(id, old, new)

  def shown_changes(id, old, new) do
    data =
      for {{field, value, _}, {_, before, _}} <- Enum.zip(values(new), values(old)),
          value != before,
          do: {field, value}

    if data == [], do: [], else: [binary(EntityPackets.metadata(id, data))]
  end

  defp binary({id, payload}), do: {id, IO.iodata_to_binary(payload)}
end
