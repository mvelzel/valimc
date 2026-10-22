defmodule Valimc.Player.Travel do
  @moduledoc """
  A player changing dimension (VMC-026b), as vanilla's `ServerPlayer.teleport`
  does it across levels: the player keeps its inventory, effects, experience,
  health and game mode, arrives at the destination with the destination's
  velocity and rotation, and the client rebuilds its level from a respawn
  packet that keeps all data.

  A travel waits until no world job of the old dimension is in flight, then
  switches; the player's next frame (`Valimc.Player.Storage`) names the
  destination. Respawning after a death elsewhere crosses the same way
  (`leave/2`).
  """

  alias Valimc.Players
  alias Valimc.Session.Jobs

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
  def settled?(state), do: not Jobs.active?(state.jobs, :placement)

  @doc "Arrive at the destination once settled (`finish/2`)."
  def continue(%{travel: nil} = state), do: state
  def continue(%{phase: phase} = state) when phase != :play, do: state
  def continue(%{life_stage: stage} = state) when stage != :alive, do: %{state | travel: nil}

  def continue(%{travel: target} = state) do
    if settled?(state), do: finish(state, arrive(state.player, target)), else: state
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
  The player has arrived: leave the old level, rebuild the client's in
  `player.dimension` and place the player there.
  """
  def finish(state, player) do
    portal = match?(%{portal: true}, state.travel)
    # Vanilla keeps all data across a teleport; a respawn after the credits keeps attributes.
    keep = Map.get(state.travel || %{}, :keep, 3)
    state = %{state | travel: nil, portal: state.portal && %{state.portal | last: nil}}

    Valimc.Player.Level.respawn(state, player, state.inventory,
      keep: keep,
      portal: portal,
      post_effects: post_effects(player)
    )
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
