defmodule Valimc.World.CookingOrbDelivery do
  @moduledoc "One bounded remote spawn delivery per owner; durable intent survives any uncertain attempt."
  alias Valimc.Txn.Delivery
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
    epoch = state.items.epoch
    cs = state.containers
    key = state.key

    case Delivery.start(
           self(),
           fn worker, token, result ->
             {:resource, epoch, {:cooking_orb_delivered, worker, token, result}}
           end,
           fn -> deliver(cs, key, id) end,
           link: true,
           deadline: 8000,
           deadline_message: &{:resource, epoch, {:cooking_orb_delivery_deadline, &1}}
         ) do
      {:ok, job} ->
        put_in(
          state.cooking_orbs.delivery,
          Map.merge(job, %{id: id, award: cs.pending_awards[id]})
        )

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
      %{pid: ^worker, token: ^token} = job ->
        Delivery.finish(job)
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
        Delivery.abort(job)

        state = put_in(state.cooking_orbs.delivery, nil)
        {:noreply, retry(state, job.id, now() + 1000)}

      _ ->
        {:noreply, state}
    end
  end

  def down(state) do
    job = state.cooking_orbs.delivery
    Delivery.finish(job)
    state = put_in(state.cooking_orbs.delivery, nil)
    {:noreply, retry(state, job.id, now() + 1000)}
  end

  def terminate(runtime) do
    if runtime.delivery, do: Delivery.abort(runtime.delivery)
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

  defp now, do: System.monotonic_time(:millisecond)
end
