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

  test "accepted fall context changes powder-snow collision instead of caching zero", %{player: p} do
    :ok = World.set_block({floor(p.x), 64, floor(p.z)}, 30519)
    p = %{p | y: 67.0}
    light = Map.put(p, :motion, %Valimc.PlayerMotion{fall_distance: 2.5})
    heavy = Map.put(p, :motion, %Valimc.PlayerMotion{fall_distance: 2.5000000000000004})
    assert {:ok, %{accepted: true}} = query(light, %{y: 64.5})
    assert {:ok, %{accepted: false}} = query(heavy, %{y: 64.5})
    assert {:ok, %{accepted: true}} = query(heavy, %{y: 64.89999997615814})
    refute Valimc.PlayerPoseQuery.signature(light) == Valimc.PlayerPoseQuery.signature(heavy)
  end

  test "pending slow motion clips physical travel while validation keeps the requested anchor", %{
    player: p
  } do
    p =
      Map.put(p, :motion, %Valimc.PlayerMotion{
        velocity: {0.4, -0.1, 0.0},
        stuck_multiplier: {0.25, 0.05000000074505806, 0.25}
      })

    assert {:ok, %{accepted: true, moved: {x, _, _}, kinetics: %{packet: packet}}} =
             query(p, %{x: p.x + 0.4})

    assert abs(x - (p.x + 0.1)) < 1.0e-9
    assert packet.velocity == {0.0, 0.0, 0.0}
    assert packet.stuck_multiplier == {0.0, 0.0, 0.0}
    assert packet.paths.count == 1

    assert {:ok, %{accepted: false}} =
             query(%{p | game_mode: GameMode.new(:survival)}, %{x: p.x + 0.4})

    # Powder can enlarge the supplied vertical displacement beyond the target box.
    snow = %{
      p
      | y: 67.0,
        motion: %{p.motion | stuck_multiplier: {0.8999999761581421, 1.5, 0.8999999761581421}}
    }

    assert {:ok, %{accepted: true, moved: {_, 65.5, _}}} = query(snow, %{y: 66.0})
  end

  test "retained paths sample crossed material, fit the frame and remain owned until a tick commits",
       %{player: p} do
    paths =
      Valimc.Physics.MovementPaths.record(
        %Valimc.Physics.MovementPaths{},
        {p.x - 3, p.y, p.z},
        {3.0, 0.0, 0.0},
        {3.0, 0.0, 0.0}
      )

    :ok = World.set_block({floor(p.x) - 2, 64, floor(p.z)}, 2362)
    p = Map.put(p, :motion, %Valimc.PlayerMotion{paths: paths})

    assert {:ok, %{accepted: true, kinetics: %{packet: packet, tick: tick}}} =
             query(p, %{x: p.x + 0.2})

    assert packet.paths.count == 2 and tick.paths.count == 0
    assert elem(tick.stuck_multiplier, 0) == 0.25 and tick.reset_fall
    assert p.motion.paths == paths
    assert {:error, :block_scan_limit} = PlayerMotionQuery.start(p, %{p | z: p.z + 64})
  end

  test "Shift protects a ledge before collision and flight/upward travel bypass it", %{player: p} do
    for x <- (floor(p.x) + 1)..(floor(p.x) + 4),
        z <- (floor(p.z) - 2)..(floor(p.z) + 2),
        do: :ok = World.set_block({x, 63, z}, 0)

    shifted = %{p | input: %{p.input | shared_flags: 2}}
    shifted = Map.put(shifted, :motion, %Valimc.PlayerMotion{on_ground: true})

    {:ok, %{accepted: true, moved: {x, _, _}, kinetics: %{packet: packet}}} =
      query(shifted, %{x: p.x + 1.0})

    assert x < p.x + 0.8 and x > p.x + 0.7
    [path] = :queue.to_list(packet.paths.queue)
    assert elem(path.axis, 0) < 0.8
    assert {:ok, %{moved: {_, y, _}}} = query(shifted, %{x: p.x + 1.0, y: 64.1})
    assert y == 64.1
    flying = %{shifted | abilities: %{shifted.abilities | flying: true}}
    {:ok, %{moved: {x, _, _}}} = query(flying, %{x: p.x + 1.0})
    assert x == p.x + 1.0
  end
end
