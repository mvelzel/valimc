defmodule Valimc.Menus.Merchant do
  @moduledoc """
  The merchant menu's own rules (VMC-044b2), pure, over offers as
  `Valimc.Menus.Offers` makes them and the player's `Inventory` with its two
  payment slots:

  - `MerchantOffer`: `cost_count/1` (`getModifiedCostCount`: the base cost
    with its demand times the price multiplier and the special price,
    within 1 and the stack size), `satisfied_by?/3` and `take/3`.
  - `MerchantContainer.updateSellItem` (`sell/3`): the offer the payments
    meet, in either order, preferring the selection hint; its result, or
    none when it is out of stock.
  - `MerchantMenu.tryMoveItems` (`select/3`): the payments back to the
    inventory, then the selected offer's costs into the payment slots from
    the inventory, as vanilla moves them.
  - `move/3`: `AbstractContainerMenu.moveItemStackTo` into inventory slots.
  - `click/5`: a click in the menu. The payments and the inventory go
    through the one click engine; the result's gestures are
    `MerchantResultSlot`'s: picking it up, shift-moving it (repeated while
    it stays the same item; a partial move still pays a whole trade, as in
    vanilla), throwing it (with ctrl, again while it stays the same item),
    swapping it into an empty hotbar slot and a creative clone. A take pays
    the payments and asks the caller's `trade` for the merchant's side.
  """
  alias Valimc.Data.Float32
  alias Valimc.Menus.{Click, Inventory, Menu}
  alias Valimc.Protocol.ItemStack

  # A shift-move or a ctrl-throw repeats at most this often per click.
  @repeats 64

  # Window slots 3..38 as inventory slots, in window order.
  @window Enum.to_list(9..44)

  @doc "`getModifiedCostCount` of the first cost."
  def cost_count(%{buy: buy} = offer) do
    product = Float32.round(buy.count * offer.demand * offer.price_multiplier)
    demand = max(0, floor(product))
    (buy.count + demand + offer.special_price) |> max(1) |> min(ItemStack.max_stack_size(buy))
  end

  @doc "`getCostA`: the first cost at its modified count."
  def cost_a(offer), do: %{offer.buy | count: cost_count(offer)}

  def out_of_stock?(offer), do: offer.uses >= offer.max_uses

  @doc "`ItemCost.test`: the item, and exactly the components the cost asks for."
  def test?(_cost, nil), do: false

  def test?(cost, %ItemStack{} = stack),
    do:
      stack.item_id == cost.item_id and
        Enum.all?(cost.components, fn {name, value} ->
          ItemStack.component(stack, name) == value
        end)

  @doc "`MerchantOffer.satisfiedBy(a, b)`."
  def satisfied_by?(offer, a, b) do
    test?(offer.buy, a) and a.count >= cost_count(offer) and
      case offer.buy_b do
        nil -> b == nil
        cost -> test?(cost, b) and b.count >= cost.count
      end
  end

  @doc "`MerchantOffer.take`: `{:ok, a, b}` with the costs paid, either way round, or `:error`."
  def take(offer, a, b) do
    cond do
      satisfied_by?(offer, a, b) -> {:ok, pay(a, cost_count(offer)), pay_b(offer, b)}
      satisfied_by?(offer, b, a) -> {:ok, pay_b(offer, a), pay(b, cost_count(offer))}
      true -> :error
    end
  end

  defp pay(stack, n), do: if(stack.count > n, do: %{stack | count: stack.count - n})
  defp pay_b(%{buy_b: nil}, stack), do: stack
  defp pay_b(%{buy_b: cost}, stack), do: pay(stack, cost.count)

  @doc "`MerchantOffers.getRecipeFor`: the offer index the payments meet, or nil."
  def recipe_for(offers, a, b, hint) do
    if hint > 0 and hint < length(offers) do
      if satisfied_by?(Enum.at(offers, hint), a, b), do: hint
    else
      Enum.find_index(offers, &satisfied_by?(&1, a, b))
    end
  end

  @doc """
  `updateSellItem` over payments `{a, b}`: `{result, active}`, the result
  stack (nil) and the active offer's index (nil), which an offer out of
  stock may be without a result.
  """
  def sell(offers, {a, b}, hint) do
    {buy_a, buy_b} = if a == nil, do: {b, nil}, else: {a, b}

    cond do
      buy_a == nil ->
        {nil, nil}

      offers == [] ->
        {nil, nil}

      true ->
        first = recipe_for(offers, buy_a, buy_b, hint)

        {active, index} =
          if first == nil or out_of_stock?(Enum.at(offers, first)),
            do: {first, recipe_for(offers, buy_b, buy_a, hint)},
            else: {first, first}

        if index != nil and not out_of_stock?(Enum.at(offers, index)),
          do: {Enum.at(offers, index).sell, index},
          else: {nil, if(index != nil, do: index, else: active)}
    end
  end

  @doc """
  `tryMoveItems(index)`: the payments back into the inventory (window
  order backwards; a payment that cannot move at all stops it), then, both
  slots empty, the offer's costs from the inventory into them.
  """
  def select(%Inventory{payments: {_, _}} = inventory, offers, index)
      when is_integer(index) and index >= 0 do
    if index < length(offers) do
      with {:ok, inventory} <- unload(inventory, 0),
           {:ok, inventory} <- unload(inventory, 1) do
        if Inventory.payment_contents(inventory) == [nil, nil] do
          offer = Enum.at(offers, index)
          inventory = load(inventory, 0, offer.buy)
          if offer.buy_b, do: load(inventory, 1, offer.buy_b), else: inventory
        else
          inventory
        end
      else
        {:stuck, inventory} -> inventory
      end
    else
      inventory
    end
  end

  def select(inventory, _offers, _index), do: inventory

  defp unload(inventory, slot) do
    case Inventory.get(inventory, {:payment, slot}) do
      nil ->
        {:ok, inventory}

      stack ->
        case move(inventory, stack, Enum.reverse(@window)) do
          {_, _, false} ->
            {:stuck, inventory}

          {inventory, left, true} ->
            {:ok, Inventory.put(inventory, {:payment, slot}, left)}
        end
    end
  end

  # `moveFromInventoryToPaymentSlot`.
  defp load(inventory, slot, cost) do
    Enum.reduce_while(@window, inventory, fn i, inventory ->
      item = Inventory.get(inventory, i)
      current = Inventory.get(inventory, {:payment, slot})

      if item != nil and test?(cost, item) and
           (current == nil or ItemStack.same_item?(item, current)) do
        max = ItemStack.max_stack_size(item)
        have = if current, do: current.count, else: 0
        moved = min(max - have, item.count)
        paid = %{item | count: have + moved}

        inventory =
          inventory
          |> Inventory.put(i, if(item.count > moved, do: %{item | count: item.count - moved}))
          |> Inventory.put({:payment, slot}, paid)

        if paid.count >= max, do: {:halt, inventory}, else: {:cont, inventory}
      else
        {:cont, inventory}
      end
    end)
  end

  @doc """
  `moveItemStackTo(stack, …)` over inventory slots `slots` in that order:
  merged into equal stacks, then into the first empty slot. `{inventory,
  left over or nil, whether anything moved}`.
  """
  def move(inventory, stack, slots) do
    max = ItemStack.max_stack_size(stack)

    {inventory, left, moved} =
      if max > 1 and not damaged?(stack) do
        Enum.reduce_while(slots, {inventory, stack, false}, fn slot, {inventory, left, moved} ->
          target = Inventory.get(inventory, slot)

          cond do
            left == nil ->
              {:halt, {inventory, left, moved}}

            target != nil and ItemStack.same_item?(target, left) ->
              limit = ItemStack.max_stack_size(target)
              total = target.count + left.count

              cond do
                total <= limit ->
                  {:cont, {Inventory.put(inventory, slot, %{target | count: total}), nil, true}}

                target.count < limit ->
                  left = %{left | count: total - limit}
                  {:cont, {Inventory.put(inventory, slot, %{target | count: limit}), left, true}}

                true ->
                  {:cont, {inventory, left, moved}}
              end

            true ->
              {:cont, {inventory, left, moved}}
          end
        end)
      else
        {inventory, stack, false}
      end

    case left && Enum.find(slots, &(Inventory.get(inventory, &1) == nil)) do
      nil ->
        {inventory, left, moved}

      slot ->
        placed = min(left.count, max)
        rest = if left.count > placed, do: %{left | count: left.count - placed}

        {Inventory.put(inventory, slot, %{left | count: placed}), rest, true}
    end
  end

  # `isStackable` refuses a damaged stack.
  defp damaged?(stack), do: (ItemStack.component(stack, "minecraft:damage") || 0) > 0

  @doc """
  A click (`%{action, slot, button}`) with the offers and the selection
  hint. `trade.(index, offers)` is the merchant's side of a take of offer
  `index` from the menu's current offers:
  `{:ok, offers, info}` or `:error` (the take does not happen).
  `{:ok, inventory, offers, drops, infos}` or `{:error, reason}`.
  """
  def click(inventory, offers, hint, %{slot: 2, action: action} = click, trade)
      when action != :quick_craft do
    result_click(
      %{inventory: inventory, offers: offers, hint: hint, drops: [], infos: [], trade: trade},
      click
    )
  end

  def click(inventory, offers, _hint, click, _trade) do
    case Click.plan(Menu.merchant(), nil, inventory, click.action, click.slot, click.button) do
      {:ok, nil, inventory, drops} -> {:ok, inventory, offers, drops, []}
      {:error, _} = error -> error
    end
  end

  defp result_click(m, %{action: action, button: button}) do
    {stack, active} = sell(m.offers, m.inventory.payments, m.hint)
    carried = m.inventory.carried

    m =
      cond do
        stack == nil or not may_pickup?(m, active) ->
          m

        action == :pickup and button in [0, 1] and carried == nil ->
          take_result(m, active, &%{&1 | carried: stack})

        action == :pickup and button in [0, 1] ->
          if ItemStack.same_item?(carried, stack) and
               ItemStack.max_stack_size(carried) - carried.count >= stack.count,
             do:
               take_result(
                 m,
                 active,
                 &%{&1 | carried: %{carried | count: carried.count + stack.count}}
               ),
             else: m

        action == :quick_move and button in [0, 1] ->
          quick_move(m, stack, @repeats)

        action == :throw and carried == nil ->
          throw(m, stack, button == 1, @repeats)

        action == :swap and (button in 0..8 or button == 40) ->
          slot = if button == 40, do: 45, else: 36 + button

          if Inventory.get(m.inventory, slot) == nil,
            do: take_result(m, active, &Inventory.put(&1, slot, stack)),
            else: m

        action == :clone and carried == nil and m.inventory.infinite_materials ->
          %{
            m
            | inventory: %{
                m.inventory
                | carried: %{stack | count: ItemStack.max_stack_size(stack)}
              }
          }

        true ->
          m
      end

    {:ok, Inventory.advance(m.inventory), m.offers, Enum.reverse(m.drops), Enum.reverse(m.infos)}
  end

  # `MerchantResultSlot.mayPickup`: the active offer is met, either way round.
  defp may_pickup?(_m, nil), do: false

  defp may_pickup?(m, active) do
    offer = Enum.at(m.offers, active)
    {a, b} = m.inventory.payments
    satisfied_by?(offer, a, b) or satisfied_by?(offer, b, a)
  end

  # `onTake`: the payments paid, then the merchant's side; `give` puts the
  # result where the gesture takes it. Nothing changes if either fails.
  defp take_result(m, active, give) do
    {a, b} = m.inventory.payments

    with {:ok, a, b} <- take(Enum.at(m.offers, active), a, b),
         {:ok, offers, info} <- m.trade.(active, m.offers) do
      inventory = m.inventory |> give.() |> Map.put(:payments, {a, b})
      %{m | inventory: inventory, offers: offers, infos: [info | m.infos]}
    else
      _ -> m
    end
  end

  # `quickMoveStack` on the result, while it stays the same item: into the
  # inventory from its end; a trade each time anything moved.
  defp quick_move(m, _original, 0), do: m

  defp quick_move(m, original, repeats) do
    {stack, active} = sell(m.offers, m.inventory.payments, m.hint)

    with true <- stack != nil and stack.item_id == original.item_id,
         true <- may_pickup?(m, active),
         {inventory, _left, true} <- move(m.inventory, stack, Enum.to_list(44..9//-1)) do
      payments = m.inventory.payments
      taken = take_result(m, active, fn _ -> %{inventory | payments: payments} end)
      if taken.infos == m.infos, do: m, else: quick_move(taken, original, repeats - 1)
    else
      _ -> m
    end
  end

  # `THROW`: the whole result taken and dropped; with ctrl, again while it
  # stays the same item.
  defp throw(m, _original, _all, 0), do: m

  defp throw(m, original, all, repeats) do
    {stack, active} = sell(m.offers, m.inventory.payments, m.hint)

    if stack != nil and stack.item_id == original.item_id and may_pickup?(m, active) do
      taken = take_result(m, active, & &1)

      cond do
        taken.infos == m.infos -> m
        all -> throw(%{taken | drops: [stack | taken.drops]}, original, all, repeats - 1)
        true -> %{taken | drops: [stack | taken.drops]}
      end
    else
      m
    end
  end
end
