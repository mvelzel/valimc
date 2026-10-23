defmodule Valimc.GrowthTest do
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks
  alias Valimc.TestScope
  alias Valimc.World.Region

  # Growth's rules are checked tick by tick against the oracle (stage
  # `growth`); this is their wiring in a stepped owner: the sampler hands
  # the growing blocks to the rules, which read the owner's light and water.
  setup do
    nonce = System.unique_integer([:positive])
    key = {76_000 + rem(nonce, 3_333) * 3, 1830}
    base = Path.join(System.tmp_dir!(), "valimc-growth-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual, random_tick_speed: 4096)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    span = Valimc.Data.Grid.region_size() * 16
    {:ok, owner} = Valimc.TestWorld.owner(key)
    TestScope.simulate(owner, key)
    %{owner: owner, origin: {rx * span + 40, 63, rz * span + 40}}
  end

  defp blocks(owner, positions) do
    {:ok, %{blocks: blocks}} = Region.observe_blocks(owner, positions)
    blocks
  end

  defp name(state), do: Blocks.name(Blocks.block_id(state))
  defp value(state, property), do: Map.new(Blocks.properties(state))[property]

  test "crops and sugar cane grow; farmland away from water dries to dirt; grass spreads",
       %{owner: owner, origin: {x, y, z}} do
    farmland = {x + 1, y, z}
    wheat = {x + 1, y + 1, z}
    cane = {x, y + 1, z + 1}
    dry = {x + 10, y, z}

    edits = %{
      {x, y, z} => Blocks.default_state("water"),
      farmland => Blocks.default_state("farmland"),
      wheat => Blocks.default_state("wheat"),
      {x, y, z + 1} => Blocks.default_state("sand"),
      cane => Blocks.default_state("sugar_cane"),
      dry => Blocks.default_state("farmland")
    }

    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
    {:ok, _} = Region.step(owner, 300)

    grown =
      blocks(owner, [farmland, wheat, cane, {x, y + 2, z + 1}, {x, y + 3, z + 1}, dry])

    assert value(grown[farmland], "moisture") == "7"
    assert value(grown[wheat], "age") == "7"
    assert name(grown[{x, y + 2, z + 1}]) == "sugar_cane"
    assert name(grown[{x, y + 3, z + 1}]) == "sugar_cane"
    # The flat world's grass may already have spread onto the dried dirt.
    assert name(grown[dry]) in ["dirt", "grass_block"]
  end

  test "a sapling grows into its tree", %{owner: owner, origin: {x, y, z}} do
    sapling = {x, y + 1, z}
    stage = Blocks.state("oak_sapling", %{"stage" => "1"})
    {:ok, observed} = Region.observe_blocks(owner, [sapling])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{sapling => stage})

    # The tree grows in a task once a tick decides it; step until it lands.
    Valimc.TestWait.until(fn ->
      {:ok, _} = Region.step(owner, 1)
      name(blocks(owner, [sapling])[sapling]) == "oak_log"
    end)

    # A trunk of at least four logs over the grass, which became dirt.
    trunk = for dy <- 1..4, do: {x, y + dy, z}
    assert Enum.all?(blocks(owner, trunk), fn {_, state} -> name(state) == "oak_log" end)
    assert name(blocks(owner, [{x, y, z}])[{x, y, z}]) == "dirt"
  end

  test "bone meal grows a crop, seagrass and grass, drops a sunflower, passes on stone",
       %{owner: owner, origin: {x, y, z}} do
    wheat = {x + 3, y + 1, z}
    {sunflower, water} = {{x + 3, y + 1, z + 2}, {x + 3, y + 1, z + 4}}

    edits = %{
      {x + 3, y, z} => Blocks.default_state("farmland"),
      wheat => Blocks.default_state("wheat"),
      sunflower => Blocks.state("sunflower", %{"half" => "lower"}),
      {x + 3, y + 2, z + 2} => Blocks.state("sunflower", %{"half" => "upper"}),
      {x + 3, y, z + 4} => Blocks.default_state("sand"),
      water => Blocks.default_state("water")
    }

    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)

    assert {:ok, 1} = Region.bucket(owner, {:bone_meal, wheat})
    assert String.to_integer(value(blocks(owner, [wheat])[wheat], "age")) in 2..5
    assert {:ok, 0} = Region.bucket(owner, {:bone_meal, {x + 3, y - 2, z}})

    # A tall flower drops a copy; the water above sand clicked from its top
    # face grows seagrass there (the first try is the clicked cell's).
    assert {:ok, 3} = Region.bucket(owner, {:bone_meal, sunflower, 1, false})

    assert [%{stack: %{item_id: item}}] =
             Valimc.Entity.Store.records(Valimc.TestRegion.section(owner).entities.store)

    assert item == Valimc.Protocol.Data.item("sunflower")
    assert {:ok, 1} = Region.bucket(owner, {:bone_meal, {x + 3, y, z + 4}, 1, false})
    assert name(blocks(owner, [water])[water]) == "seagrass"

    # A grass block hands its bone meal to the generator, whose first try
    # grows grass or a flower on it.
    grass = {x + 8, y, z + 8}
    assert {:ok, 2} = Region.bucket(owner, {:bone_meal, grass, 1, false})
    dimension = Valimc.TestRegion.section(owner).dimension
    assert :ok = Valimc.World.Growth.generate(dimension, grass)
    top = {x + 8, y + 1, z + 8}
    refute name(blocks(owner, [top])[top]) == "air"
  end

  test "tools transform blocks; farmland trampled turns to dirt", %{
    owner: owner,
    origin: {x, y, z}
  } do
    [axe, hoe, shovel] = for name <- ~w(axe hoe shovel), do: tool(name)
    log = Blocks.state("oak_log", %{"axis" => "x"})
    {grass, covered, path, trodden} = {{x + 5, y, z}, {x + 6, y, z}, {x + 7, y, z}, {x + 8, y, z}}

    edits = %{
      {x + 5, y + 1, z + 2} => log,
      {x + 6, y + 1, z} => Blocks.default_state("stone"),
      trodden => Blocks.default_state("farmland")
    }

    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)

    # A hoe tills grass with air above, never from below; a shovel flattens.
    assert {:ok, 0} = Region.bucket(owner, {:transform, grass, hoe, 0})
    assert {:ok, 1} = Region.bucket(owner, {:transform, grass, hoe, 1})
    assert {:ok, 0} = Region.bucket(owner, {:transform, covered, hoe, 1})
    assert {:ok, 1} = Region.bucket(owner, {:transform, path, shovel, 2})
    assert {:ok, 1} = Region.bucket(owner, {:transform, {x + 5, y + 1, z + 2}, axe, 4})
    assert {:ok, 1} = Region.bucket(owner, {:trample, trodden})

    after_use = blocks(owner, [grass, covered, path, {x + 5, y + 1, z + 2}, trodden])
    assert name(after_use[grass]) == "farmland"
    assert name(after_use[covered]) == "grass_block"
    assert name(after_use[path]) == "dirt_path"
    assert name(after_use[{x + 5, y + 1, z + 2}]) == "stripped_oak_log"
    assert value(after_use[{x + 5, y + 1, z + 2}], "axis") == "x"
    assert name(after_use[trodden]) == "dirt"
  end

  test "berries picked drop their loot; tilled rooted dirt drops hanging roots",
       %{owner: owner, origin: {x, y, z}} do
    {bush, young, vines, rooted} =
      {{x + 12, y + 1, z}, {x + 12, y + 1, z + 2}, {x + 12, y + 3, z + 4}, {x + 12, y, z + 6}}

    edits = %{
      bush => Blocks.state("sweet_berry_bush", %{"age" => "3"}),
      young => Blocks.state("sweet_berry_bush", %{"age" => "2"}),
      {x + 12, y + 4, z + 4} => Blocks.default_state("stone"),
      vines => Blocks.state("cave_vines", %{"age" => "0", "berries" => "true"}),
      rooted => Blocks.default_state("rooted_dirt")
    }

    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
    bone_meal = Valimc.Protocol.Data.item("bone_meal")

    # A growing bush held bone meal gives way to it; a full one is picked.
    assert :pass = Region.menu(owner, self(), young, grant(young, bone_meal))
    assert :used = Region.menu(owner, self(), bush, grant(bush, bone_meal))
    assert :used = Region.menu(owner, self(), vines, grant(vines, nil))
    assert :pass = Region.menu(owner, self(), vines, grant(vines, nil))
    assert {:ok, 2} = Region.bucket(owner, {:transform, rooted, tool("hoe"), 1})

    after_use = blocks(owner, [bush, vines, rooted])
    assert value(after_use[bush], "age") == "1"
    assert value(after_use[vines], "berries") == "false"
    assert name(after_use[rooted]) == "dirt"

    items =
      for %{stack: stack} <-
            Valimc.Entity.Store.records(Valimc.TestRegion.section(owner).entities.store),
          do: {stack.item_id, stack.count}

    [berries, glow, roots] =
      for name <- ~w(sweet_berries glow_berries hanging_roots),
          do: Valimc.Protocol.Data.item(name)

    # A full bush drops one berry and one or two more, in two stacks.
    assert [b1, b2] = for({^berries, n} <- items, do: n)
    assert (b1 + b2) in 2..3
    assert {glow, 1} in items
    assert {roots, 1} in items
  end

  test "shears carve a pumpkin; a fungus grows its huge fungus",
       %{owner: owner, origin: {x, y, z}} do
    {pumpkin, fungus} = {{x + 14, y + 1, z + 2}, {x + 14, y + 1, z + 8}}

    edits = %{
      pumpkin => Blocks.default_state("pumpkin"),
      {x + 14, y, z + 8} => Blocks.default_state("crimson_nylium"),
      fungus => Blocks.default_state("crimson_fungus")
    }

    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
    shears = Valimc.Protocol.Data.item("shears")

    # Clicked on its west side with shears, the pumpkin is carved facing
    # west; a carved one passes.
    assert :pass = Region.menu(owner, self(), pumpkin, grant(pumpkin, nil, 4))
    assert :sheared = Region.menu(owner, self(), pumpkin, grant(pumpkin, shears, 4))
    assert :pass = Region.menu(owner, self(), pumpkin, grant(pumpkin, shears, 4))

    after_use = blocks(owner, [pumpkin])
    assert name(after_use[pumpkin]) == "carved_pumpkin"
    assert value(after_use[pumpkin], "facing") == "west"

    items =
      for %{stack: stack} <-
            Valimc.Entity.Store.records(Valimc.TestRegion.section(owner).entities.store),
          do: {stack.item_id, stack.count}

    assert items == [{Valimc.Protocol.Data.item("pumpkin_seeds"), 4}]

    # Bone meal succeeds on a fungus two times in five; then the generator
    # grows the planted huge fungus from its cell.
    Valimc.TestWait.until(fn ->
      {:ok, result} = Region.bucket(owner, {:bone_meal, fungus, 1, false})
      result == 2
    end)

    dimension = Valimc.TestRegion.section(owner).dimension
    assert :ok = Valimc.World.Growth.generate(dimension, fungus)
    assert name(blocks(owner, [fungus])[fungus]) == "crimson_stem"
  end

  test "a landing tramples farmland by its distance and the body's size" do
    farmland = Blocks.default_state("farmland")
    refute Valimc.Blocks.Farmland.tramples?(farmland, 1.0, {0.6, 1.8}, 0.6)
    assert Valimc.Blocks.Farmland.tramples?(farmland, 1.5, {0.6, 1.8}, 0.6)
    refute Valimc.Blocks.Farmland.tramples?(farmland, 3.0, {0.4, 0.7}, 0.1)
    refute Valimc.Blocks.Farmland.tramples?(Blocks.default_state("dirt"), 3.0, {0.6, 1.8}, 0.1)
  end

  defp grant({x, y, z}, item, face \\ 1) do
    %{
      kind: :open,
      mode: :survival,
      eye: {x + 0.5, y + 1.5, z + 0.5},
      hand: :main,
      secondary: false,
      main: item != nil,
      off: false,
      main_item: item,
      item: item,
      face: face,
      expires: Valimc.TestRegion.grant_expires(200)
    }
  end

  defp tool(name) do
    Valimc.Blocks.Transformers.tool(%{item_id: Valimc.Protocol.Data.item("iron_" <> name)})
  end
end
