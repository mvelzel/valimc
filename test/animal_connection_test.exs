defmodule Valimc.AnimalConnectionTest do
  @moduledoc """
  A player's items on a farm animal through a connection (VMC-043c): an
  `interact` with a bucket milks a cow (the bucket becomes milk), wheat
  makes it fall in love and is used up.
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
    ctx = TestPlayer.scope("Animals", {146_000, 997}, survival: {2, false})
    Valimc.TestScope.isolate(Valimc.TestScope.neighborhood(ctx.key), item_simulation: true)
    ctx
  end

  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  defp body(owner, uuid) do
    {:ok, {_, id, _}} = Store.find(store(owner), uuid)
    {id, store(owner).entries[id].body}
  end

  test "a bucket milks a cow and wheat makes it fall in love", ctx do
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
        36 => ItemStack.new("minecraft:bucket"),
        37 => %{ItemStack.new("minecraft:wheat") | count: 3}
      }
    }

    TestPlayer.save(ctx, player, inventory)
    {client, pid} = TestPlayer.login(ctx)

    # A still cow (no AI: it stays in reach) two blocks east.
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, cow} = Body.new("minecraft:cow")
    uuid = <<6::128>>

    record =
      Store.body_record(put_in(cow.mob.no_ai, true), uuid, {ctx.pose.x + 2.0, 64.0, ctx.pose.z})

    :ok = Region.drop_items(owner, [record])
    {_, client} = Client.await(client, :play, "add_entity")
    {id, _} = body(owner, uuid)

    interact = fn ->
      Client.send_packet(client, :play, "interact", [Wire.varint(id), Wire.varint(0), <<0, 0>>])
    end

    interact.()

    Valimc.TestWait.until(fn ->
      TestPlayer.state(pid).inventory.slots[36].item_id == ItemTypes.id("minecraft:milk_bucket")
    end)

    Client.send_packet(client, :play, "set_carried_item", <<1::16>>)
    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.selected == 1 end)
    interact.()

    Valimc.TestWait.until(fn -> TestPlayer.state(pid).inventory.slots[37].count == 2 end)
    assert elem(body(owner, uuid), 1).data.in_love > 0
    _ = client
  end
end
