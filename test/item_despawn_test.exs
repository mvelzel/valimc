defmodule Valimc.ItemDespawnTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {71_000 + rem(nonce, 1_666) * 3, 1900}
    base = Path.join(System.tmp_dir!(), "valimc-despawn-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    on_exit(fn ->
      for k <- TestScope.neighborhood(key),
          {pid, _} <- Valimc.TestWorld.registered(k),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key}
  end

  test "a dropped item despawns after 6000 ticks even while item planning keeps the owner busy",
       ctx do
    {rx, rz} = ctx.key
    {:ok, {pid, _} = owner} = Valimc.TestWorld.item_owner(ctx.key)
    Valimc.TestScope.simulate(owner, ctx.key)

    {:ok, _} =
      Region.create_item(owner, ItemStack.new("dirt"), {rx * 128 + 8.5, 64.0, rz * 128 + 8.5})

    assert map_size(Valimc.TestWorld.item_snapshot(ctx.key)) == 1

    # A busy planning slot (e.g. a nearby player's repeated pickup queries)
    # must not stall the despawn clock.
    busy = %{kind: :plan, token: make_ref(), pid: self(), monitor: make_ref(), data: %{}}
    Valimc.TestRegion.replace_section(owner, &put_in(&1.jobs.entries[:plan], busy))
    for _ <- 1..5, do: {:ok, _} = Region.step(owner, 1200)

    Valimc.TestRegion.replace_section(
      pid,
      &update_in(&1.jobs.entries, fn e -> Map.delete(e, :plan) end)
    )

    {:ok, _} = Region.step(owner, 1)
    wait(fn -> Valimc.TestWorld.item_snapshot(ctx.key) == %{} end)
  end

  defp wait(fun, _budget \\ nil), do: Valimc.TestWait.until(fun)
end
