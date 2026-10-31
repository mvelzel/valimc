defmodule Valimc.ShulkerBoxRegionTest do
  @moduledoc """
  Shulker boxes in region owners (VMC-032c2): placement facing the clicked
  face with an item's contents, the lid's room, its block events and sounds,
  the menu's and hoppers' refusal of a box in a box, the box dropping with its
  contents in survival and creative, and contents through a handoff and a
  restart.
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.ShulkerBox
  alias Valimc.Data.Blocks, as: Registry
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.TestScope
  alias Valimc.World.{BlockBatch, Containers, Region}

  setup do
    nonce = System.unique_integer([:positive])
    a = {91_000 + rem(nonce, 3_333) * 3, 2530}
    b = {elem(a, 0) + 1, elem(a, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-shulker-#{nonce}")

    TestScope.isolate([a, b],
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false
    )

    on_exit(fn ->
      for key <- [a, b], {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, {pa, _} = oa} = Valimc.TestWorld.item_owner(a)
    {:ok, ob} = Valimc.TestWorld.item_owner(b)
    {rx, rz} = a
    %{a: a, b: b, oa: oa, ob: ob, pa: pa, x: rx * 128, z: rz * 128}
  end

  defp box(facing, name \\ "shulker_box"), do: Registry.state(name, %{"facing" => facing})

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp entry(owner, at), do: Valimc.TestRegion.section(owner).containers.entries[at]

  defp fill(owner, at, slots) do
    Valimc.TestRegion.replace_section(owner, fn section ->
      %{revision: revision} = section.containers.entries[at]
      {:ok, containers, _} = Containers.replace(section.containers, at, revision, slots)
      %{section | containers: containers}
    end)
  end

  defp grant(kind, {x, y, z}, extra \\ %{}) do
    Map.merge(
      %{
        kind: kind,
        mode: :survival,
        eye: {x + 0.5, y + 1.6, z + 2.5},
        expires: Valimc.TestRegion.grant_expires(),
        hand: :main,
        secondary: false,
        main: false,
        off: false
      },
      extra
    )
  end

  defp items(owner) do
    for {_, %{kind: :item} = item} <- Valimc.TestRegion.section(owner).entities.store.entries,
        do: item
  end

  defp holding(slots),
    do: Enum.reduce(slots, Tuple.duplicate(nil, 27), fn {i, s}, acc -> put_elem(acc, i, s) end)

  test "placement faces the clicked face and takes the item's contents", ctx do
    item = Valimc.Protocol.Data.item("red_shulker_box")
    target = {ctx.x + 20, 64, ctx.z + 20}
    {x, y, z} = target

    for {face, clicked, facing} <- [
          {1, {x, y - 1, z}, "up"},
          {0, {x, y + 1, z}, "down"},
          {2, {x, y, z + 1}, "north"},
          {5, {x - 1, y, z}, "east"}
        ] do
      request = %{position: clicked, face: face, cursor: {0.5, 0.5, 0.5}, yaw: 0.0, pitch: 0.0}

      {:ok, %{position: ^target, values: values}} =
        Valimc.Blocks.Placement.target(item, Registry.default_state("stone"), request)

      {:ok, writes} = Region.placement(ctx.oa, item, values, target)
      assert Map.new(writes)[target] == box(facing, "red_shulker_box"), facing
    end

    contents = [ItemStack.new("diamond", 5), nil, ItemStack.new("ender_pearl", 16)]

    stack =
      ItemStack.normalize(%{
        ItemStack.new("red_shulker_box")
        | components: %{"minecraft:container" => contents}
      })

    assert Valimc.Blocks.Placement.placeable_stack?(stack)

    # A name places with the contents (VMC-032c5); a lock does not.
    named = %{
      stack
      | components: Map.put(stack.components, "minecraft:custom_name", {:string, "Box"})
    }

    assert Valimc.Blocks.Placement.placeable_stack?(named)
    locked = %{stack | components: Map.put(stack.components, "minecraft:lock", %{})}
    refute Valimc.Blocks.Placement.placeable_stack?(locked)

    {:ok, slots} = ShulkerBox.slots(stack)
    {:ok, observed} = Region.observe_blocks(ctx.oa, [target])
    {:ok, batch} = BlockBatch.prepare(%{target => box("up", "red_shulker_box")})

    {:ok, _} =
      Region.place_block(ctx.oa, observed.fence, batch, Valimc.TestRegion.grant_expires(), %{
        target => %{slots: slots, name: {:string, "Box"}}
      })

    assert %{kind: :shulker_box, slots: placed, name: {:string, "Box"}} = entry(ctx.oa, target)
    assert Enum.take(Tuple.to_list(placed), 3) == contents and tuple_size(placed) == 27

    # Broken, it drops as the box holding them, named.
    block = Valimc.TestBlocks.get(target)

    assert :ok =
             Region.mine_block(
               ctx.oa,
               target,
               %{target => {block, Valimc.Blocks.after_removal(block)}},
               [
                 Valimc.Entity.ItemDrop.pop(target, ItemStack.new("red_shulker_box"))
               ]
             )

    assert [dropped] = items(ctx.oa)
    assert ItemStack.component(dropped.stack, "minecraft:custom_name") == {:string, "Box"}
    assert Enum.take(ItemStack.component(dropped.stack, "minecraft:container"), 3) == contents
  end

  test "a closed box needs room for its lid, which opens and closes by block event", ctx do
    at = {ctx.x + 30, 64, ctx.z + 20}
    {x, y, z} = at
    above = {x, y + 1, z}
    Valimc.TestWorld.subscribe(MapSet.new([ctx.a]), MapSet.new())

    set(ctx.oa, %{at => box("up"), above => Registry.state("stone_slab", %{"type" => "bottom"})})
    assert {:error, :blocked_shulker_box} = Region.menu(ctx.oa, self(), at, grant(:open, at))

    # A top slab leaves the lid's half block free.
    set(ctx.oa, %{above => Registry.state("stone_slab", %{"type" => "top"})})
    assert {:storage, _, view} = Region.menu(ctx.oa, self(), at, grant(:open, at))
    assert view.kind == :shulker_box and tuple_size(view.slots) == 27

    viewer = spawn(fn -> receive do: (:stop -> :ok) end)
    ref = make_ref()

    {:storage, _, _} =
      Region.menu(
        ctx.oa,
        viewer,
        at,
        grant(:subscribe, at, %{menu: :storage, view_ref: ref})
      )

    assert_receive {:event, {:chest_lid, _, ^at, true, lid, sound}}
    threshold = Valimc.config(:compression_threshold)
    packet = ShulkerBox.lid_event(box("up"), at, true)
    assert lid == Valimc.Protocol.Packets.frame(packet, threshold)
    assert sound != nil

    # While it is open, a block over it does not stop another viewer.
    set(ctx.oa, %{above => Registry.default_state("stone")})
    assert {:storage, _, _} = Region.menu(ctx.oa, self(), at, grant(:open, at))

    Region.unsubscribe_container(ctx.oa, viewer, ref)
    assert_receive {:event, {:chest_lid, _, ^at, false, _lid, closing}}
    assert closing != nil
    assert {:error, :blocked_shulker_box} = Region.menu(ctx.oa, self(), at, grant(:open, at))
  end

  test "neither the menu nor a hopper puts a box in a box; a comparator reads 27 slots", ctx do
    TestScope.simulate(ctx.oa, ctx.a)
    at = {ctx.x + 40, 64, ctx.z + 20}
    {x, y, z} = at
    hopper = {x, y + 1, z}
    comparator = {x + 1, y, z}

    set(ctx.oa, %{
      at => box("down"),
      hopper => Registry.state("hopper", %{"facing" => "down", "enabled" => "true"}),
      comparator =>
        Registry.state("comparator", %{
          "facing" => "west",
          "mode" => "compare",
          "powered" => "false"
        })
    })

    ref = make_ref()

    {:storage, _, _} =
      Region.menu(ctx.oa, self(), at, grant(:subscribe, at, %{menu: :storage, view_ref: ref}))

    actor = Map.merge(grant(:click, at), %{health: 20.0, position: {x + 0.5, y + 1.0, z + 2.5}})

    click = fn inventory, action, slot ->
      actor = %{actor | expires: Valimc.TestRegion.grant_expires()}

      Region.container_click(ctx.oa, self(), ref, at, actor, %{
        inventory: inventory,
        action: action,
        slot: slot,
        button: 0
      })
    end

    inner = ItemStack.new("blue_shulker_box")
    # The cursor's box stays on the cursor.
    {:ok, inventory, view, [], []} = click.(%Inventory{carried: inner}, :pickup, 4)
    assert inventory.carried == inner and elem(view.slots, 4) == nil

    # Shift-click: the box stays in the hotbar, the stone goes in.
    inventory = %{
      inventory
      | carried: nil,
        slots: %{36 => inner, 37 => ItemStack.new("stone", 64)}
    }

    {:ok, inventory, view, [], []} = click.(inventory, :quick_move, 54)
    assert inventory.slots[36] == inner and Enum.all?(Tuple.to_list(view.slots), &is_nil/1)
    {:ok, inventory, view, [], []} = click.(inventory, :quick_move, 55)
    assert inventory.slots[37] == nil and elem(view.slots, 0) == ItemStack.new("stone", 64)

    Valimc.TestRegion.replace_section(ctx.oa, fn section ->
      %{revision: revision} = section.containers.entries[hopper]
      slots = {inner, ItemStack.new("dirt", 2), nil, nil, nil}
      {:ok, containers, _} = Containers.replace(section.containers, hopper, revision, slots)
      %{section | containers: containers}
    end)

    {:ok, _} = Region.step(ctx.oa, 20)
    assert elem(entry(ctx.oa, hopper).slots, 0) == inner
    assert elem(entry(ctx.oa, at).slots, 1) == ItemStack.new("dirt", 2)
    # 64/64 stone and 2/64 dirt over 27 slots: 1 + floor(14 * f).
    assert Valimc.TestRegion.section(ctx.oa).comparators[comparator] == 1
  end

  test "breaking drops the box holding its contents, in survival and creative", ctx do
    survival = {ctx.x + 50, 64, ctx.z + 20}
    creative = {ctx.x + 52, 64, ctx.z + 20}
    empty = {ctx.x + 54, 64, ctx.z + 20}

    set(ctx.oa, %{
      survival => box("up", "lime_shulker_box"),
      creative => box("up"),
      empty => box("up")
    })

    fill(
      ctx.oa,
      survival,
      holding([{0, ItemStack.new("diamond", 3)}, {9, ItemStack.new("dirt", 7)}])
    )

    fill(ctx.oa, creative, holding([{26, ItemStack.new("emerald", 2)}]))

    # The player's loot holds the box itself; the owner adds what it held.
    block = Valimc.TestBlocks.get(survival)
    {:ok, [loot]} = Valimc.Blocks.MiningLoot.drops(block, survival)
    assert loot == ItemStack.new("lime_shulker_box")
    records = [Valimc.Entity.ItemDrop.pop(survival, loot)]

    assert :ok =
             Region.mine_block(
               ctx.oa,
               survival,
               %{survival => {block, Valimc.Blocks.after_removal(block)}},
               records
             )

    assert entry(ctx.oa, survival) == nil
    assert [dropped] = items(ctx.oa)

    assert ItemStack.component(dropped.stack, "minecraft:container") ==
             [ItemStack.new("diamond", 3)] ++
               List.duplicate(nil, 8) ++ [ItemStack.new("dirt", 7)]

    assert dropped.stack.item_id == ItemTypes.id("lime_shulker_box")

    for at <- [creative, empty] do
      {:ok, observed} = Region.observe_blocks(ctx.oa, [at])
      :ok = Region.destroy_block(ctx.oa, observed.fence, at, Valimc.TestRegion.grant_expires())
      assert entry(ctx.oa, at) == nil
    end

    # Only the filled box drops, at its centre with the default pickup delay.
    {cx, cy, cz} = creative
    assert [held] = Enum.reject(items(ctx.oa), &(&1.stack == dropped.stack))
    assert {held.entity.x, held.entity.y, held.entity.z} == {cx + 0.5, cy + 0.5, cz + 0.5}
    assert held.motion.pickup_delay == 10

    assert ItemStack.component(held.stack, "minecraft:container") ==
             List.duplicate(nil, 26) ++ [ItemStack.new("emerald", 2)]
  end

  test "contents survive a group handoff and a restart", ctx do
    at = {elem(ctx.b, 0) * 128 + 10, 64, ctx.z + 20}
    set(ctx.ob, %{at => box("east", "black_shulker_box")})
    fill(ctx.ob, at, holding([{13, ItemStack.new("emerald", 5)}]))

    {pb, _} = ctx.ob
    {:ok, [_]} = Region.hand_over(pb, ctx.pa)
    {:ok, ob} = Valimc.TestWorld.item_owner(ctx.b)
    assert elem(entry(ob, at).slots, 13) == ItemStack.new("emerald", 5)

    # One group holds both sections now: flush and stop each group once.
    pids =
      for key <- [ctx.a, ctx.b], {pid, _} <- Valimc.TestWorld.registered(key), uniq: true, do: pid

    for pid <- pids, do: :ok = Region.flush(pid)
    for pid <- pids, do: TestScope.kill(pid)

    {:ok, ob} = Valimc.TestWorld.item_owner(ctx.b)
    assert %{kind: :shulker_box, slots: slots} = entry(ob, at)
    assert elem(slots, 13) == ItemStack.new("emerald", 5)
  end
end
