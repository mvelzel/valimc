defmodule Valimc.BarrelRegionTest do
  @moduledoc """
  Barrels in region owners (VMC-032c1): placement facing, the 27-slot storage
  entry behind the three-row chest menu, `open` and the sounds as viewers come
  and go, hoppers, comparators, the spill on breaking, loot on first open, and
  contents through a restart and a group handoff.
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.BlockEntityTypes, as: Types
  alias Valimc.Data.Blocks, as: Registry
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.TestScope
  alias Valimc.World.{BlockBatch, BlockEntities, Blocks, Containers, Region, RegionStorage}

  setup do
    nonce = System.unique_integer([:positive])
    a = {97_000 + rem(nonce, 3_333) * 3, 2470}
    b = {elem(a, 0) + 1, elem(a, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-barrel-#{nonce}")

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
    %{a: a, b: b, oa: oa, ob: ob, pa: pa, base: base, x: rx * 128, z: rz * 128}
  end

  defp barrel(facing, open \\ false),
    do: Registry.state("barrel", %{"facing" => facing, "open" => Atom.to_string(open)})

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp entry(owner, at), do: Valimc.TestRegion.section(owner).containers.entries[at]

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

  defp viewer do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp count_of(stacks, name) do
    id = ItemTypes.id(name)
    for(%{item_id: ^id, count: n} <- stacks, do: n) |> Enum.sum()
  end

  test "placement faces away from the look in all six directions and owns a 27-slot entry",
       ctx do
    item = Valimc.Protocol.Data.item("barrel")
    target = {ctx.x + 20, 64, ctx.z + 20}

    looks = [
      {0.0, 90.0, "up"},
      {0.0, -90.0, "down"},
      {0.0, 0.0, "north"},
      {180.0, 0.0, "south"},
      {90.0, 0.0, "east"},
      {-90.0, 0.0, "west"}
    ]

    for {yaw, pitch, facing} <- looks do
      request = %{position: target, face: 1, cursor: {0.5, 1.0, 0.5}, yaw: yaw, pitch: pitch}
      {:ok, %{values: values}} = Valimc.Blocks.Placement.target(item, 0, request)
      {:ok, writes} = Region.placement(ctx.oa, item, values, target)
      assert Map.new(writes)[target] == barrel(facing), inspect({yaw, pitch, facing})
    end

    request = %{position: target, face: 1, cursor: {0.5, 1.0, 0.5}, yaw: 0.0, pitch: 0.0}
    {:ok, %{values: values}} = Valimc.Blocks.Placement.target(item, 0, request)
    {:ok, writes} = Region.placement(ctx.oa, item, values, target)
    {:ok, observed} = Region.observe_blocks(ctx.oa, [target])
    {:ok, batch} = BlockBatch.prepare(Map.new(writes))

    {:ok, _} =
      Region.place_block(ctx.oa, observed.fence, batch, Valimc.TestRegion.grant_expires())

    assert Valimc.TestBlocks.get(target) == barrel("north")
    assert %{kind: :barrel, slots: slots} = entry(ctx.oa, target)
    assert slots == Tuple.duplicate(nil, 27)
    assert Types.supported?(barrel("up", true)) and not Types.unsupported?(barrel("up", true))
  end

  test "the first viewer opens it with a sound and the last closes it; a spectator is silent",
       ctx do
    at = {ctx.x + 30, 64, ctx.z + 20}
    {x, y, z} = at
    set(ctx.oa, %{at => barrel("north")})
    Valimc.TestWorld.subscribe(MapSet.new([ctx.a]), MapSet.new())

    assert {:storage, _, view} = Region.menu(ctx.oa, self(), at, grant(:open, at))
    assert view.kind == :barrel and tuple_size(view.slots) == 27

    [first, second, spectator] = for _ <- 1..3, do: viewer()
    subscribe = fn _pid, ref, extra -> Map.merge(%{menu: :storage, view_ref: ref}, extra) end

    {:storage, _, _} =
      Region.menu(ctx.oa, first, at, grant(:subscribe, at, subscribe.(first, make_ref(), %{})))

    assert Valimc.TestBlocks.get(at) == barrel("north", true)
    # `BarrelBlockEntity.playSound`: the centre of the front face, volume 0.5.
    assert_receive {:event, {:sound, {fx, fy, fz}, 16.0, packet}}
    assert {fx, fy, fz} == {x + 0.5, y + 0.5, z + 0.0}
    body = IO.iodata_to_binary(elem(packet, 1))
    assert <<142, 1, 4, _::binary>> = body

    second_ref = make_ref()

    {:storage, _, _} =
      Region.menu(ctx.oa, second, at, grant(:subscribe, at, subscribe.(second, second_ref, %{})))

    {:storage, _, _} =
      Region.menu(
        ctx.oa,
        spectator,
        at,
        grant(:subscribe, at, subscribe.(spectator, make_ref(), %{mode: :spectator}))
      )

    refute_receive {:event, {:sound, _, _, _}}, 20
    # The entry and its viewers stay through the state change.
    assert Valimc.World.ContainerViewers.open_count(
             Valimc.TestRegion.section(ctx.oa).container_viewers,
             at
           ) == 2

    Process.exit(first, :kill)
    refute_receive {:event, {:sound, _, _, _}}, 20
    assert Valimc.TestBlocks.get(at) == barrel("north", true)
    Region.unsubscribe_container(ctx.oa, second, second_ref)
    assert_receive {:event, {:sound, {^fx, ^fy, ^fz}, 16.0, packet}}
    assert <<141, 1, 4, _::binary>> = IO.iodata_to_binary(elem(packet, 1))
    assert Valimc.TestBlocks.get(at) == barrel("north")
    assert %{kind: :barrel} = entry(ctx.oa, at)
  end

  test "the chest menu engine fills it; hoppers, comparators and the spill treat it as 27 slots",
       ctx do
    TestScope.simulate(ctx.oa, ctx.a)
    at = {ctx.x + 40, 64, ctx.z + 20}
    {x, y, z} = at
    hopper = {x, y + 1, z}
    comparator = {x + 1, y, z}

    set(ctx.oa, %{
      at => barrel("up"),
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

    # Put a stack down in slot 4, then shift-click a hotbar stack in.
    {:ok, inventory, _, [], []} =
      click.(%Inventory{carried: ItemStack.new("diamond", 3)}, :pickup, 4)

    inventory = %{inventory | slots: %{36 => ItemStack.new("stone", 64)}}
    # Window slot 27 + 27 is hotbar slot 36.
    {:ok, inventory, view, [], []} = click.(inventory, :quick_move, 54)
    assert inventory.slots[36] == nil
    assert elem(view.slots, 0) == ItemStack.new("stone", 64)
    assert elem(view.slots, 4) == ItemStack.new("diamond", 3)

    Valimc.TestRegion.replace_section(ctx.oa, fn section ->
      %{revision: revision} = section.containers.entries[hopper]
      slots = put_elem(Tuple.duplicate(nil, 5), 0, ItemStack.new("dirt", 2))
      {:ok, containers, _} = Containers.replace(section.containers, hopper, revision, slots)
      %{section | containers: containers}
    end)

    {:ok, _} = Region.step(ctx.oa, 20)
    stacks = Tuple.to_list(entry(ctx.oa, at).slots)
    assert count_of(stacks, "dirt") == 2
    # Two stacks of 64 and 3/64 diamonds, 2/64 dirt over 27 slots: 1 + floor(14 * f).
    assert Valimc.TestRegion.section(ctx.oa).comparators[comparator] == 1

    block = Valimc.TestBlocks.get(at)

    assert :ok =
             Region.mine_block(
               ctx.oa,
               at,
               %{at => {block, Valimc.Blocks.after_removal(block)}},
               []
             )

    assert entry(ctx.oa, at) == nil

    spilled =
      for {_, %{kind: :item, stack: stack}} <-
            Valimc.TestRegion.section(ctx.oa).entities.store.entries,
          do: stack

    assert count_of(spilled, "stone") == 64 and count_of(spilled, "diamond") == 3 and
             count_of(spilled, "dirt") == 2
  end

  test "contents survive a group handoff and a restart", ctx do
    at = {elem(ctx.b, 0) * 128 + 10, 64, ctx.z + 20}
    set(ctx.ob, %{at => barrel("east")})

    Valimc.TestRegion.replace_section(ctx.ob, fn section ->
      %{revision: revision} = section.containers.entries[at]
      slots = put_elem(Tuple.duplicate(nil, 27), 26, ItemStack.new("emerald", 5))
      {:ok, containers, _} = Containers.replace(section.containers, at, revision, slots)
      %{section | containers: containers}
    end)

    {pb, _} = ctx.ob
    {:ok, [_]} = Region.hand_over(pb, ctx.pa)
    {:ok, ob} = Valimc.TestWorld.item_owner(ctx.b)
    assert elem(entry(ob, at).slots, 26) == ItemStack.new("emerald", 5)
    {:storage, _, view} = Region.menu(ob, self(), at, grant(:open, at))
    assert elem(view.slots, 26) == ItemStack.new("emerald", 5)

    # One group holds both sections now: flush and stop each group once.
    pids =
      for key <- [ctx.a, ctx.b], {pid, _} <- Valimc.TestWorld.registered(key), uniq: true, do: pid

    for pid <- pids, do: :ok = Region.flush(pid)
    for pid <- pids, do: TestScope.kill(pid)

    {:ok, ob} = Valimc.TestWorld.item_owner(ctx.b)
    assert %{kind: :barrel, slots: slots} = entry(ob, at)
    assert elem(slots, 26) == ItemStack.new("emerald", 5)
  end

  test "a generated barrel's loot table unrolls on first open, once" do
    nonce = System.unique_integer([:positive])
    key = {93_000 + rem(nonce, 3_333) * 3, -1990}
    base = Path.join(System.tmp_dir!(), "valimc-loot-barrel-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {rx, rz} = key
    size = Valimc.Data.Grid.region_size()
    {cx, cz} = chunk = {rx * size + 1, rz * size + 2}
    {x, y, z} = at = {cx * 16 + 2, 70, cz * 16 + 4}
    state = barrel("up")
    {:ok, blocks} = Blocks.new(key)
    :ok = Blocks.put(blocks, %{at => state})
    {:ok, image} = Blocks.column_image(blocks, chunk)

    tag =
      {:compound,
       %{
         "id" => {:string, "minecraft:barrel"},
         "x" => {:int, x},
         "y" => {:int, y},
         "z" => {:int, z},
         "LootTable" => {:string, "minecraft:chests/simple_dungeon"},
         "LootTableSeed" => {:long, 5_530_731_629_134_945_404},
         "components" => {:compound, %{}}
       }}

    {:ok, nbt} = BlockEntities.encode_nbt(tag)

    :ok =
      RegionStorage.import(base, :overworld, key, %{
        columns: %{chunk => image},
        block_entities: %{at => {Types.type_id(state), nbt}}
      })

    {:ok, owner} = Valimc.TestWorld.owner(key)
    assert {:storage, _, view} = Region.menu(owner, self(), at, grant(:open, at))
    # Vanilla's simple dungeon fill for this seed (as `loot_chest_region_test.exs`).
    assert elem(view.slots, 0) == ItemStack.new("enchanted_golden_apple", 1)
    assert count_of(Tuple.to_list(view.slots), "rotten_flesh") == 15
    assert {:storage, _, again} = Region.menu(owner, self(), at, grant(:open, at))
    assert again.slots == view.slots and again.revision == view.revision
  end
end
