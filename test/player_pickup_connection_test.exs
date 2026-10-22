defmodule Valimc.PlayerPickupConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Connection, GameMode, Inventory, Players, World}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.World.Region
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-pickup-#{nonce}")
    previous = Valimc.config(:world_path)
    simulation = Valimc.config(:item_simulation)
    Application.put_env(:valimc, :world_path, base)
    Application.put_env(:valimc, :item_simulation, true)
    key = {70000 + rem(nonce, 3333) * 3, 1900}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    names = ["Pickup#{nonce}", "Race#{nonce}"]

    on_exit(fn ->
      for player <- Players.all(),
          player.name in names,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for x <- (rx - 1)..(rx + 1), z <- (rz - 1)..(rz + 1) do
        for {pid, _} <- Valimc.TestWorld.registered({x, z}),
            do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      end

      Application.put_env(:valimc, :world_path, previous)
      Application.put_env(:valimc, :item_simulation, simulation)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{
      base: base,
      key: key,
      pose: pose,
      names: names,
      name: hd(names),
      uuid: Connection.offline_uuid(hd(names))
    }
  end

  defp seed(c, mode \\ :survival, slots \\ %{}) do
    player =
      Map.merge(c.pose, %{
        game_mode: GameMode.new(mode),
        abilities: Valimc.PlayerAbilities.for_mode(mode)
      })

    {:ok, bytes} =
      PlayerState.encode(c.uuid, PlayerState.capture(player, %Inventory{slots: slots}))

    path = Valimc.Player.Storage.path(c.base, c.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp login(c) do
    {_, client} = Client.login(c.name)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "player_loaded", <<>>)
    pid = Enum.find(Players.all(), &(&1.name == c.name)).pid
    on_exit(fn -> Client.close(client) end)
    wait(fn -> Valimc.TestConn.state(pid).pose_checked != nil end)
    {client, pid}
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)

  defp spawn_item(c, stack, dx) do
    at = {c.pose.x + dx, c.pose.y, c.pose.z}
    key = World.region_key(World.chunk_key(c.pose.x + dx, c.pose.z))
    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    {:ok, handle} = Region.create_item(owner, stack, at)
    {owner, handle, key}
  end

  # The items as their owner's frames hold them, once it wrote them.
  defp records(c, key) do
    {:ok, {pid, _}} = Valimc.TestWorld.item_owner(key)
    :ok = Region.flush(pid)

    case Valimc.TestDisk.read(c.base, key, :items) do
      nil -> []
      saved -> saved.records
    end
  end

  defp picked(pid, slot, count) do
    state = Valimc.TestConn.state(pid)
    match?(%{count: ^count}, state.inventory.slots[slot])
  end

  test "automatic whole pickup sends native callback and survives fresh login exactly once", c do
    seed(c)
    {client, pid} = login(c)
    # Out of reach until the client tracks it (vanilla sends the take to trackers).
    {_owner, {_, _, id, _}, key} = spawn_item(c, ItemStack.new("stone", 7), 3.0)
    client = Client.await_spawn(client, id)
    client = Client.teleport(client, pid, %{c.pose | x: c.pose.x + 3.0})
    {body, client} = Client.await(client, :play, "take_item_entity")
    {^id, body} = Wire.take_varint(body)
    {collector, body} = Wire.take_varint(body)
    assert collector == Valimc.TestConn.state(pid).player.entity_id
    assert {7, <<>>} == Wire.take_varint(body)
    wait(fn -> picked(pid, 36, 7) end)
    assert records(c, key) == []
    Client.close(client)

    wait(fn ->
      not Process.alive?(pid) and Registry.lookup(Valimc.PlayerRegistry, c.uuid) == []
    end)

    {_fresh, next} = login(c)
    assert picked(next, 36, 7)
    assert records(c, key) == []
  end
end
