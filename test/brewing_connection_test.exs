defmodule Valimc.BrewingConnectionTest do
  @moduledoc "A player opens a brewing stand (VMC-034o): its screen, slots and data, and a shift-click."
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Player.{GameMode, PlayerList}
  alias Valimc.Menus.Inventory
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, ItemTypes, Wire}
  alias Valimc.World.Containers
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])

    base =
      Path.join(System.tmp_dir!(), "valimc-brewing-view-#{System.os_time(:nanosecond)}-#{nonce}")

    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {75_000 + rem(nonce, 3_333) * 3, 967}
    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    name = "BrewV#{rem(nonce, 1_000_000_000)}"
    uuid = Valimc.Data.UUID.offline(name)

    on_exit(fn ->
      for player <- PlayerList.all(),
          player.name == name,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      Application.put_env(:valimc, :world_path, previous)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      Valimc.TestScope.await_checkpoints(base)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      name: name,
      uuid: uuid,
      key: key,
      pose: pose,
      position: {floor(pose.x), 64, floor(pose.z) + 3}
    }
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp seed(ctx) do
    inventory = %Inventory{slots: %{36 => ItemStack.new("blaze_powder", 5)}}
    seed_player(ctx, :survival, inventory)

    {:ok, containers, entry} =
      Containers.create_owned(%Containers{}, ctx.key, ctx.position, :brewing_stand)

    brewing = %Valimc.Blocks.Brewing{fuel: 7, total_fuel: 20}

    {:ok, containers, _} =
      Containers.replace_brewing(containers, ctx.position, entry.revision, brewing)

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    block = Valimc.Data.Blocks.default_state("brewing_stand")
    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{ctx.position => block})
    :ok = Valimc.TestBlocks.set(ctx.position, block)
  end

  defp seed_player(ctx, mode, inventory) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.Player.Abilities.for_mode(mode)
      })

    {:ok, bytes} = PlayerState.encode(ctx.uuid, PlayerState.capture(player, inventory))
    path = Valimc.Player.Storage.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    pid = Enum.find(PlayerList.all(), &(&1.name == ctx.name)).pid
    Client.send_packet(client, :play, "player_loaded", <<>>)
    wait(fn -> Valimc.Player.Input.loaded?(Valimc.TestConn.state(pid).player.input) end)

    on_exit(fn ->
      Client.close(client)

      if Process.alive?(pid),
        do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, pid)
    end)

    {client, pid}
  end

  defp use_menu(client, ctx, hand \\ 0) do
    Client.send_packet(client, :play, "use_item_on", [
      Wire.varint(hand),
      Wire.position(ctx.position),
      # Target the occupied underside so secondary-use negatives cannot place
      # the held item above the processor.
      <<0, 0.5::float-32, 0.5::float-32, 0.5::float-32, 0, 0, 1>>
    ])
  end

  defp content(client, predicate \\ fn _ -> true end) do
    {body, client} = Client.await(client, :play, "container_set_content")
    client = Client.auto_reply(client, :play, "container_set_content", body)
    {_, client} = Client.await(client, :play, "set_cursor_item")
    if predicate.(client.inventory), do: client, else: content(client, predicate)
  end

  # The containers as their owner's frames hold them, once it wrote them.
  defp stored(ctx) do
    with {:ok, {pid, _}} <- Valimc.TestWorld.existing_owner(ctx.key),
         do: Valimc.World.Region.flush(pid)

    {:ok, containers} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    containers
  end

  test "a brewing stand opens with its five slots and four data slots, and takes fuel", ctx do
    seed(ctx)
    {client, _pid} = login(ctx)
    use_menu(client, ctx)
    {_, client} = Client.await(client, :play, "block_changed_ack")
    {body, client} = Client.await(client, :play, "open_screen")
    {id, body} = Wire.take_varint(body)
    assert {11, _} = Wire.take_varint(body)
    client = content(client)
    assert client.inventory.container == id and length(client.inventory.items) == 41

    {client, values} =
      Enum.reduce(0..3, {client, []}, fn index, {client, values} ->
        {body, client} = Client.await(client, :play, "container_set_data")
        {^id, <<^index::signed-16, value::signed-16>>} = Wire.take_varint(body)
        {client, values ++ [value]}
      end)

    # Brew time, fuel and their totals.
    assert values == [0, 7, 0, 20]

    # Shift-clicking the blaze powder (window 32, the first hotbar slot) fuels it.
    Client.send_packet(client, :play, "container_click", [
      Wire.varint(id),
      <<0, 32::signed-16, 0::signed-8>>,
      Wire.varint(ItemTypes.input_id("quick_move")),
      <<0, 0>>
    ])

    wait(fn ->
      {:ok, %{brewing: brewing}} = Containers.observe(stored(ctx), ctx.position)
      match?(%ItemStack{count: 5}, elem(brewing.slots, 4))
    end)
  end
end
