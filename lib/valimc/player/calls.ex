defmodule Valimc.Player.Calls do
  @moduledoc """
  Server-authorized changes to a playing session (VMC-077i3): command
  operations. They arrive as calls to the player's connection, which
  forwards them to the session's owner; each expires rather than applying an
  abandoned queued call.
  """
  require Logger

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

  # Tests read, replace and run code on a session wherever it runs
  # (`Valimc.TestConn`); `fun.(state)` answers as a call does.
  def call(:debug_state, state), do: {:reply, state, state}
  def call({:debug_call, fun}, state), do: fun.(state)

  def call({:debug_update, fun}, state) do
    next = fun.(state)
    {:reply, next, next}
  end
end
