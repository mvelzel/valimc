defmodule Valimc.PlayerMotionQueryTest do
  use ExUnit.Case, async: false
  # Serial: asserts production latency deadlines that concurrent CPU load can exceed.
  alias Valimc.TestScope
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
          do: TestScope.kill(pid)
    end)

    %{player: player, key: key}
  end

  defp query(player, changes) do
    {:ok, task} = PlayerMotionQuery.start(player, Map.merge(player, changes))
    Task.await(task, 60_000)
  end

  test "a newly entered wall rejects creative, while spectator retains no-physics", %{
    player: p
  } do
    x = floor(p.x) + 1
    z = floor(p.z)
    for y <- 64..65, do: :ok = World.set_block({x, y, z}, 1)

    assert {:ok, %{accepted: false}} = query(p, %{x: p.x + 0.5})

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
      # A busy owner no longer stalls movement: reads use its published snapshot.
      assert {:ok, %{accepted: true}} = query(p, %{x: p.x + 0.2})
    after
      :sys.resume(replacement)
    end

    assert {:ok, %{accepted: true}} = query(p, %{x: p.x + 0.2})
    assert {:error, :movement_query_limit} = PlayerMotionQuery.start(p, %{p | x: p.x + 65})
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
end
