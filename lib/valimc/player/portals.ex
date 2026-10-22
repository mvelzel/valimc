defmodule Valimc.Player.Portals do
  @moduledoc """
  A player in a portal (VMC-026b2), as vanilla's `Entity.setAsInsidePortal`,
  `handlePortal` and `PortalProcessor` keep it, once per player tick:

  - Contact: the portal blocks the player's box touched on its way since the
    last tick. On cooldown, a touch only renews the cooldown (10 ticks), so a
    player arriving in a portal does not travel back until it steps out.
    Otherwise it starts a portal process (or renews the entry block of one).
  - The cooldown runs down.
  - The process: a tick inside counts towards the portal's time (80 ticks for
    a nether portal in survival, the game rules' delays; none for creative
    players and end portals and gateways); a tick outside takes 4 off, and at
    0 the process ends. At its time the player starts its cooldown and the
    destination is found in a job (`Valimc.Portal.Destination`); its target
    becomes a travel (`Valimc.Player.Travel`).

  Spectators touch no blocks (vanilla's `noPhysics`), so never travel.
  """
  alias Valimc.GameRules
  alias Valimc.Physics.PlayerPose
  alias Valimc.Player.Travel
  alias Valimc.Session.Jobs
  alias Valimc.World.View

  @cooldown Travel.cooldown()
  # Ticks before a failed destination is tried again.
  @retry 20

  @doc "The portal kind of a block state, or nil."
  defdelegate kind(state), to: Valimc.Portal.Contact

  @doc "One player tick of portal contact, cooldown and process."
  def tick(%{life_stage: :alive, phase: :play, player: %{won_game: true}} = state), do: state

  def tick(%{life_stage: :alive, phase: :play} = state) do
    player = state.player
    portal = Map.get(state, :portal) || %{process: nil, last: nil}
    position = {player.x, player.y, player.z}

    touch =
      if player.game_mode.current == :spectator,
        do: nil,
        else: touched(player, portal.last || position)

    # An end portal in the End shows a player the credits once (`showEndCredits`).
    if match?({:end_portal, _}, touch) and Valimc.Dimension.current() == :the_end and
         not Map.get(player, :seen_credits, false) do
      credits(%{state | portal: %{portal | last: position}})
    else
      tick(state, player, portal, position, touch)
    end
  end

  def tick(state), do: %{state | portal: nil}

  defp tick(state, player, portal, position, touch) do
    {player, process, due} = step(player, portal.process, touch)
    retry = max(Map.get(portal, :retry, 0) - 1, 0)
    state = %{state | player: player, portal: %{process: process, last: position, retry: retry}}

    # A process that starts has its destination's regions admitted (`Valimc.Portal.Warm`).
    if process && (portal.process == nil or portal.process.kind != process.kind),
      do: Valimc.Portal.Warm.start(process.kind, process.entry)

    if due and retry == 0 do
      player = %{state.player | portal_cooldown: @cooldown}
      start_destination(%{state | player: player}, process)
    else
      state
    end
  end

  @doc """
  A destination job that failed (an error, a crash or its deadline): vanilla
  finds destinations synchronously and never gets here. The player's cooldown
  ends, so a player still in the portal tries again after `@retry` ticks
  rather than renewing the cooldown until it steps out.
  """
  def failed(state) do
    portal = Map.get(state, :portal) || %{process: nil, last: nil}

    %{
      state
      | player: %{state.player | portal_cooldown: 0},
        portal: Map.put(portal, :retry, @retry)
    }
  end

  @doc """
  One tick of a player's portal state (pure): the touch (`{kind, position}`
  or nil) as `setAsInsidePortal` takes it, the cooldown running down, then
  the process (`processPortalTeleportation`, `hasExpired`). Returns the
  player, the process and whether it is due to travel now.
  """
  def step(player, process, touch) do
    {player, process} =
      if player.game_mode.current == :spectator,
        do: {player, nil},
        else: contact(player, process, touch)

    player = %{player | portal_cooldown: max(Map.get(player, :portal_cooldown, 0) - 1, 0)}
    {process, due} = advance(player, process)
    {player, process, due}
  end

  # The credits roll: the player leaves the End's level until its client asks
  # to respawn (`PERFORM_RESPAWN`, `credits_done/1`).
  defp credits(state) do
    player = state.player |> Map.put(:seen_credits, true) |> Map.put(:won_game, true)

    Valimc.Net.Codec.send_packets(state, [
      Valimc.Protocol.Packets.packet("game_event", <<4, 0.0::float-32>>)
    ])

    Valimc.Players.update(state.connection, player)

    for pid <- Valimc.Players.around(state.player),
        pid != state.connection,
        do:
          Valimc.Connection.deliver(pid, {:player_respawned, state.connection, player.entity_id})

    %{state | player: player}
  end

  @doc """
  After the credits (`PlayerList.respawn` keeping all data): the player
  respawns in the overworld with everything it had.
  """
  def credits_done(%{player: %{won_game: true}} = state) do
    state = %{state | player: Map.put(state.player, :won_game, false)}

    target =
      Valimc.Portal.EndPortal.respawn_target()
      |> Map.merge(%{portal: false, keep: 1})

    Travel.request(state, target)
  end

  def credits_done(state), do: state

  # `setAsInsidePortal`.
  defp contact(player, process, nil), do: {player, process}

  defp contact(player, process, {kind, position}) do
    cond do
      Map.get(player, :portal_cooldown, 0) > 0 ->
        {%{player | portal_cooldown: @cooldown}, process}

      process == nil or process.kind != kind ->
        {player, %{kind: kind, entry: position, time: 0, inside: true}}

      not process.inside ->
        {player, %{process | entry: position, inside: true}}

      true ->
        {player, process}
    end
  end

  # `processPortalTeleportation`, then `hasExpired`.
  defp advance(_player, nil), do: {nil, false}

  defp advance(_player, %{inside: false} = process) do
    time = max(process.time - 4, 0)
    {if(time <= 0, do: nil, else: %{process | time: time}), false}
  end

  defp advance(player, process) do
    due = process.time >= transition_time(player, process.kind)
    {%{process | inside: false, time: process.time + 1}, due}
  end

  @doc "Ticks a player stays in a portal of `kind` before it travels (`getPortalTransitionTime`)."
  def transition_time(player, :nether_portal) do
    rule =
      if player.abilities.invulnerable,
        do: :players_nether_portal_creative_delay,
        else: :players_nether_portal_default_delay

    max(0, GameRules.get(rule))
  end

  def transition_time(_player, _kind), do: 0

  defp start_destination(state, process) do
    if Jobs.active?(state.jobs, :portal) do
      state
    else
      player = state.player

      entry = %{
        kind: process.kind,
        position: {player.x, player.y, player.z},
        entry: process.entry,
        pose: Map.get(player, :pose, :standing),
        yaw: player.yaw,
        pitch: player.pitch,
        velocity: player.motion.velocity,
        spectator: player.game_mode.current == :spectator,
        seen_credits: Map.get(player, :seen_credits, false)
      }

      task =
        Task.Supervisor.async_nolink(
          Valimc.TransferWorkers,
          Valimc.Dimension.bind(fn ->
            try do
              destination(entry)
            rescue
              error -> {:error, Exception.message(error)}
            catch
              :exit, reason -> {:error, {:exit, reason}}
            end
          end)
        )

      {jobs, _job} = Jobs.track(state.jobs, :portal, task, timeout: 60_000, data: %{entry: entry})
      %{state | jobs: jobs}
    end
  rescue
    RuntimeError -> state
  catch
    :exit, _ -> state
  end

  defp destination(%{kind: :nether_portal} = entry), do: Valimc.Portal.Destination.nether(entry)
  defp destination(%{kind: :end_portal} = entry), do: Valimc.Portal.EndPortal.destination(entry)

  defp destination(%{kind: :end_gateway} = entry),
    do: Valimc.Portal.GatewayDestination.destination(entry)

  defp destination(_entry), do: :none

  @doc """
  A destination job's result: travel there (`isAllowedToEnterPortal`
  permitting), or teleport within the dimension (an end gateway) keeping the
  player's motion.
  """
  def arrived(state, {:ok, %{dimension: dimension} = target}) do
    cond do
      dimension == :the_nether and not GameRules.get(:allow_entering_nether_using_portals) ->
        state

      dimension == Valimc.Dimension.current() ->
        player = state.player

        player = %{
          player
          | x: target.x,
            y: target.y,
            z: target.z,
            yaw: target.yaw,
            pitch: target.pitch,
            motion: %{player.motion | velocity: target.velocity}
        }

        Valimc.Player.Movement.relocate(state, player, false, target.velocity)

      true ->
        Travel.request(state, target)
    end
  end

  def arrived(state, {:credits, target}), do: arrived(state, {:ok, target})
  def arrived(state, :none), do: state

  def arrived(state, result) do
    require Logger
    Logger.warning("Portal destination unavailable: #{inspect(result, limit: 12)}")
    failed(state)
  end

  # The first portal block the player's box met on its way from `from`.
  defp touched(player, from) do
    pose = Map.get(player, :pose, :standing)

    box_at = fn point ->
      {:ok, %{box: box}} = PlayerPose.geometry(pose, point)
      box
    end

    Valimc.Portal.Contact.touched(box_at, from, {player.x, player.y, player.z}, &read/1)
  end

  # States at `positions` from the loaded owners' published snapshots.
  defp read(positions) do
    states = View.blocks(View.new(), positions)

    for {position, state} <- Enum.zip(positions, states),
        state != nil,
        into: %{},
        do: {position, state}
  end
end
