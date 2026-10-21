defmodule Valimc.ItemPortalRegionTest do
  # Items through portals (VMC-026c) between live owners. Serial: the End's
  # arrival platform is shared by every test that enters the End.
  use ExUnit.Case, async: false
  @moduletag timeout: 240_000
  alias Valimc.{Dimension, ItemMotionState, TestScope}
  alias Valimc.Portal.{Access, Blocks}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{ItemRecords, Items, Region}

  setup do
    nonce = System.unique_integer([:positive])
    key = {50_000 + rem(nonce, 300) * 3, 3000}
    base = Path.join(System.tmp_dir!(), "valimc-item-portal-#{nonce}")
    old = Valimc.config(:world_path)
    # The source region simulates its items when stepped; every other owner
    # (the Nether's, the End's) runs in the same world.
    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    Application.put_env(:valimc, :world_path, base)
    File.mkdir_p!(base)

    on_exit(fn ->
      for k <- TestScope.neighborhood(key),
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, k),
          do: TestScope.kill(pid)

      elsewhere = [{{{:"$1", :_}, :"$2", :_}, [{:is_atom, :"$1"}], [:"$2"]}]

      for pid <- Registry.select(Valimc.RegionRegistry, elsewhere),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      for pid <- Registry.select(Valimc.ProtoRegistry, elsewhere),
          do: DynamicSupervisor.terminate_child(Valimc.ProtoSupervisor, pid)

      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(base)
    end)

    {rx, rz} = key
    %{key: key, base: base, origin: {rx * 128 + 40, 64, rz * 128 + 40}}
  end

  # An item at `position` falling, written before its owner starts.
  defp seed(ctx, position, dimension \\ :overworld) do
    {x, y, z} = position

    record = %{
      uuid: <<7::128>>,
      x: x,
      y: y,
      z: z,
      stack: ItemStack.new("diamond", 2),
      motion: %ItemMotionState{velocity: {0.0, -0.2, 0.0}, age: 30, pickup_delay: 5}
    }

    region = World.region_key(World.chunk_key(x, z))
    {:ok, bytes} = ItemRecords.encode(region, [record])
    Valimc.TestDisk.write(Dimension.storage(ctx.base, dimension), region, :items, bytes)
    Dimension.within(dimension, fn -> elem(World.item_owner(region), 1) end)
  end

  defp resource({pid, _}), do: Valimc.TestConn.state(pid).resource

  # Step the source owner tick by tick until `fun` holds.
  defp run(owner, fun) do
    Valimc.TestWait.until(fn ->
      fun.() ||
        (
          Region.step(owner, 1)
          nil
        )
    end)
  end

  defp holds?(owner, uuid), do: match?({:ok, _}, Items.find(resource(owner).items, uuid))

  # The item, searched in the regions around `position` of `dimension`.
  defp found(dimension, {x, _, z}) do
    Dimension.within(dimension, fn ->
      World.region_key(World.chunk_key(x, z))
      |> TestScope.neighborhood()
      |> Enum.find_value(fn key ->
        {:ok, owner} = World.item_owner(key)

        case Items.find(resource(owner).items, <<7::128>>) do
          {:ok, {_, id, _}} -> resource(owner).items.entries[id]
          _ -> nil
        end
      end)
    end)
  end

  defp frame({x, y, z}) do
    for dx <- -1..2, dy <- -1..3, dx in [-1, 2] or dy in [-1, 3] do
      {{x + dx, y + dy, z}, Blocks.obsidian()}
    end
  end

  test "an item falling into a nether portal arrives in a new Nether portal, keeping its stack",
       ctx do
    {x, y, z} = ctx.origin
    portal = for dx <- 0..1, dy <- 0..2, do: {{x + dx, y + dy, z}, Blocks.portal(:x)}
    source = seed(ctx, {x + 1.0, y + 2.5, z + 0.5})
    :ok = Access.commit(frame(ctx.origin) ++ portal)

    run(source, fn ->
      not holds?(source, <<7::128>>) and resource(source).items.ledger.outgoing == nil
    end)

    approx = {(x + 1.0) / 8, 64.0, (z + 0.5) / 8}
    entry = Valimc.TestWait.until(fn -> found(:the_nether, approx) end)
    position = {entry.entity.x, entry.entity.y, entry.entity.z}
    {ax, ay, az} = position
    assert abs(ax - elem(approx, 0)) < 17 and abs(az - elem(approx, 2)) < 17
    cell = {floor(ax), floor(ay), floor(az)}
    read = Dimension.within(:the_nether, fn -> Access.reader() end)
    assert Blocks.portal?(Dimension.within(:the_nether, fn -> read.(cell) end))
    assert entry.stack == ItemStack.new("diamond", 2)
    assert entry.motion.portal_cooldown > 0 and entry.motion.age >= 30
    assert entry.entity.uuid == <<7::128>>
  end

  test "an item dropping into an end portal lands on the End's platform, a block above a player",
       ctx do
    {x, y, z} = ctx.origin

    cells =
      for dx <- 0..2,
          dz <- 0..2,
          do: {{x + dx, y, z + dz}, Valimc.Registry.Blocks.default_state("end_portal")}

    source = seed(ctx, {x + 1.5, y + 1.2, z + 1.5})
    :ok = Access.commit(cells)

    run(source, fn ->
      not holds?(source, <<7::128>>) and resource(source).items.ledger.outgoing == nil
    end)

    entry = Valimc.TestWait.until(fn -> found(:the_end, {100.5, 50.0, 0.5}) end)
    assert {entry.entity.x, entry.entity.z} == {100.5, 0.5}
    # Arrived at y 50 (a player arrives at 49); it may have fallen since.
    assert entry.entity.y <= 50.0 and entry.entity.y >= 49.0
    floor = Dimension.within(:the_end, fn -> Access.reader().({100, 48, 0}) end)
    assert floor == Blocks.obsidian()
  end

  test "an item in a gateway with an exit elsewhere in the End moves to that region", ctx do
    gateway = Valimc.Registry.Blocks.default_state("end_gateway")
    at = {50 * 128 + 20, 70, 50 * 128 + 20}
    exit = {51 * 128 + 20, 60, 50 * 128 + 20}
    {gx, gy, gz} = at
    {:ok, recorded} = Valimc.Worldgen.FullChunk.gateway_entry(at, {exit, true})

    TestScope.isolate(TestScope.neighborhood({50, 50}),
      world_path: ctx.base,
      item_simulation: true,
      region_ticks: :manual
    )

    source = seed(ctx, {gx + 0.5, gy + 1.1, gz + 0.5}, :the_end)

    Dimension.within(:the_end, fn ->
      :ok = Access.commit([{at, gateway}])
      :ok = Access.put_block_entities(%{at => recorded})

      run(source, fn ->
        not holds?(source, <<7::128>>) and resource(source).items.ledger.outgoing == nil
      end)
    end)

    entry = Valimc.TestWait.until(fn -> found(:the_end, exit) end)
    {ex, ey, ez} = exit
    assert abs(entry.entity.x - (ex + 0.5)) < 1.0e-9 and abs(entry.entity.z - (ez + 0.5)) < 1.0e-9
    assert entry.entity.y <= ey + 0.0
    assert entry.motion.portal_cooldown > 0
  end
end
