defmodule Valimc.PlayerPickupQuery do
  @moduledoc "Observed candidates grant nothing; bounded I/O obtains fresh owner permission."
  alias Valimc.Physics.{ItemPickup, PlayerPose}
  alias Valimc.World
  alias Valimc.World.Region

  def signature(player),
    do:
      {player.uuid, player.x, player.y, player.z, player.pose, player.game_mode.current,
       player.living.health.value}

  def actor(player) do
    with {:ok, body} <- PlayerPose.geometry(player.pose, {player.x, player.y, player.z}) do
      {:ok,
       %{
         uuid: player.uuid,
         entity_id: player.entity_id,
         box: body.box,
         game_mode: player.game_mode,
         health: %{value: player.living.health.value}
       }}
    end
  end

  @doc "Rotate through at most 1024 visible observations without queueing every item."
  def candidate(views, box, cursor) when map_size(views) <= 1024 do
    {first, later} =
      Enum.reduce(views, {nil, nil}, fn {id, view}, {first, later} ->
        if view.pickup_delay == 0 and ItemPickup.contact?(box, view.at) do
          {earlier(first, {id, view}),
           if(id > cursor, do: earlier(later, {id, view}), else: later)}
        else
          {first, later}
        end
      end)

    later || first
  end

  def start(actor, view) do
    {:ok,
     Task.Supervisor.async_nolink(
       Valimc.TransferWorkers,
       Valimc.Dimension.bind(fn ->
         key = World.region_key(view.chunk)

         with {:ok, {_, epoch} = owner} <-
                World.existing_owner(World.section(Valimc.Dimension.current(), key, :section)),
              true <- epoch == view.epoch,
              {:ok, grant} <- Region.reserve_pickup(owner, actor, view.uuid) do
           {:ok, %{key: key, owner: owner, grant: grant}}
         else
           _ -> {:error, :pickup_not_available}
         end
       end)
     )}
  rescue
    RuntimeError -> {:error, :pickup_workers_busy}
  catch
    :exit, _ -> {:error, :pickup_workers_busy}
  end

  def release(%{owner: owner, grant: %{permit: permit}}, source),
    do: Region.release_pickup(owner, permit, source)

  defp earlier(nil, entry), do: entry
  defp earlier({id, _} = first, {next, _} = entry), do: if(next < id, do: entry, else: first)
end
