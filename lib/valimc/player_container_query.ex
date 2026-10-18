defmodule Valimc.PlayerContainerQuery do
  @moduledoc "Bounded blocking admission outside the socket owner; no source journal is written here."
  def start(owner, request, actor) do
    {:ok,
     Task.Supervisor.async_nolink(Valimc.TransferWorkers, fn ->
       try do
         Valimc.World.Region.admit_container_transfer(owner, request, actor)
       catch
         :exit, _ -> {:error, :region_unavailable}
       end
     end)}
  rescue
    RuntimeError -> {:error, :transfer_workers_busy}
  catch
    :exit, _ -> {:error, :transfer_workers_busy}
  end
end
