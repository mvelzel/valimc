defmodule Valimc.ItemSimulationRegionTest do
  use ExUnit.Case, async: false
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{ItemLedger, ItemRecords, ItemTransfers, Region, Store}

  setup tags do
    nonce = System.unique_integer([:positive])
    key = {60_000 + rem(nonce, 1000), 2000}
    base = Path.join(System.tmp_dir!(), "valimc-item-simulation-#{nonce}")
    previous = {Valimc.config(:world_path), Valimc.config(:item_simulation)}
    Application.put_env(:valimc, :world_path, base)
    Application.put_env(:valimc, :item_simulation, true)
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
    File.write!(Store.item_path(base, key), bytes)
    {:ok, owner} = World.item_owner(key)

    on_exit(fn ->
      Application.put_env(:valimc, :item_simulation, elem(previous, 1))

      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, {x, z}) do
        :sys.resume(pid)
        DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      end

      Application.put_env(:valimc, :world_path, elem(previous, 0))
      File.rm_rf!(base)
    end)

    %{key: key, owner: owner, base: base, records: records, receipts: receipts}
  end

  defp state(ctx), do: :sys.get_state(elem(ctx.owner, 0)).resource
  defp entry(ctx), do: state(ctx).items.entries |> Map.values() |> hd()

  defp wait(fun, count \\ 600) do
    if value = fun.(),
      do: value,
      else:
        (
          assert count > 0
          Process.sleep(5)
          wait(fun, count - 1)
        )
  end

  test "owned cadence falls, sleeps without geometry work, ages, and wakes on support edits",
       ctx do
    wait(fn -> map_size(state(ctx).item_resting) == 1 end)
    assert entry(ctx).entity.y == 64.0 and entry(ctx).motion.on_ground
    age = entry(ctx).motion.age
    jobs = Map.get(Valimc.Metrics.snapshot(), :item_simulation_jobs, 0)
    Process.sleep(160)
    assert entry(ctx).motion.age > age
    assert Map.get(Valimc.Metrics.snapshot(), :item_simulation_jobs, 0) == jobs
    pos = hd(ctx.records)
    :ok = World.set_block({floor(pos.x), 63, floor(pos.z)}, 0)
    wait(fn -> entry(ctx).entity.y < 63.9 end)
    assert entry(ctx).motion.age > age
  end

  @tag count: 256
  test "one owner advances every active item at its cadence", ctx do
    wait(fn -> Enum.all?(state(ctx).items.entries, fn {_, e} -> e.entity.y < 67.8 end) end)
    entries = Map.values(state(ctx).items.entries)
    assert length(entries) == 256
    assert length(Enum.uniq(Enum.map(entries, & &1.motion.age))) == 1
    assert Enum.all?(entries, &(&1.motion.age >= 3))
  end

  @tag edge: true, motion: %ItemMotionState{no_gravity: true}
  test "unavailable neighbor geometry does not freeze age and pickup-delay clocks", ctx do
    neighbor = {elem(ctx.key, 0) + 1, elem(ctx.key, 1)}
    {:ok, {pid, _}} = World.item_owner(neighbor)
    :sys.suspend(pid)

    try do
      age = entry(ctx).motion.age
      wait(fn -> entry(ctx).motion.age >= age + 7 end)
      assert entry(ctx).entity.y == 68.0
      assert state(ctx).item_resting == %{}
    after
      :sys.resume(pid)
    end
  end

  @tag motion: %ItemMotionState{age: 5998}
  test "despawn is durable and original source replay cannot recreate the item", ctx do
    wait(fn -> state(ctx).items.entries == %{} and state(ctx).item_pending == nil end)

    assert {:ok, saved} =
             ItemLedger.decode(File.read!(Store.item_path(ctx.base, ctx.key)), ctx.key)

    assert saved.records == [] and saved.receipts == ctx.receipts
    transfer = %{source: <<99::128>>, sequence: 1, records: ctx.records}
    assert {:ok, :already_applied} = Region.apply_item_transfer(ctx.owner, transfer)
    assert state(ctx).items.entries == %{}
  end

  @tag edge: true, motion: %ItemMotionState{velocity: {0.3, 0.0, 0.0}, no_gravity: true}
  test "automatic motion crosses owners and conserves the source receipt", ctx do
    destination = {elem(ctx.key, 0) + 1, elem(ctx.key, 1)}
    {:ok, {pid, _} = owner} = World.item_owner(destination)

    wait(fn ->
      state(ctx).items.entries == %{} and state(ctx).items.ledger.outgoing == nil and
        map_size(:sys.get_state(pid).resource.items.entries) == 1
    end)

    assert {:ok, handle} = Region.find_item(owner, <<1::128>>)
    current = :sys.get_state(pid).resource
    assert current.items.ledger.generations == %{<<1::128>> => 1}
    assert current.items.entries[elem(handle, 2)].entity.x > elem(destination, 0) * 128
    assert current.items.entries[elem(handle, 2)].motion.age >= 1
    assert state(ctx).item_receipts == ctx.receipts and state(ctx).items.ledger.sequence == 1
  end
end
