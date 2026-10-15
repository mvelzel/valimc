defmodule Valimc.PlayerMotionQueryTest do
  use ExUnit.Case, async: false
  alias Valimc.{GameMode, PlayerAbilities, PlayerInput, PlayerMotionQuery, World}

  setup do
    key = {6100, 6210}
    {:ok, _} = World.owner(key)

    player = %{
      x: 780_810.5,
      y: 64.0,
      z: 794_890.5,
      pose: :standing,
      input: PlayerInput.loaded(%PlayerInput{}),
      abilities: PlayerAbilities.for_mode(:creative),
      game_mode: GameMode.new(:creative),
      entity_id: 1
    }

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    end)

    %{player: player, key: key}
  end

  defp query(player, changes) do
    {:ok, task} = PlayerMotionQuery.start(player, Map.merge(player, changes))
    Task.await(task, 1000)
  end

  test "open walking, flying and downward floor contact resolve without changing authority", %{
    player: p
  } do
    assert {:ok, %{accepted: true, moved: {x, 64.0, _}, pose: :standing, fences: fences}} =
             query(p, %{x: p.x + 0.2})

    assert x == p.x + 0.2 and map_size(fences) == 1
    # Clipping resolves to the floor, but the requested position enters it and
    # must be corrected; the handler must not silently commit the clipped pose.
    assert {:ok, %{accepted: false, moved: {_, 64.0, _}}} = query(p, %{y: 63.99})
    assert {:ok, %{accepted: true, moved: {_, 65.0, _}}} = query(p, %{y: 65.0})
    assert p.y == 64.0
  end

  test "a newly entered wall rejects creative too, while spectator retains no-physics", %{
    player: p
  } do
    x = floor(p.x) + 1
    z = floor(p.z)
    for y <- 64..65, do: :ok = World.set_block({x, y, z}, 1)

    for mode <- [:survival, :creative, :adventure] do
      assert {:ok, %{accepted: false}} =
               query(%{p | game_mode: GameMode.new(mode)}, %{x: p.x + 0.5})
    end

    spectator = %{
      p
      | game_mode: GameMode.new(:spectator),
        abilities: PlayerAbilities.for_mode(:spectator)
    }

    assert {:ok, %{accepted: true}} = query(spectator, %{x: p.x + 0.5})
    # An existing overlap may be escaped; it is not itself a newly entered shape.
    :ok = World.set_block({floor(p.x), 64, z}, 1)
    assert {:ok, %{accepted: true}} = query(p, %{z: p.z - 0.1})
  end

  test "grounded slab stepping and low ceiling use distinct complete queries", %{player: p} do
    x = floor(p.x) + 1
    z = floor(p.z)
    :ok = World.set_block({x, 64, z}, 15180)
    assert {:ok, %{accepted: true, moved: {_, y, _}}} = query(p, %{x: p.x + 1.0, y: 64.5})
    assert y == 64.5
    :ok = World.set_block({x, 65, z}, 1)
    assert {:ok, %{accepted: false}} = query(p, %{x: p.x + 1.0, y: 64.5})
  end

  test "Shift fits a tunnel and contextual block facts fail explicitly", %{player: p} do
    for x <- floor(p.x)..(floor(p.x) + 2), do: :ok = World.set_block({x, 65, floor(p.z)}, 15178)
    p = %{p | input: %{p.input | shared_flags: 2}}
    assert {:ok, %{accepted: true, pose: :crouching}} = query(p, %{x: p.x + 0.2})
    :ok = World.set_block({floor(p.x) + 1, 64, floor(p.z)}, 16849)
    assert {:error, {:context_required, _, "minecraft:shulker_box"}} = query(p, %{x: p.x + 0.5})
  end

  test "source loss requests recovery but never supplies missing air", %{player: p, key: key} do
    {:ok, {old, _}} = World.existing_owner(key)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, old)
    result = query(p, %{x: p.x + 0.2})

    assert match?({:error, {:region, ^key, _}}, result) or
             match?({:ok, %{accepted: true}}, result)

    assert {:ok, {replacement, _}} = World.owner(key)
    refute old == replacement
    :sys.suspend(replacement)

    try do
      assert {:error, :collision_query_timeout} = query(p, %{x: p.x + 0.2})
    after
      :sys.resume(replacement)
    end

    assert {:ok, %{accepted: true}} = query(p, %{x: p.x + 0.2})
    assert {:error, :movement_query_limit} = PlayerMotionQuery.start(p, %{p | x: p.x + 65})
  end
end
