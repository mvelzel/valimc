defmodule Valimc.Entity.Tracker do
  @moduledoc """
  An entity's replication state in its owner (VMC-077h), as vanilla's
  `ServerEntity`: what observers were last sent (the position base, movement and
  ground flag) and the packets of each tick's changes, encoded once for every
  observer. An observer that starts tracking the entity spawns it at the base,
  so the relative moves that follow apply to the same position.

  Items and orbs update every 20 ticks (their type's update interval), sooner
  when their motion changes sharply; every 60 ticks the position is sent even
  unchanged, and after 400 ticks of relative moves an absolute sync replaces one.

  A body (`Valimc.Entity.Body`, VMC-043a) updates at its type's interval and
  whenever its entity data, attributes or equipment changed: its motion (when
  the type tracks it), a relative move with its rotation (or the rotation
  alone), what changed and its head's yaw, as `ServerEntity.sendChanges`. Its
  entity events (hurt, death) go out the tick they happen.
  """
  alias Valimc.Data.EntityTypes
  alias Valimc.Entity.Body
  alias Valimc.Protocol.EntityPackets

  defstruct [
    :base,
    :movement,
    :on_ground,
    # Owner bookkeeping: last tick's velocity and the metadata revision sent.
    :previous,
    :metadata,
    # Unique per tracker: one entity's new tracker under the same id and owner
    # (an item a sibling section handed back) must resync its observers.
    :incarnation,
    # A body's: the rotation and head yaw sent (angle bytes), the body whose
    # data observers have, the last event sent and whether motion is tracked.
    :rotation,
    :head,
    :body,
    # What observers see of that body (`Body.shown/1`), kept so each tick
    # projects only the new body.
    :shown,
    event_seq: 0,
    track_deltas: true,
    tick: 0,
    teleport_delay: 0,
    interval: 20
  ]

  @tolerance 7.6293945e-6

  def new({_, _, _} = position, movement, on_ground, interval \\ 20) do
    %__MODULE__{
      base: position,
      movement: movement,
      on_ground: on_ground,
      interval: interval,
      incarnation: System.unique_integer([:positive, :monotonic])
    }
  end

  @doc "The tracker of a body's `view` (its type's interval; events already in the view are sent)."
  def new_body(view) do
    type = EntityTypes.fetch(view.type)

    %{
      new(view.at, view.velocity, view.on_ground, type.update_interval)
      | rotation: {EntityPackets.angle(view.yaw), EntityPackets.angle(view.pitch)},
        head: EntityPackets.angle(view.head_yaw),
        body: view.body,
        event_seq: last_event(view),
        track_deltas: type.track_deltas,
        previous: view.velocity
    }
  end

  defp last_event(%{events: []}), do: 0
  defp last_event(%{events: events}), do: events |> List.last() |> elem(0)

  @doc "One tick of a body's `view`: `{tracker, packets}`."
  def tick_body(tracker, view) do
    id = view.entity_id
    events = for {seq, packet} <- view.events, seq > tracker.event_seq, do: packet
    {shown, changes} = changes(tracker, id, view.body)

    # A projectile's `needsSync` (VMC-037o): shot, stuck or turned back.
    impulse = impulse(view.body) != impulse(tracker.body)

    {tracker, packets} =
      if rem(tracker.tick, tracker.interval) == 0 or changes != [] or impulse do
        tracker = %{tracker | teleport_delay: tracker.teleport_delay + 1}
        entity = %{entity(view) | yaw: view.yaw, pitch: view.pitch}

        {tracker, motion} =
          if tracker.track_deltas, do: motion(tracker, id, view.velocity), else: {tracker, []}

        {tracker, move} = move_body(tracker, entity)
        head = EntityPackets.angle(view.head_yaw)

        turn =
          if head != tracker.head, do: [binary(EntityPackets.rotate_head(id, head))], else: []

        {%{tracker | head: head, body: view.body}, motion ++ move ++ changes ++ turn}
      else
        {tracker, []}
      end

    {%{tracker | tick: tracker.tick + 1, event_seq: last_event(view), shown: shown},
     events ++ packets}
  end

  defp changes(%{body: same} = tracker, _id, same), do: {tracker.shown, []}

  defp changes(tracker, id, body) do
    shown = Body.shown(body)
    old = tracker.shown || Body.shown(tracker.body)
    if shown == old, do: {shown, []}, else: {shown, Body.shown_changes(id, tracker.body, body)}
  end

  defp impulse(%Body{data: %{impulse: n}}), do: n
  defp impulse(_body), do: nil

  defp entity(view) do
    {x, y, z} = view.at

    %{
      entity_id: view.entity_id,
      x: x,
      y: y,
      z: z,
      yaw: 0.0,
      pitch: 0.0,
      velocity: view.velocity,
      on_ground: view.on_ground
    }
  end

  # `ServerEntity.createMovePacket`: a sync, a relative move (with the
  # rotation when it turned), the rotation alone, or nothing.
  defp move_body(tracker, entity) do
    position = {entity.x, entity.y, entity.z}
    rotation = {EntityPackets.angle(entity.yaw), EntityPackets.angle(entity.pitch)}
    turned = rotation != tracker.rotation
    {yaw, pitch} = rotation
    delta = delta(tracker.base, position)
    moved = distance_sq(position, tracker.base) >= @tolerance or rem(tracker.tick, 60) == 0

    cond do
      tracker.teleport_delay > 400 or tracker.on_ground != entity.on_ground or
          (moved and not Enum.all?(Tuple.to_list(delta), &(&1 in -32768..32767))) ->
        tracker = %{
          tracker
          | on_ground: entity.on_ground,
            teleport_delay: 0,
            base: position,
            rotation: rotation
        }

        {tracker, [sync(entity, entity.on_ground)]}

      moved and turned ->
        {%{tracker | base: position, rotation: rotation},
         [
           binary(
             EntityPackets.move_rotate(entity.entity_id, delta, yaw, pitch, entity.on_ground)
           )
         ]}

      moved ->
        {%{tracker | base: position},
         [binary(EntityPackets.move(entity.entity_id, delta, entity.on_ground))]}

      turned ->
        {%{tracker | rotation: rotation},
         [binary(EntityPackets.rotate(entity.entity_id, yaw, pitch, entity.on_ground))]}

      true ->
        {tracker, []}
    end
  end

  @doc """
  One tick of `entity` (`entity_id`, `uuid`, `x`, `y`, `z`, `velocity`,
  `on_ground`): `{tracker, packets}`. `sync` is vanilla's `needsSync` (a sharp
  change of motion); `metadata` is the metadata packet when it changed, or nil.
  """
  def tick(tracker, entity, sync \\ false, metadata \\ nil) do
    %{entity_id: id, x: x, y: y, z: z} = entity
    position = {x, y, z}
    velocity = Map.get(entity, :velocity, {0.0, 0.0, 0.0})
    on_ground = Map.get(entity, :on_ground, false)

    {tracker, packets} =
      if sync or rem(tracker.tick, tracker.interval) == 0 or metadata != nil do
        tracker = %{tracker | teleport_delay: tracker.teleport_delay + 1}
        {tracker, move} = move(tracker, entity, position, on_ground)
        {tracker, motion} = motion(tracker, id, velocity)
        {tracker, motion ++ move ++ List.wrap(metadata)}
      else
        {tracker, []}
      end

    {%{tracker | tick: tracker.tick + 1}, packets}
  end

  defp move(tracker, entity, position, on_ground) do
    cond do
      tracker.teleport_delay > 400 or tracker.on_ground != on_ground ->
        tracker = %{tracker | on_ground: on_ground, teleport_delay: 0, base: position}
        {tracker, [sync(entity, on_ground)]}

      distance_sq(position, tracker.base) >= @tolerance or rem(tracker.tick, 60) == 0 ->
        delta = delta(tracker.base, position)

        packet =
          if Enum.all?(Tuple.to_list(delta), &(&1 in -32768..32767)),
            do: binary(EntityPackets.move(entity.entity_id, delta, on_ground)),
            else: sync(entity, on_ground)

        {%{tracker | base: position}, [packet]}

      true ->
        {tracker, []}
    end
  end

  defp motion(tracker, id, {vx, vy, vz} = velocity) do
    diff = distance_sq(velocity, tracker.movement)

    if diff > 1.0e-7 or (diff > 0.0 and vx * vx + vy * vy + vz * vz == 0.0),
      do: {%{tracker | movement: velocity}, [binary(EntityPackets.motion(id, velocity))]},
      else: {tracker, []}
  end

  defp sync(entity, on_ground),
    do: binary(EntityPackets.position(Map.put(entity, :on_ground, on_ground)))

  # Encoded once, sent to every observer as is.
  defp binary({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  # Vanilla's VecDeltaCodec: positions in 1/4096 blocks, rounded half up.
  defp delta({bx, by, bz}, {x, y, z}),
    do: {encode(x) - encode(bx), encode(y) - encode(by), encode(z) - encode(bz)}

  defp encode(value), do: floor(value * 4096.0 + 0.5)

  defp distance_sq({ax, ay, az}, {bx, by, bz}) do
    {dx, dy, dz} = {ax - bx, ay - by, az - bz}
    dx * dx + dy * dy + dz * dz
  end
end
