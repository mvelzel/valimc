defmodule Valimc.PlayerMotionQueryTest do
  use ExUnit.Case, async: false
  alias Valimc.TestScope
  alias Valimc.{GameMode, PlayerAbilities, PlayerInput, PlayerMotionQuery}

  setup do
    key = {6100, 6210}
    {:ok, _} = Valimc.TestWorld.owner(key)

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
      for {pid, _} <- Valimc.TestWorld.registered(key),
          do: TestScope.kill(pid)
    end)

    %{player: player, key: key}
  end

  defp query(player, changes), do: PlayerMotionQuery.run(player, Map.merge(player, changes))

  test "a newly entered wall rejects creative, while spectator retains no-physics", %{
    player: p
  } do
    x = floor(p.x) + 1
    z = floor(p.z)
    for y <- 64..65, do: :ok = Valimc.TestBlocks.set({x, y, z}, 1)

    assert {:ok, %{accepted: false}} = query(p, %{x: p.x + 0.5})

    spectator = %{
      p
      | game_mode: GameMode.new(:spectator),
        abilities: PlayerAbilities.for_mode(:spectator)
    }

    assert {:ok, %{accepted: true}} = query(spectator, %{x: p.x + 0.5})
    # An existing overlap may be escaped; it is not itself a newly entered shape.
    :ok = Valimc.TestBlocks.set({floor(p.x), 64, z}, 1)
    assert {:ok, %{accepted: true}} = query(p, %{z: p.z - 0.1})
  end

  test "source loss requests recovery but never supplies missing air", %{player: p, key: key} do
    {:ok, {old, _}} = Valimc.TestWorld.existing_owner(key)
    DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, old)
    result = query(p, %{x: p.x + 0.2})

    # Space of a region not running cannot be read (unless its replacement
    # already published it).
    assert match?({:error, {:missing_block, _}}, result) or
             match?({:ok, %{accepted: true}}, result)

    assert {:ok, {replacement, _}} = Valimc.TestWorld.owner(key)
    refute old == replacement
    :sys.suspend(replacement)

    try do
      # A busy owner no longer stalls movement: reads use its published snapshot.
      assert {:ok, %{accepted: true}} = query(p, %{x: p.x + 0.2})
    after
      :sys.resume(replacement)
    end

    assert {:ok, %{accepted: true}} = query(p, %{x: p.x + 0.2})
    assert {:error, :movement_query_limit} = PlayerMotionQuery.run(p, %{p | x: p.x + 65})
  end

  test "retained paths sample crossed material, fit the frame and remain owned until a tick commits",
       %{player: p} do
    paths = [{{p.x - 3, p.y, p.z}, {p.x, p.y, p.z}, {3.0, 0.0, 0.0}}]

    :ok = Valimc.TestBlocks.set({floor(p.x) - 2, 64, floor(p.z)}, 2362)
    p = Map.put(p, :motion, %Valimc.PlayerMotion{paths: paths})

    assert {:ok, %{accepted: true, kinetics: %{packet: packet, tick: tick}}} =
             query(p, %{x: p.x + 0.2})

    assert length(packet.paths) == 2 and tick.paths == []
    assert elem(tick.stuck_multiplier, 0) == 0.25 and tick.reset_fall
    assert p.motion.paths == paths
    assert {:error, :movement_query_limit} = PlayerMotionQuery.run(p, %{p | z: p.z + 64})
  end
end
