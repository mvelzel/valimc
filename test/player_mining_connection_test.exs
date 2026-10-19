defmodule Valimc.PlayerMiningConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
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

  defp seed(ctx, slots, block \\ Data.block("stone")) do
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
    :ok = World.set_block(ctx.target, block)
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
    unsupported = Data.item_block(Data.item("diamond_ore"))
    :ok = World.set_block(ctx.target, unsupported)
    action(client, "start_destroy_block", ctx.target, 3)
    await_ack(client, 3)
    wait(fn -> finished(pid) end)
    assert World.get_block(ctx.target) == unsupported
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

  test "live wet single and dry double slabs commit contained fluid, exact counts and one wear each",
       ctx do
    tool = %{
      ItemStack.new("diamond_axe")
      | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 10}}
    }

    seed(ctx, %{36 => tool})
    {client, pid} = login(ctx)

    for {{block, replacement}, sequence} <- Enum.with_index([{15179, 89}, {15182, 0}], 1) do
      :ok = World.set_block(ctx.target, block)
      action(client, "start_destroy_block", ctx.target, sequence)
      await_ack(client, sequence)
      wait(fn -> finished(pid) and World.get_block(ctx.target) == replacement end)
      assert saved(ctx).transfer_sequence == sequence and saved(ctx).outbox == nil

      assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] ==
               sequence
    end

    assert Enum.sort_by(drops(ctx), & &1.count) == [
             ItemStack.new("oak_slab"),
             ItemStack.new("oak_slab", 2)
           ]

    assert map_size(World.item_snapshot(ctx.key)) == 2
  end

  test "ordinary cubes use live tool rules, bookshelf counts and Silk Touch across reconnect",
       ctx do
    enchant = fn name, levels ->
      %{ItemStack.new(name) | components: %{"minecraft:enchantments" => levels}}
    end

    seed(ctx, %{
      36 => enchant.("diamond_pickaxe", %{"minecraft:efficiency" => 5}),
      37 => enchant.("diamond_axe", %{"minecraft:efficiency" => 5}),
      38 => enchant.("diamond_axe", %{"minecraft:efficiency" => 5, "minecraft:silk_touch" => 1})
    })

    {client, pid} = login(ctx)

    cases = [
      {"polished_granite", 0, ItemStack.new("polished_granite")},
      {"spruce_planks", 1, ItemStack.new("spruce_planks")},
      {"iron_block", 0, ItemStack.new("iron_block")},
      {"red_concrete", 0, ItemStack.new("red_concrete")},
      {"crafting_table", 1, ItemStack.new("crafting_table")},
      {"bookshelf", 1, ItemStack.new("book", 3)},
      {"bookshelf", 2, ItemStack.new("bookshelf")}
    ]

    for {{name, slot, _drop}, sequence} <- Enum.with_index(cases, 1) do
      Client.send_packet(client, :play, "set_carried_item", <<slot::signed-16>>)
      wait(fn -> state(pid).inventory.selected == slot end)
      :ok = World.set_block(ctx.target, Data.item_block(Data.item(name)))
      action(client, "start_destroy_block", ctx.target, sequence * 2 - 1)
      await_ack(client, sequence * 2 - 1)
      action(client, "stop_destroy_block", ctx.target, sequence * 2)
      await_ack(client, sequence * 2)
      wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
      assert saved(ctx).transfer_sequence == sequence and saved(ctx).outbox == nil
    end

    expected = cases |> Enum.map(&elem(&1, 2)) |> Enum.sort_by(& &1.item_id)
    assert Enum.sort_by(drops(ctx), & &1.item_id) == expected

    for {slot, damage} <- [{36, 3}, {37, 3}, {38, 1}] do
      assert state(pid).inventory.slots[slot].components["minecraft:damage"] == damage
    end

    inventory = state(pid).inventory
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, pid} = login(ctx)
    assert state(pid).inventory.slots == inventory.slots
    assert state(pid).inventory.selected == inventory.selected
    assert state(pid).inventory.carried == inventory.carried
    assert saved(ctx).transfer_sequence == 7 and saved(ctx).outbox == nil
    assert Enum.sort_by(drops(ctx), & &1.item_id) == expected
    assert World.get_block(ctx.target) == 0
  end

  test "wrong-tier ordinary mining wears its tool without loot and excluded blocks do nothing",
       ctx do
    tool = %{
      ItemStack.new("wooden_pickaxe")
      | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 5}}
    }

    seed(ctx, %{36 => tool})
    {client, pid} = login(ctx)
    :ok = World.set_block(ctx.target, Data.item_block(Data.item("iron_block")))
    action(client, "start_destroy_block", ctx.target, 1)
    await_ack(client, 1)
    action(client, "stop_destroy_block", ctx.target, 2)
    await_ack(client, 2)
    wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
    assert drops(ctx) == []
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    worn = Inventory.held(state(pid).inventory, :main)
    assert worn.components["minecraft:damage"] == 1

    for {name, sequence} <-
          Enum.with_index(~w(bedrock diamond_ore oak_stairs), 3) do
      block = Data.item_block(Data.item(name))
      :ok = World.set_block(ctx.target, block)
      action(client, "start_destroy_block", ctx.target, sequence)
      await_ack(client, sequence)
      wait(fn -> finished(pid) and state(pid).mining_job == nil end)
      assert World.get_block(ctx.target) == block
      assert Inventory.held(state(pid).inventory, :main) == worn
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      assert drops(ctx) == []
    end
  end

  test "physical empty wet chest mining durably removes metadata and drops exactly its block",
       ctx do
    tool = %{
      ItemStack.new("diamond_axe")
      | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 255}}
    }

    seed(ctx, %{36 => tool})
    :ok = World.set_block(ctx.target, 89)
    {:ok, owner} = World.owner(ctx.key)
    {:ok, observed} = Valimc.World.Region.observe_blocks(owner, [ctx.target])
    {:ok, chest} = Valimc.Physics.ChestPlacement.single_state(0.0, 89)
    {:ok, batch} = Valimc.World.BlockBatch.prepare(%{ctx.target => chest})

    assert {:ok, _} =
             Valimc.World.Region.place_block(
               owner,
               observed.revision,
               batch,
               System.monotonic_time(:millisecond) + 250
             )

    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> finished(pid) and World.get_block(ctx.target) == 89 end)
    assert drops(ctx) == [ItemStack.new("chest")]
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1

    {:ok, containers} =
      Valimc.World.Containers.decode(
        File.read!(Valimc.World.Store.container_path(ctx.base, ctx.key)),
        ctx.key
      )

    assert containers.entries == %{} and containers.sequence == 2 and containers.receipts == %{}
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, fresh_pid} = login(ctx)
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    assert Inventory.held(state(fresh_pid).inventory, :main).components["minecraft:damage"] == 1
    assert drops(ctx) == [ItemStack.new("chest")]
  end

  for kind <- [:furnace, :smoker, :blast_furnace] do
    test "empty #{kind} TCP mining retires metadata and releases exactly its stock block", ctx do
      kind = unquote(kind)

      tool = %{
        ItemStack.new("diamond_pickaxe")
        | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 255}}
      }

      seed(ctx, %{36 => tool}, 0)
      {:ok, owner} = World.owner(ctx.key)
      {:ok, observed} = Valimc.World.Region.observe_blocks(owner, [ctx.target])
      {:ok, block} = Valimc.Physics.CookingBlocks.placement(kind, 0.0)
      {:ok, batch} = Valimc.World.BlockBatch.prepare(%{ctx.target => block})

      assert {:ok, _} =
               Valimc.World.Region.place_block(
                 owner,
                 observed.revision,
                 batch,
                 System.monotonic_time(:millisecond) + 250
               )

      {client, pid} = login(ctx)
      action(client, "start_destroy_block", ctx.target, 1)
      wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
      assert drops(ctx) == [ItemStack.new(Atom.to_string(kind))]
      assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1

      {:ok, containers} =
        Valimc.World.Containers.decode(
          File.read!(Valimc.World.Store.container_path(ctx.base, ctx.key)),
          ctx.key
        )

      assert containers.entries == %{} and containers.sequence == 2 and containers.receipts == %{}
      Client.close(client)
      wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
      {_fresh, fresh_pid} = login(ctx)
      assert Inventory.held(state(fresh_pid).inventory, :main).components["minecraft:damage"] == 1
      assert drops(ctx) == [ItemStack.new(Atom.to_string(kind))]
    end
  end

  for kind <- [:furnace, :smoker, :blast_furnace] do
    test "occupied #{kind} TCP mining rejects durably without wearing tools or releasing contents",
         ctx do
      alias Valimc.World.{Containers, Store}
      kind = unquote(kind)

      tool = %{
        ItemStack.new("diamond_pickaxe")
        | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 255}}
      }

      seed(ctx, %{36 => tool}, 0)
      {:ok, {region, _}} = World.existing_owner(ctx.key)
      :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, region)

      {:ok, containers, entry} =
        Containers.create_cooking(%Containers{}, ctx.key, ctx.target, kind)

      cooking = %Valimc.Cooking{slots: {ItemStack.new("raw_iron"), nil, nil}}

      {:ok, containers, _} =
        Containers.replace_cooking(containers, ctx.target, entry.revision, cooking, %{})

      {:ok, bytes} = Containers.encode(ctx.key, containers)
      File.write!(Store.container_path(ctx.base, ctx.key), bytes)
      {:ok, block} = Valimc.Physics.CookingBlocks.placement(kind, 0.0)
      {rx, rz} = ctx.key

      File.write!(
        Path.join(ctx.base, "r.#{rx}.#{rz}.etf"),
        :erlang.term_to_binary({:valimc_region, 1, %{ctx.target => block}})
      )

      {client, pid} = login(ctx)
      action(client, "start_destroy_block", ctx.target, 1)

      wait(fn ->
        finished(pid) and saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
      end)

      assert World.get_block(ctx.target) == block
      assert Inventory.held(state(pid).inventory, :main) == tool
      assert drops(ctx) == []

      {:ok, restored} =
        Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

      assert restored == containers
    end
  end

  test "filled chest TCP mining consumes only tool wear while its owner releases exact stored patches",
       ctx do
    alias Valimc.World.{Containers, Region, Store}

    tool = %{
      ItemStack.new("diamond_axe")
      | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 255}}
    }

    stored = %{
      ItemStack.new("diamond", 3)
      | components: %{"minecraft:custom_name" => {:string, "Saved diamonds"}}
    }

    {:ok, chest} = Valimc.Physics.ChestPlacement.single_state(0.0, 0)
    {:ok, containers, entry} = Containers.create(%Containers{}, ctx.key, ctx.target, 3)

    {:ok, containers, _} =
      Containers.replace(containers, ctx.target, entry.revision, put_elem(entry.slots, 0, stored))

    typed = %{ctx.uuid => %{sequence: 5, digest: <<7::256>>}}
    {:ok, bytes} = Containers.encode(ctx.key, %{containers | receipts: typed})
    File.mkdir_p!(ctx.base)
    File.write!(Store.container_path(ctx.base, ctx.key), bytes)
    {rx, rz} = ctx.key

    File.write!(
      Path.join(ctx.base, "r.#{rx}.#{rz}.etf"),
      :erlang.term_to_binary({:valimc_region, 1, %{ctx.target => chest}})
    )

    seed(ctx, %{36 => tool}, chest)
    {client, pid} = login(ctx)
    action(client, "start_destroy_block", ctx.target, 1)
    wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)

    assert Enum.sort_by(drops(ctx), & &1.item_id) ==
             Enum.sort_by([ItemStack.new("chest"), stored], & &1.item_id)

    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    assert Inventory.held(state(pid).inventory, :main).components["minecraft:damage"] == 1

    {:ok, containers} =
      Containers.decode(File.read!(Store.container_path(ctx.base, ctx.key)), ctx.key)

    assert containers.entries == %{} and containers.sequence == 3 and containers.receipts == typed
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, fresh_pid} = login(ctx)
    assert saved(ctx).transfer_sequence == 1 and saved(ctx).outbox == nil
    assert Inventory.held(state(fresh_pid).inventory, :main).components["minecraft:damage"] == 1
    {:ok, owner} = World.item_owner(ctx.key)
    assert {:ok, {_, receipt}} = Region.item_transfer_receipt(owner, ctx.uuid)
    assert receipt.sequence == 1

    assert Enum.sort_by(drops(ctx), & &1.item_id) ==
             Enum.sort_by([ItemStack.new("chest"), stored], & &1.item_id)
  end

  test "live random cubes persist bounded sampled loot and original-tool Silk Touch", ctx do
    tool = %{
      ItemStack.new("diamond_pickaxe")
      | components: %{
          "minecraft:enchantments" => %{"minecraft:efficiency" => 10, "minecraft:fortune" => 3}
        }
    }

    silk = %{
      tool
      | components: %{
          "minecraft:enchantments" => %{
            "minecraft:efficiency" => 10,
            "minecraft:fortune" => 255,
            "minecraft:silk_touch" => 1
          }
        }
    }

    seed(ctx, %{36 => tool, 37 => silk})
    {client, pid} = login(ctx)

    cases = [
      {"melon", 0, "melon_slice", 3..9},
      {"glowstone", 0, "glowstone_dust", 2..4},
      {"sea_lantern", 0, "prismarine_crystals", 2..5},
      {"gilded_blackstone", 0, "gold_nugget", 2..5},
      {"melon", 1, "melon", 1..1},
      {"gilded_blackstone", 1, "gilded_blackstone", 1..1}
    ]

    for {{name, slot, drop, count}, sequence} <- Enum.with_index(cases, 1) do
      Client.send_packet(client, :play, "set_carried_item", <<slot::signed-16>>)
      wait(fn -> state(pid).inventory.selected == slot end)
      :ok = World.set_block(ctx.target, Data.item_block(Data.item(name)))
      action(client, "start_destroy_block", ctx.target, sequence * 2 - 1)
      await_ack(client, sequence * 2 - 1)
      action(client, "stop_destroy_block", ctx.target, sequence * 2)
      await_ack(client, sequence * 2)
      wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
      assert saved(ctx).transfer_sequence == sequence and saved(ctx).outbox == nil
      assert Enum.count(drops(ctx), &(&1.item_id == Data.item(drop) and &1.count in count)) == 1
    end

    before = drops(ctx)
    assert state(pid).inventory.slots[36].components["minecraft:damage"] == 4
    assert state(pid).inventory.slots[37].components["minecraft:damage"] == 2
    Client.close(client)
    wait(fn -> Registry.lookup(Valimc.PlayerStoreRegistry, ctx.uuid) == [] end)
    {_fresh, pid} = login(ctx)
    assert drops(ctx) == before
    assert saved(ctx).transfer_sequence == 6 and saved(ctx).outbox == nil
    assert state(pid).inventory.slots[36].components["minecraft:damage"] == 4
    assert state(pid).inventory.slots[37].components["minecraft:damage"] == 2
  end

  test "live pillar mining handles horizontal logs and deepslate with native tool and loot rules",
       ctx do
    enchant = fn name ->
      %{
        ItemStack.new(name)
        | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 10}}
      }
    end

    seed(ctx, %{36 => enchant.("diamond_axe"), 37 => enchant.("diamond_pickaxe")})
    {client, pid} = login(ctx)

    for {{block, slot}, sequence} <-
          Enum.with_index([{139, 0}, {140, 0}, {141, 0}, {33773, 1}], 1) do
      Client.send_packet(client, :play, "set_carried_item", <<slot::signed-16>>)
      wait(fn -> state(pid).inventory.selected == slot end)
      :ok = World.set_block(ctx.target, block)
      action(client, "start_destroy_block", ctx.target, sequence * 2 - 1)
      await_ack(client, sequence * 2 - 1)
      action(client, "stop_destroy_block", ctx.target, sequence * 2)
      await_ack(client, sequence * 2)
      wait(fn -> finished(pid) and World.get_block(ctx.target) == 0 end)
      assert saved(ctx).transfer_sequence == sequence and saved(ctx).outbox == nil
    end

    assert Enum.sort_by(drops(ctx), & &1.item_id) ==
             Enum.sort_by(
               [
                 ItemStack.new("oak_log"),
                 ItemStack.new("oak_log"),
                 ItemStack.new("oak_log"),
                 ItemStack.new("cobbled_deepslate")
               ],
               & &1.item_id
             )

    assert state(pid).inventory.slots[36].components["minecraft:damage"] == 3
    assert state(pid).inventory.slots[37].components["minecraft:damage"] == 1
  end
end
