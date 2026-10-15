defmodule Valimc.CreativeDropTest do
  use ExUnit.Case, async: false
  alias Valimc.{Inventory, PlayerSnapshot, PlayerStore, Players, World}
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.World.Items
  alias Valimc.TestClient, as: Client
  import ExUnit.CaptureLog

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-creative-drop-#{nonce}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {40_000 + rem(nonce, 10_000), 500}
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
    {:ok, bytes} = PlayerSnapshot.encode(uuid, PlayerSnapshot.capture(pose, inv))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    %{base: base, key: key, name: name, uuid: uuid, pose: pose, stone: stone, path: path}
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    Client.load_world(client)
  end

  defp wait(ctx, predicate, attempts \\ 1500) do
    player = Enum.find(Players.all(), &(&1.name == ctx.name))
    state = if player, do: :sys.get_state(player.pid)

    if state && predicate.(state) do
      {player.pid, state}
    else
      assert attempts > 0
      Process.sleep(2)
      wait(ctx, predicate, attempts - 1)
    end
  end

  defp depart(ctx, client) do
    p = Enum.find(Players.all(), &(&1.name == ctx.name))
    ref = if p, do: Process.monitor(p.pid)
    Client.close(client)
    if ref, do: assert_receive({:DOWN, ^ref, :process, _, :normal}, 6000)
  end

  defp saved(ctx) do
    {:ok, snapshot} = PlayerSnapshot.decode(File.read!(ctx.path), ctx.uuid)
    snapshot
  end

  defp records(ctx) do
    {:ok, {pid, _}} = World.item_owner(ctx.key)
    Items.records(:sys.get_state(pid).resource.items)
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

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    stats(client)
  end

  defp stats(client) do
    {body, client} = Client.await(client, :play, "system_chat", 600)
    if :binary.match(body, " schedulers") != :nomatch, do: client, else: stats(client)
  end

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
    assert Enum.sort(Enum.map(original, & &1.stack.count)) == [1, 3]
    assert Enum.any?(original, &(&1.stack == %{ctx.stone | count: 1}))
    depart(ctx, client)
    assert saved(ctx).inventory.slots == state.inventory.slots
    {:ok, {region, _}} = World.item_owner(ctx.key)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)
    second = login(ctx)
    assert second.inventory.items == Inventory.contents(state.inventory)
    assert records(ctx) == original and saved(ctx).transfer_sequence == 2
    depart(ctx, second)
  end

  test "stalled creation preserves pairs, pinned origins and peer responsiveness across both writers",
       ctx do
    client = login(ctx)
    {pid, initial} = wait(ctx, &(&1.recovery == nil))
    {:ok, {region, _}} = World.item_owner(ctx.key)
    destination = :sys.get_state(region).resource.store
    :sys.suspend(initial.player_store)
    :sys.suspend(destination)

    try do
      batch(client, [
        {-1, %{ctx.stone | count: 1}},
        {36, %{ctx.stone | count: 6}},
        {-2, ItemStack.new("egg", 2)},
        {45, ItemStack.new("egg", 1)}
      ])

      {^pid, pending} =
        wait(
          ctx,
          &(&1.recovery != nil && &1.recovery.stage == :prepare && &1.creative_input.queued == 3)
        )

      assert pending.inventory.slots == initial.inventory.slots
      client = barrier(client)
      assert client.inventory.state_id == initial.inventory.state_id

      Client.send_packet(
        client,
        :play,
        "move_player_pos",
        <<ctx.pose.x + 1::float-64, 64.0::float-64, ctx.pose.z::float-64, 1>>
      )

      Client.send_packet(client, :play, "container_close", <<0>>)
      client = barrier(client)
      Client.await_position(pid, %{x: ctx.pose.x + 1})
      assert :sys.get_state(pid).player.x == ctx.pose.x + 1
      assert records(ctx) == [] and saved(ctx).transfer_sequence == 0
      {_, peer} = Client.login("Peer" <> Integer.to_string(System.unique_integer([:positive])))
      peer = barrier(peer)
      Client.close(peer)
      :sys.resume(initial.player_store)

      wait(
        ctx,
        &(&1.recovery != nil && &1.recovery.stage == :delivery &&
            :sys.get_state(region).resource.item_pending != nil)
      )

      assert saved(ctx).outbox != nil and World.item_snapshot(ctx.key) == %{}
      assert :sys.get_state(pid).creative_input.queued == 3
      :sys.resume(destination)
      {_, finished} = completed(ctx, 2)

      assert finished.inventory.slots == %{
               36 => %{ctx.stone | count: 6},
               45 => ItemStack.new("egg", 1)
             }

      assert Enum.all?(records(ctx), &(&1.x == ctx.pose.x and &1.z == ctx.pose.z))
      depart(ctx, client)
    after
      if Process.alive?(initial.player_store), do: :sys.resume(initial.player_store)
      if Process.alive?(destination), do: :sys.resume(destination)
      Client.close(client)
    end
  end

  test "prepared creative creation preserves predictions while paired edits remain queued", ctx do
    client = login(ctx)
    {_, initial} = wait(ctx, &(&1.recovery == nil))
    {:ok, {region, _}} = World.item_owner(ctx.key)
    destination = :sys.get_state(region).resource.store
    :sys.suspend(destination)

    try do
      batch(client, [{-1, %{ctx.stone | count: 1}}, {36, %{ctx.stone | count: 6}}])

      wait(
        ctx,
        &(&1.recovery != nil && &1.recovery.stage == :delivery && &1.creative_input.queued == 1 &&
            :sys.get_state(region).resource.item_pending != nil)
      )

      client = barrier(client)
      assert client.inventory.state_id == initial.inventory.state_id
      :sys.resume(destination)
      {_, done} = completed(ctx, 1)
      assert done.inventory.slots[36].count == 6
      depart(ctx, client)
    after
      if Process.alive?(destination), do: :sys.resume(destination)
      Client.close(client)
    end
  end

  test "save admission preserves paired ordering, and revoked permission discards deferred edits",
       ctx do
    client = login(ctx)
    {pid, initial} = wait(ctx, &(&1.recovery == nil))
    :sys.suspend(initial.player_store)

    try do
      send(pid, :save_player)
      wait(ctx, &(&1.save_ref != nil))
      batch(client, [{-1, %{ctx.stone | count: 1}}, {36, %{ctx.stone | count: 6}}])
      wait(ctx, &(&1.creative_input.queued == 2))
      assert :sys.get_state(pid).recovery == nil
      :sys.resume(initial.player_store)
      {_, finished} = completed(ctx, 1)
      assert finished.inventory.slots[36].count == 6
      :sys.suspend(initial.player_store)
      batch(client, [{-1, %{ctx.stone | count: 1}}, {36, %{ctx.stone | count: 5}}])

      wait(
        ctx,
        &(&1.recovery != nil && &1.recovery.stage == :prepare && &1.creative_input.queued == 1)
      )

      :sys.replace_state(pid, &%{&1 | inventory: %{&1.inventory | infinite_materials: false}})
      :sys.resume(initial.player_store)
      {_, denied} = completed(ctx, 2)
      assert denied.inventory.slots[36].count == 6 and not denied.inventory.infinite_materials
      depart(ctx, client)
    after
      if Process.alive?(initial.player_store), do: :sys.resume(initial.player_store)
      Client.close(client)
    end
  end

  test "unauthorized/invalid slots do not mutate, and empty requests charge without an intent",
       ctx do
    client = login(ctx)
    {pid, initial} = wait(ctx, &(&1.recovery == nil))
    :sys.replace_state(pid, &%{&1 | inventory: %{&1.inventory | infinite_materials: false}})
    batch(client, [{-1, ItemStack.new("diamond")}, {36, ItemStack.new("diamond")}])
    client = barrier(client)
    assert :sys.get_state(pid).inventory.slots == initial.inventory.slots
    assert :sys.get_state(pid).creative_input.level == 0

    :sys.replace_state(pid, fn s ->
      %{
        s
        | inventory: %{s.inventory | infinite_materials: true},
          creative_input: %{
            s.creative_input
            | level: 1459,
              tick: Integer.floor_div(System.monotonic_time(:millisecond), 50) + 1000
          }
      }
    end)

    batch(client, [
      {0, ItemStack.new("diamond")},
      {46, ItemStack.new("diamond")},
      {32767, ItemStack.new("diamond")},
      {-1, nil},
      {-1, ItemStack.new("air", 8)},
      {-1, ItemStack.new("diamond")}
    ])

    client = barrier(client)
    assert :sys.get_state(pid).creative_input.level == 1499
    assert :sys.get_state(pid).inventory.slots == initial.inventory.slots
    assert saved(ctx).transfer_sequence == 0 and records(ctx) == []
    depart(ctx, client)
  end

  test "bounded deferred count yields callbacks and rejects command 161 without partial admission",
       ctx do
    client = login(ctx)
    {_, initial} = wait(ctx, &(&1.recovery == nil))
    :sys.suspend(initial.player_store)

    try do
      batch(client, [{-1, %{ctx.stone | count: 1}}])
      wait(ctx, &(&1.recovery != nil && &1.recovery.stage == :prepare))
      batch(client, for(n <- 1..161, do: {9, ItemStack.new("dirt", rem(n, 64) + 1)}))
      client = barrier(client)
      {_, pending} = wait(ctx, &(&1.creative_input.queued == 160))
      assert pending.inventory.slots[9] == nil
      :sys.resume(initial.player_store)
      {_, done} = completed(ctx, 1)
      assert done.inventory.slots[9] == ItemStack.new("dirt", 33)
      assert length(records(ctx)) == 1 and done.creative_input.bytes == 0
      depart(ctx, client)
    after
      if Process.alive?(initial.player_store), do: :sys.resume(initial.player_store)
      Client.close(client)
    end
  end

  test "bounded deferred bytes reject the ninth large update while retaining eight exact commands",
       ctx do
    client = login(ctx)
    {_, initial} = wait(ctx, &(&1.recovery == nil))
    :sys.suspend(initial.player_store)

    big = fn n ->
      %{
        ItemStack.new("stone")
        | components: %{
            "minecraft:custom_data" =>
              {:compound,
               %{"big" => {:byte_array, :binary.copy(<<1>>, 60_000)}, "n" => {:int, n}}}
          }
      }
    end

    try do
      batch(client, [{-1, %{ctx.stone | count: 1}}])
      wait(ctx, &(&1.recovery != nil && &1.recovery.stage == :prepare))
      batch(client, for(n <- 1..9, do: {9, big.(n)}))
      client = barrier(client)
      {_, pending} = wait(ctx, &(&1.creative_input.queued == 8))
      assert pending.creative_input.bytes <= 524_288
      :sys.resume(initial.player_store)
      {_, client} = Client.await(client, :play, "container_set_slot")
      {_, done} = completed(ctx, 1)
      assert done.inventory.slots[9] == big.(8) and done.creative_input.bytes == 0
      depart(ctx, client)
    after
      if Process.alive?(initial.player_store), do: :sys.resume(initial.player_store)
      Client.close(client)
    end
  end

  test "no-commit storage rejection still applies an independent queued creative slot write",
       ctx do
    client = login(ctx)
    {_, initial} = wait(ctx, &(&1.recovery == nil))
    :sys.replace_state(initial.player_store, &%{&1 | path: nil})
    batch(client, [{-1, %{ctx.stone | count: 1}}, {36, %{ctx.stone | count: 6}}])
    client = barrier(client)
    {_, state} = completed(ctx, 0)
    assert state.inventory.slots[36].count == 6 and records(ctx) == []
    :sys.replace_state(initial.player_store, &%{&1 | path: ctx.path})
    depart(ctx, client)
    assert saved(ctx).inventory.slots[36].count == 6
  end

  test "disconnect preserves only the committed creation, without replaying unacknowledged input",
       ctx do
    client = login(ctx)
    {:ok, {region, _}} = World.item_owner(ctx.key)
    destination = :sys.get_state(region).resource.store
    :sys.suspend(destination)

    try do
      batch(client, [
        {-1, %{ctx.stone | count: 1}},
        {36, %{ctx.stone | count: 6}},
        {-1, %{ctx.stone | count: 1}}
      ])

      wait(
        ctx,
        &(&1.recovery != nil && &1.recovery.stage == :delivery && &1.creative_input.queued == 2 &&
            :sys.get_state(region).resource.item_pending != nil)
      )

      pinned = saved(ctx).outbox.records
      depart(ctx, client)
      :sys.resume(destination)
      second = login(ctx)
      completed(ctx, 1)
      assert records(ctx) == pinned
      assert second.inventory.items |> Enum.at(36) == ctx.stone
      depart(ctx, second)
    after
      if Process.alive?(destination), do: :sys.resume(destination)
      Client.close(client)
    end
  end

  test "uncertain creation write disconnects before publishing queued slot edits or items", ctx do
    client = login(ctx)
    {pid, initial} = wait(ctx, &(&1.recovery == nil))
    original = File.read!(ctx.path)
    File.write!(Path.join(ctx.base, "blocked"), "not a directory")

    :sys.replace_state(
      initial.player_store,
      &%{&1 | path: Path.join(ctx.base, "blocked/player.pose")}
    )

    monitor = Process.monitor(pid)

    capture_log(fn ->
      batch(client, [{-1, %{ctx.stone | count: 1}}, {36, %{ctx.stone | count: 6}}])
      {_, _} = Client.await(client, :play, "disconnect")
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
    end)

    assert File.read!(ctx.path) == original and records(ctx) == []
    Client.close(client)
  end
end
