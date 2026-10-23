defmodule Valimc.PistonRegionTest do
  @moduledoc """
  Pistons in region owners (VMC-048b): a lever's power reaches a piston
  whose block event runs at the next tick's event phase, the moving blocks'
  block entities tick after the entities and land, a sticky piston pulls its
  block back, a moving block carries an item, the kernel collides with a
  moving block from its block entity, and the block entities persist. The
  rules themselves are `check_pistons.exs`'s, the shapes
  `check_piston_collisions.exs`'s.
  """
  use ExUnit.Case, async: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    a = {97_000 + rem(nonce, 3_333) * 3, 2310}
    base = Path.join(System.tmp_dir!(), "valimc-pistons-#{nonce}")

    TestScope.isolate([a],
      world_path: base,
      region_ticks: :manual,
      regionizer: false,
      item_simulation: true
    )

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(a), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, {pa, ea}} = Valimc.TestWorld.owner(a)
    TestScope.simulate({pa, ea}, a)
    {ax, az} = a
    %{owner: {pa, ea}, x: ax * 128, z: az * 128}
  end

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  defp block(position),
    do: BlockRegistry.name(BlockRegistry.block_id(Valimc.TestBlocks.get(position)))

  defp props(position), do: Map.new(BlockRegistry.properties(Valimc.TestBlocks.get(position)))

  defp state(name, props), do: BlockRegistry.state(name, props)

  defp press(owner, {x, y, z} = position) do
    grant = %{
      kind: :open,
      mode: :survival,
      eye: {x + 0.5, y + 1.6, z - 1.5},
      hand: :main,
      secondary: false,
      main: false,
      off: false,
      yaw: 0.0,
      expires: Valimc.TestRegion.grant_expires(200)
    }

    Region.menu(owner, self(), position, grant)
  end

  defp section(owner), do: Valimc.TestRegion.section(owner)

  # The test world's floor is at y 63.
  test "a lever extends a sticky piston, which pulls its block back when the lever goes off",
       ctx do
    {x, z} = {ctx.x + 20, ctx.z + 20}
    piston = {x, 64, z}
    # On a stone block beside the piston: a lever on the piston itself would
    # pop as the base extends (its top face no longer whole).
    lever = {x - 1, 65, z}

    set(ctx.owner, %{
      piston => state("sticky_piston", %{"facing" => "east", "extended" => "false"}),
      {x + 1, 64, z} => BlockRegistry.default_state("stone"),
      {x - 1, 64, z} => BlockRegistry.default_state("stone"),
      lever => state("lever", %{"face" => "floor", "facing" => "north"})
    })

    assert press(ctx.owner, lever) == :used
    # The block event waits for the tick's event phase.
    assert block({x + 1, 64, z}) == "stone"
    assert {:ok, _} = Region.step(ctx.owner, 1)
    assert props(piston)["extended"] == "true"
    assert block({x + 1, 64, z}) == "moving_piston"
    assert block({x + 2, 64, z}) == "moving_piston"
    pistons = section(ctx.owner).pistons
    assert map_size(pistons) == 2
    assert {_moved, 5, true, false, 0.5, +0.0, _, _} = pistons[{x + 2, 64, z}]
    # Persisted with the section's parts.
    assert Valimc.World.RegionData.parts(section(ctx.owner)).pistons == pistons

    assert {:ok, _} = Region.step(ctx.owner, 2)
    assert block({x + 1, 64, z}) == "piston_head"
    assert block({x + 2, 64, z}) == "stone"
    assert section(ctx.owner).pistons == %{}

    assert press(ctx.owner, lever) == :used
    assert {:ok, _} = Region.step(ctx.owner, 3)
    assert props(piston)["extended"] == "false"
    assert block({x + 1, 64, z}) == "stone"
    assert block({x + 2, 64, z}) == "air"
  end

  test "a block pushed up carries an item and collides as it moves", ctx do
    {x, z} = {ctx.x + 40, ctx.z + 40}
    piston = {x, 64, z}

    set(ctx.owner, %{
      piston => state("piston", %{"facing" => "up", "extended" => "false"}),
      {x, 65, z} => BlockRegistry.default_state("stone")
    })

    {:ok, _} = Region.create_item(ctx.owner, ItemStack.new("dirt"), {x + 0.5, 66.0, z + 0.5})
    assert {:ok, _} = Region.step(ctx.owner, 5)

    set(ctx.owner, %{{x + 1, 64, z} => BlockRegistry.default_state("redstone_block")})
    assert {:ok, _} = Region.step(ctx.owner, 1)
    # Half way up, the moving stone's top is at 66.5 and stops a box above.
    view = Valimc.World.View.new()
    context = Valimc.Physics.CollisionContext.empty()

    assert {:ok, true} =
             Valimc.Physics.Kernel.colliding?(
               view,
               {x + 0.2, 66.2, z + 0.2, x + 0.8, 66.4, z + 0.8},
               context
             )

    assert {:ok, _} = Region.step(ctx.owner, 3)
    assert block({x, 66, z}) == "stone"

    [{_, item}] =
      Enum.filter(section(ctx.owner).entities.store.entries, fn {_, e} -> e.kind == :item end)

    assert_in_delta item.entity.y, 67.0, 0.05
  end
end
