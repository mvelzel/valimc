defmodule Valimc.AnimalLeadRecordTest do
  @moduledoc "A farm animal's lead and home in its record (VMC-043c3)."
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Mob}

  test "a lead and home are saved; a restored lead looks for its holder" do
    {:ok, cow} = Body.new("minecraft:cow")
    leash = %{holder: {:player, <<9::128>>}, id: 70, momentum: 0.0, restored: false}
    mob = %{cow.mob | leash: leash, home: {{2, 64, 0}, 5}}
    {:ok, restored} = Mob.restore("minecraft:cow", Mob.record(mob))
    assert restored.leash == %{leash | id: nil, restored: true}
    assert restored.home == {{2, 64, 0}, 5}
  end
end

defmodule Valimc.AnimalRegionTest do
  @moduledoc "Farm animals in their owner (VMC-043c): breeding's calf and orb, shearing's wool, a mooshroom's cow."
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {66_000 + rem(nonce, 333) * 3, 2400}
    base = Path.join(System.tmp_dir!(), "valimc-animals-#{nonce}")

    TestScope.isolate(TestScope.neighborhood(key),
      world_path: base,
      item_simulation: true,
      region_ticks: :manual
    )

    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :items, %{records: []})
    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    {rx, rz} = key
    {x0, z0} = {rx * 128 + 8, rz * 128 + 8}
    grass = Valimc.Data.Blocks.default_state("grass_block")

    for x <- (x0 - 6)..(x0 + 6),
        z <- (z0 - 6)..(z0 + 6),
        do: Valimc.TestBlocks.set({x, 63, z}, grass)

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

  defp summon(ctx, type, uuid, {dx, dz}, data \\ %{}) do
    {x, z} = ctx.at
    {:ok, body} = Body.new(type)
    body = %{body | data: Map.merge(body.data, data)}
    :ok = Region.drop_items(ctx.owner, [Store.body_record(body, uuid, {x + dx, 64.0, z + dz})])
  end

  defp store(ctx), do: Valimc.TestRegion.section(ctx.owner).entities.store

  defp step(ctx, ticks) do
    {pid, _} = ctx.owner
    TestScope.simulate(pid, ctx.key)
    for _ <- 1..ticks, do: Region.step({pid, nil}, 1)
  end

  test "two cows in love breed: a calf where one stood and an orb", ctx do
    summon(ctx, "minecraft:cow", <<1::128>>, {0.0, 0.0}, %{in_love: 600})
    summon(ctx, "minecraft:cow", <<2::128>>, {1.5, 0.0}, %{in_love: 600})
    step(ctx, 120)

    bodies = for {_, %{kind: :mob, body: body}} <- store(ctx).entries, do: body
    assert Enum.count(bodies, &(&1.data.age < 0)) == 1
    assert Enum.count(bodies, &(&1.data.age > 0)) == 2
    assert Enum.any?(store(ctx).entries, fn {_, e} -> e.kind == :orb end)
  end

  # The M3 gate's turtles never bred.
  test "two turtles in love breed: one carries an egg", ctx do
    summon(ctx, "minecraft:turtle", <<6::128>>, {0.0, 0.0}, %{in_love: 600})
    summon(ctx, "minecraft:turtle", <<7::128>>, {1.5, 0.0}, %{in_love: 600})
    step(ctx, 200)

    bodies = for {_, %{kind: :mob, body: body}} <- store(ctx).entries, do: body
    assert Enum.count(bodies, & &1.data.has_egg) == 1
  end

  test "shears shear a sheep's wool onto the ground and turn a mooshroom into a cow", ctx do
    summon(ctx, "minecraft:sheep", <<3::128>>, {0.0, 0.0}, %{color: 4})
    summon(ctx, "minecraft:mooshroom", <<4::128>>, {3.0, 0.0})
    request = %{item: ItemStack.new("minecraft:shears"), infinite: false, player: <<9::128>>}

    assert {:ok, %{hand: {:wear, 1}, swing: true}} =
             Region.interact_entity(ctx.owner, <<3::128>>, request)

    assert {:ok, %{hand: {:wear, 1}}} = Region.interact_entity(ctx.owner, <<4::128>>, request)

    entries = Map.values(store(ctx).entries)
    wool = Valimc.Protocol.ItemTypes.id("minecraft:yellow_wool")
    assert Enum.any?(entries, &match?(%{kind: :item, stack: %{item_id: ^wool}}, &1))
    assert Enum.count(entries, &match?(%{kind: :item}, &1)) >= 6

    types = for %{kind: :mob, body: body} <- entries, do: body.type
    assert Enum.sort(types) == ["minecraft:cow", "minecraft:sheep"]
    assert {:error, _} = Store.find(store(ctx), <<4::128>>)
  end

  # VMC-043c3: a fence takes the player's leashed mobs onto its knot; the
  # knot gives them back; a broken knot's mob drops its lead.
  test "a fence knot holds a player's cow, gives it back, and breaks", ctx do
    {x, z} = ctx.at
    fence = {floor(x) + 2, 64, floor(z)}
    Valimc.TestBlocks.set(fence, Valimc.Data.Blocks.default_state("oak_fence"))
    player = <<9::128>>
    summon(ctx, "minecraft:cow", <<5::128>>, {0.0, 0.0})
    {fx, fy, fz} = fence

    request = %{
      item: ItemStack.new("minecraft:lead"),
      infinite: false,
      player: player,
      sneaking: false,
      holder: %{id: 70, x: x + 1.0, y: 64.0, z: z, width: 0.6, height: 1.8}
    }

    assert {:ok, %{hand: {:use, 1}, swing: true}} =
             Region.interact_entity(ctx.owner, <<5::128>>, request)

    grant = %{
      kind: :open,
      mode: :survival,
      eye: {x, 65.62, z},
      expires: System.monotonic_time(:millisecond) + 5000,
      hand: :main,
      player: player,
      secondary: false,
      main: false,
      off: false
    }

    assert Region.menu(ctx.owner, self(), fence, grant) == :swing

    [{knot_id, knot}] =
      for {id, %{body: %{type: "minecraft:leash_knot"}} = e} <- store(ctx).entries, do: {id, e}

    assert {knot.entity.x, knot.entity.y, knot.entity.z} == {fx * 1.0, fy * 1.0, fz * 1.0}
    assert cow(ctx).mob.leash.holder == {:knot, fence} and cow(ctx).mob.leash.id == knot_id

    # The knot gives the cow back to the player; empty, it goes.
    assert {:ok, _} = Region.interact_knot(ctx.owner, knot.entity.uuid, %{request | item: nil})
    assert cow(ctx).mob.leash.holder == {:player, player}

    refute Enum.any?(
             store(ctx).entries,
             &match?({_, %{body: %{type: "minecraft:leash_knot"}}}, &1)
           )

    # Tied again, the knot breaks: the cow drops its lead on its next tick.
    assert Region.menu(ctx.owner, self(), fence, grant) == :swing
    [knot] = for {_, %{body: %{type: "minecraft:leash_knot"}} = e} <- store(ctx).entries, do: e
    assert {:ok, _} = Region.hurt_entity(ctx.owner, knot.entity.uuid, %{})
    step(ctx, 1)
    assert cow(ctx).mob.leash == nil
    lead = Valimc.Protocol.ItemTypes.id("minecraft:lead")

    assert Enum.any?(store(ctx).entries, fn {_, e} ->
             match?(%{kind: :item, stack: %{item_id: ^lead}}, e)
           end)
  end

  defp cow(ctx) do
    {:ok, {_, id, _}} = Store.find(store(ctx), <<5::128>>)
    Valimc.TestBodies.body(store(ctx).entries[id])
  end
end
