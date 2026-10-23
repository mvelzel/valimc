defmodule Valimc.Entity.Body do
  @moduledoc """
  The record of every entity kind beyond items and XP orbs (VMC-043a): one
  schema for living types (kind `:mob`, with a `Valimc.Entity.Mob`) and the
  rest (kind `:object`). A body holds its type, rotation and head yaw, motion,
  its type's own data (a primed TNT's fuse and block) and, for a mob, its
  living part. Its position and uuid are the store entry's, as for every kind.

  Only modelled types (`modelled?/1`) are made: their entity data is known
  value by value, so what a client is sent is what vanilla sends. Mob
  families (VMC-043b–e) and world effects (VMC-050a) add theirs.

  `values/2` gives every modelled entity data field with its value and
  vanilla's default; a spawn sends those that differ (vanilla's
  `getNonDefaultValues`), a tracker those that changed.
  """
  alias Valimc.Data.{Blocks, EntityTypes}
  alias Valimc.Entity.Mob
  alias Valimc.Protocol.{EntityPackets, Packets}

  defstruct type: nil,
            yaw: 0.0,
            pitch: 0.0,
            head_yaw: 0.0,
            velocity: {0.0, 0.0, 0.0},
            on_ground: false,
            no_gravity: false,
            data: %{},
            mob: nil

  @tnt "minecraft:tnt"
  @falling "minecraft:falling_block"
  @modelled MapSet.new(["minecraft:zombie", @tnt, @falling])

  @doc "Whether type `type` is modelled (it can be summoned and stored)."
  def modelled?(type), do: MapSet.member?(@modelled, type)
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

  @doc "The type's spawn data (`getAddEntityPacket`): a falling block's state, else 0."
  def spawn_data(%__MODULE__{type: @falling, data: %{block_state: state}}), do: state
  def spawn_data(_body), do: 0

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

  defp data(_type), do: %{}

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
    with true <- modelled?(type) and Enum.all?([yaw, pitch, head, vx, vy, vz], &is_float/1),
         true <- is_boolean(on_ground) and is_boolean(no_gravity),
         true <- is_map(data) and Map.keys(data) == Map.keys(data(type)),
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
         mob: mob
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
  One tick of the body's timers: `{body, events, done}`. A dying mob's
  timers run until its death animation ends (`done`), with the poof (entity
  event 60) one tick before it is removed, so observers still track it. A
  primed TNT is inert until VMC-050a.
  """
  def tick(%__MODULE__{mob: nil} = body), do: {body, [], false}

  def tick(%__MODULE__{mob: mob} = body) do
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

  def event_packet(_id, {:sound, name, source, volume, pitch, seed}, %{x: x, y: y, z: z}),
    do: binary(Valimc.Protocol.CombatPackets.sound(name, source, {x, y, z}, volume, pitch, seed))

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
      {:no_gravity, body.no_gravity, false},
      {:pose, pose(body), :standing},
      {:frozen_ticks, frozen(body), 0}
    ]

    common ++ own(body)
  end

  defp own(%__MODULE__{mob: %Mob{living: living}}),
    do: [{:living_flags, 0, 0}, {:health, living.health.value, 1.0}, {:mob_flags, 0, 0}]

  defp own(%__MODULE__{type: @tnt, data: data}),
    do: [
      {:tnt_fuse, data.fuse, 80},
      {:tnt_block_state, data.block_state, Blocks.default_state("tnt")}
    ]

  defp own(%__MODULE__{type: @falling, data: data}),
    do: [{:falling_block_start_pos, data.start, {0, 0, 0}}]

  defp own(_body), do: []

  # Vanilla's on-fire flag (bit 0) for a burning body that is not fire immune.
  defp shared_flags(%__MODULE__{mob: %Mob{living: %{fire_ticks: ticks}}, type: type})
       when ticks > 0,
       do: if(EntityTypes.fetch(type).fire_immune, do: 0, else: 1)

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
