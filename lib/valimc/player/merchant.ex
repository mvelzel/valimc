defmodule Valimc.Player.Merchant do
  @moduledoc """
  A player's merchant menu (VMC-044b2): `MerchantMenu` over the merchant
  the player trades with, in the group that hosts both (the merchant stays
  within reach, so in a section of the same group).

  The two payment slots belong to the player's `Inventory` (saved with it,
  returned or dropped when the menu closes); the result is derived from the
  payments, the offers and the selection hint (`MerchantContainer`); a
  click is `Valimc.Menus.Merchant.click/5`. Each take of the result is a
  trade: the payments are paid there and the merchant's side (`Region.merchant/3`: uses, experience, the
  orb, a level-up's offers) changes in the same group callback, so one
  frame holds both. Selecting a trade moves the payments as
  `tryMoveItems` does. The menu closes once the merchant is gone, dead, out
  of range (4 blocks past the player's interaction range) or trades with
  someone else; closing ends its trading.
  """
  alias Valimc.Living.Interaction
  alias Valimc.Menus.Inventory
  alias Valimc.Menus.Merchant, as: Rules
  alias Valimc.Menus.Packets, as: MenuPackets
  alias Valimc.Player.{Items, ItemUse, Mining}
  alias Valimc.Protocol.{Packets, Wire}
  alias Valimc.World.Region

  import Valimc.Protocol.Codec, only: [send_packets: 2]

  @doc """
  Open the menu for `trade` (`%{uuid, villager, offers, level, xp, title}`,
  the merchant's interaction answer) at its section's owner `owner`.
  """
  def open(state, owner, trade) do
    state = if state.table_menu, do: Valimc.Player.Menus.close(state), else: state
    id = rem(state.table_counter, 127) + 1

    inventory =
      state.inventory
      |> Inventory.cancel_drag()
      |> Map.update!(:payments, &(&1 || {nil, nil}))
      |> Inventory.advance()

    state = state |> ItemUse.stop_item_use() |> Mining.cancel_mining()

    menu = %{
      kind: :merchant,
      id: id,
      owner: owner,
      uuid: trade.uuid,
      villager: trade.villager,
      offers: trade.offers,
      level: trade.level,
      xp: trade.xp,
      hint: 0
    }

    state = %{state | inventory: inventory, table_menu: menu, table_counter: id}

    send_packets(state, [
      MenuPackets.open_merchant(id, trade.title),
      MenuPackets.merchant_inventory(id, inventory, result(state)),
      Packets.cursor(inventory.carried),
      offers_packet(menu)
    ])

    state
  end

  defp offers_packet(menu),
    do:
      MenuPackets.merchant_offers(
        menu.id,
        menu.offers,
        menu.level,
        menu.xp,
        menu.villager,
        menu.villager
      )

  @doc "The result slot's stack (`updateSellItem`)."
  def result(%{table_menu: menu, inventory: inventory}),
    do: elem(Rules.sell(menu.offers, inventory.payments, menu.hint), 0)

  @doc "The menu's slots and cursor, sent again."
  def sync(state) do
    inventory = Inventory.advance(state.inventory)
    state = %{state | inventory: inventory}

    send_packets(state, [
      MenuPackets.merchant_inventory(state.table_menu.id, inventory, result(state)),
      Packets.cursor(inventory.carried)
    ])

    state
  end

  @doc """
  Whether the player may still use the menu (`MerchantMenu.stillValid`):
  `{:ok, view}` while the merchant is alive, trades with this player and is
  within reach.
  """
  def valid(state) do
    menu = state.table_menu

    with true <- state.life_stage == :alive,
         {:ok, view} <- Region.merchant(menu.owner, menu.uuid, :view),
         true <- view.alive and view.trading == state.player.uuid,
         true <- within?(state, view.box) do
      {:ok, view}
    else
      _ -> :invalid
    end
  end

  # `isWithinEntityInteractionRange(merchant, 4.0)`: its box from the eyes.
  defp within?(state, {x0, y0, z0, x1, y1, z1}) do
    {ex, ey, ez} = Interaction.eye(state.player)
    range = Interaction.entity_range(state.player.game_mode.current) + 4.0
    dx = max(max(x0 - ex, ex - x1), 0.0)
    dy = max(max(y0 - ey, ey - y1), 0.0)
    dz = max(max(z0 - ez, ez - z1), 0.0)
    dx * dx + dy * dy + dz * dz < range * range
  end

  @doc "A player tick's check: the menu closes once it is not valid."
  def check(state) do
    case valid(state) do
      {:ok, _} -> state
      :invalid -> Valimc.Player.Menus.close(state)
    end
  end

  @doc "The menu closed: the merchant stops trading with the player."
  def stop(%{table_menu: %{kind: :merchant} = menu} = state) do
    Region.merchant(menu.owner, menu.uuid, :stop)
    state
  end

  def stop(state), do: state

  @doc "`ServerboundSelectTradePacket`: the hint, then `tryMoveItems`."
  def select(%{table_menu: %{kind: :merchant}} = state, payload) do
    {index, <<>>} = Wire.take_varint(payload)

    case valid(state) do
      {:ok, _} ->
        before = state.inventory.payments
        menu = %{state.table_menu | hint: index}
        inventory = Rules.select(state.inventory, menu.offers, index)
        state = %{state | table_menu: menu, inventory: inventory}
        state |> updated(before) |> sync()

      :invalid ->
        state
    end
  end

  def select(state, _payload), do: state

  @doc "A click in the merchant menu (`Valimc.Menus.Merchant.click/5`)."
  def click(state, click) do
    case valid(state) do
      :invalid ->
        Valimc.Player.Menus.close(state)

      {:ok, _} ->
        menu = state.table_menu
        before = state.inventory.payments
        player = state.player.uuid

        # Each take is the merchant's trade, in this group callback.
        trade = fn index, _offers ->
          case Region.merchant(menu.owner, menu.uuid, {:trade, index, player}) do
            {:ok, traded} -> {:ok, traded.offers, traded}
            _ -> :error
          end
        end

        case Rules.click(state.inventory, menu.offers, menu.hint, click, trade) do
          {:ok, inventory, offers, drops, trades} ->
            menu =
              Enum.reduce(trades, %{menu | offers: offers}, fn traded, menu ->
                %{menu | level: traded.level, xp: traded.xp}
              end)

            state = updated(%{state | inventory: inventory, table_menu: menu}, before)

            if Enum.any?(trades, & &1.leveled), do: send_packets(state, [offers_packet(menu)])

            case Items.drop(state, state.inventory, drops) do
              {:ok, state} -> sync(state)
              :error -> sync(state)
            end

          {:error, _} ->
            sync(state)
        end
    end
  end

  # `notifyTradeUpdated` as the payments change with something in them: the
  # merchant's yes or no.
  defp updated(state, before) do
    payments = state.inventory.payments

    if payments != before and payments != {nil, nil} do
      menu = state.table_menu
      Region.merchant(menu.owner, menu.uuid, {:updated, result(state) != nil})
    end

    state
  end
end
