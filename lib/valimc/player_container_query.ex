defmodule Valimc.PlayerContainerQuery do
  @moduledoc "Bounded blocking admission outside the socket owner; no source journal is written here."
  def start(owner, request, actor) do
    {:ok,
     Task.Supervisor.async_nolink(
       Valimc.TransferWorkers,
       Valimc.Dimension.bind(fn ->
         try do
           Valimc.World.Region.admit_container_transfer(owner, request, actor)
         catch
           :exit, _ -> Valimc.Error.retry(:region_unavailable)
         end
       end)
     )}
  rescue
    # `async_nolink` raises when the pool is full.
    RuntimeError -> Valimc.Error.retry(:transfer_workers_busy)
  catch
    :exit, _ -> Valimc.Error.retry(:transfer_workers_busy)
  end
end
