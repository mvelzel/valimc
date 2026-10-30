defmodule Valimc.MobBrainRegionTest do
  @moduledoc """
  A brain mob in its owner (VMC-041a2): a summoned piglin sees a gold ingot
  lying near it, walks to it, takes it into its off hand and admires it;
  then it barters (VMC-043d): the ingot gone, the bartering table's items
  thrown near it.
  """
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {67_000 + rem(nonce, 333) * 3, 2900}
    base = Path.join(System.tmp_dir!(), "valimc-mob-brain-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual,
      # These read Elixir brains (activities, memories): their mobs stay
      # Elixir (VMC-081d; the native brains' think parity compares them).
      native_mob_types:
        Application.get_env(:valimc, :native_mob_types) --
          ~w(minecraft:piglin minecraft:hoglin minecraft:villager minecraft:iron_golem minecraft:wandering_trader minecraft:cat)
    )

    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :items, %{records: []})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    {rx, rz} = key
    {x0, z0} = {rx * 128 + 8, rz * 128 + 8}
    stone = Valimc.Data.Blocks.default_state("stone")

    for x <- (x0 - 6)..(x0 + 6),
        z <- (z0 - 6)..(z0 + 6),
        do: Valimc.TestBlocks.set({x, 63, z}, stone)

    on_exit(fn ->
      for k <- TestScope.neighborhood(key), {pid, _} <- Valimc.TestWorld.registered(k) do
        try do
          :sys.resume(pid)
          TestScope.kill(pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf(base)
    end)

    %{key: key, owner: owner, at: {x0 + 0.5, z0 + 0.5}}
  end

  defp step(ctx, ticks) do
    {pid, _} = ctx.owner
    TestScope.simulate(pid, ctx.key)
    for _ <- 1..ticks, do: Region.step({pid, nil}, 1)
  end

  defp store(ctx), do: Valimc.TestRegion.section(ctx.owner).entities.store

  test "a piglin takes a gold ingot it sees into its off hand and admires it", ctx do
    {x, z} = ctx.at
    {:ok, piglin} = Body.new("minecraft:piglin")
    :ok = Region.drop_items(ctx.owner, [Store.body_record(piglin, <<21::128>>, {x, 64.0, z})])

    ingot = %{
      uuid: <<22::128>>,
      x: x + 3.0,
      y: 64.0,
      z: z + 2.0,
      stack: ItemStack.new("gold_ingot"),
      motion: %Valimc.Entity.ItemMotionState{on_ground: true}
    }

    :ok = Region.drop_items(ctx.owner, [ingot])

    Valimc.TestWait.until(fn ->
      step(ctx, 5)
      {:ok, {_, id, _}} = Store.find(store(ctx), <<21::128>>)
      offhand = store(ctx).entries[id].body.mob.equipment[:offhand]
      offhand != nil and offhand.item_id == Valimc.Protocol.ItemTypes.id("gold_ingot")
    end)

    {:ok, {_, id, _}} = Store.find(store(ctx), <<21::128>>)
    mind = store(ctx).entries[id].body.mob.ai
    assert Valimc.AI.Brain.activity(%Valimc.AI.Self{mind: mind}) == :admire_item
    assert {:error, _} = Store.find(store(ctx), <<22::128>>)

    # Admired for 119 ticks, the ingot becomes its barter.
    gold = Valimc.Protocol.ItemTypes.id("gold_ingot")

    Valimc.TestWait.until(fn ->
      step(ctx, 10)

      Enum.any?(store(ctx).entries, fn {_, entry} ->
        entry.kind == :item and entry.stack.item_id != gold
      end)
    end)

    {:ok, {_, id, _}} = Store.find(store(ctx), <<21::128>>)
    assert store(ctx).entries[id].body.mob.equipment[:offhand] == nil
  end
end
