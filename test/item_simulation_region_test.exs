defmodule Valimc.ItemSimulationRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{ItemLedger, ItemRecords, ItemTransfers, Region}

  setup :scope

  def scope(tags) do
    nonce = System.unique_integer([:positive])
    key = {60_000 + rem(nonce, 1000), 2000}
    base = Path.join(System.tmp_dir!(), "valimc-item-simulation-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    File.mkdir_p!(base)
    {rx, rz} = key
    motion = Map.get(tags, :motion, %ItemMotionState{})
    count = Map.get(tags, :count, 1)

    records =
      for n <- 1..count do
        x = if Map.get(tags, :edge, false), do: 127.85, else: 4.5 + rem(n - 1, 16) * 4

        %{
          uuid: <<n::128>>,
          x: rx * 128 + x,
          y: 68.0,
          z: rz * 128 + 4.5 + div(n - 1, 16) * 4,
          stack: ItemStack.new("stone", 3),
          motion: motion
        }
      end

    {:ok, digest} =
      ItemTransfers.digest(key, %{
        source: <<99::128>>,
        sequence: 1,
        records: Enum.take(records, 1)
      })

    receipts = %{<<99::128>> => %{sequence: 1, digest: digest}}
    {:ok, bytes} = ItemRecords.encode(key, records, receipts)
    Valimc.TestDisk.write(base, key, :items, bytes)
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}) do
        :sys.resume(pid)
        TestScope.kill(pid)
      end

      File.rm_rf(base)
    end)

    %{key: key, owner: owner, base: base, records: records, receipts: receipts}
  end

  def state(ctx), do: :sys.get_state(elem(ctx.owner, 0)).resource
  def entry(ctx), do: state(ctx).items.entries |> Map.values() |> hd()

  # Owners tick only when stepped: advance every live owner around the test's
  # region one tick at a time (simulation workers report in between).
  def wait(ctx, fun, count \\ 600) do
    if value = fun.() do
      value
    else
      assert count > 0
      step(ctx, 1)
      Process.sleep(1)
      wait(ctx, fun, count - 1)
    end
  end

  def step(ctx, ticks) do
    for key <- TestScope.neighborhood(ctx.key),
        {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
        do: Region.step({pid, nil}, ticks)

    :ok
  end

  @tag count: 256
  test "one owner advances every active item at its cadence", ctx do
    wait(ctx, fn -> Enum.all?(state(ctx).items.entries, fn {_, e} -> e.entity.y < 67.8 end) end)
    entries = Map.values(state(ctx).items.entries)
    assert length(entries) == 256
    assert length(Enum.uniq(Enum.map(entries, & &1.motion.age))) == 1
    assert Enum.all?(entries, &(&1.motion.age >= 3))
  end

  @tag edge: true, motion: %ItemMotionState{no_gravity: true}
  test "unavailable neighbor geometry does not freeze age and pickup-delay clocks", ctx do
    neighbor = {elem(ctx.key, 0) + 1, elem(ctx.key, 1)}
    {:ok, {pid, _}} = World.item_owner(neighbor)

    # Published reads of the neighbor fail (foreign epoch) while it keeps running.
    :sys.replace_state(pid, fn state ->
      :ets.insert(state.resource.item_publication, {:block_fence, make_ref(), 0})
      state
    end)

    age = entry(ctx).motion.age
    wait(ctx, fn -> entry(ctx).motion.age >= age + 7 end)
    assert entry(ctx).entity.y == 68.0
    assert state(ctx).item_resting == %{}
  end

  @tag motion: %ItemMotionState{age: 5998}
  test "despawn is durable and original source replay cannot recreate the item", ctx do
    wait(ctx, fn ->
      state(ctx).items.entries == %{} and not Valimc.TestRegion.writing?(state(ctx))
    end)

    assert {:ok, saved} =
             ItemLedger.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :items), ctx.key)

    assert saved.records == [] and saved.receipts == ctx.receipts
    transfer = %{source: <<99::128>>, sequence: 1, records: ctx.records}
    assert {:ok, :already_applied} = Region.apply_item_transfer(ctx.owner, transfer)
    assert state(ctx).items.entries == %{}
  end

  @tag edge: true, motion: %ItemMotionState{velocity: {0.3, 0.0, 0.0}, no_gravity: true}
  test "automatic motion crosses owners and conserves the source receipt", ctx do
    destination = {elem(ctx.key, 0) + 1, elem(ctx.key, 1)}
    {:ok, {pid, _} = owner} = World.item_owner(destination)

    wait(ctx, fn ->
      state(ctx).items.entries == %{} and state(ctx).items.ledger.outgoing == nil and
        map_size(Valimc.TestConn.state(pid).resource.items.entries) == 1
    end)

    assert {:ok, handle} = Region.find_item(owner, <<1::128>>)
    current = Valimc.TestConn.state(pid).resource
    assert current.items.ledger.generations == %{<<1::128>> => 1}
    assert current.items.entries[elem(handle, 2)].entity.x > elem(destination, 0) * 128
    assert current.items.entries[elem(handle, 2)].motion.age >= 1
    assert state(ctx).item_receipts == ctx.receipts and state(ctx).items.ledger.sequence == 1
  end
end

defmodule Valimc.ItemSimulationRegionTest.Serial do
  use ExUnit.Case, async: false
  # Serial: asserts deltas of global Metrics counters other owners also bump.
  import Valimc.ItemSimulationRegionTest, only: [entry: 1, state: 1, step: 2, wait: 2]
  alias Valimc.World

  setup {Valimc.ItemSimulationRegionTest, :scope}

  test "owned cadence falls, sleeps without geometry work, ages, and wakes on support edits",
       ctx do
    wait(ctx, fn -> map_size(state(ctx).item_resting) == 1 end)
    assert entry(ctx).entity.y == 64.0 and entry(ctx).motion.on_ground
    age = entry(ctx).motion.age
    jobs = Map.get(Valimc.Metrics.snapshot(), :item_simulation_jobs, 0)
    step(ctx, 3)
    assert entry(ctx).motion.age > age
    assert Map.get(Valimc.Metrics.snapshot(), :item_simulation_jobs, 0) == jobs
    pos = hd(ctx.records)
    :ok = World.set_block({floor(pos.x), 63, floor(pos.z)}, 0)
    wait(ctx, fn -> entry(ctx).entity.y < 63.9 end)
    assert entry(ctx).motion.age > age
  end
end
