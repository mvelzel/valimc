defmodule Valimc.RegionGroupTest do
  @moduledoc """
  Group processes (VMC-077j): a group owns several 8 × 8 sections, routes
  each call to its section, ticks them together, commits them in one log
  record, and hands sections to another group with their state, store, table
  and epoch.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.Storage.Log
  alias Valimc.TestScope
  alias Valimc.World.{Region, View}
  alias Valimc.Storage.RegionLog

  setup do
    nonce = System.unique_integer([:positive])
    a = {90_000 + rem(nonce, 3_333) * 3, 1900}
    b = {elem(a, 0) + 1, 1900}
    base = Path.join(System.tmp_dir!(), "valimc-groups-#{nonce}")
    # Changes wait for a flush, so the test decides what one record holds;
    # the test, not the regionizer, moves sections.
    TestScope.isolate([a, b],
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false
    )

    on_exit(fn ->
      for key <- [a, b],
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, {pa, ea}} = Valimc.TestWorld.owner(a)
    {:ok, {pb, eb}} = Valimc.TestWorld.owner(b)
    %{a: a, b: b, base: base, pa: pa, ea: ea, pb: pb, eb: eb}
  end

  defp position({rx, rz}, dx \\ 5), do: {rx * 128 + dx, 70, rz * 128 + 9}

  defp set(owner, position, block) do
    {:ok, observed} = Region.observe_blocks(owner, [position])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{position => block})
  end

  defp merge(ctx) do
    {:ok, [_]} = Region.hand_over(ctx.pb, ctx.pa)

    Valimc.TestWait.until(fn ->
      match?({pid, _, _} when pid == ctx.pa, Valimc.TestWorld.lookup(ctx.b))
    end)
  end

  test "a section handed to another group keeps its epoch, blocks and routes; one tick runs both",
       ctx do
    stone = BlockRegistry.default_state("stone")
    set({ctx.pb, ctx.eb}, position(ctx.b), stone)
    {x, y, z} = position(ctx.b, 6)
    chunk = Valimc.Data.Grid.chunk_key(x, z)
    published = View.row(View.new(), chunk)
    assert ctx.pa != ctx.pb
    merge(ctx)

    # Its published snapshot moved with its table, unchanged (VMC-077p).
    assert View.row(View.new(), chunk) == published

    # The route names the group that adopted it; the section is the same one.
    assert {:ok, {pa, eb}} = Valimc.TestWorld.owner(ctx.b)
    assert pa == ctx.pa and eb == ctx.eb
    assert Region.sections(ctx.pa) == Enum.sort([ctx.a, ctx.b])
    assert Valimc.TestBlocks.get(position(ctx.b)) == stone

    # The group it left had nothing more and retired: a handle held from
    # before the move goes on by its epoch's route.
    Valimc.TestWait.until(fn -> not Process.alive?(ctx.pb) end)
    assert {:ok, %{blocks: blocks}} = Region.observe_blocks({ctx.pb, ctx.eb}, [position(ctx.b)])
    assert blocks[position(ctx.b)] == stone

    # Both sections change through the one group and tick on one number.
    set({ctx.pa, ctx.eb}, position(ctx.b, 6), stone)

    # The adopting group republishes the chunk; the old snapshot still reads
    # what it published, and only the written section has the new revision.
    republished = View.row(View.new(), chunk)
    assert Valimc.Native.snapshot_get(republished, x, y, z) == stone
    assert Valimc.Native.snapshot_get(published, x, y, z) != stone
    {old, old_sections} = Valimc.Native.snapshot_revisions(published)
    {new, new_sections} = Valimc.Native.snapshot_revisions(republished)
    written = div(y + 64, 16)
    assert new > old and Enum.at(new_sections, written) == new

    assert List.delete_at(new_sections, written) == List.delete_at(old_sections, written)
    set({ctx.pa, ctx.ea}, position(ctx.a), stone)
    {:ok, tick} = Region.step({ctx.pa, ctx.ea}, 3)

    assert Valimc.TestRegion.section(ctx.pa, ctx.a).game_tick ==
             Valimc.TestRegion.section(ctx.pa, ctx.b).game_tick

    assert Valimc.TestRegion.section(ctx.pa, ctx.b).game_tick == tick

    # Only the adopting group may change the section's Rust store now.
    ref = Valimc.TestRegion.section(ctx.pa, ctx.b).blocks.ref
    assert Valimc.Native.region_give(ref, self()) == {:error, :not_owner}

    # The group holds one current peer projection. Stored sections must not
    # retain the projections of previous callbacks, with their old stores.
    group = :sys.get_state(ctx.pa)
    assert map_size(group.peers) == 2
    assert Enum.all?(group.sections, fn {_, section} -> section.resource.siblings == %{} end)
  end

  test "a group's sections commit in one log record and reload after a crash", ctx do
    merge(ctx)
    stone = BlockRegistry.default_state("stone")
    set({ctx.pa, ctx.ea}, position(ctx.a), stone)
    set({ctx.pa, ctx.eb}, position(ctx.b), stone)
    :ok = Region.flush(ctx.pa)

    owners = [{:region, :overworld, ctx.a}, {:region, :overworld, ctx.b}]
    stripe = Log.stripe({:region, :overworld, ctx.a})
    :ok = Log.sync(ctx.base, {:region, :overworld, ctx.a})
    {:ok, %{frames: frames}} = RegionLog.read(Log.dir(ctx.base, stripe))

    assert Enum.any?(frames, fn %{ops: ops} ->
             in_frame = for {:frame, owner, _, _} <- ops, do: owner
             Enum.all?(owners, &(&1 in in_frame))
           end)

    TestScope.kill(ctx.pa)
    Valimc.TestWait.until(fn -> Valimc.TestWorld.lookup(ctx.b) == nil end)
    assert Valimc.TestBlocks.get(position(ctx.a)) == stone
    assert Valimc.TestBlocks.get(position(ctx.b)) == stone
    # Each comes back in a group of its own.
    {:ok, {qa, _}} = Valimc.TestWorld.owner(ctx.a)
    {:ok, {qb, _}} = Valimc.TestWorld.owner(ctx.b)
    assert qa != qb
  end

  test "a split moves sections into a new group with their state", ctx do
    merge(ctx)
    stone = BlockRegistry.default_state("stone")
    set({ctx.pa, ctx.eb}, position(ctx.b), stone)
    {:ok, pc, [_]} = Region.split(ctx.pa, :overworld, [ctx.b])

    Valimc.TestWait.until(fn ->
      match?({pid, _, _} when pid == pc, Valimc.TestWorld.lookup(ctx.b))
    end)

    assert Region.sections(ctx.pa) == [ctx.a]
    assert Region.sections(pc) == [ctx.b]
    assert {:ok, {^pc, eb}} = Valimc.TestWorld.owner(ctx.b)
    assert eb == ctx.eb
    assert Valimc.TestBlocks.get(position(ctx.b)) == stone

    # A handle held from before the split goes on by the section's route.
    assert {:ok, %{blocks: blocks}} = Region.observe_blocks({ctx.pa, ctx.eb}, [position(ctx.b)])
    assert blocks[position(ctx.b)] == stone
    on_exit(fn -> if Process.alive?(pc), do: TestScope.kill(pc) end)
  end

  test "block rules cross section borders inside a group and stop at its edge", ctx do
    stone = BlockRegistry.default_state("stone")
    wire = BlockRegistry.default_state("redstone_wire")
    power = BlockRegistry.default_state("redstone_block")
    # A redstone block on section a's east edge; wire just across, in b.
    {ax, z} = ctx.a
    edge = (ax + 1) * 128
    source = {edge - 1, 70, z * 128 + 9}
    wires = [{edge, 70, z * 128 + 9}, {edge + 1, 70, z * 128 + 9}]

    levels = fn ->
      for p <- wires, do: Map.new(BlockRegistry.properties(Valimc.TestBlocks.get(p)))["power"]
    end

    set_all = fn owner, edits ->
      {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
      {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
    end

    set_all.({ctx.pa, ctx.ea}, %{{edge - 1, 69, z * 128 + 9} => stone, source => power})
    set_all.({ctx.pb, ctx.eb}, Map.new(wires, fn {x, y, z} -> {{x, y - 1, z}, stone} end))
    set_all.({ctx.pb, ctx.eb}, Map.new(wires, &{&1, wire}))
    # Separate groups: the rules stop at the group's edge.
    assert levels.() == ["0", "0"]

    merge(ctx)
    set_all.({ctx.pa, ctx.eb}, Map.new(wires, &{&1, BlockRegistry.default_state("air")}))
    set_all.({ctx.pa, ctx.eb}, Map.new(wires, &{&1, wire}))
    assert levels.() == ["15", "14"]
    # A change in a updates b's wire in the same group.
    set_all.({ctx.pa, ctx.ea}, %{source => BlockRegistry.default_state("air")})
    assert levels.() == ["0", "0"]
  end

  test "a section whose adopting group dies before adopting it loads again from its log", ctx do
    stone = BlockRegistry.default_state("stone")
    set({ctx.pb, ctx.eb}, position(ctx.b), stone)
    :ok = Region.flush(ctx.pb)
    # The adopter holds the section's state unread in its mailbox when it dies.
    :sys.suspend(ctx.pa)
    {:ok, [_]} = Region.hand_over(ctx.pb, ctx.pa)
    assert match?({pid, _, _} when pid == ctx.pa, Valimc.TestWorld.lookup(ctx.b))
    TestScope.kill(ctx.pa)

    # The route went with the adopter; the group it left, now empty, retires.
    Valimc.TestWait.until(fn -> Valimc.TestWorld.lookup(ctx.b) == nil end)
    Valimc.TestWait.until(fn -> not Process.alive?(ctx.pb) end)
    assert {:error, {:retry, _}} = Region.observe_blocks({ctx.pb, ctx.eb}, [position(ctx.b)])

    {:ok, {pid, epoch}} = Valimc.TestWorld.owner(ctx.b)
    assert pid not in [ctx.pa, ctx.pb] and epoch != ctx.eb
    assert Valimc.TestBlocks.get(position(ctx.b)) == stone
  end

  # Two more sections of the same world in one group, with `records` written
  # first: `{c, d, group, epoch of c, epoch of d}`.
  defp item_group(ctx, records) do
    {cx, z} = c = {elem(ctx.b, 0) + 1, elem(ctx.b, 1)}
    d = {cx + 1, z}

    TestScope.isolate([c, d],
      world_path: ctx.base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false,
      item_simulation: true
    )

    on_exit(fn ->
      for key <- [c, d], {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
    end)

    for {key, list} <- records,
        do: Valimc.TestDisk.write(ctx.base, key.(c, d), :items, %{records: list})

    {:ok, {pc, ec}} = Valimc.TestWorld.owner(c)
    {:ok, {pd, ed}} = Valimc.TestWorld.owner(d)
    {:ok, [_]} = Region.hand_over(pd, pc)

    Valimc.TestWait.until(fn ->
      match?({pid, _, _} when pid == pc, Valimc.TestWorld.lookup(d))
    end)

    TestScope.simulate({pc, ec}, c)
    TestScope.simulate({pc, ed}, d)
    {c, d, pc, ec, ed}
  end

  defp item(uuid, x, z, count, motion),
    do: %{
      uuid: uuid,
      x: x,
      y: 68.0,
      z: z,
      stack: Valimc.Protocol.ItemStack.new("stone", count),
      motion: motion
    }

  defp store(group, epoch), do: Valimc.TestRegion.section({group, epoch}).entities.store

  defp holds?(group, epoch, uuid),
    do: match?({:ok, _}, Valimc.Entity.Store.find(store(group, epoch), uuid))

  test "an item crossing into another section of the group moves there in one commit", ctx do
    # An item at c's east edge, moving east into d.
    uuid = <<7::128>>
    {cx, z} = c_key(ctx)
    east = %Valimc.Entity.ItemMotionState{velocity: {0.3, 0.0, 0.0}, no_gravity: true}
    moving = item(uuid, cx * 128 + 127.85, z * 128 + 4.5, 3, east)
    {c, d, pc, ec, ed} = item_group(ctx, [{fn c, _ -> c end, [moving]}])

    Valimc.TestWait.until(fn -> holds?(pc, ed, uuid) or (Region.step({pc, ec}, 1) && false) end)
    refute holds?(pc, ec, uuid)
    {:ok, {_, id, _}} = Valimc.Entity.Store.find(store(pc, ed), uuid)
    assert store(pc, ed).entries[id].hops == 1
    # No intent or receipt: the move is the group's own.
    assert store(pc, ec).ledger.outgoing == nil and store(pc, ed).ledger.incoming == %{}

    # One log record withdraws it from c and adds it to d.
    :ok = Region.flush(pc)
    :ok = Log.sync(ctx.base, {:region, :overworld, c})

    {:ok, %{frames: frames}} =
      RegionLog.read(Log.dir(ctx.base, Log.stripe({:region, :overworld, c})))

    owners = [{:region, :overworld, c}, {:region, :overworld, d}]

    assert Enum.any?(frames, fn %{ops: ops} ->
             in_frame = for {:frame, owner, _, _} <- ops, do: owner
             Enum.all?(owners, &(&1 in in_frame))
           end)

    TestScope.kill(pc)
    Valimc.TestWait.until(fn -> Valimc.TestWorld.lookup(d) == nil end)
    saved = fn key -> (Valimc.TestDisk.read(ctx.base, key, :items) || %{records: []}).records end
    assert saved.(c) == []
    assert Enum.map(saved.(d), & &1.uuid) == [uuid]
  end

  test "a border item merges into its neighbour section's stack inside the group", ctx do
    {cx, z} = c_key(ctx)
    still = %Valimc.Entity.ItemMotionState{age: 30, no_gravity: true}
    donor = item(<<8::128>>, (cx + 1) * 128 - 0.1, z * 128 + 7.5, 2, still)
    recipient = item(<<9::128>>, (cx + 1) * 128 + 0.1, z * 128 + 7.5, 3, %{still | age: 100})

    {_c, _d, pc, ec, ed} =
      item_group(ctx, [{fn c, _ -> c end, [donor]}, {fn _, d -> d end, [recipient]}])

    Valimc.TestWait.until(fn ->
      not holds?(pc, ec, donor.uuid) or (Region.step({pc, ec}, 1) && false)
    end)

    {:ok, {_, id, _}} = Valimc.Entity.Store.find(store(pc, ed), recipient.uuid)
    assert store(pc, ed).entries[id].stack.count == 5
    assert store(pc, ec).ledger.outgoing == nil and store(pc, ed).ledger.incoming == %{}
  end

  test "a fence binds and snips cows across sections in one group frame", ctx do
    alias Valimc.Entity.{Body, Store}
    alias Valimc.Protocol.ItemStack
    {cx, cz} = c_key(ctx)
    x = (cx + 1) * 128
    z = cz * 128 + 9
    {:ok, body} = Body.new("minecraft:cow")
    left = Store.body_record(body, <<71::128>>, {x - 1.5, 70.0, z + 0.5})
    right = Store.body_record(body, <<72::128>>, {x + 1.5, 70.0, z + 0.5})

    {c, d, pc, ec, ed} =
      item_group(ctx, [{fn c, _ -> c end, [left]}, {fn _, d -> d end, [right]}])

    fence = {x, 70, z + 2}
    set({pc, ed}, fence, BlockRegistry.default_state("oak_fence"))

    for px <- (x - 3)..(x + 3), pz <- (z - 1)..(z + 3) do
      owner = if px < x, do: {pc, ec}, else: {pc, ed}
      set(owner, {px, 69, pz}, BlockRegistry.default_state("grass_block"))
    end

    player = <<73::128>>

    request = %{
      item: ItemStack.new("lead"),
      infinite: false,
      player: player,
      sneaking: false,
      holder: %{id: 70, x: x * 1.0, y: 70.0, z: z + 0.5, width: 0.6, height: 1.8}
    }

    for {epoch, uuid} <- [{ec, left.uuid}, {ed, right.uuid}],
        do: assert({:ok, %{hand: {:use, 1}}} = Region.interact_entity({pc, epoch}, uuid, request))

    grant = %{
      kind: :open,
      mode: :survival,
      eye: {x * 1.0, 71.62, z + 0.5},
      expires: System.monotonic_time(:millisecond) + 5000,
      hand: :main,
      player: player,
      secondary: false,
      main: false,
      off: false
    }

    assert Region.menu({pc, ed}, self(), fence, grant) == :swing

    knot = fn ->
      for {_, %{body: %{type: "minecraft:leash_knot"}} = entry} <- store(pc, ed).entries,
          do: entry
    end

    [entry] = knot.()

    cow = fn epoch, uuid ->
      current = store(pc, epoch)
      {:ok, {_, id, _}} = Store.find(current, uuid)
      Valimc.TestBodies.body(current.entries[id])
    end

    for {epoch, uuid} <- [{ec, left.uuid}, {ed, right.uuid}] do
      assert cow.(epoch, uuid).mob.leash.holder == {:knot, fence}
      assert cow.(epoch, uuid).mob.leash.id == entry.entity.entity_id
    end

    # Its next AI tick must still find the knot in the neighbouring section.
    Region.step({pc, ec}, 1)
    assert cow.(ec, left.uuid).mob.leash.holder == {:knot, fence}
    :ok = Region.flush(pc)
    :ok = Log.sync(ctx.base, {:region, :overworld, c})

    {:ok, %{frames: frames}} =
      RegionLog.read(Log.dir(ctx.base, Log.stripe({:region, :overworld, c})))

    owners = [{:region, :overworld, c}, {:region, :overworld, d}]

    assert Enum.any?(frames, fn %{ops: ops} ->
             in_frame = for {:frame, owner, _, _} <- ops, do: owner
             Enum.all?(owners, &(&1 in in_frame))
           end)

    # Both cows return to the player before the now-empty knot disappears.
    assert {:ok, _} = Region.interact_knot({pc, ed}, entry.entity.uuid, %{request | item: nil})
    assert knot.() == []

    for {epoch, uuid} <- [{ec, left.uuid}, {ed, right.uuid}],
        do: assert(cow.(epoch, uuid).mob.leash.holder == {:player, player})

    assert Region.menu({pc, ed}, self(), fence, grant) == :swing
    [entry] = knot.()

    assert {:ok, %{hand: {:wear, 1}}} =
             Region.interact_knot({pc, ed}, entry.entity.uuid, %{
               request
               | item: ItemStack.new("shears")
             })

    assert knot.() == []

    for {epoch, uuid} <- [{ec, left.uuid}, {ed, right.uuid}] do
      assert cow.(epoch, uuid).mob.leash == nil

      leads =
        for {_, %{kind: :item, stack: stack}} <- store(pc, epoch).entries,
            stack.item_id == Valimc.Protocol.ItemTypes.id("minecraft:lead"),
            do: stack.count

      assert leads == [1]
    end
  end

  defp c_key(ctx), do: {elem(ctx.b, 0) + 1, elem(ctx.b, 1)}

  test "a hand-over moves only the sections the group still holds", ctx do
    assert Region.hand_over(ctx.pa, ctx.pa) == {:error, :invalid_handoff}
    # Keys named from reports that are behind: a section the group no longer
    # holds is not handed over, the others are.
    assert Region.hand_over(ctx.pa, ctx.pb, [ctx.b]) == {:ok, []}
    assert {:ok, nil, []} = Region.split(ctx.pa, :overworld, [ctx.b])
  end
end
