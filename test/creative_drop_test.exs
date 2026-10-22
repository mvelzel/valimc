defmodule Valimc.CreativeDropTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.{Inventory, PlayerStore, Players}
  alias Valimc.Player.State, as: PlayerState
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.World.Entities
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-creative-drop-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {40_000 + rem(nonce, 3_333) * 3, 500}
    name = "Creative" <> Integer.to_string(nonce)
    uuid = Valimc.Connection.offline_uuid(name)
    {rx, rz} = key
    pose = %{x: rx * 128 + 64.5, y: 64.0, z: rz * 128 + 64.5, yaw: 0.0, pitch: 0.0}

    stone = %{
      ItemStack.new("stone", 7)
      | components: %{"minecraft:enchantment_glint_override" => true},
        removed: MapSet.new(["minecraft:rarity"])
    }

    inv = %Inventory{slots: %{36 => stone, 45 => ItemStack.new("egg", 3)}}
    path = PlayerStore.path(base, uuid)
    {:ok, bytes} = PlayerState.encode(uuid, PlayerState.capture(pose, inv))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      Valimc.TestScope.stop_neighbourhood(key, spawn: true)
      Valimc.TestScope.stop_players(base)
      File.rm_rf!(base)
    end)

    %{base: base, key: key, name: name, uuid: uuid, pose: pose, stone: stone, path: path}
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    Client.load_world(client)
  end

  defp wait(ctx, predicate, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      player = Enum.find(Players.all(), &(&1.name == ctx.name))
      state = if player, do: :sys.get_state(player.pid)
      if state && predicate.(state), do: {player.pid, state}
    end)
  end

  defp depart(ctx, client) do
    p = Enum.find(Players.all(), &(&1.name == ctx.name))
    ref = if p, do: Process.monitor(p.pid)
    Client.close(client)
    if ref, do: assert_receive({:DOWN, ^ref, :process, _, :normal})
  end

  defp saved(ctx) do
    {:ok, snapshot} = PlayerState.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp records(ctx) do
    {:ok, {pid, _}} = Valimc.TestWorld.item_owner(ctx.key)
    Entities.records(Valimc.TestRegion.section(pid).entities.store)
  end

  defp frame(client, slot, stack),
    do:
      Wire.frame(
        Data.id(:play, :serverbound, "set_creative_mode_slot"),
        [<<slot::signed-16>>, ItemStack.encode(stack, :untrusted)],
        client.threshold
      )

  defp batch(client, commands),
    do:
      Client.send_raw(
        client,
        Enum.map(commands, fn {slot, stack} -> frame(client, slot, stack) end)
      )

  defp completed(ctx, sequence),
    do:
      wait(ctx, fn s ->
        s.recovery == nil && s.creative_input.queued == 0 && not s.creative_drain_scheduled &&
          saved(ctx).transfer_sequence == sequence && saved(ctx).outbox == nil
      end)

  test "two creative drop/write pairs in one TCP batch retain exact ordered state and recover",
       ctx do
    client = login(ctx)

    batch(client, [
      {-1, %{ctx.stone | count: 1}},
      {36, %{ctx.stone | count: 6}},
      {-32768, ItemStack.new("egg", 3)},
      {45, nil}
    ])

    {_, state} = completed(ctx, 2)
    assert state.inventory.slots == %{36 => %{ctx.stone | count: 6}}
    original = records(ctx)
    assert Enum.all?(original, &(&1.motion.pickup_delay == 40 and not &1.motion.no_gravity))
    assert Enum.sort(Enum.map(original, & &1.stack.count)) == [1, 3]
    assert Enum.any?(original, &(&1.stack == %{ctx.stone | count: 1}))
    depart(ctx, client)
    assert saved(ctx).inventory.slots == state.inventory.slots
    {:ok, {region, _}} = Valimc.TestWorld.item_owner(ctx.key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)
    second = login(ctx)
    assert second.inventory.items == Inventory.contents(state.inventory)
    assert records(ctx) == original and saved(ctx).transfer_sequence == 2
    depart(ctx, second)
  end
end
