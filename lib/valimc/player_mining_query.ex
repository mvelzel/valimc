defmodule Valimc.PlayerMiningQuery do
  @moduledoc "Bounded region I/O for a player-owned attempt; callbacks never confer player authority."
  alias Valimc.World
  alias Valimc.World.Region

  def reserve({x, _, z} = position) do
    start(fn ->
      key = World.region_key(World.chunk_key(x, z))

      with {:ok, owner} <- World.existing_owner(key),
           {:ok, reservation} <- Region.reserve_mining(owner, [position]),
           do: {:ok, Map.merge(reservation, %{key: key, owner: owner})}
    end)
  end

  def renew(reservation),
    do: start(fn -> Region.renew_mining(reservation.owner, reservation.permit) end)

  def observe({x, _, z} = position) do
    start(fn ->
      key = World.region_key(World.chunk_key(x, z))

      with {:ok, owner} <- World.existing_owner(key),
           {:ok, observation} <- Region.observe_blocks(owner, [position]),
           {:ok, update} <- Region.block_entity_update(owner, position),
           do: {:ok, owner, Map.fetch!(observation.blocks, position), update}
    end)
  end

  def release(%{owner: owner, permit: permit}) do
    Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
      safely(fn -> Region.release_mining(owner, permit) end)
    end)
  catch
    :exit, _ -> :ok
  end

  defp start(fun) do
    {:ok, Task.Supervisor.async_nolink(Valimc.Workers.collision(), fn -> safely(fun) end)}
  rescue
    RuntimeError -> {:error, :mining_workers_busy}
  catch
    :exit, _ -> {:error, :mining_workers_busy}
  end

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :mining_region_unavailable}
  end
end
