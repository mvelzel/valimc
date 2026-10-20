defmodule Valimc.ItemDespawnTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {71_000 + rem(nonce, 5_000), 1900}
    base = Path.join(System.tmp_dir!(), "valimc-despawn-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          k <- TestScope.neighborhood(key),
          {pid, _} <- Registry.lookup(reg, k),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key}
  end

  test "a dropped item despawns after 6000 ticks even while item planning keeps the owner busy",
       ctx do
    {rx, rz} = ctx.key
    {:ok, {pid, _} = owner} = World.item_owner(ctx.key)

    {:ok, _} =
      Region.create_item(owner, ItemStack.new("dirt"), {rx * 128 + 8.5, 64.0, rz * 128 + 8.5})

    assert map_size(World.item_snapshot(ctx.key)) == 1

    # A busy planning slot (e.g. a nearby player's repeated pickup queries)
    # must not stall the despawn clock.
    busy = %{kind: :busy, phase: :planning, token: make_ref(), timer: make_ref(), from: nil}
    :sys.replace_state(pid, &put_in(&1.resource.item_pending, busy))
    for _ <- 1..5, do: {:ok, _} = Region.step(owner, 1200)
    :sys.replace_state(pid, &put_in(&1.resource.item_pending, nil))
    {:ok, _} = Region.step(owner, 1)
    wait(fn -> World.item_snapshot(ctx.key) == %{} end)
  end

  defp wait(fun, tries \\ 200) do
    unless fun.() do
      assert tries > 0
      Process.sleep(5)
      wait(fun, tries - 1)
    end
  end
end
