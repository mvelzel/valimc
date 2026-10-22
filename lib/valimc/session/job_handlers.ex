defmodule Valimc.Session.JobHandlers do
  @moduledoc """
  Results, failures and deadlines of a session's worker jobs
  (`Valimc.Player.Jobs`, VMC-069): commands and suggestions, a portal's
  destination, and a portal item's use.
  """

  import Valimc.Protocol.Codec, only: [reject: 2]

  # A portal item's use (`Valimc.World.Portal.Items`): it wears and is acknowledged.
  def job_result(:placement, job, result, state) do
    Valimc.Session.Messages.guard(state, fn ->
      case result do
        {:ok, outcome, after_ack} ->
          {:noreply, Valimc.Player.Placement.ignited(state, job.command, outcome, after_ack)}

        _ ->
          reject(state, "Block interaction unavailable; please reconnect")
      end
    end)
  end

  # A portal's destination (VMC-026b2): travel there.
  def job_result(:portal, _job, result, state),
    do:
      Valimc.Session.Messages.guard(state, fn ->
        {:noreply, Valimc.Player.Portals.arrived(state, result)}
      end)

  # Command and suggestion jobs (`Valimc.Session.Commands`): the next one starts.
  def job_result(:command, job, _result, state),
    do: {:noreply, Valimc.Session.Commands.finished(state, job, :ok)}

  def job_result(:suggestion, job, packet, state),
    do:
      Valimc.Session.Messages.guard(state, fn ->
        {:noreply, Valimc.Session.Commands.suggested(state, job, packet)}
      end)

  def job_down(:command, job, reason, state),
    do: {:noreply, Valimc.Session.Commands.finished(state, job, reason)}

  def job_down(:suggestion, job, _reason, state),
    do: {:noreply, Valimc.Session.Commands.suggested(state, job, nil)}

  def job_down(:placement, _job, _reason, state),
    do:
      Valimc.Session.Messages.guard(state, fn ->
        reject(state, "Block interaction failed; please reconnect")
      end)

  def job_down(:portal, _job, _reason, state),
    do: {:noreply, Valimc.Player.Portals.failed(state)}

  def job_timeout(:placement, _job, state),
    do:
      Valimc.Session.Messages.guard(state, fn ->
        reject(state, "Block interaction timed out; please reconnect")
      end)

  def job_timeout(:portal, _job, state), do: {:noreply, Valimc.Player.Portals.failed(state)}

  def job_timeout(:command, job, state),
    do: {:noreply, Valimc.Session.Commands.finished(state, job, :timeout)}

  def job_timeout(:suggestion, job, state),
    do: {:noreply, Valimc.Session.Commands.suggested(state, job, nil)}

  def job_timeout(_kind, _job, state), do: {:noreply, state}
end
