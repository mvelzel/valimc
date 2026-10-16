defmodule Valimc.PlayerMiningConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Connection, GameMode, Inventory, Players, PlayerSnapshot, PlayerStore, World}
  alias Valimc.Protocol.{Data, ItemStack, ItemTypes, Wire}
  alias Valimc.TestClient, as: Client

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-live-mining-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {50_000 + rem(nonce, 10_000), 700}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pose = %{x: rx * span + 40.5, y: 64.0, z: rz * span + 40.5, yaw: 0.0, pitch: 0.0}
    target = {floor(pose.x), 65, floor(pose.z) + 3}
    name = "Dig#{nonce}"
    uuid = Connection.offline_uuid(name)

    on_exit(fn ->
      for player <- Players.all(),
          player.name in [name, name <> "B"],
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)

      for source <- [uuid, Connection.offline_uuid(name <> "B")],
          {pid, _} <- Registry.lookup(Valimc.PlayerStoreRegistry, source),
          do: DynamicSupervisor.terminate_child(Valimc.PlayerStoreSupervisor, pid)

      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{base: base, key: key, pose: pose, target: target, name: name, uuid: uuid}
  end

  defp state(pid), do: :sys.get_state(pid)

  defp wait(fun, attempts \\ 1000) do
    if result = fun.() do
      result
    else
      assert attempts > 0
      Process.sleep(5)
      wait(fun, attempts - 1)
    end
  end

  defp seed(ctx, slots) do
    player =
      Map.merge(ctx.pose, %{
        game_mode: GameMode.new(:survival),
        abilities: Valimc.PlayerAbilities.for_mode(:survival),
        motion: %Valimc.PlayerMotion{},
        environment: %Valimc.PlayerEnvironment{},
        health: %Valimc.PlayerHealth{},
        last_death: nil,
        air_supply: 300,
        food: %Valimc.PlayerFood{}
      })

    {:ok, bytes} =
      PlayerSnapshot.encode(ctx.uuid, PlayerSnapshot.capture(player, %Inventory{slots: slots}))

    path = PlayerStore.path(ctx.base, ctx.uuid)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    :ok = World.set_block(ctx.target, Data.block("stone"))
  end

  defp login(ctx) do
    {_, client} = Client.login(ctx.name)
    client = Client.load_world(client)
    pid = Enum.find(Players.all(), &(&1.name == ctx.name)).pid
    on_exit(fn -> Client.close(client) end)
    Client.send_packet(client, :play, "player_loaded", <<>>)

    Client.send_packet(
      client,
      :play,
      "move_player_pos",
      <<ctx.pose.x::float-64, ctx.pose.y::float-64, ctx.pose.z::float-64, 1>>
    )

    wait(fn -> state(pid).player.motion.on_ground and state(pid).pose_checked != nil end)
    {client, pid}
  end

  defp action(client, action, position, sequence) do
    Client.send_packet(client, :play, "player_action", [
      Wire.varint(ItemTypes.action_id(action)),
      Wire.position(position),
      <<1>>,
      Wire.varint(sequence)
    ])
  end

  defp saved(ctx) do
    {:ok, snapshot} =
      PlayerSnapshot.decode(File.read!(PlayerStore.path(ctx.base, ctx.uuid)), ctx.uuid)

    snapshot
  end

  defp await_ack(client, expected) do
    {body, client} = Client.await(client, :play, "block_changed_ack")
    {sequence, <<>>} = Wire.take_varint(body)
    if sequence == expected, do: client, else: await_ack(client, expected)
  end

  defp finished(pid), do: state(pid).mining == nil and state(pid).recovery == nil

  defp drops(ctx) do
    path = Valimc.World.Store.item_path(ctx.base, ctx.key)
    {:ok, ledger} = Valimc.World.ItemRecords.decode(File.read!(path), ctx.key)
    Enum.map(ledger.records, & &1.stack)
  end

  test "active ticks never destroy without stop; committed drops and wear survive a real reconnect",
       ctx do
    seed(ctx, %{36 => ItemStack.new("iron_pickaxe")})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    started = state(pid).mining.started
    wait(fn -> state(pid).simulation_clock.tick - started >= 12 end)
    assert World.get_block(ctx.target) == Data.block("stone")
    action(client, "stop_destroy_block", ctx.target, 2)
    wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
    assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil

    assert drops(ctx) == [ItemStack.new("cobblestone")]

    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, pid} = login(ctx)
    assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1
    assert map_size(World.item_snapshot(ctx.key)) == 1
    assert World.get_block(ctx.target) == 0
  end

  test "instant final-use mining samples Silk Touch before the selected tool breaks", ctx do
    tool = %{
      ItemStack.new("iron_pickaxe")
      | components: %{
          "minecraft:damage" => 249,
          "minecraft:enchantments" => %{
            "minecraft:efficiency" => 255,
            "minecraft:silk_touch" => 1
          }
        }
    }

    seed(ctx, %{36 => tool})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
    assert Inventory.held(state(pid).inventory, :main) == nil

    assert drops(ctx) == [ItemStack.new("stone")]

    assert saved(ctx).inventory.slots == %{}
    assert saved(ctx).transfer_sequence == 1
  end

  test "abort, target ABA and relocation retire attempts without changing blocks or gear", ctx do
    tool = ItemStack.new("iron_pickaxe")
    seed(ctx, %{36 => tool})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    action(client, "abort_destroy_block", ctx.target, 2)
    wait(fn -> finished(pid) end)
    assert World.get_block(ctx.target) == Data.block("stone")
    assert Inventory.held(state(pid).inventory, :main) == tool

    action(client, "start_destroy_block", ctx.target, 3)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    :ok = World.set_block(ctx.target, Data.block("dirt"))
    :ok = World.set_block(ctx.target, Data.block("stone"))
    action(client, "stop_destroy_block", ctx.target, 4)
    wait(fn -> finished(pid) end)
    assert World.get_block(ctx.target) == Data.block("stone")
    assert Inventory.held(state(pid).inventory, :main) == tool
    assert World.item_snapshot(ctx.key) == %{}

    action(client, "start_destroy_block", ctx.target, 5)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    assert :ok = Connection.teleport(pid, %{ctx.pose | x: ctx.pose.x + 15})
    assert state(pid).mining == nil
    assert World.get_block(ctx.target) == Data.block("stone")
    assert World.item_snapshot(ctx.key) == %{}
  end

  test "a slower selected tool changes the whole elapsed prefix and an early stop finishes later",
       ctx do
    seed(ctx, %{36 => ItemStack.new("iron_pickaxe"), 37 => ItemStack.new("wooden_pickaxe")})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    Client.send_packet(client, :play, "set_carried_item", <<1::signed-16>>)
    wait(fn -> state(pid).inventory.selected == 1 end)
    action(client, "stop_destroy_block", ctx.target, 2)
    wait(fn -> match?(%{attempt: %{phase: :finishing}}, state(pid).mining) end)
    assert World.get_block(ctx.target) == Data.block("stone")
    wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
    assert state(pid).inventory.slots[36] == ItemStack.new("iron_pickaxe")
    assert state(pid).inventory.slots[37].components["minecraft:damage"] == 1
    assert map_size(World.item_snapshot(ctx.key)) == 1
  end

  test "bare-handed stone completes without a harvest drop and unsupported blocks stay intact",
       ctx do
    seed(ctx, %{})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    action(client, "stop_destroy_block", ctx.target, 2)
    wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end, 2500)
    assert World.item_snapshot(ctx.key) == %{}
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    obsidian = Data.item_block(Data.item("obsidian"))
    :ok = World.set_block(ctx.target, obsidian)
    action(client, "start_destroy_block", ctx.target, 3)
    await_ack(client, 3)
    wait(fn -> finished(pid) end)
    assert World.get_block(ctx.target) == obsidian
    assert World.item_snapshot(ctx.key) == %{}
  end

  test "a pending ordinary save holds ready mining without cancelling or resampling it", ctx do
    seed(ctx, %{36 => ItemStack.new("iron_pickaxe")})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    writer = state(pid).player_store
    :ok = :sys.suspend(writer)

    try do
      send(pid, :save_player)
      wait(fn -> state(pid).save_ref != nil end)
      action(client, "stop_destroy_block", ctx.target, 2)
      wait(fn -> match?(%{attempt: %{phase: :ready}}, state(pid).mining) end)
      assert World.get_block(ctx.target) == Data.block("stone")
      assert Inventory.held(state(pid).inventory, :main) == ItemStack.new("iron_pickaxe")
      assert state(pid).recovery == nil
    after
      :ok = :sys.resume(writer)
    end

    wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
    assert saved(ctx).transfer_sequence == 1
    assert drops(ctx) == [ItemStack.new("cobblestone")]
  end

  test "nearby peers receive changed cracks and competing attempts commit only one drop and wear",
       ctx do
    tool = ItemStack.new("iron_pickaxe")
    seed(ctx, %{36 => tool})
    peer = %{ctx | name: ctx.name <> "B", uuid: Connection.offline_uuid(ctx.name <> "B")}
    seed(peer, %{36 => tool})
    {client, pid} = login(ctx)
    {other, other_pid} = login(peer)
    action(client, "start_destroy_block", ctx.target, 1)
    {body, _other} = Client.await(other, :play, "block_destruction")
    {entity, body} = Wire.take_varint(body)
    {position, <<stage>>} = Wire.take_position(body)
    assert entity == state(pid).player.entity_id and position == ctx.target and stage in 0..9
    action(other, "start_destroy_block", ctx.target, 1)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(other_pid).mining) end)
    started = max(state(pid).mining.started, state(other_pid).mining.started)
    wait(fn -> state(pid).simulation_clock.tick - started >= 7 end)
    action(client, "stop_destroy_block", ctx.target, 2)
    action(other, "stop_destroy_block", ctx.target, 2)
    wait(fn -> finished(pid) and finished(other_pid) and World.get_block(ctx.target) == 0 end)

    damages =
      for owner <- [pid, other_pid],
          do:
            Map.get(
              Inventory.held(state(owner).inventory, :main).components,
              "minecraft:damage",
              0
            )

    assert Enum.sort(damages) == [0, 1]
    assert drops(ctx) == [ItemStack.new("cobblestone")]
    assert saved(ctx).outbox == nil and saved(peer).outbox == nil
  end

  test "death retires active digging and drops owned gear without mining the target", ctx do
    tool = ItemStack.new("iron_pickaxe")
    seed(ctx, %{36 => tool})
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> match?(%{attempt: %{phase: :active}}, state(pid).mining) end)
    assert {:ok, :dead} = Connection.fall_damage(pid, 1000.0)
    wait(fn -> state(pid).life_stage == :dead end)
    assert state(pid).mining == nil
    assert World.get_block(ctx.target) == Data.block("stone")
    assert drops(ctx) == [tool]
    assert saved(ctx).outbox == nil
  end

  test "a stalled reservation expires outside the socket owner and its retired callback is inert",
       ctx do
    seed(ctx, %{36 => ItemStack.new("iron_pickaxe")})
    {client, pid} = login(ctx)
    {:ok, {region, _} = owner} = World.existing_owner(ctx.key)
    :ok = :sys.suspend(region)

    try do
      action(client, "start_destroy_block", ctx.target, 1)
      job = wait(fn -> state(pid).mining_job end)
      ref = job.task.ref
      wait(fn -> state(pid).mining == nil and state(pid).mining_job == nil end)

      send(
        pid,
        {ref,
         {:ok,
          %{
            owner: owner,
            key: ctx.key,
            permit: <<0::128>>,
            expected: %{ctx.target => Data.block("stone")}
          }}}
      )

      assert state(pid).mining == nil and state(pid).recovery == nil
      assert Inventory.held(state(pid).inventory, :main) == ItemStack.new("iron_pickaxe")
    after
      :ok = :sys.resume(region)
    end

    assert World.get_block(ctx.target) == Data.block("stone")
    assert World.item_snapshot(ctx.key) == %{}
    assert Map.get(saved(ctx), :transfer_sequence, 0) == 0
  end

  test "a completed reservation cannot outlive its budget in a suspended player mailbox", ctx do
    seed(ctx, %{36 => ItemStack.new("iron_pickaxe")})
    {client, pid} = login(ctx)
    {:ok, {region, _}} = World.existing_owner(ctx.key)
    :ok = :sys.suspend(region)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> state(pid).mining_job != nil end)
    :ok = :sys.suspend(pid)

    try do
      :ok = :sys.resume(region)
      Process.sleep(300)
    after
      :ok = :sys.resume(pid)
    end

    wait(fn -> finished(pid) and state(pid).mining_job == nil end)
    assert World.get_block(ctx.target) == Data.block("stone")
    assert World.item_snapshot(ctx.key) == %{}
    assert Inventory.held(state(pid).inventory, :main) == ItemStack.new("iron_pickaxe")
    assert Map.get(saved(ctx), :transfer_sequence, 0) == 0
  end
end
