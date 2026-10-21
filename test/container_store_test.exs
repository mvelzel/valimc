defmodule Valimc.ContainerStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.Protocol.ItemStack

  alias Valimc.{
    Cooking,
    GameMode,
    Inventory,
    PlayerContainerTransfers,
    PlayerFood,
    PlayerSnapshot
  }

  alias Valimc.World.{Containers, ContainerTransfers, CookingOrbs, Store}

  setup do
    nonce = System.unique_integer([:positive])
    key = {900, nonce}
    base = Path.join(System.tmp_dir!(), "valimc-containers-#{nonce}")
    TestScope.isolate(key, world_path: base)
    span = Valimc.config(:region_size) * 16
    position = {900 * span, 64, nonce * span}
    {:ok, empty, entry} = Containers.create(%Containers{}, key, position, 3)
    slots = put_elem(entry.slots, 26, ItemStack.new("diamond", 3))
    {:ok, filled, _} = Containers.replace(empty, position, entry.revision, slots)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key, base: base, position: position, filled: filled, empty: empty}
  end

  test "queued commits share one frame and one datasync and are acknowledged in order", ctx do
    {:ok, writer, lease} = Store.open(ctx.key)
    dir = Store.log_dir(ctx.base, ctx.key)
    {:ok, %{frames: before}} = Valimc.World.RegionLog.read(dir)
    {x, _, z} = ctx.position
    epoch = make_ref()
    :sys.suspend(writer)

    sent =
      for {containers, i} <- Enum.with_index([ctx.empty, ctx.filled, ctx.empty, ctx.filled]) do
        token = make_ref()
        Store.commit_containers(writer, lease, containers, {self(), epoch}, token)
        Store.snapshot(writer, lease, %{{x + i, 64, z} => 1}, {self(), epoch}, i)
        token
      end

    :sys.resume(writer)

    for {token, i} <- Enum.with_index(sent) do
      assert_receive {:resource, ^epoch, message}
      assert message == {:containers_saved, writer, token, :ok}
      assert_receive {:resource, ^epoch, {:saved, ^writer, ^i, :ok}}
    end

    {:ok, %{frames: frames}} = Valimc.World.RegionLog.read(dir)
    assert length(frames) == length(before) + 1
    assert {:ok, ctx.filled} == Store.load_containers(writer)
    assert Map.take(Store.load(writer), for(i <- 0..3, do: {x + i, 64, z})) |> map_size() == 4
  end

  test "checkpoints run beside appends, prune covered segments and recover exactly", ctx do
    Valimc.TestScope.isolate(ctx.key, store_checkpoint_bytes: 1)
    {:ok, writer, lease} = Store.open(ctx.key)
    dir = Store.log_dir(ctx.base, ctx.key)
    {x, _, z} = ctx.position

    for i <- 1..20 do
      assert :ok =
               Store.flush_containers(
                 writer,
                 lease,
                 if(rem(i, 2) == 0, do: ctx.filled, else: ctx.empty)
               )

      Store.snapshot(writer, lease, %{{x + i, 64, z} => 1}, {self(), make_ref()}, i)
    end

    assert :ok = Store.flush_containers(writer, lease, ctx.filled)
    wait_checkpointed(writer)
    files = File.ls!(dir)
    assert Enum.count(files, &String.starts_with?(&1, "ckpt.")) == 1
    assert Enum.count(files, &String.starts_with?(&1, "log.")) <= 2
    assert :ok = Store.close(writer, lease)
    {:ok, writer, _lease} = Store.open(ctx.key)
    assert Store.load_containers(writer) == {:ok, ctx.filled}
    assert map_size(Map.take(Store.load(writer), for(i <- 1..20, do: {x + i, 64, z}))) == 20
  end

  defp wait_checkpointed(writer, _budget \\ nil),
    do: Valimc.TestWait.until(fn -> :sys.get_state(writer).checkpointing == nil end)

  test "malformed proposals do not replace durable contents and corrupt files are not treated as empty",
       ctx do
    {:ok, writer, lease} = Store.open(ctx.key)
    assert :ok = Store.flush_containers(writer, lease, ctx.filled)
    before = Valimc.TestDisk.read(ctx.base, ctx.key, :containers)

    assert {:error, :invalid_container_snapshot} =
             Store.flush_containers(writer, lease, %{ctx.filled | sequence: 0})

    assert Valimc.TestDisk.read(ctx.base, ctx.key, :containers) == before
    assert :ok = Store.close(writer, lease)

    for corrupt <- [<<>>, :binary.copy(<<0>>, Containers.max_bytes() + 1)] do
      Valimc.TestDisk.write(ctx.base, ctx.key, :containers, corrupt)
      {:ok, writer, lease} = Store.open(ctx.key)
      assert {:error, :invalid_container_snapshot} = Store.load_containers(writer)
      assert :ok = Store.close(writer, lease)
    end
  end

  test "earned output, recipe credit and pending award recover together before player sealing",
       ctx do
    source = <<83::128>>
    recipe = "minecraft:iron_ingot_from_smelting_raw_iron"
    {x, y, z} = ctx.position
    pose = %{x: x + 0.5, y: y * 1.0, z: z + 0.5, yaw: 0.0, pitch: 0.0}

    {:ok, before, entry} =
      Containers.create_cooking(%Containers{}, ctx.key, ctx.position, :furnace)

    cooking = %Cooking{slots: {nil, nil, ItemStack.new("iron_ingot", 4)}, total: 200}

    {:ok, before, entry} =
      Containers.replace_cooking(before, ctx.position, entry.revision, cooking, %{recipe => 7})

    {:ok, before, _} = ContainerTransfers.reserve(before, source)

    request = %{
      source: source,
      sequence: 1,
      permit: <<84::128>>,
      position: ctx.position,
      revision: entry.revision,
      kind: :furnace,
      slots: cooking.slots,
      inventory: %Inventory{},
      action: :pickup,
      slot: 2,
      button: 1
    }

    snapshot = %{
      pose: pose,
      inventory: %Inventory{},
      game_mode: GameMode.new(:survival),
      flying: false,
      fall_distance: 0.0,
      frozen_ticks: 0,
      velocity: {0.0, 0.0, 0.0},
      health: %{value: 20.0, hurt_ticks: 0, death_ticks: 0},
      last_death: nil,
      air_supply: 300,
      food: %PlayerFood{},
      fire_ticks: -20,
      effects: %{},
      absorption: 0.0,
      transfer_sequence: 0,
      outbox: nil
    }

    intent = %{kind: :container, key: ctx.key, request: request}
    assert {:ok, pending} = PlayerContainerTransfers.prepare(source, 0, snapshot, intent)
    assert {:ok, bytes} = PlayerSnapshot.encode(source, pending)
    assert {:ok, restored_player} = PlayerSnapshot.decode(bytes, source)
    context = %{position: {pose.x, pose.y, pose.z}, draws: %{recipe => 0}}

    assert {:ok, %{result: :applied, containers: committed}} =
             ContainerTransfers.plan_cooking_award(
               before,
               ctx.key,
               restored_player.outbox.request,
               true,
               context
             )

    {:ok, writer, lease} = Store.open(ctx.key)
    assert :ok = Store.flush_containers(writer, lease, before)
    epoch = make_ref()
    token = make_ref()
    Store.commit_containers(writer, lease, committed, {self(), epoch}, token)
    assert {:ok, ^committed} = Store.load_containers(writer)
    monitor = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}
    assert {:ok, replacement, next_lease} = Store.open(ctx.key)
    assert {:ok, ^committed} = Store.load_containers(replacement)

    assert {:ok, %{result: :already_applied, containers: ^committed}} =
             ContainerTransfers.plan_cooking_award(
               committed,
               ctx.key,
               request,
               false,
               :new_randomness
             )

    assert {:ok, sealed} =
             PlayerContainerTransfers.resolve(source, restored_player, committed.receipts[source])

    assert sealed.inventory.carried == ItemStack.new("iron_ingot", 2) and sealed.outbox == nil

    assert elem(committed.entries[ctx.position].cooking.slots, 2) ==
             ItemStack.new("iron_ingot", 2)

    assert committed.entries[ctx.position].recipes == %{}
    [record] = Map.values(committed.pending_awards)
    assert record.award.experience == 5 and record.award.draws_used == %{recipe => 0}
    assert {:error, :stale_store_lease} = Store.flush_containers(replacement, lease, before)
    assert {:ok, ^committed} = Store.load_containers(replacement)
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, :ok}}

    # Pure materialization is still unused by live exchanges. A leased writer
    # commits the marker and all orb groups together, before any effect is allowed.
    [id] = Map.keys(committed.pending_awards)
    assert {:ok, materialized, :materialized} = CookingOrbs.materialize(committed, ctx.key, id)
    token = make_ref()
    Store.commit_containers(replacement, next_lease, materialized, {self(), epoch}, token)
    assert {:ok, ^materialized} = Store.load_containers(replacement)
    monitor = Process.monitor(replacement)
    Process.exit(replacement, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^replacement, :killed}
    assert {:ok, recovered, recovered_lease} = Store.open(ctx.key)
    assert {:ok, ^materialized} = Store.load_containers(recovered)

    assert {:ok, ^materialized, :already_materialized} =
             CookingOrbs.materialize(materialized, ctx.key, id)

    assert materialized.pending_awards === committed.pending_awards
    assert materialized.receipts === committed.receipts
    assert Enum.sum(for {_, orb} <- materialized.cooking_orbs[id], do: orb.value * orb.count) == 5
    assert {:error, :stale_store_lease} = Store.flush_containers(recovered, next_lease, committed)
    assert {:ok, ^materialized} = Store.load_containers(recovered)
    assert_receive {:resource, ^epoch, {:containers_saved, ^replacement, ^token, :ok}}
    assert :ok = Store.close(recovered, recovered_lease)
  end
end
