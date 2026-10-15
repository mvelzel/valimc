defmodule Valimc.DifficultyTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Clock, ClockRecord, ClockStore, Difficulty}
  alias Valimc.Protocol.Packets

  defp signed(body), do: body <> :crypto.hash(:sha256, body)

  test "all levels/locks and native force boundary; invalid controls preserve state" do
    for initial <- 0..3, target <- 0..3, locked <- [false, true], force <- [false, true] do
      state = %Difficulty{level: initial, locked: locked}
      assert {:ok, changed} = Difficulty.change(state, target, force)
      assert changed.level == if(locked and not force, do: initial, else: target)
      assert changed.locked == locked
      assert {:ok, %{state | locked: not locked}} == Difficulty.lock(state, not locked)
    end

    for level <- [-1, 4, 2.0, nil],
        do:
          assert({:error, :invalid_difficulty_change} == Difficulty.change(%Difficulty{}, level))

    assert {:error, :invalid_difficulty_change} = Difficulty.change(%Difficulty{}, 1, 1)
    assert {:error, :invalid_difficulty_change} = Difficulty.lock(%Difficulty{}, 1)
    refute Difficulty.valid?(%Difficulty{level: 4})
    refute Difficulty.valid?(%Difficulty{locked: 1})
  end

  test "packet cache reuses unchanged values and encodes all eight native settings" do
    for level <- 0..3, locked <- [false, true] do
      state = %Difficulty{level: level, locked: locked}
      cache = Difficulty.cache(state, nil)
      assert Difficulty.cache(state, cache) == cache
      assert {^state, packet} = cache
      assert packet == Packets.packet("change_difficulty", <<level, if(locked, do: 1, else: 0)>>)
    end
  end

  test "version 2 migration preserves clocks and weather; version 3 rejects invalid fields" do
    data = %{
      ClockRecord.new()
      | game_time: 49,
        advance_time: false,
        difficulty: %Difficulty{level: 3, locked: true}
    }

    assert {:ok, bytes} = ClockRecord.encode(data)
    assert byte_size(bytes) == 114
    assert {:ok, ^data} = ClockRecord.decode(bytes)
    <<"VMCLOCK", 4, prior::binary-size(71), 3, 1, 1, _checksum::binary-size(32)>> = bytes
    legacy = signed(<<"VMCLOCK", 2, prior::binary>>)
    assert {:ok, loaded} = ClockRecord.decode(legacy)
    assert loaded == %{data | difficulty: %Difficulty{}}

    for {level, locked} <- [{4, 0}, {255, 0}, {2, 2}, {2, 255}] do
      corrupt = signed(<<"VMCLOCK", 3, prior::binary, level, locked>>)
      assert {:error, :invalid_clock_file} = ClockRecord.decode(corrupt)
    end

    assert {:error, :invalid_clock_file} =
             ClockRecord.decode(signed(<<"VMCLOCK", 3, prior::binary, 3>>))

    assert {:error, :invalid_clock_state} = ClockRecord.encode(%{data | difficulty: nil})
  end

  test "owner ignores locked changes without republishing; persisted setting survives owner reload" do
    path = Path.join(System.tmp_dir!(), "valimc-difficulty-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    opts = [name: nil, world_path: path, tick_interval_ms: nil, save_interval_ms: nil]
    pid = start_supervised!({Clock, opts})
    assert :ok = Clock.configure({:difficulty, 1}, pid)
    assert :ok = Clock.configure({:difficulty_locked, true}, pid)
    before = :sys.get_state(pid)
    assert :ok = Clock.configure({:difficulty, 0}, pid)
    assert :sys.get_state(pid) == before

    for operation <- [{:difficulty, 4}, {:difficulty, 2, 1}, {:difficulty_locked, 1}] do
      assert {:error, :invalid_difficulty_change} = Clock.configure(operation, pid)
      assert :sys.get_state(pid) == before
    end

    assert :ok = Clock.configure({:difficulty, 3, true}, pid)
    assert :ok = Clock.flush(pid)
    assert {:ok, saved} = path |> ClockStore.path() |> File.read!() |> ClockRecord.decode()
    assert saved.difficulty == %Difficulty{level: 3, locked: true}
    stop_supervised!(Clock)
    recovered = start_supervised!({Clock, opts})
    assert Clock.snapshot(recovered).difficulty == saved.difficulty
    state = :sys.get_state(recovered)
    assert [{:difficulty, {difficulty, packet}}] = :ets.lookup(state.table, :difficulty)
    assert difficulty == saved.difficulty and packet == Packets.difficulty(difficulty)
  end
end
