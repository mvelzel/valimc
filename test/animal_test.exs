defmodule Valimc.AnimalInteractionTest do
  @moduledoc "A player's items on farm animals (VMC-043c): feeding, milking, stew, shearing, dyeing, age locks."
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Animal, Body}
  alias Valimc.Entity.Animals.Interaction
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  defp animal(type, data \\ %{}) do
    {:ok, body} = Body.new(type)
    %{body | data: Map.merge(body.data, data)}
  end

  defp apply_item(body, item, infinite \\ false),
    do: Interaction.interact(body, %{item: item && ItemStack.new(item), infinite: infinite})

  test "food makes an adult fall in love once and ages a baby on by a tenth" do
    {:ok, cow, outcome} = apply_item(animal("minecraft:cow"), "minecraft:wheat")
    assert cow.data.in_love == 600 and outcome.hand == {:use, 1} and outcome.swing
    assert outcome.events == [{:event, 18}]
    # In love, a parent cooling down, or food it does not eat: nothing.
    assert apply_item(cow, "minecraft:wheat") == :pass
    assert apply_item(animal("minecraft:cow", %{age: 3000}), "minecraft:wheat") == :pass
    assert apply_item(animal("minecraft:cow"), "minecraft:carrot") == :pass

    {:ok, calf, outcome} = apply_item(animal("minecraft:cow", %{age: -24_000}), "minecraft:wheat")
    # 24,000 ticks left: 1,200 s, a tenth of it 120 s.
    assert calf.data.age == -24_000 + 120 * 20 and calf.data.forced_age == 2400
    assert outcome.hand == {:use, 1} and not outcome.swing

    # A pig eats out loud; a chicken's seeds.
    {:ok, _, %{events: [{:event, 18}, {:sound, _, "neutral", _, _, _}]}} =
      apply_item(animal("minecraft:pig"), "minecraft:carrot")

    assert {:ok, _, _} = apply_item(animal("minecraft:chicken"), "minecraft:wheat_seeds")
  end

  test "a golden dandelion locks a baby's age back to a newborn's, and unlocks it" do
    {:ok, lamb, outcome} =
      apply_item(animal("minecraft:sheep", %{age: -100}), "minecraft:golden_dandelion")

    assert lamb.data.age_locked and lamb.data.age == -24_000 and lamb.mob.persistent
    assert [{:sound_block, _, "player", 1.0, 1.0, _}] = outcome.events
    refute Animal.can_age_up?(lamb.data)
    assert apply_item(animal("minecraft:sheep"), "minecraft:golden_dandelion") == :pass
  end

  test "a bucket milks an adult cow or mooshroom; a bowl a mooshroom's stew" do
    {:ok, _, %{hand: {:fill, %ItemStack{} = milk}, others: {_, "player", _, _, :player}}} =
      apply_item(animal("minecraft:cow"), "minecraft:bucket")

    assert milk.item_id == Valimc.Protocol.ItemTypes.id("minecraft:milk_bucket")
    assert apply_item(animal("minecraft:cow", %{age: -5}), "minecraft:bucket") == :pass

    assert {:ok, _, %{hand: {:fill, _}}} =
             apply_item(animal("minecraft:mooshroom"), "minecraft:bucket")

    {:ok, _, %{hand: {:fill, stew}}} = apply_item(animal("minecraft:mooshroom"), "minecraft:bowl")
    assert stew.item_id == Valimc.Protocol.ItemTypes.id("minecraft:mushroom_stew")

    # A brown one eats a flower for its stew's effects, once until milked.
    brown = animal("minecraft:mooshroom", %{type: "brown"})
    {:ok, fed, %{hand: {:use, 1}}} = apply_item(brown, "minecraft:poppy")
    assert fed.data.stew == [{"minecraft:night_vision", 100}]
    assert {:ok, ^fed, %{hand: :keep}} = apply_item(fed, "minecraft:dandelion")
    {:ok, milked, %{hand: {:fill, suspicious}}} = apply_item(fed, "minecraft:bowl")

    assert suspicious.components["minecraft:suspicious_stew_effects"] ==
             [{"minecraft:night_vision", 100}]

    assert milked.data.stew == nil
  end

  test "shears shear a sheep's wool and turn a mooshroom into a cow" do
    sheep = animal("minecraft:sheep", %{color: 14})
    {:ok, shorn, outcome} = apply_item(sheep, "minecraft:shears")
    assert shorn.data.sheared and outcome.hand == {:wear, 1} and outcome.swing
    assert length(outcome.drops) in 1..3

    for {stack, {+0.0, 1.0, +0.0}, {:add, _}} <- outcome.drops,
        do: assert(stack.item_id == Valimc.Protocol.ItemTypes.id("minecraft:red_wool"))

    # Shorn, or a lamb: the shears do nothing more.
    assert apply_item(shorn, "minecraft:shears") == :consume
    assert apply_item(animal("minecraft:sheep", %{age: -10}), "minecraft:shears") == :consume

    mooshroom = %{animal("minecraft:mooshroom", %{type: "brown"}) | custom_name: "Moo"}
    {:ok, _, %{convert: cow, drops: drops}} = apply_item(mooshroom, "minecraft:shears")
    assert cow.type == "minecraft:cow" and cow.custom_name == "Moo"
    assert length(drops) == 5

    for {stack, _, nil} <- drops,
        do: assert(stack.item_id == Valimc.Protocol.ItemTypes.id("minecraft:brown_mushroom"))
  end

  test "dye colours a sheep that is not shorn, unless it is that colour" do
    {:ok, dyed, %{hand: {:use, 1}, others: {_, "player", _, _, :animal}}} =
      apply_item(animal("minecraft:sheep"), "minecraft:blue_dye")

    assert dyed.data.color == 11
    assert apply_item(dyed, "minecraft:blue_dye") == :pass
    assert apply_item(animal("minecraft:sheep", %{sheared: true}), "minecraft:red_dye") == :pass
  end

  # VMC-043c3: a lead's use comes before the animal's own.
  defp lead(body, item, opts \\ []) do
    request = %{
      item: item && ItemStack.new(item),
      infinite: Keyword.get(opts, :infinite, false),
      player: <<9::128>>,
      sneaking: false,
      holder: %{id: 70, x: Keyword.get(opts, :at, 2.0), y: 64.0, z: 0.5, width: 0.6, height: 1.8}
    }

    Valimc.Entity.Leashes.interact(body, {0.5, 64.0, 0.5}, request)
  end

  test "a lead ties an animal to the player, who unties it; shears snip it first" do
    {:ok, cow, outcome} = lead(animal("minecraft:cow"), "minecraft:lead")
    assert %{holder: {:player, <<9::128>>}, id: 70, restored: false} = cow.mob.leash
    assert outcome.hand == {:use, 1} and outcome.swing
    assert [{:sound, "minecraft:item.lead.tied", "neutral", 1.0, 1.0, _}] = outcome.events

    # Too far, or a mob that takes no lead: nothing.
    assert lead(animal("minecraft:cow"), "minecraft:lead", at: 13.5) == :pass
    assert lead(animal("minecraft:zombie"), "minecraft:lead") == :pass

    # Its holder unties it (the lead an item), with any hand; in creative no item.
    {:ok, untied, %{drops: [{lead, _, nil}], hand: :keep}} = lead(cow, nil)
    assert untied.mob.leash == nil and lead.item_id == ItemTypes.id("minecraft:lead")
    assert {:ok, _, %{drops: []}} = lead(cow, "minecraft:wheat", infinite: true)

    # Shears on a leashed sheep snip the lead, not its wool.
    {:ok, sheep, _} = lead(animal("minecraft:sheep"), "minecraft:lead")
    {:ok, snipped, %{hand: {:wear, 1}, drops: [_]}} = lead(sheep, "minecraft:shears")
    assert snipped.mob.leash == nil and not snipped.data.sheared

    # Tied to a knot, a lead in hand takes it (the knot's lead an item).
    knotted = %{cow | mob: %{cow.mob | leash: %{cow.mob.leash | holder: {:knot, {3, 64, 0}}}}}
    {:ok, retied, %{drops: [_], free: [{3, 64, 0}]}} = lead(knotted, "minecraft:lead")
    assert retied.mob.leash.holder == {:player, <<9::128>>}
  end

  test "a lead and home are saved; a restored lead looks for its holder" do
    {:ok, cow, _} = lead(animal("minecraft:cow"), "minecraft:lead")
    mob = %{cow.mob | home: {{2, 64, 0}, 5}}
    {:ok, restored} = Valimc.Entity.Mob.restore("minecraft:cow", Valimc.Entity.Mob.record(mob))

    assert restored.leash == %{
             holder: {:player, <<9::128>>},
             id: nil,
             momentum: 0.0,
             restored: true
           }

    assert restored.home == {{2, 64, 0}, 5}

    # Observers are linked to its holder, and unlinked when it lets go.
    assert [{_, <<4::32, 70::32>>}] =
             for(
               {_, <<_::32, _::32>>} = p <- Body.changes(4, animal("minecraft:cow"), cow),
               do: p
             )

    assert [{_, <<4::32, 0::32>>}] =
             for(
               {_, <<_::32, _::32>>} = p <- Body.changes(4, cow, animal("minecraft:cow")),
               do: p
             )
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
    store(ctx).entries[id].body
  end
end
