defmodule Valimc.Player.Travel do
  @moduledoc """
  A player changing dimension (VMC-026b), as vanilla's `ServerPlayer.teleport`
  does it across levels: the player keeps its inventory, effects, experience,
  health and game mode, arrives at the destination with the destination's
  velocity and rotation, and the client rebuilds its level from a respawn
  packet that keeps all data.

  A player's durable state names its dimension, and a pending transfer (an
  outbox) targets the dimension it was prepared in. A travel therefore waits
  until no save, transfer, recovery or world job of the old dimension is in
  flight, then saves the player at the destination before it switches: a
  crash before that save leaves the player where it was, one after it at the
  destination. Respawning after a death elsewhere crosses the same way
  (`leave/2`).
  """

  import Valimc.Net.Codec, only: [send_packets: 2]

  alias Valimc.Players
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Player.{Movement, Vitals}
  alias Valimc.Protocol.Packets

  alias Valimc.World.{BorderReplication, Clock, WeatherReplication}

  @typedoc "Where a travel ends: a dimension and a pose, with the arrival velocity."
  @type target :: %{
          dimension: atom(),
          x: float(),
          y: float(),
          z: float(),
          yaw: float(),
          pitch: float(),
          velocity: {float(), float(), float()}
        }

  # Ticks a player stays on portal cooldown after a transition (vanilla's
  # `Player.getDimensionChangingDelay`).
  @cooldown 10
  def cooldown, do: @cooldown

  @doc "One player tick: a waiting travel tries again (the portal cooldown is `Portals.tick/1`'s)."
  def tick(state), do: continue(state)

  @doc "Begin a travel to `target`; it completes once the old dimension's work settles."
  def request(%{travel: nil} = state, target), do: continue(%{state | travel: target})
  def request(state, _target), do: state

  @doc "Whether the old dimension's work has settled, so the player can leave it."
  def settled?(state) do
    state.save_ref == nil and state.recovery == nil and state.life_save == nil and
      state.use_save == nil and state.table_job == nil and not state.table_closing and
      state.crafting_repeat == nil and state.creative_input.queued == 0 and
      state.placement_queued == 0 and state.table_queued == 0 and
      not Enum.any?(
        Map.keys(state.jobs.active),
        &(&1 in [:placement, :pickup, :mining, :experience])
      )
  end

  @doc "Save the player at the destination once settled; `finish/2` follows the save."
  def continue(%{travel: nil} = state), do: state
  def continue(%{travel: %{saving: true}} = state), do: state
  def continue(%{phase: phase} = state) when phase != :play, do: state
  def continue(%{life_stage: stage} = state) when stage != :alive, do: %{state | travel: nil}

  def continue(%{travel: target} = state) do
    if settled?(state) do
      player = arrive(state.player, target)
      snapshot = PlayerState.capture(player, state.inventory)

      Vitals.checkpoint_life(
        %{state | travel: Map.put(target, :saving, true)},
        :travel,
        snapshot,
        player
      )
    else
      state
    end
  end

  # Portals start the player's portal cooldown; command teleports do not.
  defp arrive(player, target) do
    player = %{
      player
      | dimension: target.dimension,
        x: target.x,
        y: target.y,
        z: target.z,
        yaw: target.yaw,
        pitch: target.pitch,
        motion: %{player.motion | velocity: target.velocity, fall_distance: 0.0}
    }

    if Map.get(target, :portal, false),
      do: Map.put(player, :portal_cooldown, @cooldown),
      else: player
  end

  @doc """
  The saved player has arrived: leave the old level, rebuild the client's in
  `player.dimension` and place the player there.
  """
  def finish(state, player) do
    portal = match?(%{portal: true}, state.travel)
    # Vanilla keeps all data across a teleport; a respawn after the credits keeps attributes.
    keep = Map.get(state.travel || %{}, :keep, 3)
    state = leave(state, player)
    {clock_version, clock_packet} = Clock.initial()
    {difficulty, difficulty_packet} = Clock.difficulty()
    border = Clock.border()
    weather = Clock.weather()

    Valimc.Session.Link.reset_view(state, %{
      unload: false,
      dimension: player.dimension,
      clock_version: clock_version,
      difficulty: difficulty,
      weather: weather,
      border: border
    })

    state = %{
      state
      | player: player,
        active_use: nil,
        life_save: nil,
        travel: nil,
        portal: state.portal && %{state.portal | last: nil}
    }

    send_packets(state, [
      Packets.respawn(player, player.last_death, keep),
      difficulty_packet,
      Packets.permission_level(player.entity_id, Valimc.Permissions.level(player))
    ])

    state = Movement.relocate(state, player, false, player.motion.velocity)

    # Vanilla's `sendLevelInfo`: border, clocks, spawn, rain where it rains,
    # then the chunk loading screen; then abilities, inventory and effects.
    rain = if weather.wet, do: elem(WeatherReplication.reconcile(nil, weather), 1), else: []

    send_packets(
      state,
      [
        Packets.abilities(player.abilities),
        BorderReplication.initialize(border),
        clock_packet,
        Packets.spawn_position()
      ] ++
        rain ++
        [
          Packets.level_load_start(),
          Valimc.World.TickRate.state_packet(Valimc.World.TickRate.published()),
          Valimc.World.TickRate.step_packet(Valimc.World.TickRate.join_steps()),
          Packets.inventory(state.inventory),
          Packets.cursor(state.inventory.carried),
          Packets.held_slot(state.inventory.selected),
          Packets.experience(player.progression.experience),
          Packets.health(player.living.health, player.food)
        ] ++
        Enum.map(player.living.effects, fn {id, [rung | _]} ->
          Packets.update_effect(player.entity_id, id, rung, false)
        end) ++
        post_effects(player) ++
        if(portal, do: [Packets.level_event(1032, {0, 0, 0}, 0)], else: [])
    )

    for pid <- Players.around(state.player),
        pid != state.connection,
        do:
          Valimc.Connection.deliver(pid, {:player_respawned, state.connection, player.entity_id})

    state
  end

  defp post_effects(player) do
    case Map.get(player, :post_effects, []) do
      [] -> []
      ids -> [Valimc.Player.PostEffects.packet(ids)]
    end
  end

  @doc """
  Leave the session's dimension for `player.dimension`, if it differs:
  publish the player in the new one, tell the old dimension's nearby players
  it is gone, and switch the context. The connection releases the old
  dimension's topics with its view reset; the session's group hands it to the
  new dimension's.
  """
  def leave(state, player) do
    from = state.player.dimension
    to = Map.get(player, :dimension, :overworld)

    if from == to do
      state
    else
      peers = Players.around(state.player)
      Valimc.Dimension.put(to)
      # The index moves the player first, so the old peers' refresh finds it gone.
      Players.update(state.connection, player)

      for pid <- peers,
          pid != state.connection,
          do:
            Valimc.Connection.deliver(
              pid,
              {:player_respawned, state.connection, player.entity_id}
            )

      state
    end
  end
end
