defmodule Valimc.ItemSimulationRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemTransfers, Region}

  setup :scope

  def scope(tags) do
    nonce = System.unique_integer([:positive])
    key = {60_000 + rem(nonce, 333) * 3, 2000}
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
    Valimc.TestDisk.write(base, key, :items, %{records: records, receipts: receipts})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)

    on_exit(fn ->
      for x <- (rx - 1)..(rx + 1),
          z <- (rz - 1)..(rz + 1),
          {pid, _} <- Valimc.TestWorld.registered({x, z}) do
        :sys.resume(pid)
        TestScope.kill(pid)
      end

      File.rm_rf(base)
    end)

    %{key: key, owner: owner, base: base, records: records, receipts: receipts}
  end

  def state(ctx), do: Valimc.TestRegion.section(ctx.owner)
  def entry(ctx), do: state(ctx).entities.store.entries |> Map.values() |> hd()

  # Owners tick only when stepped: advance every live owner around the test's
  # region one tick (items move within the tick, VMC-077l).
  def wait(ctx, fun, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      fun.() ||
        (
          step(ctx, 1)
          nil
        )
    end)
  end

  def step(ctx, ticks) do
    for key <- TestScope.neighborhood(ctx.key),
        {pid, _} <- Valimc.TestWorld.registered(key) do
      TestScope.simulate(pid, key)
      Region.step({pid, nil}, ticks)
    end

    :ok
  end

  @tag count: 256
  test "one owner advances every active item at its cadence", ctx do
    wait(ctx, fn ->
      Enum.all?(state(ctx).entities.store.entries, fn {_, e} -> e.entity.y < 67.8 end)
    end)

    entries = Map.values(state(ctx).entities.store.entries)
    assert length(entries) == 256
    assert length(Enum.uniq(Enum.map(entries, & &1.motion.age))) == 1
    assert Enum.all?(entries, &(&1.motion.age >= 3))
  end

  @tag edge: true, motion: %ItemMotionState{no_gravity: true}

  @tag motion: %ItemMotionState{age: 5998}
  test "despawn is durable and original source replay cannot recreate the item", ctx do
    wait(ctx, fn ->
      state(ctx).entities.store.entries == %{} and not Valimc.TestRegion.writing?(state(ctx))
    end)

    assert :ok = Region.flush(elem(ctx.owner, 0))

    saved = Valimc.TestDisk.read(ctx.base, ctx.key, :items)

    assert saved.records == [] and saved.receipts == ctx.receipts
    transfer = %{source: <<99::128>>, sequence: 1, records: ctx.records}
    assert {:ok, :already_applied} = Region.apply_item_transfer(ctx.owner, transfer)
    assert state(ctx).entities.store.entries == %{}
  end

  @tag edge: true, motion: %ItemMotionState{velocity: {0.3, 0.0, 0.0}, no_gravity: true}
end
