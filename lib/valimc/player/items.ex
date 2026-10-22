defmodule Valimc.Player.Items do
  @moduledoc """
  A player's items and the world's (VMC-077i3): drops, pickups and XP pickups
  are plain calls to the owner of the player's section, which is the group
  the session runs in (`Valimc.Player.Host`), so the inventory and the
  entities change in one process, in one callback.

  A drop is thrown from the eyes (`:directed`) or scattered (`:scattered`, a
  death), as `Valimc.Player.Drops` launches it. A pickup takes what fits of an
  item the player touches; an XP pickup takes one unit of an orb at most
  every 100 ms (vanilla's `takeXpDelay` of two ticks).
  """
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Drops, Experience, Input}
  alias Valimc.World
  alias Valimc.Entity.ItemPickup
  alias Valimc.Data.PlayerPose
  alias Valimc.Player.Movement
  alias Valimc.Protocol.Packets
  alias Valimc.Entity.ExperienceOrbs
  alias Valimc.World.Region

  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @doc """
  Drop `stacks` that `inventory` (the player's next inventory) no longer
  holds: `{:ok, state}` with `inventory`, or `:error` with nothing changed
  when the player's section is not its group's.
  """
  def drop(state, inventory, stacks, kind \\ :directed)
  def drop(state, inventory, [], _kind), do: {:ok, %{state | inventory: inventory}}

  def drop(state, inventory, stacks, kind) do
    with {:ok, owner} <- owner(state),
         {:ok, _key, records} <- Drops.records(state.player, stacks, kind),
         :ok <- Region.drop_items(owner, records) do
      {:ok, %{state | inventory: inventory}}
    else
      _ -> :error
    end
  end

  @doc "A creative player conjures `stack` and throws it, its inventory unchanged."
  def creative_drop(state, stack) do
    case drop(state, state.inventory, [stack]) do
      {:ok, state} -> state
      :error -> state
    end
  end

  @doc """
  Pick up the item, of `views` (entity views near the player), that the
  player touches first after the last one it picked up.
  """
  def pickup(state, views) when map_size(views) == 0, do: state

  def pickup(state, views) do
    with true <- allowed?(state),
         {:ok, actor} <- actor(state.player),
         {id, view} <- candidate(views, actor.box, state.pickup_cursor),
         state = %{state | pickup_cursor: id},
         {:ok, owner} <- owner_of(state, view),
         {:ok, inventory, _taken} <- Region.take_item(owner, actor, view.uuid, state.inventory) do
      send_packets(state, [
        Valimc.Menus.Packets.inventory(inventory),
        Packets.cursor(inventory.carried)
      ])

      %{state | inventory: inventory}
    else
      _ -> state
    end
  end

  @doc "Take one unit of the XP orb, of `views`, the player touches first."
  def collect_experience(state, views) do
    now = System.monotonic_time(:millisecond)

    with true <- now >= state.experience_after and allowed?(state),
         {:ok, actor} <- actor(state.player),
         {_, view} <-
           views
           |> Enum.filter(fn {_, v} ->
             v.kind == :orb and ExperienceOrbs.contact?(actor.box, v.at)
           end)
           |> Enum.min_by(fn {id, _} -> id end, fn -> nil end),
         false <- mending_pending?(state.inventory),
         {:ok, experience} <-
           Experience.give(state.player.progression.experience, view.value),
         {:ok, owner} <- owner_of(state, view),
         :ok <- Region.take_orb(owner, actor, view.uuid, view.value) do
      send_packets(state, [Valimc.Player.Packets.experience(experience)])
      state = put_in(state.player.progression.experience, experience)
      %{state | experience_after: now + 100}
    else
      _ -> state
    end
  end

  # The pickup rules of the player (`Player.aiStep` touching entities): alive,
  # in a playing mode, loaded, confirmed where it is and with a current pose.
  defp allowed?(state) do
    state.phase == :play and state.life_stage == :alive and
      state.player.living.health.value > 0 and
      state.player.game_mode.current in [:survival, :adventure, :creative] and
      Input.loaded?(state.player.input) and not state.teleport_pending and
      state.pose_checked == Movement.pose_signature(state)
  end

  @doc "The player as the pickup rules see it."
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

  # Rotate through the items in contact, so one stuck item never starves the rest.
  defp candidate(views, box, cursor) do
    {first, later} =
      Enum.reduce(views, {nil, nil}, fn {id, view}, {first, later} ->
        if view.kind == :item and view.pickup_delay == 0 and ItemPickup.contact?(box, view.at) do
          {earlier(first, {id, view}),
           if(id > cursor, do: earlier(later, {id, view}), else: later)}
        else
          {first, later}
        end
      end)

    later || first
  end

  defp earlier(nil, entry), do: entry
  defp earlier({id, _} = first, {next, _} = entry), do: if(next < id, do: entry, else: first)

  # Mending repairs equipment with the XP; until it does, its orbs stay.
  defp mending_pending?(inventory) do
    Enum.any?([5, 6, 7, 8, 36 + inventory.selected, 45], fn slot ->
      case Inventory.get(inventory, slot) do
        nil ->
          false

        stack ->
          Map.get(stack.components, "minecraft:damage", 0) > 0 and
            Map.get(
              Map.get(stack.components, "minecraft:enchantments", %{}),
              "minecraft:mending",
              0
            ) >
              0
      end
    end)
  end

  # The owner of the player's section, when it is the group the session runs in.
  defp owner(state) do
    %{x: x, z: z, dimension: dimension} = state.player

    local(
      World.existing_owner(Valimc.Data.Grid.section(dimension, Valimc.Data.Grid.chunk_key(x, z)))
    )
  end

  defp owner_of(state, view),
    do:
      local(
        World.existing_owner(
          Valimc.Data.Grid.section(
            state.player.dimension,
            Valimc.Data.Grid.region_key(view.chunk),
            :section
          )
        )
      )

  defp local({:ok, {pid, _} = owner}) when pid == self(), do: {:ok, owner}
  defp local(_), do: {:error, :not_local}
end
