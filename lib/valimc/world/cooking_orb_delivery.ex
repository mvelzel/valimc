defmodule Valimc.World.CookingOrbDelivery do
  @moduledoc "One bounded remote spawn delivery per owner; durable intent survives any uncertain attempt."
  alias Valimc.World
  alias Valimc.World.{CookingOrbTransfers, Region}

  def tick(state, now) do
    runtime = state.cooking_orbs

    cond do
      not state.item_storage_enabled or runtime.delivery != nil or runtime.receipt != nil ->
        state

      is_integer(runtime.delivery_retry_at) and now < runtime.delivery_retry_at ->
        state

      runtime.delivery_seen == state.containers.orb_transfers.revision ->
        state

      true ->
        ids = for {id, :pending} <- state.containers.orb_transfers.outgoing, do: id
        ids = Enum.sort(ids)

        {before, later} =
          if runtime.delivery_cursor == nil,
            do: {[], ids},
            else: Enum.split_while(ids, &(&1 <= runtime.delivery_cursor))

        case later ++ before do
          [] -> put_in(state.cooking_orbs.delivery_seen, state.containers.orb_transfers.revision)
          [id | _] -> start(state, id, now)
        end
    end
  end

  defp start(state, id, now) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    cs = state.containers
    key = state.key

    case Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
           Process.link(owner)
           result = deliver(cs, key, id)
           send(owner, {:resource, epoch, {:cooking_orb_delivered, self(), token, result}})
         end) do
      {:ok, worker} ->
        job = %{
          worker: worker,
          token: token,
          monitor: Process.monitor(worker),
          id: id,
          award: cs.pending_awards[id],
          timer:
            Process.send_after(
              owner,
              {:resource, epoch, {:cooking_orb_delivery_deadline, token}},
              8000
            )
        }

        put_in(state.cooking_orbs.delivery, job)

      {:error, _} ->
        retry(state, id, now + 100)
    end
  end

  defp deliver(cs, key, id) do
    with {:ok, request} <- CookingOrbTransfers.request(cs, key, id),
         {:ok, bytes} <- CookingOrbTransfers.encode_request(request),
         {:ok, digest} <- CookingOrbTransfers.digest(request),
         {:ok, owner} <- World.item_owner(request.destination),
         {:ok, result} when result in [:applied, :already_applied] <-
           Region.apply_cooking_orb_spawn(owner, bytes),
         do: {:ok, id, digest}
  catch
    :exit, _ -> {:error, :cooking_orb_delivery_uncertain}
  end

  def returned(state, worker, token, result) do
    case state.cooking_orbs.delivery do
      %{worker: ^worker, token: ^token} = job ->
        clear(job)
        state = put_in(state.cooking_orbs.delivery, nil)

        case result do
          {:ok, id, <<_::256>> = digest} when id == job.id ->
            if state.containers.pending_awards[id] === job.award and
                 state.containers.orb_transfers.outgoing[id] == :pending do
              {:noreply, put_in(state.cooking_orbs.receipt, {id, digest})}
            else
              {:noreply, retry(state, id, now() + 100)}
            end

          _ ->
            {:noreply, retry(state, job.id, now() + 1000)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def expired(state, token) do
    case state.cooking_orbs.delivery do
      %{token: ^token} = job ->
        clear(job)
        Process.exit(job.worker, :kill)

        state = put_in(state.cooking_orbs.delivery, nil)
        {:noreply, retry(state, job.id, now() + 1000)}

      _ ->
        {:noreply, state}
    end
  end

  def down(state) do
    job = state.cooking_orbs.delivery
    clear(job)
    state = put_in(state.cooking_orbs.delivery, nil)
    {:noreply, retry(state, job.id, now() + 1000)}
  end

  def terminate(runtime) do
    if runtime.delivery do
      clear(runtime.delivery)
      Process.exit(runtime.delivery.worker, :kill)
    end
  end

  defp retry(state, id, at),
    do: %{
      state
      | cooking_orbs: %{
          state.cooking_orbs
          | delivery_cursor: id,
            delivery_retry_at: at,
            delivery_seen: nil
        }
    }

  defp clear(job) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
  end

  defp now, do: System.monotonic_time(:millisecond)
end
