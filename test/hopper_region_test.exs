defmodule Valimc.HopperRegionTest do
  @moduledoc """
  Hoppers in region owners (VMC-049a): set by a raw write they own an entry,
  feed a furnace from above and a side and empty it below, power locks them,
  they take item entities above them, give across a section line once both
  sections share a group, and open their menu. The transfers themselves are
  `check_hoppers.exs`'s.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.{Containers, Region}

  setup do
    nonce = System.unique_integer([:positive])
    a = {99_000 + rem(nonce, 3_333) * 3, 2310}
    b = {elem(a, 0) + 1, 2310}
    base = Path.join(System.tmp_dir!(), "valimc-hoppers-#{nonce}")

    TestScope.isolate([a, b],
      world_path: base,
      region_ticks: :manual,
      regionizer: false,
      cooking_simulation: true
    )

    on_exit(fn ->
      for key <- [a, b],
          {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, {pa, ea}} = Valimc.TestWorld.owner(a)
    {:ok, {pb, eb}} = Valimc.TestWorld.owner(b)
    TestScope.simulate({pa, ea}, a)
    TestScope.simulate({pb, eb}, b)
    {ax, az} = a
    %{a: a, b: b, owner: {pa, ea}, pa: pa, pb: pb, eb: eb, x: ax * 128, z: az * 128}
  end

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp hopper(facing),
    do: BlockRegistry.state("hopper", %{"facing" => facing, "enabled" => "true"})

  defp chest,
    do:
      BlockRegistry.state("chest", %{
        "facing" => "north",
        "type" => "single",
        "waterlogged" => "false"
      })

  defp entry(owner, position, key \\ nil),
    do: Valimc.TestRegion.section(owner, key).containers.entries[position]

  defp fill(owner, position, stacks) do
    Valimc.TestRegion.replace_section(owner, fn section ->
      {containers, entry} =
        case Containers.observe(section.containers, position) do
          {:ok, entry} ->
            {section.containers, entry}

          :error ->
            {:ok, containers, entry} =
              Containers.create(section.containers, section.key, position, 3)

            {containers, entry}
        end

      size = tuple_size(entry.slots)
      slots = List.to_tuple(Enum.take(stacks ++ List.duplicate(nil, size), size))
      {:ok, containers, _} = Containers.replace(containers, position, entry.revision, slots)
      %{section | containers: containers}
    end)
  end

  defp count(owner, position, name, key \\ nil) do
    case entry(owner, position, key) do
      %{slots: slots} -> slots |> Tuple.to_list() |> count_of(name)
      %{cooking: cooking} -> cooking.slots |> Tuple.to_list() |> count_of(name)
      nil -> 0
    end
  end

  defp count_of(stacks, name) do
    id = Valimc.Protocol.ItemTypes.id(name)
    for(%{item_id: ^id, count: n} <- stacks, do: n) |> Enum.sum()
  end

  test "hoppers feed a furnace from above and a side and take its output below", ctx do
    {x, z} = {ctx.x + 20, ctx.z + 20}
    furnace = {x, 66, z}
    {top, top_chest} = {{x, 67, z}, {x, 68, z}}
    {side, side_chest} = {{x + 1, 66, z}, {x + 1, 67, z}}
    {bottom, bottom_chest} = {{x, 65, z}, {x, 64, z}}

    set(ctx.owner, %{
      furnace => BlockRegistry.default_state("furnace"),
      top => hopper("down"),
      top_chest => chest(),
      side => hopper("west"),
      side_chest => chest(),
      bottom => hopper("down"),
      bottom_chest => chest()
    })

    # A raw write gives the hoppers their entries, as vanilla's block entity.
    assert %{kind: :hopper, slots: {nil, nil, nil, nil, nil}} = entry(ctx.owner, top)
    fill(ctx.owner, top_chest, [ItemStack.new("raw_iron", 2)])
    fill(ctx.owner, side_chest, [ItemStack.new("coal", 1)])

    Valimc.TestWait.until(
      fn ->
        {:ok, _} = Region.step(ctx.owner, 1)
        count(ctx.owner, bottom_chest, "iron_ingot") == 2
      end,
      30_000
    )

    assert count(ctx.owner, top_chest, "raw_iron") == 0
    assert count(ctx.owner, side_chest, "coal") == 0
    assert count(ctx.owner, furnace, "raw_iron") == 0
  end

  test "power locks a hopper; once free it pushes and takes an item entity above it", ctx do
    {x, z} = {ctx.x + 40, ctx.z + 20}
    {at, below, power} = {{x, 65, z}, {x, 64, z}, {x + 1, 65, z}}
    set(ctx.owner, %{at => hopper("down"), below => chest()})
    fill(ctx.owner, at, [ItemStack.new("dirt", 5)])
    fill(ctx.owner, below, [])

    # A hopper holding items switches `enabled` and keeps them.
    set(ctx.owner, %{power => BlockRegistry.default_state("redstone_block")})
    assert Map.new(BlockRegistry.properties(Valimc.TestBlocks.get(at)))["enabled"] == "false"
    assert count(ctx.owner, at, "dirt") == 5

    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5,
      y: 66.25,
      z: z + 0.5,
      stack: ItemStack.new("stone", 3)
    }

    :ok = Region.drop_items(ctx.owner, [record])
    {:ok, _} = Region.step(ctx.owner, 10)
    assert count(ctx.owner, at, "stone") == 0
    assert count(ctx.owner, below, "dirt") == 0

    set(ctx.owner, %{power => BlockRegistry.default_state("air")})
    assert Map.new(BlockRegistry.properties(Valimc.TestBlocks.get(at)))["enabled"] == "true"
    {:ok, _} = Region.step(ctx.owner, 1)
    # One item down, the whole stack in: the item is gone.
    assert count(ctx.owner, below, "dirt") == 1
    assert count(ctx.owner, at, "stone") == 3

    refute Enum.any?(Valimc.TestRegion.section(ctx.owner).entities.store.entries, fn {_, e} ->
             e[:stack] == ItemStack.new("stone", 3)
           end)

    # Then one item every eight ticks.
    {:ok, _} = Region.step(ctx.owner, 8)
    assert count(ctx.owner, below, "dirt") == 2
  end

  test "a broken hopper spills what it holds in the same call", ctx do
    {x, z} = {ctx.x + 50, ctx.z + 20}
    at = {x, 65, z}
    set(ctx.owner, %{at => hopper("down")})
    fill(ctx.owner, at, [ItemStack.new("dirt", 5), nil, ItemStack.new("stone", 2)])
    block = Valimc.TestBlocks.get(at)

    assert :ok =
             Region.mine_block(
               ctx.owner,
               at,
               %{at => {block, Valimc.Blocks.after_removal(block)}},
               []
             )

    assert entry(ctx.owner, at) == nil

    stacks =
      for {_, %{kind: :item, stack: stack}} <-
            Valimc.TestRegion.section(ctx.owner).entities.store.entries,
          do: stack

    assert count_of(stacks, "dirt") == 5 and count_of(stacks, "stone") == 2
  end

  test "a hopper gives across a section line only within its group", ctx do
    edge = ctx.x + 128
    z = ctx.z + 9
    {at, target} = {{edge - 1, 65, z}, {edge, 65, z}}
    set(ctx.owner, %{at => hopper("east")})
    set({ctx.pb, ctx.eb}, %{target => chest()})
    fill(ctx.owner, at, [ItemStack.new("dirt", 4)])
    fill({ctx.pb, ctx.eb}, target, [])

    {:ok, _} = Region.step(ctx.owner, 10)
    assert count(ctx.owner, at, "dirt") == 4

    {:ok, [_]} = Region.hand_over(ctx.pb, ctx.pa)

    Valimc.TestWait.until(fn ->
      match?({pid, _, _} when pid == ctx.pa, Valimc.TestWorld.lookup(ctx.b))
    end)

    {:ok, _} = Region.step(ctx.owner, 9)
    assert count(ctx.owner, at, "dirt") == 2
    assert count(ctx.pa, target, "dirt", ctx.b) == 2
  end

  # Every item in the group's containers and on the ground, by name.
  defp census(owner, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      section = Valimc.TestRegion.section(owner, key)

      held =
        for {_, entry} <- section.containers.entries,
            stack <- Tuple.to_list(Map.get(entry, :slots) || entry.cooking.slots),
            stack != nil,
            do: stack

      loose = for {_, %{kind: :item, stack: stack}} <- section.entities.store.entries, do: stack

      Enum.reduce(held ++ loose, acc, fn stack, acc ->
        Map.update(acc, stack.item_id, stack.count, &(&1 + stack.count))
      end)
    end)
  end

  test "a hopper chain across a section line keeps every item through ticks and a crash", ctx do
    edge = ctx.x + 128
    z = ctx.z + 40

    {source, first, second, target} =
      {{edge - 2, 66, z}, {edge - 2, 65, z}, {edge - 1, 65, z}, {edge, 65, z}}

    set(ctx.owner, %{source => chest(), first => hopper("east"), second => hopper("east")})
    set({ctx.pb, ctx.eb}, %{target => chest()})
    fill(ctx.owner, source, [ItemStack.new("cobblestone", 64), ItemStack.new("dirt", 9)])
    fill(ctx.owner, first, [ItemStack.new("stone", 3)])
    fill({ctx.pb, ctx.eb}, target, [])

    {:ok, [_]} = Region.hand_over(ctx.pb, ctx.pa)

    Valimc.TestWait.until(fn ->
      match?({pid, _, _} when pid == ctx.pa, Valimc.TestWorld.lookup(ctx.b))
    end)

    keys = [ctx.a, ctx.b]
    expected = census(ctx.pa, keys)

    for round <- 1..12 do
      {:ok, _} = Region.step(ctx.owner, 1 + :rand.uniform(9))
      assert census(ctx.pa, keys) == expected
      # Durable up to here; the ticks after it may be lost, whole.
      if round == 6, do: :ok = Region.flush(ctx.pa)
    end

    assert count(ctx.pa, target, "cobblestone", ctx.b) + count(ctx.pa, target, "stone", ctx.b) > 0

    # A crash loses whole ticks at most: what the log holds is one of them.
    TestScope.kill(ctx.pa)
    {:ok, {pa, _} = owner_a} = Valimc.TestWorld.owner(ctx.a)
    {:ok, {pb, _}} = Valimc.TestWorld.owner(ctx.b)

    reloaded =
      Map.merge(census(pa, [ctx.a]), census(pb, [ctx.b]), fn _, a, b -> a + b end)

    assert reloaded == expected
    # At least the moves made before the flush.
    assert count(pa, source, "cobblestone", ctx.a) + count(pa, source, "dirt", ctx.a) < 73
    TestScope.simulate(owner_a, ctx.a)
  end

  test "hoppers, droppers and dispensers open their menus", ctx do
    {x, z} = {ctx.x + 60, ctx.z + 20}
    {at, dropper} = {{x, 65, z}, {x + 2, 65, z}}

    set(ctx.owner, %{
      at => hopper("down"),
      dropper => BlockRegistry.state("dropper", %{"facing" => "north", "triggered" => "false"})
    })

    grant = fn {px, py, pz} ->
      %{
        kind: :open,
        mode: :survival,
        eye: {px + 0.5, py + 1.6, pz - 1.5},
        hand: :main,
        secondary: false,
        main: false,
        off: false,
        yaw: 0.0,
        expires: Valimc.TestRegion.grant_expires(200)
      }
    end

    assert {:hopper, _, %{kind: :hopper, slots: slots}} =
             Region.menu(ctx.owner, self(), at, grant.(at))

    assert tuple_size(slots) == 5

    assert {:dispenser, _, %{kind: :dropper, slots: slots}} =
             Region.menu(ctx.owner, self(), dropper, grant.(dropper))

    assert tuple_size(slots) == 9
  end
end

defmodule Valimc.DispenserRegionTest do
  @moduledoc """
  Droppers and dispensers in region owners (VMC-049a): a powered rising
  edge fires them four ticks later; a dropper puts one item into the
  container in front, else drops it; a dispenser shoots arrows, pours and
  fills buckets, primes TNT and uses bone meal.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.{Containers, Region}

  setup do
    nonce = System.unique_integer([:positive])
    a = {102_000 + rem(nonce, 3_333) * 3, 2320}
    base = Path.join(System.tmp_dir!(), "valimc-dispensers-#{nonce}")
    TestScope.isolate([a], world_path: base, region_ticks: :manual, regionizer: false)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(a), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, owner} = Valimc.TestWorld.owner(a)
    TestScope.simulate(owner, a)
    {ax, az} = a
    %{owner: owner, x: ax * 128, z: az * 128}
  end

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp section(owner), do: Valimc.TestRegion.section(owner)

  defp fill(owner, position, stacks) do
    Valimc.TestRegion.replace_section(owner, fn section ->
      {:ok, entry} = Containers.observe(section.containers, position)
      size = tuple_size(entry.slots)
      slots = List.to_tuple(Enum.take(stacks ++ List.duplicate(nil, size), size))

      {:ok, containers, _} =
        Containers.replace(section.containers, position, entry.revision, slots)

      %{section | containers: containers}
    end)
  end

  defp slots(owner, position),
    do: Tuple.to_list(section(owner).containers.entries[position].slots)

  defp machine(name, facing),
    do: BlockRegistry.state(name, %{"facing" => facing, "triggered" => "false"})

  # Power on, the tick four later, power off again.
  defp fire(owner, power) do
    set(owner, %{power => BlockRegistry.default_state("redstone_block")})
    {:ok, _} = Region.step(owner, 5)
    set(owner, %{power => BlockRegistry.default_state("air")})
  end

  defp entities(owner, kind),
    do: for({_, %{kind: ^kind} = e} <- section(owner).entities.store.entries, do: e)

  test "a dropper fills the chest in front, else drops an item", ctx do
    {x, z} = {ctx.x + 20, ctx.z + 20}
    {dropper, chest, power} = {{x, 65, z}, {x + 1, 65, z}, {x, 65, z - 1}}

    chest_state =
      BlockRegistry.state("chest", %{
        "facing" => "north",
        "type" => "single",
        "waterlogged" => "false"
      })

    set(ctx.owner, %{dropper => machine("dropper", "east"), chest => chest_state})
    fill(ctx.owner, dropper, [ItemStack.new("dirt", 2)])

    fire(ctx.owner, power)
    assert slots(ctx.owner, dropper) |> hd() == ItemStack.new("dirt", 1)
    assert hd(slots(ctx.owner, chest)) == ItemStack.new("dirt", 1)
    assert entities(ctx.owner, :item) == []

    fill(ctx.owner, chest, [])
    set(ctx.owner, %{chest => BlockRegistry.default_state("air")})
    fire(ctx.owner, power)
    assert slots(ctx.owner, dropper) |> Enum.all?(&is_nil/1)
    assert [%{stack: %{count: 1}, entity: %{x: ix}}] = entities(ctx.owner, :item)
    assert_in_delta ix, x + 1.2, 0.01
  end

  test "a dispenser shoots arrows, pours and fills buckets, primes TNT", ctx do
    {x, z} = {ctx.x + 40, ctx.z + 20}
    {dispenser, power, front} = {{x, 66, z}, {x, 66, z - 1}, {x + 1, 66, z}}
    set(ctx.owner, %{dispenser => machine("dispenser", "east")})

    fill(ctx.owner, dispenser, [ItemStack.new("arrow", 3)])
    fire(ctx.owner, power)
    assert hd(slots(ctx.owner, dispenser)) == ItemStack.new("arrow", 2)

    assert [%{body: %{type: "minecraft:arrow", data: %{pickup: :allowed}}}] =
             entities(ctx.owner, :object)

    fill(ctx.owner, dispenser, [ItemStack.new("water_bucket")])
    fire(ctx.owner, power)
    assert hd(slots(ctx.owner, dispenser)) == ItemStack.new("bucket")
    assert BlockRegistry.name(BlockRegistry.block_id(Valimc.TestBlocks.get(front))) == "water"

    fire(ctx.owner, power)
    assert hd(slots(ctx.owner, dispenser)) == ItemStack.new("water_bucket")

    fill(ctx.owner, dispenser, [ItemStack.new("tnt", 1)])
    fire(ctx.owner, power)
    assert slots(ctx.owner, dispenser) |> Enum.all?(&is_nil/1)
    assert Enum.any?(entities(ctx.owner, :object), &(&1.body.type == "minecraft:tnt"))
  end

  test "a dispenser's bone meal grows a crop; on stone it fails and stays", ctx do
    {x, z} = {ctx.x + 60, ctx.z + 20}
    {dispenser, power, crop, soil} = {{x, 65, z}, {x, 65, z - 1}, {x + 1, 65, z}, {x + 1, 64, z}}

    set(ctx.owner, %{
      soil => BlockRegistry.state("farmland", %{"moisture" => "7"}),
      crop => BlockRegistry.default_state("wheat"),
      dispenser => machine("dispenser", "east")
    })

    fill(ctx.owner, dispenser, [ItemStack.new("bone_meal", 2)])
    fire(ctx.owner, power)
    assert hd(slots(ctx.owner, dispenser)) == ItemStack.new("bone_meal", 1)
    age = Map.new(BlockRegistry.properties(Valimc.TestBlocks.get(crop)))["age"]
    assert String.to_integer(age) > 0

    set(ctx.owner, %{crop => BlockRegistry.default_state("stone")})
    fire(ctx.owner, power)
    assert hd(slots(ctx.owner, dispenser)) == ItemStack.new("bone_meal", 1)
  end
end
