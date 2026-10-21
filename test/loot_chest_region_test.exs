defmodule Valimc.LootChestRegionTest do
  @moduledoc "Unrolled loot chests unpack on open and break, once, durably (VMC-072b)."
  use ExUnit.Case, async: true
  alias Valimc.Physics.BlockEntities, as: Types
  alias Valimc.Protocol.ItemStack
  alias Valimc.Registry.Blocks, as: BlockRegistry
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.{BlockEntities, Blocks, Containers, ItemLedger, Region, Store}

  @chest BlockRegistry.default_state("chest")
  @seed 5_530_731_629_134_945_404
  # Vanilla's simple dungeon fill for @seed (`LootOracle`, as in loot_test.exs).
  @dungeon [
    {0, "enchanted_golden_apple", 1},
    {1, "wheat", 2},
    {2, "rotten_flesh", 5},
    {4, "rotten_flesh", 5},
    {5, "rotten_flesh", 3},
    {6, "coal", 2},
    {11, "wheat", 2},
    {12, "bucket", 1},
    {14, "leather", 2},
    {15, "gunpowder", 2},
    {18, "bread", 1},
    {19, "rotten_flesh", 2},
    {20, "coal", 2},
    {21, "leather", 1},
    {22, "gunpowder", 1},
    {25, "gunpowder", 1}
  ]

  setup do
    nonce = System.unique_integer([:positive])
    key = {91_000 + rem(nonce, 3_333) * 3, -1730}
    base = Path.join(System.tmp_dir!(), "valimc-loot-chest-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    size = Valimc.config(:region_size)
    {cx, cz} = chunk = {rx * size + 1, rz * size + 2}
    at = fn dx -> {cx * 16 + dx, 70, cz * 16 + 4} end

    chests = %{
      seeded: at.(2),
      unseeded: at.(5),
      named: at.(8),
      unknown: at.(11)
    }

    {:ok, blocks} = Blocks.new(key)
    :ok = Blocks.put(blocks, Map.new(chests, fn {_, position} -> {position, @chest} end))
    {:ok, image} = Blocks.column_image(blocks, chunk)

    loot = fn table, seed ->
      %{"LootTable" => {:string, table}, "LootTableSeed" => {:long, seed}}
    end

    fields = %{
      seeded: loot.("minecraft:chests/simple_dungeon", @seed),
      unseeded: %{"LootTable" => {:string, "minecraft:chests/simple_dungeon"}},
      named:
        Map.put(
          loot.("minecraft:chests/simple_dungeon", @seed),
          "CustomName",
          {:string, "Named"}
        ),
      unknown: loot.("minecraft:chests/nonexistent", 7)
    }

    entities =
      Map.new(chests, fn {name, {x, y, z} = position} ->
        tag =
          {:compound,
           Map.merge(fields[name], %{
             "id" => {:string, "minecraft:chest"},
             "x" => {:int, x},
             "y" => {:int, y},
             "z" => {:int, z},
             "components" => {:compound, %{}}
           })}

        {:ok, nbt} = BlockEntities.encode_nbt(tag)
        {position, {Types.type_id(@chest), nbt}}
      end)

    :ok =
      Store.import_region(base, key, %{columns: %{chunk => image}, block_entities: entities})

    %{key: key, base: base, chests: chests}
  end

  defp grant(position, mode) do
    {x, y, z} = position

    %{
      kind: :open,
      mode: mode,
      eye: {x + 0.5, y + 1.5, z + 0.5},
      hand: :main,
      secondary: false,
      main: false,
      off: false,
      expires: Valimc.TestRegion.grant_expires(200)
    }
  end

  # A grant lives 200 ms; a loaded machine can outlast it, so an expired one is
  # retried with a fresh grant.
  defp open(ctx, position, mode \\ :survival, tries \\ 5) do
    {:ok, owner} = World.owner(ctx.key)
    World.subscribe(MapSet.new([ctx.key]), MapSet.new())
    ref = make_ref()
    assert :ok = Region.request_table(owner, self(), ref, position, grant(position, mode))
    assert_receive {:event, {:table_admitted, ^ref, ^owner, decision}}

    if decision == {:error, :expired_chest_grant} and tries > 1,
      do: open(ctx, position, mode, tries - 1),
      else: decision
  end

  defp slots(slots) do
    for {stack, slot} <- slots |> Tuple.to_list() |> Enum.with_index(),
        stack != nil,
        do:
          {slot,
           String.replace_prefix(
             Valimc.Protocol.ItemTypes.item(stack.item_id)["name"],
             "minecraft:",
             ""
           ), stack.count}
  end

  defp durable(ctx, part), do: Store.durable(ctx.base, ctx.key, part)

  defp restart(ctx) do
    for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, ctx.key),
        do: :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
  end

  test "a seeded chest opens with vanilla's fill, keeps it across a restart and never rolls again",
       ctx do
    position = ctx.chests.seeded
    assert {:chest, @chest, view} = open(ctx, position)
    assert slots(view.slots) == @dungeon

    # One durable frame: the owned chest and the preserved entry's removal.
    {:ok, containers} = Containers.decode(durable(ctx, :containers), ctx.key)
    assert containers.entries[position].slots == view.slots
    refute Map.has_key?(durable(ctx, :block_entities), position)
    assert Map.has_key?(durable(ctx, :block_entities), ctx.chests.unseeded)

    assert {:chest, @chest, again} = open(ctx, position)
    assert again.slots == view.slots and again.revision == view.revision

    restart(ctx)
    assert {:chest, @chest, restarted} = open(ctx, position)
    assert restarted.slots == view.slots and restarted.revision == view.revision
  end

  test "a chest without a stored seed rolls a fresh seed once", ctx do
    position = ctx.chests.unseeded
    assert {:chest, @chest, view} = open(ctx, position)
    assert slots(view.slots) != []
    restart(ctx)
    assert {:chest, @chest, again} = open(ctx, position)
    assert again.slots == view.slots
  end

  test "spectators and locked chests do not unpack; an unknown table fills nothing", ctx do
    assert {:error, :missing_chest} = open(ctx, ctx.chests.seeded, :spectator)
    assert {:error, :missing_chest} = open(ctx, ctx.chests.named)
    entities = durable(ctx, :block_entities)
    assert Map.has_key?(entities, ctx.chests.seeded) and Map.has_key?(entities, ctx.chests.named)

    assert {:chest, @chest, view} = open(ctx, ctx.chests.unknown)
    assert slots(view.slots) == []
    refute Map.has_key?(durable(ctx, :block_entities), ctx.chests.unknown)
  end

  test "breaking an unrolled chest spills vanilla's fill", ctx do
    position = ctx.chests.seeded
    assert :ok = World.remove_block(position)
    assert World.get_block(position) != @chest

    {:ok, saved} = ItemLedger.decode(durable(ctx, :items), ctx.key)

    spilled =
      saved.records
      |> Enum.map(
        &{String.replace_prefix(
           Valimc.Protocol.ItemTypes.item(&1.stack.item_id)["name"],
           "minecraft:",
           ""
         ), &1.stack.count}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {name, counts} -> {name, Enum.sum(counts)} end)

    expected =
      @dungeon
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
      |> Map.new(fn {name, counts} -> {name, Enum.sum(counts)} end)

    assert spilled == expected
    {:ok, containers} = Containers.decode(durable(ctx, :containers), ctx.key)
    refute Map.has_key?(containers.entries, position)
    refute Map.has_key?(durable(ctx, :block_entities), position)
  end

  test "survival mining unpacks the chest into its spill", ctx do
    position = ctx.chests.unseeded
    {:ok, owner} = World.item_owner(ctx.key)
    {:ok, permit} = Region.reserve_mining(owner, [position])
    {x, y, z} = position

    chest = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x + 0.5,
      y: y + 0.5,
      z: z + 0.5,
      stack: ItemStack.new("chest")
    }

    transfer =
      Map.merge(permit, %{source: <<1::128>>, sequence: 1, records: [chest]})

    assert {:ok, :applied} = Region.apply_mining_transfer(owner, transfer)
    {:ok, saved} = ItemLedger.decode(durable(ctx, :items), ctx.key)
    assert length(saved.records) > 1
    assert Enum.any?(saved.records, &(&1.stack == ItemStack.new("chest")))
    refute Map.has_key?(durable(ctx, :block_entities), position)
  end
end
