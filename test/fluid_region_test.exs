defmodule Valimc.FluidRegionTest do
  @moduledoc """
  Water and lava in region owners (VMC-031a): fluid ticks are scheduled ticks
  the block rules run, across section lines inside a group; a fluid tick that
  would read past its group waits; generated chunks' post-processing marks
  settle when the chunk first ticks. Flow itself is `check_fluids.exs`'s.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.TestScope
  alias Valimc.World.{Region, ScheduledTicks}

  setup do
    nonce = System.unique_integer([:positive])
    a = {93_000 + rem(nonce, 3_333) * 3, 2100}
    b = {elem(a, 0) + 1, 2100}
    base = Path.join(System.tmp_dir!(), "valimc-fluids-#{nonce}")
    TestScope.isolate([a, b], world_path: base, region_ticks: :manual, regionizer: false)

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
    %{a: a, b: b, pa: pa, ea: ea, pb: pb, eb: eb}
  end

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp block(position),
    do: BlockRegistry.name(BlockRegistry.block_id(Valimc.TestBlocks.get(position)))

  defp level(position),
    do: Map.new(BlockRegistry.properties(Valimc.TestBlocks.get(position)))["level"]

  test "water waits at its group's edge and flows across the section line once the groups merge",
       ctx do
    water = BlockRegistry.default_state("water")
    {ax, z} = ctx.a
    edge = (ax + 1) * 128
    # The test world's floor is at y 63.
    source = {edge - 1, 64, z * 128 + 9}
    set({ctx.pa, ctx.ea}, %{source => water})
    assert {:ok, _} = Region.step({ctx.pa, ctx.ea}, 12)
    # Its ticks read section b, another group's: they wait.
    assert block({edge - 2, 64, z * 128 + 9}) == "air"
    assert block({edge, 64, z * 128 + 9}) == "air"

    {:ok, [_]} = Region.hand_over(ctx.pb, ctx.pa)

    Valimc.TestWait.until(fn ->
      match?({pid, _, _} when pid == ctx.pa, Valimc.TestWorld.lookup(ctx.b))
    end)

    assert {:ok, _} = Region.step({ctx.pa, ctx.ea}, 12)
    # One group: the water spreads into b as into a, a level lower each cell.
    assert {block({edge, 64, z * 128 + 9}), level({edge, 64, z * 128 + 9})} == {"water", "1"}

    assert {block({edge - 2, 64, z * 128 + 9}), level({edge - 2, 64, z * 128 + 9})} ==
             {"water", "1"}

    assert level({edge + 1, 64, z * 128 + 9}) == "2"
  end

  test "lava meeting water makes obsidian from a source and cobblestone from flowing lava", ctx do
    {ax, z} = ctx.a
    {x, y, z} = {ax * 128 + 40, 64, z * 128 + 40}
    lava = BlockRegistry.default_state("lava")
    set({ctx.pa, ctx.ea}, %{{x, y, z} => lava})
    set({ctx.pa, ctx.ea}, %{{x + 1, y, z} => BlockRegistry.default_state("water")})
    assert block({x, y, z}) == "obsidian"

    # Flowing lava beside water hardens to cobblestone.
    flowing = BlockRegistry.state("lava", %{"level" => "2"})
    set({ctx.pa, ctx.ea}, %{{x + 1, y, z + 1} => flowing})
    assert block({x + 1, y, z + 1}) == "cobblestone"
  end

  test "a generated chunk's post-processing marks settle when it first ticks", ctx do
    {ax, z} = ctx.a
    position = {ax * 128 + 72, 64, z * 128 + 72}
    chunk = Valimc.Data.Grid.chunk_key(ax * 128 + 72, z * 128 + 72)
    set({ctx.pa, ctx.ea}, %{position => BlockRegistry.default_state("water")})

    # As generation leaves it: a source without its tick, marked.
    :ok =
      Valimc.TestRegion.replace_section({ctx.pa, ctx.ea}, fn s ->
        %{s | scheduled_ticks: ScheduledTicks.new(), post: %{chunk => {[position], []}}}
      end)

    assert {:ok, _} = Region.step({ctx.pa, ctx.ea})
    assert Valimc.TestRegion.section({ctx.pa, ctx.ea}).post == %{}
    # The mark's tick spread it at once.
    {x, y, z} = position
    assert {block({x + 1, y, z}), level({x + 1, y, z})} == {"water", "1"}
  end

  test "water over a magma block fills with a dragging bubble column", ctx do
    {ax, z} = ctx.a
    {x, z} = {ax * 128 + 100, z * 128 + 100}
    water = BlockRegistry.default_state("water")
    set({ctx.pa, ctx.ea}, Map.new(64..66, &{{x, &1, z}, water}))
    set({ctx.pa, ctx.ea}, %{{x, 63, z} => BlockRegistry.default_state("magma_block")})
    assert {:ok, _} = Region.step({ctx.pa, ctx.ea}, 25)

    assert for(y <- 64..66, do: Valimc.TestBlocks.get({x, y, z})) ==
             List.duplicate(BlockRegistry.state("bubble_column", %{"drag" => "true"}), 3)
  end

  test "lava lights what it can burn near a player", ctx do
    {ax, z} = ctx.a
    {x, z} = {ax * 128 + 20, z * 128 + 100}
    planks = BlockRegistry.default_state("oak_planks")
    # A pit of lava ringed by planks, a player's spread radius everywhere.
    :persistent_term.put({Valimc.World.GameRules, :fire_spread_radius_around_player}, -1)

    on_exit(fn ->
      :persistent_term.erase({Valimc.World.GameRules, :fire_spread_radius_around_player})
    end)

    ring =
      for dx <- -2..2,
          dz <- -2..2,
          abs(dx) == 2 or abs(dz) == 2,
          do: {{x + dx, 64, z + dz}, planks}

    set({ctx.pa, ctx.ea}, Map.new([{{x, 64, z}, BlockRegistry.default_state("lava")} | ring]))

    :ok =
      Valimc.TestRegion.replace_section({ctx.pa, ctx.ea}, fn s ->
        %{s | random_tick_speed: 4096}
      end)

    fires =
      Enum.reduce_while(1..200, 0, fn _, _ ->
        {:ok, _} = Region.step({ctx.pa, ctx.ea})

        fires =
          for dx <- -3..3, dz <- -3..3, y <- 64..66, block({x + dx, y, z + dz}) == "fire", do: 1

        if fires == [], do: {:cont, 0}, else: {:halt, length(fires)}
      end)

    assert fires > 0
  end
end
