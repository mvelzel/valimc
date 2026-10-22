defmodule Valimc.Player.Calls do
  @moduledoc """
  Server-authorized changes to a playing session (VMC-077i3): teleports,
  velocity, fall damage, effects and command operations. They arrive as
  calls to the player's connection, which forwards them to the session's
  owner; each expires rather than applying an abandoned queued call.
  """
  require Logger

  alias Valimc.Player.{Movement, Vitals}
  alias Valimc.Player.{Kinetics, PlayerList}
  alias Valimc.Player.State, as: PlayerState

  @live_effects Valimc.Living.Effects.live()

  def call(
        {:teleport, destination, deadline},
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and is_map(destination) and
         map_size(destination) == 5 and
         Enum.all?([:x, :y, :z, :yaw, :pitch], &Map.has_key?(destination, &1)) and
         PlayerState.valid_pose?(destination) do
      {:reply, :ok, Movement.relocate(state, Map.merge(state.player, destination))}
    else
      {:reply, {:error, :invalid_or_expired_teleport}, state}
    end
  end

  def call({:teleport, _, _}, state), do: {:reply, {:error, :not_playing}, state}

  def call(
        {:set_velocity, velocity, deadline},
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and Kinetics.valid_velocity?(velocity) and
         Kinetics.admissible?(state.player, velocity) do
      velocity = velocity |> Tuple.to_list() |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()
      motion = %{state.player.motion | velocity: velocity, settled: false}
      player = %{state.player | motion: motion}
      PlayerList.update(state.connection, player)
      state = %{state | player: player, pose_checked: nil, login_velocity_pending: false}
      state = Movement.send_velocity(state, velocity)
      {:reply, :ok, Movement.sample_pose(state)}
    else
      {:reply, {:error, :invalid_or_expired_velocity}, state}
    end
  end

  def call({:set_velocity, _, _}, state), do: {:reply, {:error, :not_playing}, state}

  def call({:fall_damage, amount, deadline}, %{phase: :play} = state) do
    if System.monotonic_time(:millisecond) < deadline do
      case Valimc.Living.Health.hurt_window(state.player.living.health, amount) do
        {:ok, selected} ->
          try do
            {result, next} = Vitals.apply_damage(state, selected, :fall)
            {:reply, {:ok, result}, next}
          catch
            {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
          end

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :expired_damage}, state}
    end
  end

  def call({:fall_damage, _, _}, state), do: {:reply, {:error, :not_playing}, state}

  def call(
        {:effect, id, incoming, deadline},
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and id in @live_effects do
      try do
        case Vitals.apply_effect(state, id, incoming) do
          {:ok, changed, next} -> {:reply, {:ok, changed}, next}
          {:error, _} = error -> {:reply, error, state}
        end
      catch
        {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
      end
    else
      {:reply, {:error, :invalid_or_expired_effect}, state}
    end
  end

  def call({:command_op, op, deadline}, %{phase: :play} = state) do
    if System.monotonic_time(:millisecond) < deadline do
      try do
        {reply, next} = Valimc.Player.CommandOps.apply(state, op)
        {:reply, {:ok, reply}, next}
      rescue
        exception ->
          Logger.error(
            "Command operation failed: " <> Exception.format(:error, exception, __STACKTRACE__)
          )

          {:reply, {:error, :failed}, state}
      catch
        {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
        {:command_syntax, error} -> {:reply, {:error, error}, state}
      end
    else
      {:reply, {:error, :expired}, state}
    end
  end

  def call({:command_op, _, _}, state), do: {:reply, {:error, :not_playing}, state}

  def call({:effect, _, _, _}, state), do: {:reply, {:error, :not_playing}, state}

  # Tests read and replace a session wherever it runs (`Valimc.TestConn`).
  def call(:debug_state, state), do: {:reply, state, state}

  def call({:debug_update, fun}, state) do
    next = fun.(state)
    {:reply, next, next}
  end
end
