defmodule Valimc.World.EntityTracker do
  @moduledoc """
  An entity's replication state in its owner (VMC-077h), as vanilla's
  `ServerEntity`: what observers were last sent (the position base, movement and
  ground flag) and the packets of each tick's changes, encoded once for every
  observer. An observer that starts tracking the entity spawns it at the base,
  so the relative moves that follow apply to the same position.

  Items and orbs update every 20 ticks (their type's update interval), sooner
  when their motion changes sharply; every 60 ticks the position is sent even
  unchanged, and after 400 ticks of relative moves an absolute sync replaces one.
  """
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
