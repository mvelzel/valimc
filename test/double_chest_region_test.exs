defmodule Valimc.DoubleChestRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Chest
  alias Valimc.Data.Blocks, as: Registry
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.{BlockBatch, Containers, Region}

  setup do
    nonce = System.unique_integer([:positive])
    a = {94_000 + rem(nonce, 3_333) * 3, 2100}
    b = {elem(a, 0) + 1, elem(a, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-double-chest-#{nonce}")

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
    {:ok, {pb, _}} = Valimc.TestWorld.item_owner(b)
    {:ok, [_]} = Region.hand_over(pb, pa)
    {:ok, ob} = Valimc.TestWorld.item_owner(b)
    %{a: a, b: b, oa: oa, ob: ob, pid: pa, base: base}
  end

  defp set(owner, position, state) do
    {:ok, observed} = Region.observe_blocks(owner, [position])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{position => state})
  end

  defp fill(owner, at, slots) do
    Valimc.TestRegion.replace_section(owner, fn resource ->
      entry = resource.containers.entries[at]
      {:ok, containers, _} = Containers.replace(resource.containers, at, entry.revision, slots)
      %{resource | containers: containers}
    end)
  end

  defp grant(kind, at, extra \\ %{}) do
    {x, y, z} = at

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

  defp pair(ctx, across) do
    {rx, rz} = ctx.a
    left = {rx * 128 + if(across, do: 127, else: 40), 64, rz * 128 + 40}
    {x, y, z} = left
    right = {x + 1, y, z}
    owner = if across, do: ctx.ob, else: ctx.oa
    single = Registry.default_state("chest")
    set(ctx.oa, left, single)
    # The native placement chooses a right half; its shape updates join the old chest.
    item = Valimc.Protocol.Data.item("chest")
    request = %{position: right, face: 1, cursor: {0.5, 1.0, 0.5}, yaw: 0.0, pitch: 45.0}
    {:ok, %{values: values}} = Valimc.Blocks.Placement.target(item, 0, request)
    {:ok, writes} = Region.placement(owner, item, values, right)
    {:ok, observed} = Region.observe_blocks(owner, [right])
    {:ok, batch} = BlockBatch.prepare(Map.new(writes))

    {:ok, _} =
      Region.place_block(owner, observed.fence, batch, Valimc.TestRegion.grant_expires())

    assert not Chest.single?(Valimc.TestBlocks.get(left)),
           inspect(
             {writes, Registry.properties(Valimc.TestBlocks.get(left)),
              Registry.properties(Valimc.TestBlocks.get(right)), values}
           )

    assert not Chest.single?(Valimc.TestBlocks.get(right))
    {left, right, owner}
  end

  test "a busy half defers a session refresh without closing; removal still closes", ctx do
    {_left, right, owner} = pair(ctx, true)
    ref = make_ref()

    {:chest, block, view} =
      Region.menu(owner, self(), right, grant(:subscribe, right, %{menu: :chest, view_ref: ref}))

    {x, y, z} = right

    state = %{
      life_stage: :alive,
      teleport_pending: false,
      socket: nil,
      threshold: 256,
      connection: self(),
      inventory: %Inventory{},
      player: %{
        x: x + 0.5,
        y: y * 1.0,
        z: z + 2.5,
        yaw: 0.0,
        uuid: <<0::128>>,
        dimension: :overworld,
        input: %Valimc.Player.Input{load_ticks: 0},
        game_mode: %{current: :survival}
      },
      table_menu: %{
        id: 1,
        kind: :chest,
        owner: owner,
        position: right,
        view_ref: ref,
        block: block,
        view: view,
        opener: true,
        dirty: false,
        progress_dirty: false
      }
    }

    Valimc.TestRegion.replace_section(owner, fn resource ->
      %{resource | jobs: %{resource.jobs | entries: Map.put(resource.jobs.entries, :plan, %{})}}
    end)

    Valimc.Protocol.Codec.open_outbox()
    deferred = Valimc.Player.Menus.changed(state, 1)
    assert deferred.table_menu.view_ref == ref and deferred.table_menu.dirty
    assert Valimc.Protocol.Codec.take_outbox() == []

    Valimc.TestRegion.replace_section(owner, fn resource ->
      %{resource | jobs: %{resource.jobs | entries: Map.delete(resource.jobs.entries, :plan)}}
    end)

    Valimc.Protocol.Codec.open_outbox()
    refreshed = Valimc.Player.Menus.check_table_menu(deferred)
    assert refreshed.table_menu.view_ref == ref and not refreshed.table_menu.dirty
    assert Valimc.Protocol.Codec.take_outbox() != []

    :ok = Region.mine_block(owner, right, %{right => {block, 0}}, [])
    Valimc.Protocol.Codec.open_outbox()
    assert Valimc.Player.Menus.changed(refreshed, 2).table_menu == nil
    assert Valimc.Protocol.Codec.take_outbox() != []
  end

  test "one collection spans both sections, survives reload, and breaking one half keeps the other",
       ctx do
    {left, right, owner} = pair(ctx, true)
    ref = make_ref()
    {:chest, _, view} = Region.menu(owner, self(), right, grant(:open, right))
    assert view.rows == 6 and tuple_size(view.slots) == 54

    {:chest, _, _} =
      Region.menu(owner, self(), right, grant(:subscribe, right, %{menu: :chest, view_ref: ref}))

    {x, y, z} = right

    actor =
      Map.merge(grant(:click, right), %{health: 20.0, position: {x + 0.5, y * 1.0, z + 2.5}})

    click = fn inventory, action, slot ->
      actor = %{actor | expires: Valimc.TestRegion.grant_expires()}

      Region.container_click(owner, self(), ref, right, actor, %{
        inventory: inventory,
        action: action,
        slot: slot,
        button: 0
      })
    end

    # Put matching stacks in each half through the same menu the player uses.
    {:ok, inventory, _, [], []} =
      click.(%Inventory{carried: ItemStack.new("diamond", 3)}, :pickup, 0)

    {:ok, inventory, _, [], []} =
      click.(%{inventory | carried: ItemStack.new("diamond", 7)}, :pickup, 27)

    {:ok, inventory, _, [], []} = click.(inventory, :pickup, 0)
    assert inventory.carried.count == 3
    {:ok, inventory, view, [], []} = click.(inventory, :pickup_all, 0)
    assert inventory.carried.count == 10 and Enum.all?(Tuple.to_list(view.slots), &is_nil/1)
    {:ok, inventory, _, [], []} = click.(inventory, :pickup, 27)
    assert inventory.carried == nil
    :ok = Region.flush(ctx.pid)
    TestScope.kill(ctx.pid)
    {:ok, oa} = Valimc.TestWorld.item_owner(ctx.a)
    {:ok, ob} = Valimc.TestWorld.item_owner(ctx.b)
    assert elem(Valimc.TestRegion.section(oa).containers.entries[left].slots, 0).count == 10

    assert Enum.all?(
             Tuple.to_list(Valimc.TestRegion.section(ob).containers.entries[right].slots),
             &is_nil/1
           )

    {:ok, [_]} = Region.hand_over(elem(ob, 0), elem(oa, 0))
    {:ok, ob} = Valimc.TestWorld.item_owner(ctx.b)
    :ok = Region.mine_block(ob, right, %{right => {Valimc.TestBlocks.get(right), 0}}, [])
    assert Chest.single?(Valimc.TestBlocks.get(left))
    assert elem(Valimc.TestRegion.section(oa).containers.entries[left].slots, 0).count == 10
  end

  test "both local lids and observers retire together; either half's roof blocks opening", ctx do
    {left, right, owner} = pair(ctx, false)
    {x, y, z} = left
    set(owner, {x, y + 1, z}, Registry.default_state("stone"))
    assert {:error, :blocked_chest} = Region.menu(owner, self(), right, grant(:open, right))
    set(owner, {x, y + 1, z}, 0)
    ref = make_ref()

    assert {:chest, _, _} =
             Region.menu(
               owner,
               self(),
               right,
               grant(:subscribe, right, %{menu: :chest, view_ref: ref})
             )

    viewers = Valimc.TestRegion.section(owner).container_viewers
    assert Map.keys(viewers.positions) |> Enum.sort() == Enum.sort([left, right])
    Region.unsubscribe_container(owner, self(), ref)

    Valimc.TestWait.until(fn ->
      Valimc.TestRegion.section(owner).container_viewers.views == %{}
    end)

    assert Valimc.TestRegion.section(owner).container_viewers.positions == %{}
  end

  test "comparators, droppers and two hoppers use both halves in the group tick's order", ctx do
    {left, right, owner} = pair(ctx, true)
    TestScope.simulate(ctx.oa, ctx.a)
    TestScope.simulate(ctx.ob, ctx.b)
    {lx, y, z} = left
    {rx, _, _} = right
    comparator = {rx + 1, y, z}

    set(
      owner,
      comparator,
      Registry.state("comparator", %{
        "facing" => "west",
        "mode" => "compare",
        "powered" => "false"
      })
    )

    empty = Tuple.duplicate(nil, 27)
    fill(ctx.oa, left, Tuple.duplicate(ItemStack.new("stone", 64), 27))
    Region.step(owner, 3)
    # Native CompoundContainer fullness: 27 full slots out of 54 gives eight.
    assert Valimc.TestRegion.section(owner).comparators[comparator] == 8
    fill(ctx.oa, left, empty)
    Region.step(owner, 3)
    assert Valimc.TestRegion.section(owner).comparators[comparator] == 0

    dropper = {lx, y, z + 1}

    set(
      ctx.oa,
      dropper,
      Registry.state("dropper", %{"facing" => "north", "triggered" => "false"})
    )

    fill(ctx.oa, dropper, put_elem(Tuple.duplicate(nil, 9), 0, ItemStack.new("stone")))
    set(ctx.oa, {lx - 1, y, z + 1}, Registry.default_state("redstone_block"))
    Region.step(owner, 5)

    assert elem(Valimc.TestRegion.section(owner).containers.entries[right].slots, 0) ==
             ItemStack.new("stone")

    assert Valimc.TestRegion.section(ctx.oa).containers.entries[left].slots == empty

    fill(ctx.oa, left, put_elem(empty, 0, ItemStack.new("diamond")))
    hopper = Registry.state("hopper", %{"facing" => "down", "enabled" => "true"})
    set(ctx.oa, {lx, y - 1, z}, hopper)
    set(owner, {rx, y - 1, z}, hopper)
    Region.step(owner, 1)
    # Section A ticks first, so its hopper takes the right half's stone;
    # section B's then sees the empty right half and takes A's diamond.
    assert elem(Valimc.TestRegion.section(ctx.oa).containers.entries[{lx, y - 1, z}].slots, 0) ==
             ItemStack.new("stone")

    assert elem(Valimc.TestRegion.section(owner).containers.entries[{rx, y - 1, z}].slots, 0) ==
             ItemStack.new("diamond")

    assert Valimc.TestRegion.section(ctx.oa).containers.entries[left].slots == empty
    assert Valimc.TestRegion.section(owner).containers.entries[right].slots == empty
  end
end
