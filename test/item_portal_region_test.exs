defmodule Valimc.ItemPortalRegionTest do
  # Items through portals (VMC-026c) between live owners. Serial: the End's
  # arrival platform is shared by every test that enters the End.
  use ExUnit.Case, async: false
  @moduletag :slow
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
    TestScope.simulate(owner, resource(owner).key)

    Valimc.TestWait.until(fn ->
      fun.() ||
        (
          Region.step(owner, 1)
          nil
        )
    end)
  end

  defp holds?(owner, uuid), do: match?({:ok, _}, Items.find(resource(owner).entities.items, uuid))

  # The item, searched in the regions around `position` of `dimension`.
  defp found(dimension, {x, _, z}) do
    Dimension.within(dimension, fn ->
      World.region_key(World.chunk_key(x, z))
      |> TestScope.neighborhood()
      |> Enum.find_value(fn key ->
        {:ok, owner} = World.item_owner(key)

        case Items.find(resource(owner).entities.items, <<7::128>>) do
          {:ok, {_, id, _}} -> resource(owner).entities.items.entries[id]
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
      not holds?(source, <<7::128>>) and resource(source).entities.items.ledger.outgoing == nil
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
end
