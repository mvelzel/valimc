defmodule Valimc.World.Portal.GatewayDestination do
  @moduledoc """
  Where an end gateway takes a player (VMC-026b4), as vanilla's
  `EndGatewayBlock.getPortalDestination` and
  `TheEndGatewayBlockEntity.getPortalPosition` decide it, within the End:

  - A gateway with an exit takes the player above the tallest block near it
    (or exactly to it, for an exact exit, as the outer islands' return
    gateways have).
  - One without an exit in the End finds one first (`Valimc.World.Portal.Gateway`),
    builds the exit gateway there with its own exit back, and records both
    exits durably in their regions' preserved block entities.

  The player keeps its rotation and motion. Runs in a task of the End.
  """
  alias Valimc.World.Portal.{Access, Gateway}
  alias Valimc.Worldgen.FullChunk

  @doc "The travel target for `entry` (`%{entry, yaw, pitch, velocity}`), `:none` or an error."
  def destination(entry) do
    dimension = Valimc.World.Dimension.current()
    {min_y, height} = Valimc.World.Dimension.bounds()
    bounds = {min_y, min_y + height - 1}

    with {:ok, gateway} <- Access.block_entity(entry.entry),
         {:ok, {exit, exact}} <- exit(gateway, entry.entry, dimension, bounds) do
      {x, y, z} = Gateway.arrival(Access.reader(), exit, exact, bounds)

      {:ok,
       %{
         dimension: dimension,
         x: x + 0.5,
         y: y * 1.0,
         z: z + 0.5,
         yaw: entry.yaw,
         pitch: entry.pitch,
         velocity: entry.velocity,
         portal: false
       }}
    end
  end

  defp exit(gateway, position, dimension, bounds) do
    case recorded(gateway) do
      {:ok, exit} -> {:ok, exit}
      :none when dimension == :the_end -> search(position, bounds)
      :none -> :none
    end
  end

  # `loadAdditional`: an exit in the spawnable bounds, and whether it is exact.
  defp recorded(%{nbt: nbt}) do
    with {:ok, {:compound, tag}} <- Valimc.Data.NBT.read(nbt),
         {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>} <- tag["exit_portal"],
         true <- abs(x) < 30_000_000 and abs(z) < 30_000_000 and abs(y) < 20_000_000 do
      {:ok, {{x, y, z}, match?({:byte, b} when b != 0, tag["ExactTeleport"])}}
    else
      _ -> :none
    end
  end

  defp recorded(nil), do: :none

  # `getPortalPosition` without an exit: find a spot, raise an island if
  # needed, build the exit gateway 10 above the tallest block there.
  defp search(position, bounds) do
    read = Access.reader()

    point =
      Gateway.tentative(position, fn x, z -> Access.chunk_empty?(Gateway.chunk_of({x, z})) end)

    chunk = Gateway.chunk_of(point)
    spot = Gateway.valid_spawn(read, chunk, Access.chunk_top(chunk))

    spot =
      case spot do
        nil ->
          {px, pz} = point
          origin = {floor(px + 0.5), 75, floor(pz + 0.5)}
          :ok = Access.commit(Gateway.island(origin))
          origin

        found ->
          found
      end

    {tx, ty, tz} = Gateway.tallest(Access.reader(), spot, 16, true, bounds)
    portal = {tx, ty + 10, tz}

    with :ok <- Access.commit(Gateway.structure(portal)),
         {:ok, back} <- FullChunk.gateway_entry(portal, {position, false}),
         {:ok, there} <- FullChunk.gateway_entry(position, {portal, false}),
         :ok <- Access.put_block_entities(%{portal => back}),
         :ok <- Access.put_block_entities(%{position => there}) do
      {:ok, {portal, false}}
    end
  end
end
