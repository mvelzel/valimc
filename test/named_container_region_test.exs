defmodule Valimc.NamedContainerRegionTest do
  @moduledoc """
  Occupied furnaces and named containers in region owners (VMC-032c5): an
  occupied furnace mined in survival or removed in creative spills its slots
  and pays out its stored experience once, in the commit that removes it; a
  container placed from a named item keeps the name in its entry, shows it as
  its menu title, keeps it through a restart and drops it with the block.
  """
  use ExUnit.Case, async: true
  alias Valimc.Blocks.Cooking
  alias Valimc.Data.Blocks, as: Registry
  alias Valimc.Protocol.{ItemStack, ItemTypes}
  alias Valimc.TestScope
  alias Valimc.World.{BlockBatch, Containers, Region}

  @custom_name "minecraft:custom_name"

  setup do
    nonce = System.unique_integer([:positive])
    key = {99_000 + rem(nonce, 3_333) * 3, 2610}
    base = Path.join(System.tmp_dir!(), "valimc-named-#{nonce}")

    TestScope.isolate(key,
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false
    )

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    {rx, rz} = key
    %{key: key, owner: owner, x: rx * 128, z: rz * 128}
  end

  defp entry(owner, at), do: Valimc.TestRegion.section(owner).containers.entries[at]

  defp records(owner, kind) do
    for {_, %{kind: ^kind} = record} <- Valimc.TestRegion.section(owner).entities.store.entries,
        do: record
  end

  defp restart(ctx) do
    pids = for {pid, _} <- Valimc.TestWorld.registered(ctx.key), uniq: true, do: pid
    for pid <- pids, do: :ok = Region.flush(pid)
    for pid <- pids, do: TestScope.kill(pid)
    {:ok, owner} = Valimc.TestWorld.item_owner(ctx.key)
    owner
  end

  defp grant(kind, {x, y, z}) do
    %{
      kind: kind,
      mode: :survival,
      eye: {x + 0.5, y + 1.6, z + 2.5},
      expires: Valimc.TestRegion.grant_expires(),
      hand: :main,
      secondary: false,
      main: false,
      off: false
    }
  end

  defp place(owner, at, block, fill) do
    {:ok, observed} = Region.observe_blocks(owner, [at])
    {:ok, batch} = BlockBatch.prepare(%{at => block})

    fill = if fill == %{}, do: %{}, else: %{at => fill}
    Region.place_block(owner, observed.fence, batch, Valimc.TestRegion.grant_expires(), fill)
  end

  defp mine(owner, at, loot) do
    block = Valimc.TestBlocks.get(at)
    records = for stack <- loot, do: Valimc.Entity.ItemDrop.pop(at, stack)

    Region.mine_block(owner, at, %{at => {block, Valimc.Blocks.after_removal(block)}}, records)
  end

  defp count_of(records, name) do
    id = ItemTypes.id(name)
    Enum.sum(for %{stack: %{item_id: ^id, count: n}} <- records, do: n)
  end

  defp occupy(owner, at) do
    {:ok, block} = Valimc.Blocks.CookingBlocks.placement(:furnace, 0.0)
    {:ok, recipe} = Valimc.Blocks.CookingRecipes.find(ItemStack.new("raw_iron"), block)

    cooking = %Cooking{
      slots:
        {ItemStack.new("raw_iron", 5), ItemStack.new("coal", 3), ItemStack.new("iron_ingot", 9)},
      burn_left: 100,
      burn_total: 1600,
      progress: 40,
      total: 200
    }

    Valimc.TestRegion.replace_section(owner, fn section ->
      %{revision: revision} = section.containers.entries[at]

      {:ok, containers, _} =
        Containers.replace_cooking(section.containers, at, revision, cooking, %{
          recipe.key => 20
        })

      %{section | containers: containers}
    end)

    {:ok, xp} = Valimc.Blocks.CookingRecipes.experience(recipe.key)
    floor(20 * xp)
  end

  test "an occupied furnace spills its slots and pays out its experience once, in survival and creative",
       ctx do
    {:ok, block} = Valimc.Blocks.CookingBlocks.placement(:furnace, 0.0)
    survival = {ctx.x + 20, 64, ctx.z + 20}
    creative = {ctx.x + 24, 64, ctx.z + 20}

    for at <- [survival, creative] do
      {:ok, _} = place(ctx.owner, at, block, %{})
    end

    xp = occupy(ctx.owner, survival)
    ^xp = occupy(ctx.owner, creative)

    assert :ok = mine(ctx.owner, survival, [ItemStack.new("furnace")])
    assert entry(ctx.owner, survival) == nil
    items = records(ctx.owner, :item)

    assert {count_of(items, "raw_iron"), count_of(items, "coal"), count_of(items, "iron_ingot"),
            count_of(items, "furnace")} == {5, 3, 9, 1}

    orbs = records(ctx.owner, :orb)
    total = Enum.sum(for orb <- orbs, do: orb.value * orb.count)
    assert total in [xp, xp + 1]
    {x, y, z} = survival

    assert Enum.all?(
             orbs,
             &({&1.entity.x, &1.entity.y, &1.entity.z} == {x + 0.5, y + 0.5, z + 0.5})
           )

    # The removal committed with its spill: a restart holds both, once.
    owner = restart(ctx)
    assert entry(owner, survival) == nil
    assert length(records(owner, :item)) == length(items)
    assert Enum.sum(for orb <- records(owner, :orb), do: orb.value * orb.count) == total

    # Creative removal (`destroy_block`) spills the same, with no block loot.
    {:ok, observed} = Region.observe_blocks(owner, [creative])
    :ok = Region.destroy_block(owner, observed.fence, creative, Valimc.TestRegion.grant_expires())
    assert entry(owner, creative) == nil
    items = records(owner, :item)

    assert {count_of(items, "raw_iron"), count_of(items, "coal"), count_of(items, "iron_ingot"),
            count_of(items, "furnace")} == {10, 6, 18, 1}

    all = Enum.sum(for orb <- records(owner, :orb), do: orb.value * orb.count)
    assert (all - total) in [xp, xp + 1]
  end

  test "a named container keeps its name through placement, its menu title, a restart and breaking",
       ctx do
    name = {:string, "Ore Store"}
    {:ok, furnace} = Valimc.Blocks.CookingBlocks.placement(:furnace, 0.0)

    cases = [
      {"chest", Registry.default_state("chest"), :chest},
      {"barrel", Registry.default_state("barrel"), :storage},
      {"furnace", furnace, :cooking},
      {"hopper", Registry.default_state("hopper"), :hopper},
      {"dropper", Registry.default_state("dropper"), :dispenser},
      {"blue_shulker_box", Registry.default_state("blue_shulker_box"), :storage}
    ]

    placed =
      for {{item, block, menu}, i} <- Enum.with_index(cases) do
        at = {ctx.x + 20 + 3 * i, 64, ctx.z + 30}
        stack = %{ItemStack.new(item) | components: %{@custom_name => name}}
        assert Valimc.Blocks.Placement.placeable_stack?(stack), item
        {:ok, _} = place(ctx.owner, at, block, %{name: name})
        assert %{name: ^name} = entry(ctx.owner, at)
        assert {^menu, _, view} = Region.menu(ctx.owner, self(), at, grant(:open, at))
        assert view.name == name
        {item, at, menu, view}
      end

    # The title is the name in place of the default translation.
    for {_, _, menu, view} <- placed do
      {_, body} =
        case menu do
          :chest -> Valimc.Menus.Packets.open_chest(17, 3, view[:name])
          :storage -> Valimc.Menus.Packets.open_storage(17, view.kind, view[:name])
          :cooking -> Valimc.Menus.Packets.open_cooking(17, view.kind, view[:name])
          _ -> Valimc.Menus.Packets.open_machine(17, view.kind, view[:name])
        end

      body = IO.iodata_to_binary(body)
      assert :binary.match(body, "Ore Store") != :nomatch
      refute :binary.match(body, "container.") != :nomatch
    end

    owner = restart(ctx)

    for {item, at, _, _} <- placed do
      assert %{name: ^name} = entry(owner, at), item
      loot = if item == "blue_shulker_box", do: [], else: [ItemStack.new(item)]
      assert :ok = mine(owner, at, loot)
      assert entry(owner, at) == nil
    end

    dropped = records(owner, :item)
    assert length(dropped) == length(placed)

    for %{stack: stack} <- dropped do
      assert ItemStack.component(stack, @custom_name) == name
    end

    # An unnamed placement keeps no name; a name on an ender chest does not place.
    plain = {ctx.x + 60, 64, ctx.z + 30}
    {:ok, _} = place(owner, plain, Registry.default_state("barrel"), %{})
    refute Map.has_key?(entry(owner, plain), :name)

    refute Valimc.Blocks.Placement.placeable_stack?(%{
             ItemStack.new("ender_chest")
             | components: %{@custom_name => name}
           })
  end

  test "a joined chest is titled by its first half's name, else its second's", _ctx do
    name = {:string, "Left"}
    key = {0, 0}
    right = {1, 64, 1}
    left = {2, 64, 1}
    {:ok, containers, a} = Containers.create(%Containers{}, key, right, 3)
    {:ok, containers, b} = Containers.create(containers, key, left, 3)
    fetch = &containers.entries[&1]
    {:ok, view} = Containers.chest_view([right, left], fetch)
    refute Map.has_key?(view, :name)

    {:ok, named, _} = Containers.put_name(containers, left, b.revision, name)
    {:ok, view} = Containers.chest_view([right, left], &named.entries[&1])
    assert view.name == name

    {:ok, both, _} = Containers.put_name(named, right, a.revision, {:string, "Right"})
    {:ok, view} = Containers.chest_view([right, left], &both.entries[&1])
    assert view.name == {:string, "Right"}

    {:ok, bytes} = Containers.encode(key, both)
    assert {:ok, ^both} = Containers.decode(bytes, key)
    revision = both.entries[right].revision

    assert {:error, :invalid_container_name} =
             Containers.put_name(both, right, revision, :unsupported)
  end
end
