defmodule Valimc.BlockTickBehavioursTest do
  use ExUnit.Case, async: true
  alias Valimc.Block.BuddingAmethyst
  alias Valimc.Registry.Blocks
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region

  @air Blocks.default_state("air")
  @water Blocks.default_state("water")
  @coral Blocks.default_state("tube_coral_block")
  @dead Blocks.default_state("dead_tube_coral_block")
  @budding Blocks.default_state("budding_amethyst")

  defp bud(stage, facing, waterlogged \\ false),
    do: Blocks.state(stage, %{"facing" => facing, "waterlogged" => "#{waterlogged}"})

  defp world(blocks), do: &Map.get(blocks, &1, @air)

  # A random source that returns `values` in order.
  defp draws(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)
    fn _bound -> Agent.get_and_update(agent, fn [value | rest] -> {value, rest} end) end
  end

  describe "budding amethyst" do
    defp grow(blocks, values) do
      BuddingAmethyst.random_tick({0, 64, 0}, @budding, world(blocks), draws(values))
    end

    test "one tick in five starts a bud on the chosen face, in air or full water" do
      assert grow(%{}, [1]) == []
      assert grow(%{}, [0, 1]) == [{:set, {0, 65, 0}, bud("small_amethyst_bud", "up")}]
      assert grow(%{}, [0, 5]) == [{:set, {1, 64, 0}, bud("small_amethyst_bud", "east")}]

      assert grow(%{{0, 64, -1} => @water}, [0, 2]) ==
               [{:set, {0, 64, -1}, bud("small_amethyst_bud", "north", true)}]

      flowing = Blocks.state("water", %{"level" => "1"})
      assert grow(%{{0, 64, -1} => flowing}, [0, 2]) == []
      assert grow(%{{0, 63, 0} => Blocks.default_state("stone")}, [0, 0]) == []
    end
  end

  describe "in a region owner" do
    setup do
      nonce = System.unique_integer([:positive])
      key = {72_000 + rem(nonce, 3_333) * 3, 1810}
      base = Path.join(System.tmp_dir!(), "valimc-block-ticks-#{nonce}")
      TestScope.isolate(key, world_path: base, region_ticks: :manual, random_tick_speed: 0)

      on_exit(fn ->
        for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
            {pid, _} <- Registry.lookup(reg, key),
            do: TestScope.kill(pid)

        File.rm_rf(base)
      end)

      {rx, rz} = key
      span = Valimc.config(:region_size) * 16
      {:ok, owner} = World.owner(key)
      %{owner: owner, origin: {rx * span + 40, 64, rz * span + 40}}
    end

    defp block(owner, position) do
      {:ok, %{blocks: %{^position => state}}} = Region.observe_blocks(owner, [position])
      state
    end

    defp set(owner, edits) do
      {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
      {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
    end

    test "placed coral dies 60 to 99 ticks later away from water, and after its water goes",
         %{owner: owner, origin: {x, y, z} = dry} do
      wet = {x + 4, y, z}
      water = {x + 5, y, z}
      set(owner, %{dry => @coral, wet => @coral, water => @water})

      {:ok, _} = Region.step(owner, 59)
      assert block(owner, dry) == @coral
      {:ok, _} = Region.step(owner, 41)
      assert block(owner, dry) == @dead
      assert block(owner, wet) == @coral

      set(owner, %{water => @air})
      {:ok, _} = Region.step(owner, 100)
      assert block(owner, wet) == @dead
    end
  end

  test "budding amethyst grows buds on its faces in play" do
    nonce = System.unique_integer([:positive])
    key = {74_000 + rem(nonce, 3_333) * 3, 1820}
    base = Path.join(System.tmp_dir!(), "valimc-amethyst-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual, random_tick_speed: 4096)

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    {x, y, z} = position = {rx * span + 40, 64, rz * span + 40}
    {:ok, owner} = World.owner(key)
    {:ok, observed} = Region.observe_blocks(owner, [position])
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{position => @budding})
    {:ok, _} = Region.step(owner, 150)

    faces = %{
      {x, y + 1, z} => "up",
      {x, y, z - 1} => "north",
      {x, y, z + 1} => "south",
      {x - 1, y, z} => "west",
      {x + 1, y, z} => "east"
    }

    {:ok, %{blocks: blocks}} = Region.observe_blocks(owner, Map.keys(faces))

    grown =
      for {face, state} <- blocks, Blocks.class(state) == "AmethystClusterBlock" do
        assert {"facing", faces[face]} in Blocks.properties(state)
        face
      end

    assert grown != []
  end
end
