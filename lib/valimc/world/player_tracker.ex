defmodule Valimc.World.PlayerTracker do
  @moduledoc """
  A hosted player's replication state in its group (VMC-077i4), as vanilla's
  `ServerEntity` for a player. Every second tick (a player's update
  interval), and whenever its data changed, the packets of what changed are
  encoded once for every observer and go into the frame of the section the
  player stands in (`Valimc.Entity.Publication`):

  - a relative move (`Pos`, `PosRot` or `Rot`) with the player's rotation and
    ground flag, or an absolute sync when the ground flag changed, the move
    is too long for a delta or 400 updates passed;
  - the head's rotation when it turned;
  - the entity data (flags, pose, the bed it sleeps in, freezing and air,
    item use, health, absorption and its attribute) and the equipment that
    changed.

  Observers spawn the player from its row (`view/5`): at the tracker's base,
  with all of its data and equipment.
  """
  alias Valimc.Data.Grid
  import Bitwise

  alias Valimc.Living.Attributes
  alias Valimc.Protocol.{EntityPackets, Packets}

  defstruct [
    :base,
    :yaw,
    :pitch,
    :head,
    :on_ground,
    :data,
    :equipment,
    # Unique per tracker: a new one (a new host) resyncs its observers; the
    # generation orders two groups publishing the player during a handoff.
    :incarnation,
    tick: 0,
    teleport_delay: 0
  ]

  @interval 2
  @tolerance 7.62939453125e-6
  @death_ticks 20

  def new(player) do
    %__MODULE__{
      base: position(player),
      yaw: angle(player.yaw),
      pitch: angle(player.pitch),
      head: angle(player.yaw),
      on_ground: on_ground(player),
      data: data(player),
      equipment: Map.get(player, :equipment, %{}),
      incarnation: System.unique_integer([:positive, :monotonic])
    }
  end

  @doc "One tick of `player`: `{tracker, packets}`."
  def tick(tracker, player) do
    data = data(player)
    equipment = Map.get(player, :equipment, %{})

    if rem(tracker.tick, @interval) == 0 or data != tracker.data or
         equipment != tracker.equipment do
      {tracker, move} = move(%{tracker | teleport_delay: tracker.teleport_delay + 1}, player)
      head = angle(player.yaw)
      turn = if abs(head - tracker.head) >= 1, do: [rotate_head(player.entity_id, head)], else: []

      packets =
        move ++
          turn ++
          data_packets(player, tracker.data, data) ++
          Enum.map(Valimc.Player.Packets.player_equipment(player, tracker.equipment), &binary/1)

      {%{tracker | head: head, data: data, equipment: equipment, tick: tracker.tick + 1}, packets}
    else
      {%{tracker | tick: tracker.tick + 1}, []}
    end
  end

  defp move(tracker, player) do
    position = position(player)
    {yaw, pitch} = {angle(player.yaw), angle(player.pitch)}
    on_ground = on_ground(player)
    delta = delta(tracker.base, position)
    moved = distance_sq(position, tracker.base) >= @tolerance or rem(tracker.tick, 60) == 0
    turned = abs(yaw - tracker.yaw) >= 1 or abs(pitch - tracker.pitch) >= 1
    id = player.entity_id

    cond do
      tracker.teleport_delay > 400 or tracker.on_ground != on_ground or
          not Enum.all?(Tuple.to_list(delta), &(&1 in -32768..32767)) ->
        sync =
          EntityPackets.position(%{
            entity_id: id,
            x: player.x,
            y: player.y,
            z: player.z,
            yaw: player.yaw,
            pitch: player.pitch,
            on_ground: on_ground
          })

        {%{
           tracker
           | base: position,
             yaw: yaw,
             pitch: pitch,
             on_ground: on_ground,
             teleport_delay: 0
         }, [binary(sync)]}

      moved and turned ->
        {%{tracker | base: position, yaw: yaw, pitch: pitch},
         [binary(EntityPackets.move_rotate(id, delta, yaw, pitch, on_ground))]}

      moved ->
        {%{tracker | base: position}, [binary(EntityPackets.move(id, delta, on_ground))]}

      turned ->
        {%{tracker | yaw: yaw, pitch: pitch},
         [binary(EntityPackets.rotate(id, yaw, pitch, on_ground))]}

      true ->
        {tracker, []}
    end
  end

  @doc """
  The row observers read of `player` (none for a body past its death
  animation or a player in the credits): the spawn at the tracker's base and
  everything the player shows. `connection` is the player's address, `epoch`
  its section's and `generation` its host's.
  """
  def view(tracker, player, connection, epoch, generation) do
    health = player.living.health

    if Map.get(player, :won_game, false) or
         (health.value <= 0 and health.death_ticks >= @death_ticks) do
      nil
    else
      {x, y, z} = tracker.base

      %{
        kind: :player,
        entity_id: player.entity_id,
        uuid: player.uuid,
        pid: connection,
        epoch: epoch,
        ownership_generation: generation,
        tracker: tracker.incarnation,
        chunk: Grid.chunk_key(x, z),
        at: {player.x, player.y, player.z},
        base: tracker.base,
        yaw: player.yaw,
        pitch: player.pitch,
        velocity: player.motion.velocity,
        on_ground: tracker.on_ground,
        spectator: player.game_mode.current == :spectator,
        spawn: binary(Packets.add_entity(%{player | x: x, y: y, z: z})),
        metadata: Enum.map(shown(player), &binary/1)
      }
    end
  end

  # Everything an observer that starts tracking the player needs.
  defp shown(player) do
    [
      Valimc.Player.Packets.player_flags(player),
      Valimc.Player.Packets.player_pose(player),
      Valimc.Player.Packets.player_environment(player),
      Valimc.Player.Packets.player_use(player),
      Valimc.Player.Packets.player_health(player),
      Valimc.Player.Packets.player_absorption(player),
      absorption_attribute(player)
    ] ++
      if(player.living.effects != %{},
        do: [Valimc.Player.Packets.player_effect_particles(player)],
        else: []
      ) ++
      if(Valimc.Player.Packets.sleeping_pos(player),
        do: [Valimc.Player.Packets.player_sleeping_pos(player)],
        else: []
      ) ++ Valimc.Player.Packets.player_equipment(player)
  end

  defp data(player) do
    living = player.living

    {Valimc.Player.Packets.shared_flags(player), Map.get(player, :pose, :standing),
     {living.freezing.frozen_ticks, living.air_supply}, Map.get(player, :use_flags, 0),
     living.health.value, living.absorption, Attributes.absorption_level(living.effects),
     Valimc.Player.Packets.sleeping_pos(player), Valimc.Living.Effects.particles(living.effects)}
  end

  defp data_packets(_player, same, same), do: []

  defp data_packets(player, old, new) do
    [
      {0, &Valimc.Player.Packets.player_flags/1},
      {1, &Valimc.Player.Packets.player_pose/1},
      {2, &Valimc.Player.Packets.player_environment/1},
      {3, &Valimc.Player.Packets.player_use/1},
      {4, &Valimc.Player.Packets.player_health/1},
      {5, &Valimc.Player.Packets.player_absorption/1},
      {6, &absorption_attribute/1},
      {7, &Valimc.Player.Packets.player_sleeping_pos/1},
      {8, &Valimc.Player.Packets.player_effect_particles/1}
    ]
    |> Enum.filter(fn {index, _} -> elem(old, index) != elem(new, index) end)
    |> Enum.map(fn {_, packet} -> binary(packet.(player)) end)
  end

  defp absorption_attribute(player) do
    {:ok, derived} = Attributes.absorption(player.living.effects)
    Packets.attribute(player.entity_id, derived.attribute)
  end

  defp rotate_head(id, head), do: binary(EntityPackets.rotate_head(id, head))

  defp position(player), do: {player.x, player.y, player.z}

  defp on_ground(player) do
    case player do
      %{motion: %{on_ground: on_ground}} when is_boolean(on_ground) -> on_ground
      _ -> false
    end
  end

  defp delta({x0, y0, z0}, {x1, y1, z1}),
    do:
      {round(x1 * 4096) - round(x0 * 4096), round(y1 * 4096) - round(y0 * 4096),
       round(z1 * 4096) - round(z0 * 4096)}

  defp distance_sq({x0, y0, z0}, {x1, y1, z1}),
    do: (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0)

  defp angle(value), do: round(value * 256 / 360) &&& 255

  defp binary({id, payload}), do: {id, IO.iodata_to_binary(payload)}
end
