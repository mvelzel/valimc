defmodule Valimc.CookingRegionRuntimeTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{Cooking, ItemMotionState}
  alias Valimc.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Blocks, Containers, RegionData}

  setup :scope

  def scope(_context) do
    nonce = System.unique_integer([:positive])
    key = {86_000 + rem(nonce, 3_333) * 3, 1992}
    {rx, rz} = key
    position = {rx * 128 + 40, 64, rz * 128 + 40}
    base = Path.join(System.tmp_dir!(), "valimc-cooking-owned-#{nonce}")
    TestScope.isolate(key, world_path: base, cooking_simulation: true)
    File.mkdir_p!(base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, unlit} = CookingBlocks.placement(:furnace, 0.0)
    {:ok, lit} = CookingBlocks.lit(unlit, true)
    %{key: key, base: base, position: position, unlit: unlit, lit: lit}
  end

  def seed(ctx, cooking, lit \\ true) do
    {:ok, containers, entry} =
      Containers.create_cooking(%Containers{}, ctx.key, ctx.position, :furnace)

    {:ok, containers, _} =
      Containers.replace_cooking(containers, ctx.position, entry.revision, cooking, %{})

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)

    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, %{
      ctx.position => if(lit, do: ctx.lit, else: ctx.unlit)
    })

    RegionData.load(ctx.key)
  end

  def progress,
    do: %Cooking{
      slots: {ItemStack.new("raw_iron", 2), ItemStack.new("coal", 2), nil},
      burn_left: 500,
      burn_total: 1600,
      progress: 10,
      total: 200
    }

  defp start(state), do: RegionData.cooking_tick(state, System.monotonic_time(:millisecond))

  defp result(state) do
    %{token: token} = Valimc.World.Jobs.get(state.jobs, :cooking)
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:job, :cooking, ^token, _} = message}
    {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  def disk(ctx) do
    {:ok, containers} =
      Containers.decode(Valimc.TestDisk.read(ctx.base, ctx.key, :containers), ctx.key)

    containers
  end

  test "clean shutdown retains the exact uncheckpointed progress", ctx do
    state = seed(ctx, progress()) |> start() |> result()
    expected = state.containers
    assert disk(ctx) != expected
    RegionData.terminate(:shutdown, state)
    assert disk(ctx) == expected
    reloaded = RegionData.load(ctx.key)
    assert reloaded.containers == expected
    RegionData.terminate(:shutdown, reloaded)
  end

  def eventually(fun, _budget \\ nil) do
    Valimc.TestWait.until(fun)
    :ok
  end
end

defmodule Valimc.CookingRegionRuntimeTest.Serial do
  use ExUnit.Case, async: false
  # Serial: waits on the owner's real game ticks, which concurrent load can starve.
  import Valimc.CookingRegionRuntimeTest, only: [seed: 2, progress: 0, eventually: 1, disk: 1]
  alias Valimc.TestScope
  alias Valimc.{Cooking, ItemMotionState}
  alias Valimc.CookingBlocks
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Blocks, Containers, RegionData}

  setup {Valimc.CookingRegionRuntimeTest, :scope}

  test "the actual region clock cooks all families while dropped-item physics advances", ctx do
    state = seed(ctx, %{progress() | progress: 199})
    RegionData.terminate(:shutdown, state)
    {x, y, z} = ctx.position

    {containers, edits} =
      Enum.reduce(
        [
          {1, :smoker, "cod"},
          {2, :blast_furnace, "raw_iron"}
        ],
        {state.containers, %{ctx.position => Blocks.get(state.blocks, ctx.position)}},
        fn {offset, kind, input}, {containers, edits} ->
          position = {x + offset, y, z}

          {:ok, containers, entry} =
            Containers.create_cooking(containers, ctx.key, position, kind)

          {:ok, containers, _} =
            Containers.replace_cooking(
              containers,
              position,
              entry.revision,
              %Cooking{
                slots: {ItemStack.new(input, 2), ItemStack.new("coal", 2), nil},
                burn_left: 500,
                burn_total: 800,
                progress: 99,
                total: 100,
                speed: 2.0
              },
              %{}
            )

          {:ok, block} = CookingBlocks.placement(kind, 0.0)
          {:ok, lit} = CookingBlocks.lit(block, true)
          {containers, Map.put(edits, position, lit)}
        end
      )

    {:ok, bytes} = Containers.encode(ctx.key, containers)
    Valimc.TestDisk.write(ctx.base, ctx.key, :containers, bytes)
    Valimc.TestDisk.write(ctx.base, ctx.key, :blocks, edits)

    TestScope.isolate(ctx.key, item_simulation: true)
    {:ok, {pid, _} = owner} = Valimc.World.item_owner(ctx.key)
    TestScope.simulate(owner, ctx.key)

    record = %{
      uuid: <<81::128>>,
      x: x + 5.5,
      y: 70.0,
      z: z + 0.5,
      stack: ItemStack.new("stone"),
      motion: %ItemMotionState{pickup_delay: 100}
    }

    assert {:ok, :applied} =
             Valimc.World.Region.apply_item_transfer(
               owner,
               %{source: <<82::128>>, sequence: 1, records: [record]}
             )

    eventually(fn ->
      current = Valimc.TestConn.state(pid).resource

      Enum.all?(current.containers.entries, fn {_, entry} ->
        Enum.sum(Map.values(entry.recipes)) == 1
      end) and Enum.any?(current.items.entries, fn {_, entry} -> entry.entity.y < 69.9 end)
    end)

    assert Enum.all?(disk(ctx).entries, fn {_, entry} -> map_size(entry.recipes) == 1 end)
  end
end
