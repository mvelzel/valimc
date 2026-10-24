defmodule Valimc.ShulkerPlayerCollisionTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Player.{Abilities, GameMode, Input, Motion, MotionQuery, PoseQuery}
  alias Valimc.TestScope
  alias Valimc.World.{EntityColliders, Region, View}

  setup do
    nonce = System.unique_integer([:positive])
    key = {63_000 + rem(nonce, 3333) * 3, 6800}
    other = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-shulker-solid-#{nonce}")

    TestScope.isolate([key, other],
      world_path: base,
      region_ticks: :manual,
      region_commit_ms: 600_000,
      regionizer: false,
      item_simulation: true
    )

    {:ok, a} = Valimc.TestWorld.owner(key)
    {:ok, b} = Valimc.TestWorld.owner(other)
    edge = elem(other, 0) * 128.0
    z = elem(key, 1) * 128.0 + 8.5

    for x <- (floor(edge) - 5)..(floor(edge) + 5),
        cz <- (floor(z) - 3)..(floor(z) + 3),
        do: :ok = Valimc.TestBlocks.set({x, 63, cz}, 1)

    on_exit(fn ->
      for k <- [key, other], {pid, _} <- Valimc.TestWorld.registered(k), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    player = %{
      x: edge - 1.6,
      y: 64.0,
      z: z,
      dimension: :overworld,
      entity_id: 2_147_483_647,
      pose: :standing,
      input: Input.loaded(%Input{}),
      abilities: Abilities.for_mode(:creative),
      game_mode: GameMode.new(:creative),
      motion: %Motion{on_ground: true}
    }

    %{a: a, b: b, edge: edge, z: z, player: player}
  end

  defp shulker do
    {:ok, body} = Body.new("minecraft:shulker")

    %{
      body
      | mob: %{body.mob | no_ai: true},
        data: %{body.data | attach_face: 5, peek: 100, peek_amount: 1.0}
    }
  end

  defp spawn(c, records) do
    :ok = Region.drop_items(c.b, records)
    {:ok, _} = Region.step(c.b, 1)
  end

  test "published neighboring-section lids block moves, refresh resting poses and retire on death",
       c do
    before = PoseQuery.signature(c.player)
    spawn(c, [Store.body_record(shulker(), <<51::128>>, {c.edge + 0.5, 64.0, c.z})])
    opened = PoseQuery.signature(c.player)
    refute opened == before
    target = %{c.player | x: c.edge - 0.8}
    assert {:ok, %{accepted: false, moved: {mx, _, _}}} = MotionQuery.run(c.player, target)
    assert_in_delta mx, c.edge - 1.3, 1.0e-7

    spectator = %{
      c.player
      | game_mode: GameMode.new(:spectator),
        abilities: Abilities.for_mode(:spectator)
    }

    assert {:ok, %{accepted: true}} = MotionQuery.run(spectator, target)

    # Raw metadata stays at 100 while the physical lid changes.
    Valimc.TestRegion.replace_section(c.b, fn section ->
      {:ok, {_, id, _}} = Store.find(section.entities.store, <<51::128>>)
      body = section.entities.store.entries[id].body
      body = put_in(body.data.peek_amount, 0.0)
      put_in(section.entities.store, Store.change_body(section.entities.store, id, body))
    end)

    {:ok, _} = Region.step(c.b, 1)
    refute PoseQuery.signature(c.player) == opened
    assert {:ok, %{accepted: true}} = MotionQuery.run(c.player, target)
    assert {:ok, %{accepted: false}} = MotionQuery.run(c.player, %{target | x: c.edge + 0.2})

    # The ordinary owner kill path withdraws the solid observation.
    {:ok, _} = Region.kill_entities(c.b, [<<51::128>>])
    {:ok, _} = Region.step(c.b, 1)
    assert {:ok, %{accepted: true}} = MotionQuery.run(c.player, %{target | x: c.edge + 0.2})
  end

  test "a resting server tick finds ground on a closed shulker", c do
    body = shulker()
    body = %{body | data: %{body.data | peek: 0, peek_amount: 0.0}}
    spawn(c, [Store.body_record(body, <<53::128>>, {c.edge + 0.5, 64.0, c.z})])
    player = %{c.player | x: c.edge + 0.5, y: 65.0, motion: %Motion{velocity: {0.0, -0.2, 0.0}}}
    assert {:ok, result} = PoseQuery.run(player)
    assert result.ticked.physical_ground
    {:ok, 1} = Region.kill_entities(c.b, [<<53::128>>])
    {:ok, _} = Region.step(c.b, 1)
    assert {:ok, result} = PoseQuery.run(player)
    refute result.ticked.physical_ground
  end

  test "resting pose fit sees an opening lid overhead", c do
    body = shulker()
    body = %{body | data: %{body.data | attach_face: 1, peek: 0, peek_amount: 0.0}}
    spawn(c, [Store.body_record(body, <<52::128>>, {c.edge + 0.5, 66.0, c.z})])
    player = %{c.player | x: c.edge + 0.5}
    assert {:ok, %{pose: :standing}} = PoseQuery.run(player)

    Valimc.TestRegion.replace_section(c.b, fn section ->
      {:ok, {_, id, _}} = Store.find(section.entities.store, <<52::128>>)
      body = section.entities.store.entries[id].body
      body = %{body | data: %{body.data | peek: 100, peek_amount: 1.0}}
      put_in(section.entities.store, Store.change_body(section.entities.store, id, body))
    end)

    {:ok, _} = Region.step(c.b, 1)
    assert {:ok, %{pose: :swimming}} = PoseQuery.run(player)
  end

  test "a complete collider set over the bound refuses movement instead of truncating it", c do
    records =
      for n <- 1..257, do: Store.body_record(shulker(), <<n::128>>, {c.edge + 0.5, 64.0, c.z})

    spawn(c, records)

    assert {:error, :entity_query_limit} =
             MotionQuery.run(c.player, %{c.player | x: c.edge - 0.8})

    # The bound concerns this query's intersections, not distant boxes in a chunk.
    assert {:ok, []} =
             EntityColliders.collect(
               View.new(),
               {c.edge - 1, 200.0, c.z, c.edge + 1, 202.0, c.z + 1},
               1
             )
  end
end
