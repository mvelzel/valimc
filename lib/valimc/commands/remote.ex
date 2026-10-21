defmodule Valimc.Commands.Remote do
  @moduledoc """
  Runs `Valimc.Player.CommandOps` operations on target players (VMC-053b,
  VMC-077a). Each target's connection applies its own operation, the
  command's own player's too: a command runs in a job beside its connection
  (`Valimc.Session.Commands`), never inside one. The requests go out at once
  (`:gen_server.send_request`) and are awaited under one deadline; a target
  that is gone, not playing or late is `:unavailable`, and a target that
  refuses with a command error reports it as `{:error, error}`.
  """
  alias Valimc.Command.Error

  @timeout 1000

  @doc "`[{target, reply}]` in `targets` order; `op_fun.(target)` is each target's operation."
  def run_all(targets, op_fun) do
    deadline = System.monotonic_time(:millisecond) + @timeout * Valimc.config(:owner_call_scale)

    requests =
      for target <- targets,
          do:
            {target,
             :gen_server.send_request(target.pid, {:command_op, op_fun.(target), deadline})}

    for {target, request} <- requests do
      case :gen_server.receive_response(request, {:abs, deadline + 500}) do
        {:reply, {:ok, reply}} -> {target, reply}
        {:reply, {:error, %Error{} = error}} -> {target, {:error, error}}
        _gone_late_or_not_playing -> {target, :unavailable}
      end
    end
  end

  @doc """
  `run_all/2` for commands that report per target: a command error of every
  target is the command's error (`Error.throw!/1`); otherwise targets that
  refused count as unavailable.
  """
  def run_all!(targets, op_fun) do
    replies = run_all(targets, op_fun)

    case Enum.filter(replies, &match?({_, {:error, %Error{}}}, &1)) do
      [{_, {:error, error}} | _] = refused when length(refused) == length(replies) ->
        Error.throw!(error)

      _ ->
        Enum.map(replies, fn
          {target, {:error, %Error{}}} -> {target, :unavailable}
          reply -> reply
        end)
    end
  end

  @doc "One target's reply (`run_all!/2`)."
  def run!(target, op), do: [target] |> run_all!(fn _ -> op end) |> hd() |> elem(1)
end
