defmodule Valimc.MerchantConnectionTest do
  @moduledoc """
  A trade through a connection (VMC-044b2): a librarian's first use draws
  its offers and opens the merchant menu with them; selecting an offer
  moves its costs into the payment slots; taking the result pays them,
  counts the use, gives the villager experience and drops an orb; closing
  returns the payments and ends its trading. The trade, the payments and
  the villager's offers are one group's state.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 180_000

  alias Valimc.Entity.{Body, Store}
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.TestPlayer
  alias Valimc.World.Region

  setup do
    ctx = TestPlayer.scope("Merchant", {147_000, 997}, survival: {2, false})
    Valimc.TestScope.isolate(Valimc.TestScope.neighborhood(ctx.key), item_simulation: true)
    ctx
  end

  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  defp villager(owner, uuid) do
    {:ok, {_, id, _}} = Store.find(store(owner), uuid)
    {id, store(owner).entries[id].body}
  end

  # A native mob's family data, read in its owner.
  defp merchant_data(owner, id) do
    me = self()

    Valimc.TestRegion.replace_section(owner, fn section ->
      %{native: ref} = section.entities.store.entries[id]
      {:ok, {data, _, _}} = Valimc.Native.mob_section_merchant(ref, id, :data)
      send(me, {:merchant_data, data})
      section
    end)

    assert_receive {:merchant_data, data}
    data
  end

  defp click(client, container, slot, action \\ "pickup", button \\ 0) do
    Client.send_packet(client, :play, "container_click", [
      Wire.varint(container),
      <<0, slot::signed-16, button::signed-8>>,
      Wire.varint(ItemTypes.input_id(action)),
      <<0, 0>>
    ])
  end

  # A librarian two blocks east, its offers drawn and its menu open, one
  # trade of the first offer the player can pay taken by pickup.
  defp trade(ctx) do
    player = %{
      living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: -90.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Valimc.Player.Food{}
    }

    inventory = %Inventory{
      slots: %{
        36 => ItemStack.new("minecraft:emerald", 64),
        37 => ItemStack.new("minecraft:paper", 64),
        38 => ItemStack.new("minecraft:book", 16)
      }
    }

    TestPlayer.save(ctx, player, inventory)
    {client, pid} = TestPlayer.login(ctx)

    # A still librarian (no AI: it stays in reach) two blocks east.
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, body} = Body.new("minecraft:villager")
    body = %{body | data: %{body.data | profession: "minecraft:librarian", finalized: true}}
    uuid = <<8::128>>

    record =
      Store.body_record(put_in(body.mob.no_ai, true), uuid, {ctx.pose.x + 2.0, 64.0, ctx.pose.z})

    :ok = Region.drop_items(owner, [record])
    {_, client} = Client.await(client, :play, "add_entity")
    {id, _} = villager(owner, uuid)

    Client.send_packet(client, :play, "interact", [Wire.varint(id), Wire.varint(0), <<0, 0>>])
    {screen, client} = Client.await(client, :play, "open_screen")
    {container, _} = Wire.take_varint(screen)
    {_, client} = Client.await(client, :play, "merchant_offers")

    menu = TestPlayer.state(pid).table_menu
    assert %{kind: :merchant, level: 1, xp: 0} = menu
    assert [_, _] = menu.offers
    assert {:ok, %{trading: trading}} = Region.merchant(owner, uuid, :view)
    assert trading == TestPlayer.state(pid).player.uuid

    # Its offers are its own now: the record keeps them.
    assert elem(villager(owner, uuid), 1).data.offers == menu.offers

    # The first offer a player here can pay.
    paper = ItemTypes.id("minecraft:paper")
    emerald = ItemTypes.id("minecraft:emerald")
    book = ItemTypes.id("minecraft:book")

    {index, offer} =
      menu.offers
      |> Enum.with_index()
      |> Enum.map(fn {o, i} -> {i, o} end)
      |> Enum.find(fn {_, o} ->
        o.buy.item_id in [paper, emerald] and
          (o.buy_b == nil or o.buy_b.item_id == book)
      end)

    Client.send_packet(client, :play, "select_trade", Wire.varint(index))

    Valimc.TestWait.until(fn ->
      {a, _} = TestPlayer.state(pid).inventory.payments
      a != nil and a.item_id == offer.buy.item_id
    end)

    before = TestPlayer.state(pid).inventory
    click(client, container, 2)

    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.carried != nil end)
    after_trade = TestPlayer.state(pid).inventory
    assert after_trade.carried.item_id == offer.sell.item_id
    {a0, _} = before.payments
    {a1, _} = after_trade.payments
    assert ((a1 && a1.count) || 0) == a0.count - Valimc.Menus.Merchant.cost_count(offer)

    {_, row} = villager(owner, uuid)
    assert row.data.xp == offer.xp
    assert Enum.at(row.data.offers, index).uses == 1

    assert Enum.any?(store(owner).entries, fn {_, entry} -> entry.kind == :orb end)

    %{
      client: client,
      pid: pid,
      owner: owner,
      uuid: uuid,
      offer: offer,
      container: container,
      before: before
    }
  end

  test "a librarian's offers, a selected trade, its payment and its experience", ctx do
    %{client: client, pid: pid, owner: owner, uuid: uuid, container: container} = trade(ctx)
    # Closing returns the payments to the inventory and ends its trading.
    Client.send_packet(client, :play, "container_close", Wire.varint(container))
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).table_menu == nil end)
    assert TestPlayer.state(pid).inventory.payments == nil
    assert {:ok, %{trading: nil}} = Region.merchant(owner, uuid, :view)
    _ = client
  end

  test "a crash after a trade keeps both sides of it", ctx do
    %{owner: owner, uuid: uuid, offer: offer, before: before} = trade(ctx)
    {pid, _} = owner
    :ok = Region.flush(pid)
    Process.exit(pid, :kill)
    Valimc.TestWait.until(fn -> not Process.alive?(pid) end)

    # The villager comes back from the log with the trade and no trader.
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {_, row} = villager(owner, uuid)
    assert row.data.xp == offer.xp
    assert row.data.trading == nil
    assert Enum.any?(row.data.offers, &(&1.uses == 1))

    # The player's frame holds the result and the paid payments: back in
    # play, the cursor and payments drop; nothing of the price returns.
    {_client, pid} = TestPlayer.login(ctx)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.payments == nil end)
    paid = offer.buy.item_id

    count = fn item ->
      held =
        TestPlayer.state(pid).inventory.slots
        |> Map.values()
        |> Enum.filter(&(&1.item_id == item))
        |> Enum.map(& &1.count)
        |> Enum.sum()

      dropped =
        for {_, %{kind: :item, stack: %{item_id: ^item, count: n}}} <-
              store(owner).entries,
            reduce: 0,
            do: (sum -> sum + n)

      held + dropped
    end

    Valimc.TestWait.until(fn -> count.(offer.sell.item_id) >= offer.sell.count end)

    before_total =
      before.slots
      |> Map.values()
      |> Enum.filter(&(&1.item_id == paid))
      |> Enum.map(& &1.count)
      |> Enum.sum()

    {a, b} = before.payments
    before_total = before_total + Enum.sum(for s <- [a, b], s, s.item_id == paid, do: s.count)
    assert count.(paid) == before_total - Valimc.Menus.Merchant.cost_count(offer)
  end

  test "a wandering trader draws its three sets and opens without a level bar", ctx do
    player = %{
      living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: -90.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Valimc.Player.Food{}
    }

    TestPlayer.save(ctx, player, %Inventory{})
    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, body} = Body.new("minecraft:wandering_trader")
    uuid = <<9::128>>

    record =
      Store.body_record(put_in(body.mob.no_ai, true), uuid, {ctx.pose.x + 2.0, 64.0, ctx.pose.z})

    :ok = Region.drop_items(owner, [record])
    {_, client} = Client.await(client, :play, "add_entity")
    {id, _} = villager(owner, uuid)
    Client.send_packet(client, :play, "interact", [Wire.varint(id), Wire.varint(0), <<0, 0>>])
    {_, client} = Client.await(client, :play, "open_screen")
    {_, client} = Client.await(client, :play, "merchant_offers")
    menu = TestPlayer.state(pid).table_menu
    assert %{kind: :merchant, villager: false, level: 1} = menu
    # Buying 2, uncommon 2 and common 5, unless a draw ran out of trades.
    assert length(menu.offers) in 5..9
    _ = client
  end

  test "a player's punch is gossip: minor negative, and higher prices", ctx do
    %{client: client, pid: pid, owner: owner, uuid: uuid} = trade(ctx)
    {id, _} = villager(owner, uuid)
    before = TestPlayer.state(pid).table_menu.offers
    player = TestPlayer.state(pid).player.uuid
    Client.send_packet(client, :play, "attack", Wire.varint(id))

    Valimc.TestWait.until(fn ->
      {targets, _} = elem(villager(owner, uuid), 1).data.gossips || {[], 0}
      Enum.any?(targets, fn {p, entries} -> p == player and entries[:minor_negative] == 25 end)
    end)

    # Its prices for its trading player rose (-25 reputation), unless the
    # punch closed the menu first.
    {_, row} = villager(owner, uuid)

    assert Enum.zip(before, row.data.offers)
           |> Enum.all?(fn {b, a} -> a.special_price >= b.special_price end)
  end

  test "a golden apple cures a weakened zombie villager into the villager it was", ctx do
    player = %{
      living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: -90.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Valimc.Player.Food{}
    }

    TestPlayer.save(ctx, player, %Inventory{
      slots: %{36 => ItemStack.new("minecraft:golden_apple", 2)}
    })

    {client, pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, body} = Body.new("minecraft:zombie_villager")
    weakness = Valimc.Data.EffectTypes.id("weakness")

    body = %{
      body
      | data: %{
          body.data
          | villager: {"minecraft:plains", "minecraft:librarian", 2},
            finalized: true,
            xp: 20
        }
    }

    body = put_in(body.mob.living.effects, %{weakness => [{600, 0, false, true, true}]})
    body = put_in(body.mob.no_ai, true)
    uuid = <<10::128>>

    :ok =
      Region.drop_items(owner, [
        Store.body_record(body, uuid, {ctx.pose.x + 2.0, 64.0, ctx.pose.z})
      ])

    {_, client} = Client.await(client, :play, "add_entity")
    {id, _} = villager(owner, uuid)
    Client.send_packet(client, :play, "interact", [Wire.varint(id), Wire.varint(0), <<0, 0>>])

    Valimc.TestWait.until(fn -> elem(villager(owner, uuid), 1).data.cure >= 3600 end)
    {_, zombie} = villager(owner, uuid)
    assert zombie.data.cure <= 6000
    assert TestPlayer.state(pid).inventory.slots[36].count == 1

    # Its cure's last tick: a villager of its data, with the curer's gossip.
    Valimc.TestRegion.replace_section(owner, fn section ->
      %{native: ref} = section.entities.store.entries[id]
      {:ok, {_, events, {position, row}}} = Valimc.Native.mob_section_data(ref, id, :cure, 1)

      put_in(
        section.entities.store,
        Store.native_change(section.entities.store, id, position, row, events)
      )
    end)

    me = TestPlayer.state(pid).player.uuid
    Region.step(owner, 1)

    Valimc.TestWait.until(fn ->
      Enum.any?(store(owner).entries, fn {_, e} ->
        e.kind == :mob and e.body.type == "minecraft:villager"
      end)
    end)

    {_, cured} =
      Enum.find(store(owner).entries, fn {_, e} ->
        e.kind == :mob and e.body.type == "minecraft:villager"
      end)

    data = merchant_data(owner, cured.entity.entity_id)

    assert {data.profession, data.level, data.xp} == {"minecraft:librarian", 2, 20}
    {targets, _} = data.gossips
    assert {me, [minor_positive: 25, major_positive: 20]} in targets
    assert Store.find(store(owner), uuid) == {:error, :missing_item}
    _ = client
  end

  test "on hard a zombie's kill turns a villager into a zombie villager with its data", ctx do
    {difficulty, _} = Valimc.World.Clock.difficulty()
    on_exit(fn -> Valimc.World.Clock.configure({:difficulty, difficulty.level, true}) end)
    :ok = Valimc.World.Clock.configure({:difficulty, 3, true})

    player = %{
      living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: -90.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:creative),
      abilities: Valimc.Player.Abilities.for_mode(:creative),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Valimc.Player.Food{}
    }

    TestPlayer.save(ctx, player, %Inventory{})
    {_client, _pid} = TestPlayer.login(ctx)
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, villager} = Body.new("minecraft:villager")

    villager = %{
      villager
      | data: %{
          villager.data
          | profession: "minecraft:librarian",
            level: 2,
            xp: 20,
            finalized: true
        }
    }

    # It stands still (a panicking villager outruns a zombie).
    villager = put_in(villager.mob.living.health.value, 1.0)
    villager = put_in(villager.mob.no_ai, true)
    {:ok, zombie} = Body.new("minecraft:zombie")
    uuid = <<11::128>>

    :ok =
      Region.drop_items(owner, [
        Store.body_record(villager, uuid, {ctx.pose.x + 4.0, 64.0, ctx.pose.z}),
        Store.body_record(zombie, <<12::128>>, {ctx.pose.x + 5.5, 64.0, ctx.pose.z})
      ])

    zombie_villager = fn ->
      Enum.find_value(store(owner).entries, fn {_, e} ->
        e.kind == :mob and e.body.type == "minecraft:zombie_villager" and e
      end)
    end

    # Up to twenty seconds of play, until the zombie's kill.
    Enum.reduce_while(1..20, nil, fn _, _ ->
      Region.step(owner, 20)
      if zombie_villager.(), do: {:halt, nil}, else: {:cont, nil}
    end)

    entry = zombie_villager.()
    assert Store.find(store(owner), uuid) == {:error, :missing_item}

    data = merchant_data(owner, entry.entity.entity_id)

    assert {data.villager, data.finalized, data.xp} ==
             {{"minecraft:plains", "minecraft:librarian", 2}, true, 20}
  end
end
