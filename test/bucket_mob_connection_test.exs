defmodule Valimc.BucketMobConnectionTest do
  @moduledoc "Capture, persist and release a named fish across a section boundary (VMC-043e8)."
  use ExUnit.Case, async: false
  @moduletag :tcp
  @moduletag timeout: 180_000
  alias Valimc.Data.{Blocks, Grid}
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{GameMode, PlayerList}
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.TestPlayer
  alias Valimc.World.Region

  setup do
    ctx = TestPlayer.scope("FishBucket", {145_000, 1009}, survival: {2, false})
    {x, z} = ctx.key
    ctx = %{ctx | pose: %{ctx.pose | x: x * 128 + 127.5, z: z * 128 + 40.5}}
    Valimc.TestScope.isolate(Valimc.TestScope.neighborhood(ctx.key), item_simulation: true)
    ctx
  end

  defp store(owner), do: Valimc.TestRegion.section(owner).entities.store

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp pour(client, sequence, pitch \\ 60.0) do
    Client.send_packet(client, :play, "use_item", [
      Wire.varint(0),
      Wire.varint(sequence),
      <<-90::float-32, pitch::float-32>>
    ])

    {_, client} = Client.await(client, :play, "block_changed_ack")
    client
  end

  test "capture consumes one body, survives reconnect, and release changes fluid and held item once",
       ctx do
    player =
      Map.merge(ctx.pose, %{
        living: %Valimc.Living{health: %Valimc.Living.Health{value: 20.0}},
        game_mode: GameMode.new(:survival),
        abilities: Valimc.Player.Abilities.for_mode(:survival),
        motion: %Valimc.Player.Motion{},
        last_death: nil,
        food: %Valimc.Player.Food{}
      })

    TestPlayer.save(ctx, player, %Inventory{slots: %{36 => ItemStack.new("water_bucket")}})
    {client, pid} = TestPlayer.login(ctx)
    {sx, sz} = ctx.key
    next_key = {sx + 1, sz}
    {:ok, owner} = Valimc.TestWorld.owner(next_key)
    x = (sx + 1) * 128
    z = floor(ctx.pose.z)
    cell = {x, 64, z}

    set(owner, %{
      {x, 63, z} => Blocks.default_state("stone"),
      cell => Blocks.default_state("water")
    })

    {:ok, fish} = Body.new("minecraft:salmon")

    fish = %{
      fish
      | custom_name: {:string, "Bucket salmon"},
        no_gravity: true,
        data: %{fish.data | size: 2},
        mob: %{fish.mob | no_ai: true}
    }

    uuid = <<91::128>>
    :ok = Region.drop_items(owner, [Store.body_record(fish, uuid, {x + 0.5, 64.0, z + 0.5})])
    {_, client} = Client.await(client, :play, "add_entity")
    {:ok, {_, id, _}} = Store.find(store(owner), uuid)
    interact = [Wire.varint(id), Wire.varint(0), <<0, 0>>]
    Client.send_packet(client, :play, "interact", interact)

    Valimc.TestWait.until(fn ->
      TestPlayer.state(pid).inventory.slots[36].item_id ==
        Valimc.Protocol.ItemTypes.id("salmon_bucket")
    end)

    captured = TestPlayer.state(pid).inventory.slots[36]
    assert captured.components["minecraft:salmon/size"] == 2
    assert captured.components["minecraft:custom_name"] == {:string, "Bucket salmon"}
    assert {:error, _} = Store.find(store(owner), uuid)
    Client.send_packet(client, :play, "interact", interact)
    TestPlayer.checkpointed(pid)
    assert TestPlayer.state(pid).inventory.slots[36] == captured
    Client.close(client)
    Valimc.TestWait.until(fn -> not Enum.any?(PlayerList.all(), &(&1.name == ctx.name)) end)
    {client, pid} = TestPlayer.login(ctx)
    assert TestPlayer.state(pid).inventory.slots[36] == captured

    # A stale owner cannot pour fluid or admit the saved animal.
    {group, _epoch} = owner

    assert {:error, {:retry, :stale_owner}} =
             Region.bucket(
               {group, make_ref()},
               {:release, cell, {:empty, cell, 2, cell, false}, captured}
             )

    assert Enum.empty?(store(owner).entries)

    # A solid target and retry cell refuse the fluid before admitting a body.
    blocked = {x, 70, z}
    set(owner, %{blocked => Blocks.default_state("stone")})
    before_random = Valimc.TestRegion.section(owner).ai_random

    assert {:ok, 0} =
             Region.bucket(
               owner,
               {:release, blocked, {:empty, blocked, 2, blocked, false}, captured}
             )

    assert Enum.empty?(store(owner).entries)
    assert TestPlayer.state(pid).inventory.slots[36] == captured
    assert Valimc.TestRegion.section(owner).ai_random == before_random

    # Denied game-mode use leaves both the saved bucket and world intact.
    Valimc.TestConn.replace(pid, fn s ->
      %{s | player: %{s.player | game_mode: GameMode.new(:adventure)}}
    end)

    client = pour(client, 1)
    assert TestPlayer.state(pid).inventory.slots[36] == captured
    assert Enum.empty?(store(owner).entries)

    Valimc.TestConn.replace(pid, fn s ->
      %{s | player: %{s.player | game_mode: GameMode.new(:survival)}}
    end)

    # The ray hits the floor across X=128; pouring an existing source is valid.
    client = pour(client, 2)

    Valimc.TestWait.until(fn ->
      TestPlayer.state(pid).inventory.slots[36] == ItemStack.new("bucket")
    end)

    [released] = for {_, %{kind: :mob} = entry} <- store(owner).entries, do: entry
    assert released.entity.uuid != uuid
    assert released.body.type == "minecraft:salmon"
    assert released.body.data.size == 2 and released.body.data.from_bucket
    assert released.body.custom_name == {:string, "Bucket salmon"}
    assert released.body.mob.no_ai and released.body.no_gravity
    assert Grid.region_key(Grid.chunk_key(released.entity.x, released.entity.z)) == next_key
    assert Valimc.Player.Buckets.block_at(:overworld, cell) == Blocks.default_state("water")
    client = pour(client, 3)
    assert Enum.count(store(owner).entries, fn {_, entry} -> entry.kind == :mob end) == 1

    # Re-capture, then pour from a wall's side into a snow layer. Placement
    # must use the post-pour shape, after water has washed away the snow.
    {_, client} = Client.await(client, :play, "add_entity")
    {:ok, {_, id, _}} = Store.find(store(owner), released.entity.uuid)
    Client.send_packet(client, :play, "interact", [Wire.varint(id), Wire.varint(0), <<0, 0>>])

    Valimc.TestWait.until(fn ->
      TestPlayer.state(pid).inventory.slots[36].item_id ==
        Valimc.Protocol.ItemTypes.id("salmon_bucket")
    end)

    snow = Blocks.state("snow", %{"layers" => "4"})

    assert {:ok, {_, 64.375, _}} =
             Valimc.Entity.Bucketable.spawn_point("minecraft:salmon", cell, fn at ->
               if at == cell, do: snow, else: 0
             end)

    set(owner, %{
      cell => snow,
      {x + 1, 64, z} => Blocks.default_state("stone")
    })

    _client = pour(client, 4, 24.0)

    Valimc.TestWait.until(fn ->
      TestPlayer.state(pid).inventory.slots[36] == ItemStack.new("bucket")
    end)

    [second] = for {_, %{kind: :mob} = entry} <- store(owner).entries, do: entry
    assert second.entity.y == 64.0
    assert Valimc.Player.Buckets.block_at(:overworld, cell) == Blocks.default_state("water")
  end
end
