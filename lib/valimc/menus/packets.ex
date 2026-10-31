defmodule Valimc.Menus.Packets do
  @moduledoc "The packets of a player's menus (VMC-077r): screens, their contents and properties."
  alias Valimc.Protocol.{ItemStack, Packets, Wire}

  def inventory(inventory),
    do: inventory_content(0, inventory, Valimc.Menus.Inventory.display_contents(inventory))

  def open_table(container) when container in 1..127 do
    open_screen(container, 12, "container.crafting")
  end

  def open_chest(container, rows) when container in 1..127 and rows in 1..6 do
    {:ok, type} = Valimc.Menus.Menu.type(Valimc.Menus.Menu.chest(rows))

    open_screen(
      container,
      type,
      if(rows == 6, do: "container.chestDouble", else: "container.chest")
    )
  end

  @doc "A hopper's, dropper's or dispenser's screen (VMC-049a)."
  def open_machine(container, kind) when container in 1..127 do
    {:ok, type} = Valimc.Menus.Menu.type(Valimc.Menus.Menu.machine(kind))
    open_screen(container, type, "container." <> Atom.to_string(kind))
  end

  # A storage block's default name (`getDefaultName`).
  @storage_titles %{barrel: "container.barrel"}

  @doc "A storage block's screen (VMC-032c1): its menu's type and its title."
  def open_storage(container, kind)
      when container in 1..127 and is_map_key(@storage_titles, kind) do
    {:ok, type} = Valimc.Menus.Menu.type(Valimc.Menus.Menu.storage(kind))
    open_screen(container, type, Map.fetch!(@storage_titles, kind))
  end

  def storage_inventory(container, kind, storage, inventory) when container in 1..127 do
    {:ok, contents} =
      Valimc.Menus.Menu.contents(Valimc.Menus.Menu.storage(kind), storage, inventory)

    inventory_content(container, inventory, contents)
  end

  def machine_inventory(container, kind, storage, inventory) when container in 1..127 do
    {:ok, contents} =
      Valimc.Menus.Menu.contents(Valimc.Menus.Menu.machine(kind), storage, inventory)

    inventory_content(container, inventory, contents)
  end

  def open_cooking(container, kind) when container in 1..127 do
    {:ok, type} = Valimc.Menus.Menu.cooking_type(kind)
    open_screen(container, type, "container." <> Atom.to_string(kind))
  end

  @doc "A merchant's screen (VMC-044b2), its title a text component (its name)."
  def open_merchant(container, title) when container in 1..127 do
    {:ok, type} = Valimc.Menus.Menu.type(Valimc.Menus.Menu.merchant())

    Packets.packet("open_screen", [
      Wire.varint(container),
      Wire.varint(type),
      Valimc.Text.Codec.encode(title)
    ])
  end

  @doc """
  `ClientboundMerchantOffersPacket`: each offer's costs, result, stock,
  uses, experience, special price, price multiplier and demand, with the
  merchant's level and experience and whether it shows progress and
  restocks.
  """
  def merchant_offers(container, offers, level, xp, progress, restock) when container in 1..127 do
    Packets.packet("merchant_offers", [
      Wire.varint(container),
      Wire.varint(length(offers)),
      Enum.map(offers, fn offer ->
        [
          ItemStack.encode_cost(offer.buy),
          ItemStack.encode(offer.sell),
          if(offer.buy_b, do: [<<1>>, ItemStack.encode_cost(offer.buy_b)], else: <<0>>),
          Wire.bool(offer.uses >= offer.max_uses),
          <<offer.uses::signed-32, offer.max_uses::signed-32, offer.xp::signed-32,
            offer.special_price::signed-32, offer.price_multiplier::float-32,
            offer.demand::signed-32>>
        ]
      end),
      Wire.varint(level),
      Wire.varint(xp),
      Wire.bool(progress),
      Wire.bool(restock)
    ])
  end

  @doc "A merchant menu's slots: the payments, the result and the inventory."
  def merchant_inventory(container, inventory, result) when container in 1..127 do
    {a, b} = inventory.payments

    inventory_content(
      container,
      inventory,
      [a, b, result | Enum.map(9..44, &Valimc.Menus.Inventory.get(inventory, &1))]
    )
  end

  defp open_screen(container, type, title) do
    Packets.packet("open_screen", [
      Wire.varint(container),
      Wire.varint(type),
      Valimc.Data.NBT.encode({:compound, %{"translate" => {:string, title}}})
    ])
  end

  def table_inventory(container, inventory) when container in 1..127,
    do:
      inventory_content(
        container,
        inventory,
        elem(Valimc.Menus.Menu.contents(Valimc.Menus.Menu.table(), nil, inventory), 1)
      )

  def chest_inventory(container, rows, storage, inventory) when container in 1..127 do
    {:ok, contents} =
      Valimc.Menus.Menu.contents(Valimc.Menus.Menu.chest(rows), storage, inventory)

    inventory_content(container, inventory, contents)
  end

  def cooking_inventory(container, cooking, inventory) when container in 1..127 do
    {:ok, contents} = Valimc.Menus.Menu.cooking_contents(cooking, inventory)
    inventory_content(container, inventory, contents)
  end

  def cooking_properties(container, cooking) when container in 1..127 do
    {:ok, properties} = Valimc.Menus.Menu.properties(cooking)

    for {value, index} <- Enum.with_index(properties),
        do:
          Packets.packet("container_set_data", [Wire.varint(container), <<index::16, value::16>>])
  end

  defp inventory_content(container, inventory, contents) do
    Packets.packet("container_set_content", [
      Wire.varint(container),
      Wire.varint(inventory.state_id),
      Wire.varint(length(contents)),
      Enum.map(contents, &ItemStack.encode/1),
      ItemStack.encode(inventory.carried)
    ])
  end
end
