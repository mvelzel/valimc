defmodule Valimc.BucketConnectionTest do
  @moduledoc """
  Buckets through a connection (VMC-031a): `use_item` casts the player's own
  ray; an empty bucket takes the source it looks at, a full one pours beside
  the block face it looks at, and lava poured beside water hardens.
  """
  use ExUnit.Case, async: false
  @moduletag :tcp

  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Food, PlayerList}
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.Region
  import Valimc.TestPlayer, only: [park: 1, state: 1]

  setup do: Valimc.TestPlayer.scope("Bucket", {141_000, 991}, survival: {1, false})

  defp login(ctx) do
    {_, client} = Client.configure_session(Client.begin_login(ctx.name), ctx.name)
    Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")

    {pid, _} =
      Valimc.TestWait.until(fn ->
        Enum.find(:ets.tab2list(PlayerList), fn {_, p} -> p.name == ctx.name end)
      end)

    park(pid)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    Valimc.TestWait.until(fn ->
      not state(pid).teleport_pending and Valimc.Player.Input.loaded?(state(pid).player.input)
    end)

    on_exit(fn -> Client.close(client) end)
    {client, pid}
  end

  defp seed(ctx, inventory) do
    player = %{
      living: %Valimc.Living{
        freezing: %Valimc.Living.Freezing{},
        health: %Valimc.Living.Health{value: 20.0},
        air_supply: 300,
        effects: %{},
        absorption: 0.0
      },
      x: ctx.pose.x,
      y: 64.0,
      z: ctx.pose.z,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: Valimc.Player.GameMode.new(:survival),
      abilities: Valimc.Player.Abilities.for_mode(:survival),
      motion: %Valimc.Player.Motion{},
      last_death: nil,
      food: %Food{}
    }

    Valimc.TestPlayer.save(ctx, player, inventory)
  end

  # Use the held item looking straight down.
  defp use_down(client, sequence) do
    Client.send_packet(
      client,
      :play,
      "use_item",
      IO.iodata_to_binary([Wire.varint(0), Wire.varint(sequence), <<0::float-32, 90::float-32>>])
    )

    {<<^sequence>>, client} = Client.await(client, :play, "block_changed_ack")
    client
  end

  defp set(ctx, edits) do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp block(position),
    do: BlockRegistry.name(BlockRegistry.block_id(Valimc.TestBlocks.get(position)))

  test "an empty bucket takes the source below; the full ones pour it back and lava hardens",
       ctx do
    seed(ctx, %Inventory{slots: %{36 => ItemStack.new("bucket")}})
    feet = {trunc(Float.floor(ctx.pose.x)), 64, trunc(Float.floor(ctx.pose.z))}
    {fx, fy, fz} = feet
    set(ctx, %{feet => BlockRegistry.default_state("water")})
    {client, pid} = login(ctx)

    client = use_down(client, 1)
    Valimc.TestWait.until(fn -> block(feet) == "air" end)
    assert state(pid).inventory.slots[36] == ItemStack.new("water_bucket")

    # Poured on the floor's top face: back into the feet cell.
    client = use_down(client, 2)
    Valimc.TestWait.until(fn -> block(feet) == "water" end)
    assert state(pid).inventory.slots[36] == ItemStack.new("bucket")

    # Lava poured where it meets the water at once makes obsidian.
    set(ctx, %{
      feet => BlockRegistry.default_state("air"),
      {fx + 1, fy, fz} => BlockRegistry.default_state("water")
    })

    Valimc.TestConn.replace(pid, fn s ->
      %{s | inventory: %{s.inventory | slots: %{36 => ItemStack.new("lava_bucket")}}}
    end)

    _client = use_down(client, 3)
    Valimc.TestWait.until(fn -> block(feet) == "obsidian" end)
    assert state(pid).inventory.slots[36] == ItemStack.new("bucket")
  end

  # The M3 gate's disconnect: a pickup that takes nothing (a solid block, or
  # seagrass, which holds water but is no `BucketPickup`) left the session on
  # `{:ok, 0}`.
  test "an empty bucket on a block it cannot take from changes nothing", ctx do
    seed(ctx, %Inventory{slots: %{36 => ItemStack.new("bucket")}})
    feet = {trunc(Float.floor(ctx.pose.x)), 64, trunc(Float.floor(ctx.pose.z))}
    {fx, fy, fz} = feet
    {client, pid} = login(ctx)

    # Looking down at the floor.
    client = use_down(client, 1)
    assert Process.alive?(pid)
    assert state(pid).inventory.slots[36] == ItemStack.new("bucket")

    set(ctx, %{feet => BlockRegistry.default_state("seagrass")})
    _client = use_down(client, 2)
    assert Process.alive?(pid)
    assert block(feet) == "seagrass"
    assert block({fx, fy - 1, fz}) != "air"
    assert state(pid).inventory.slots[36] == ItemStack.new("bucket")
  end
end
