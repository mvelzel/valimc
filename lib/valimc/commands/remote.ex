defmodule Valimc.Commands.Remote do
  @moduledoc """
  Runs a `Valimc.Player.CommandOps` operation on a target player (VMC-053b):
  inline for the command's own player, otherwise a bounded call to the target's
  connection. A target that does not answer in time is skipped (`:unavailable`).
  """
  alias Valimc.Player.CommandOps

  @timeout 1000

  def run(state, %{pid: pid}, op) when pid == self(), do: CommandOps.apply(state, op)

  def run(state, %{pid: pid}, op) do
    deadline = System.monotonic_time(:millisecond) + @timeout

    case GenServer.call(pid, {:command_op, op, deadline}, @timeout + 500) do
      {:ok, reply} -> {reply, state}
      {:error, %Valimc.Command.Error{} = error} -> Valimc.Command.Error.throw!(error)
      {:error, _} -> {:unavailable, state}
    end
  catch
    :exit, _ -> {:unavailable, state}
  end
end
