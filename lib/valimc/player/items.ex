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
  alias Valimc.Data.Grid
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
  def drop(state, inventory, stacks, kind \\ :directed, orbs \\ [])
  def drop(state, inventory, [], _kind, []), do: {:ok, %{state | inventory: inventory}}

  def drop(state, inventory, stacks, kind, orbs) do
    with {:ok, owner} <- owner(state),
         {:ok, _key, records} <- item_records(state.player, stacks, kind),
         :ok <- Region.drop_items(owner, records ++ orbs) do
      {:ok, %{state | inventory: inventory}}
    else
      _ -> :error
    end
  end

  defp item_records(_player, [], _kind), do: {:ok, nil, []}
  defp item_records(player, stacks, kind), do: Drops.records(player, stacks, kind)

  @doc "Whether the player's section is its group's, so it can drop items there."
  def local?(state), do: match?({:ok, _}, owner(state))

  @doc """
  Put entity `records` (a shot projectile, VMC-037o; an endermite) in the
  player's section: `:ok`, or `:error` when the section is not its group's.
  """
  def spawn(state, records) do
    with {:ok, owner} <- owner(state), :ok <- Region.drop_items(owner, records) do
      :ok
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
         {inventory, remaining} = mend(state.inventory, view.value),
         {:ok, experience} <-
           Experience.give(state.player.progression.experience, remaining),
         {:ok, owner} <- owner_of(state, view),
         :ok <- Region.take_orb(owner, actor, view.uuid, view.value) do
      state =
        if inventory == state.inventory,
          do: state,
          else:
            Valimc.Player.CreativeInventory.resync_inventory(%{
              state
              | inventory: Inventory.advance(inventory)
            })

      if remaining > 0,
        do: send_packets(state, [Valimc.Player.Packets.experience(experience)])

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

  # `ExperienceOrb.repairPlayerItems` (VMC-037q): a random damaged item
  # whose enchantments repair with experience (Mending), once per such
  # enchantment, takes the repair its effects give, and what is left of the
  # orb goes on to the next. `{inventory, experience left}`.
  @equipment [mainhand: nil, offhand: 45, feet: 8, legs: 7, chest: 6, head: 5]

  @doc false
  def mend(inventory, amount) do
    candidates =
      for {slot, index} <- @equipment,
          index = index || 36 + inventory.selected,
          %{} = stack <- [Inventory.get(inventory, index)],
          Map.get(stack.components, "minecraft:damage", 0) > 0,
          levels = Valimc.Living.Enchant.levels(stack),
          _ <- 1..Valimc.Living.Enchant.count_with(:repair_with_xp, levels, slot)//1,
          do: {index, stack, levels}

    case candidates do
      [] ->
        {inventory, amount}

      _ ->
        {index, stack, levels} = Enum.random(candidates)

        from_xp =
          max(
            0,
            trunc(
              Valimc.Living.Enchant.value(
                :repair_with_xp,
                levels,
                %{tool: stack.item_id},
                amount
              )
            )
          )

        damage = stack.components["minecraft:damage"]
        repair = min(from_xp, damage)

        stack = %{
          stack
          | components: Map.put(stack.components, "minecraft:damage", damage - repair)
        }

        inventory = %{inventory | slots: Map.put(inventory.slots, index, stack)}
        left = if repair > 0, do: amount - div(repair * amount, from_xp), else: 0

        if repair > 0 and left > 0, do: mend(inventory, left), else: {inventory, 0}
    end
  end

  # The owner of the player's section, when it is the group the session runs in.
  defp owner(state) do
    %{x: x, z: z, dimension: dimension} = state.player

    local(World.existing_owner(Grid.section(dimension, Grid.chunk_key(x, z))))
  end

  @doc "The owner of `view`'s section when it is this group."
  def owner_of(state, view),
    do:
      local(
        World.existing_owner(
          Grid.section(
            state.player.dimension,
            Grid.region_key(view.chunk),
            :section
          )
        )
      )

  defp local({:ok, {pid, _} = owner}) when pid == self(), do: {:ok, owner}
  defp local(_), do: {:error, :not_local}
end
