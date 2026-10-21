defmodule Valimc.Session.JobHandlers do
  @moduledoc "Per-kind results, failures and deadlines of the connection's worker jobs (Session.Jobs) (VMC-069)."

  alias Valimc.Protocol.{
    Packets
  }

  alias Valimc.Player.Placement
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Transfers
  alias Valimc.Player.Mining
  alias Valimc.Player.Vitals

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    PlayerMiningQuery,
    PlayerSnapshot,
    PlayerStore
  }

  def job_result(:pickup, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
      case result do
        {:ok, reservation} -> {:noreply, Transfers.prepare_pickup(state, job, reservation)}
        _ -> {:noreply, state}
      end
    end)
  end

  def job_result(:mining, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
      if System.monotonic_time(:millisecond) < job.deadline do
        {:noreply, Mining.mining_result(state, job, result)}
      else
        if job.stage == :reserve and match?({:ok, %{owner: _, permit: _}}, result),
          do: PlayerMiningQuery.release(elem(result, 1))

        state = Mining.cancel_mining(state)

        {:noreply,
         if(job.stage == :correct, do: state, else: Mining.correct_mining(state, job.position))}
      end
    end)
  end

  def job_result(:placement, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
      case result do
        {:reserved, reservation} ->
          {:noreply, Placement.prepare_survival_placement(state, job.command, reservation)}

        {:ok, outcome, after_ack} ->
          state =
            if job.command.body == nil, do: CreativeInventory.resync_inventory(state), else: state

          state =
            if job.command[:kind] == :ignite,
              do: Valimc.Portal.Items.used(state, job.command, outcome),
              else: state

          send_packets(state, [Packets.ack(job.command.request.sequence) | after_ack])
          {:noreply, state |> Vitals.continue_life() |> Placement.drain_placements()}

        _ ->
          reject(state, "Block interaction unavailable; please reconnect")
      end
    end)
  end

  def job_result(:experience, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
      with {:ok, request} <- result,
           true <- Transfers.experience_current?(state, job),
           true <- Map.delete(request, :permit) == Map.delete(job.intent.request, :permit) do
        state = Transfers.cancel_experience_query(state)
        ref = make_ref()
        snapshot = PlayerSnapshot.capture(state.player, state.inventory)
        intent = %{job.intent | request: request}

        recovery = %{
          Transfers.new_recovery(:play, :prepare, nil)
          | ref: ref,
            plan: %{
              key: intent.key,
              records: [],
              inventory: state.inventory,
              intent: intent,
              snapshot: snapshot
            }
        }

        PlayerStore.prepare_container(
          state.player_store,
          state.store_fence,
          snapshot,
          intent,
          ref
        )

        {:noreply, %{state | recovery: recovery}}
      else
        _ -> {:noreply, Transfers.cancel_experience_query(state)}
      end
    end)
  end

  # A portal's destination (VMC-026b2): travel there.
  def job_result(:portal, _job, result, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Valimc.Player.Portals.arrived(state, result)}
      end)

  # Command and suggestion jobs (`Valimc.Session.Commands`): the next one starts.
  def job_result(:command, job, _result, state),
    do: {:noreply, Valimc.Session.Commands.finished(state, job, :ok)}

  def job_result(:suggestion, job, packet, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Valimc.Session.Commands.suggested(state, job, packet)}
      end)

  def job_down(:command, job, reason, state),
    do: {:noreply, Valimc.Session.Commands.finished(state, job, reason)}

  def job_down(:suggestion, job, _reason, state),
    do: {:noreply, Valimc.Session.Commands.suggested(state, job, nil)}

  def job_down(:placement, _job, _reason, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        reject(state, "Block interaction failed; please reconnect")
      end)

  def job_down(:mining, _job, _reason, state),
    do:
      Valimc.Connection.guard_connection(state, fn -> {:noreply, Mining.cancel_mining(state)} end)

  def job_down(:portal, _job, _reason, state),
    do: {:noreply, Valimc.Player.Portals.failed(state)}

  def job_down(kind, _job, _reason, state) when kind in [:pickup, :experience],
    do: {:noreply, state}

  def job_timeout(:placement, _job, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        reject(state, "Block interaction timed out; please reconnect")
      end)

  def job_timeout(:mining, _job, state),
    do:
      Valimc.Connection.guard_connection(state, fn -> {:noreply, Mining.cancel_mining(state)} end)

  def job_timeout(:portal, _job, state), do: {:noreply, Valimc.Player.Portals.failed(state)}

  def job_timeout(:command, job, state),
    do: {:noreply, Valimc.Session.Commands.finished(state, job, :timeout)}

  def job_timeout(:suggestion, job, state),
    do: {:noreply, Valimc.Session.Commands.suggested(state, job, nil)}

  def job_timeout(_kind, _job, state), do: {:noreply, state}
end
