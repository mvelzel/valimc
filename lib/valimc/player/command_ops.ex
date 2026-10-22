defmodule Valimc.Player.CommandOps do
  @moduledoc """
  Command effects on one player, run by that player's session (VMC-053b):
  game mode, teleport, items, effects, experience and `/kill`. Every target,
  the command's own player too, gets them through a bounded call from the
  command's job (`Valimc.Commands.Remote`), so feedback reports what the
  target did.
  """
  alias Valimc.Menus.Inventory
  alias Valimc.Player.Experience
  alias Valimc.Living.{Effects, Health}
  alias Valimc.Commands.Parser.ItemPredicate

  alias Valimc.Player.{
    CreativeInventory,
    GameModes,
    ItemUse,
    Teleports,
    Vitals
  }

  alias Valimc.Protocol.{ItemStack, Packets}
  import Valimc.Protocol.Codec, only: [send_packets: 2]
  import Kernel, except: [apply: 2]

  def apply(state, {:game_mode, mode, notice}) do
    case GameModes.set(state, mode) do
      {:changed, state} ->
        if notice, do: send_packets(state, [Packets.chat(notice)])
        {:changed, state}

      unchanged ->
        unchanged
    end
  end

  def apply(state, {:teleport, pose}), do: {:ok, Teleports.apply(state, pose)}

  def apply(state, {:give, stack, count}) do
    max = ItemStack.max_stack_size(stack)

    {inventory, drops} =
      Stream.unfold(count, fn
        0 -> nil
        left -> {min(max, left), left - min(max, left)}
      end)
      |> Enum.reduce({state.inventory, []}, fn n, {inventory, drops} ->
        {:ok, inventory, remainder, _} = Inventory.pickup_stack(inventory, %{stack | count: n})
        {inventory, if(remainder, do: [remainder | drops], else: drops)}
      end)

    # The overflow is thrown from the eyes (vanilla's `Player.drop`).
    state =
      case Valimc.Player.Items.drop(state, inventory, Enum.reverse(drops)) do
        {:ok, state} -> state
        :error -> %{state | inventory: inventory}
      end

    {:ok, state |> CreativeInventory.resync_inventory() |> ItemUse.publish_equipment()}
  end

  def apply(state, {:clear, predicate, max_count}) do
    counting = max_count == 0
    # Vanilla order: hotbar, main, armour feet to head, offhand, crafting grid.
    slots = Enum.to_list(36..44) ++ Enum.to_list(9..35) ++ [8, 7, 6, 5, 45, 1, 2, 3, 4]

    {inventory, total} =
      Enum.reduce(slots, {state.inventory, 0}, fn slot, {inventory, total} ->
        case Inventory.get(inventory, slot) do
          %ItemStack{} = stack ->
            if ItemPredicate.matches?(predicate, stack) do
              if counting do
                {inventory, total + stack.count}
              else
                taken = take(stack.count, max_count, total)

                rest =
                  if taken == stack.count, do: nil, else: %{stack | count: stack.count - taken}

                {:ok, inventory} = Inventory.creative(inventory, slot, rest)
                {inventory, total + taken}
              end
            else
              {inventory, total}
            end

          nil ->
            {inventory, total}
        end
      end)

    {inventory, total} =
      case inventory.carried do
        %ItemStack{} = stack ->
          cond do
            not ItemPredicate.matches?(predicate, stack) ->
              {inventory, total}

            counting ->
              {inventory, total + stack.count}

            true ->
              taken = take(stack.count, max_count, total)
              rest = if taken == stack.count, do: nil, else: %{stack | count: stack.count - taken}
              {%{inventory | carried: rest}, total + taken}
          end

        nil ->
          {inventory, total}
      end

    state =
      if counting or total == 0,
        do: state,
        else:
          %{state | inventory: inventory}
          |> CreativeInventory.resync_inventory()
          |> ItemUse.publish_equipment()

    {total, state}
  end

  def apply(state, {:effect, id, incoming}) do
    if state.life_stage != :alive do
      {false, state}
    else
      case Vitals.apply_effect(state, id, incoming) do
        {:ok, changed, state} -> {changed, state}
        {:error, _} -> {false, state}
      end
    end
  end

  def apply(state, :clear_effects) do
    Enum.reduce(Map.keys(state.player.living.effects), {false, state}, fn id, {changed, state} ->
      {removed, state} = apply(state, {:effect, id, :remove})
      {changed or removed, state}
    end)
  end

  def apply(state, {:experience, operation}) do
    xp = state.player.progression.experience

    {reply, next} =
      case operation do
        {:add, amount, :points} ->
          {:ok, Experience.add_points(xp, amount)}

        {:add, amount, :levels} ->
          {:ok, Experience.add_levels(xp, amount)}

        {:set, amount, :levels} ->
          {true, Experience.set_levels(xp, amount)}

        {:set, amount, :points} ->
          case Experience.set_points(xp, amount) do
            {:ok, next} -> {true, next}
            :error -> {false, xp}
          end

        {:query, :points} ->
          {Experience.points(xp), xp}

        {:query, :levels} ->
          {xp.level, xp}
      end

    if next == xp do
      {reply, state}
    else
      player = %{state.player | progression: %{state.player.progression | experience: next}}
      Valimc.Player.PlayerList.update(state.connection, player)
      send_packets(state, [Packets.experience(next)])
      {reply, %{state | player: player}}
    end
  end

  def apply(state, {:post_effect, operation}),
    do: Valimc.Player.PostEffects.apply(state, operation)

  def apply(state, :kill) do
    case Health.hurt_window(state.player.living.health, 3.4028234663852886e38, true) do
      {:ok, selected} ->
        {_result, state} = Vitals.apply_damage(state, selected, :generic_kill)
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  defp take(count, max_count, _total) when max_count < 0, do: count
  defp take(count, max_count, total), do: min(count, max(max_count - total, 0))

  @doc "A fresh effect rung for `/effect give`."
  def rung(ticks, amplifier, hide),
    do: Effects.new(ticks, amplifier, false, not hide, not hide)
end
