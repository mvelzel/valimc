defmodule Valimc.Portal.Items do
  @moduledoc """
  Items that make portals, used on a block (VMC-026b2, VMC-026b3):

  - Flint and steel and fire charges, as vanilla's `FlintAndSteelItem.useOn`
    and `FireChargeItem.useOn`: fire goes on the clicked face where
    `BaseFireBlock.canBePlacedAt` allows it, and in an empty nether portal
    frame of the overworld or the Nether the portal opens instead
    (`Valimc.Portal.Fire.ignite/4`). In survival a flint and steel wears by
    one and a fire charge is used up.
  - Eyes of ender, as `EnderEyeItem.useOn`: one fills an end portal frame
    without an eye, and a completed frame opens the end portal
    (`Valimc.Portal.EndPortal`). In survival the eye is used up.

  Campfires, candles and TNT, which flint and steel also lights, fire's spread
  and burning out, and eyes thrown into the air are not handled yet.

  The use runs as the connection's placement job: a task reads the clicked
  neighbourhood, commits per region owner, then has the owners resend the
  clicked blocks before the acknowledgement.
  """
  alias Valimc.Portal.{Access, Blocks, EndPortal, Fire, Shape}
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World
  alias Valimc.World.Region

  @flint Data.item("flint_and_steel")
  @charge Data.item("fire_charge")
  @eye Data.item("ender_eye")

  @doc "Whether a held stack makes portals."
  def item?(%ItemStack{item_id: id}), do: id in [@flint, @charge, @eye]
  def item?(_), do: false

  @doc "Start the use of `command` (from `Valimc.Player.Placement`) in a task."
  def start(command, connection) do
    {:ok,
     Task.Supervisor.async_nolink(
       Valimc.TransferWorkers,
       Valimc.Dimension.bind(fn ->
         outcome = if command.body, do: light(command), else: {:refused, :player_admission}

         with {:ok, after_ack} <- correct(command.request, connection),
              do: {:ok, outcome, after_ack}
       end)
     )}
  rescue
    RuntimeError -> {:error, :placement_workers_busy}
  catch
    :exit, _ -> {:error, :placement_workers_busy}
  end

  defp light(%{item: @eye, request: request} = command) do
    read = Access.reader()
    frame = read.(request.position)

    cond do
      System.monotonic_time(:millisecond) > command.expires ->
        {:refused, :expired}

      not EndPortal.frame?(frame) or EndPortal.eye?(frame) ->
        {:refused, :not_an_empty_frame}

      true ->
        with :ok <- Access.commit([{request.position, EndPortal.with_eye(frame)}]) do
          {x, _, z} = request.position
          key = World.section(Valimc.Dimension.current(), World.chunk_key(x, z))
          World.publish(key, {:level_events, [{request.position, 1503, 0}]})

          opened =
            case EndPortal.opening(Access.reader(), request.position) do
              nil ->
                false

              cells ->
                :ok = Access.commit(EndPortal.portal_edits(cells))
                {cx, cy, cz} = Enum.at(cells, 4)
                Valimc.Players.broadcast({:global_level_event, 1038, {cx, cy, cz}, 0})
                Valimc.Portal.Warm.start(:end_portal, {cx, cy, cz})
                true
            end

          {:ignited, %{item: @eye, portal: opened}}
        else
          error -> {:refused, error}
        end
    end
  catch
    :exit, _ -> {:refused, :region_unavailable}
  end

  defp light(%{request: request} = command) do
    dimension = Valimc.Dimension.current()
    {min_y, _height} = Valimc.Dimension.bounds()
    position = Valimc.Physics.Placement.adjacent(request)
    read = Access.reader()

    cond do
      System.monotonic_time(:millisecond) > command.expires ->
        {:refused, :expired}

      not World.Chunk.valid_y?(elem(position, 1)) ->
        {:refused, :outside_build_height}

      not Fire.placeable?(read, position, facing(request.yaw), dimension, min_y) ->
        {:refused, :fire_not_placeable}

      true ->
        edits =
          case Fire.ignite(read, position, dimension, min_y) do
            {:portal, shape} ->
              state = Blocks.portal(shape.axis)
              for cell <- Shape.positions(shape), do: {cell, state}

            {:fire, state} ->
              [{position, state}]

            :none ->
              []
          end

        portal = match?([_, _ | _], edits)

        case Access.commit(edits) do
          :ok ->
            if portal, do: Valimc.Portal.Warm.start(:nether_portal, elem(hd(edits), 0))
            {:ignited, %{item: command.item, portal: portal}}

          error ->
            {:refused, error}
        end
    end
  catch
    :exit, _ -> {:refused, :region_unavailable}
  end

  # `Direction.fromYRot`: the horizontal direction a player with `yaw` faces.
  defp facing(yaw) do
    case Bitwise.band(floor(yaw / 90.0 + 0.5), 3) do
      0 -> :south
      1 -> :west
      2 -> :north
      3 -> :east
    end
  end

  # The client predicted fire on the clicked face; the owners resend both blocks.
  defp correct(request, connection) do
    [request.position, Valimc.Physics.Placement.adjacent(request)]
    |> Enum.uniq()
    |> Enum.group_by(fn {x, _, z} -> World.region_key(World.chunk_key(x, z)) end)
    |> Enum.reduce_while({:ok, []}, fn {key, positions}, {:ok, packets} ->
      with {:ok, owner} <-
             World.existing_owner(World.section(Valimc.Dimension.current(), key, :section)),
           :ok <- Region.correct_blocks(owner, positions, connection) do
        {:cont, {:ok, packets}}
      else
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  The item's wear after a lit fire (`hurtAndBreak(1)`, `consume(1)`); creative
  players keep it.
  """
  def used(state, command, {:ignited, _}) do
    inventory = state.inventory
    slot = if command.request.hand == :off, do: 45, else: 36 + inventory.selected
    stack = Valimc.Inventory.get(inventory, slot)

    if inventory.infinite_materials or stack == nil or stack.item_id != command.item do
      state
    else
      {next, broken} =
        if stack.item_id == @flint,
          do: Valimc.Durability.hurt_and_break(stack, 1, false),
          else: {if(stack.count > 1, do: %{stack | count: stack.count - 1}), nil}

      {:ok, inventory} = Valimc.Inventory.creative(inventory, slot, next)

      state =
        %{state | inventory: inventory} |> Valimc.Player.CreativeInventory.resync_inventory()

      if broken do
        packet = Valimc.Protocol.Packets.item_break(state.player.entity_id, command.request.hand)
        Valimc.Net.Codec.send_packets(state, [packet])
        Valimc.Player.Movement.broadcast_player_packet(state, packet)
      end

      Valimc.Player.ItemUse.publish_equipment(state)
    end
  end

  def used(state, _command, _outcome), do: state
end
