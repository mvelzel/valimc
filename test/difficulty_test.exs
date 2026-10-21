defmodule Valimc.DifficultyTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Clock, ClockRecord, ClockStore, Difficulty}
  alias Valimc.Protocol.Packets

  defp signed(body), do: body <> :crypto.hash(:sha256, body)

  test "v4 records load with the default border; v1–v3 (before M1) and invalid fields reject" do
    data = %{
      ClockRecord.new()
      | game_time: 49,
        advance_time: false,
        difficulty: %Difficulty{level: 3, locked: true},
        natural_regeneration: false
    }

    assert {:ok, bytes} = ClockRecord.encode(data)
    assert {:ok, ^data} = ClockRecord.decode(bytes)

    # Version 5 appends the world borders (one overworld entry: 85 bytes) to version 4.
    <<"VMCLOCK", 5, prior::binary-size(71), 3, 1, 0, _borders::binary-size(85),
      _checksum::binary-size(32)>> = bytes

    assert {:ok, ^data} = ClockRecord.decode(signed(<<"VMCLOCK", 4, prior::binary, 3, 1, 0>>))

    for version <- 1..3 do
      assert {:error, :unsupported_clock_file} =
               ClockRecord.decode(signed(<<"VMCLOCK", version, prior::binary, 3, 1>>))
    end

    for {level, locked, rule} <- [{4, 0, 1}, {255, 0, 1}, {2, 2, 1}, {2, 0, 2}] do
      assert {:error, :invalid_clock_file} =
               ClockRecord.decode(signed(<<"VMCLOCK", 4, prior::binary, level, locked, rule>>))
    end

    assert {:error, :invalid_clock_state} = ClockRecord.encode(%{data | difficulty: nil})

    assert {:error, :invalid_clock_state} =
             ClockRecord.encode(%{data | natural_regeneration: nil})
  end

  test "owner ignores locked changes without republishing; persisted setting survives owner reload" do
    path = Path.join(System.tmp_dir!(), "valimc-difficulty-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    opts = [name: nil, world_path: path, tick_interval_ms: nil, save_interval_ms: nil]
    pid = start_supervised!({Clock, opts})
    assert :ok = Clock.configure({:difficulty, 1}, pid)
    assert :ok = Clock.configure({:difficulty_locked, true}, pid)
    before = Valimc.TestConn.state(pid)
    assert :ok = Clock.configure({:difficulty, 0}, pid)
    assert Valimc.TestConn.state(pid) == before

    for operation <- [{:difficulty, 4}, {:difficulty, 2, 1}, {:difficulty_locked, 1}] do
      assert {:error, :invalid_difficulty_change} = Clock.configure(operation, pid)
      assert Valimc.TestConn.state(pid) == before
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

  test "published difficulty/rule pair changes together and survives world-owner restart" do
    path =
      Path.join(System.tmp_dir!(), "valimc-survival-rules-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(path) end)
    opts = [name: nil, world_path: path, tick_interval_ms: nil, save_interval_ms: nil]
    pid = start_supervised!({Clock, opts})
    table = Valimc.TestConn.state(pid).table
    assert [{:survival, {1, true}}] = :ets.lookup(table, :survival)
    assert :ok = Clock.configure({:natural_regeneration, false}, pid)
    assert :ok = Clock.configure({:difficulty, 3}, pid)
    assert [{:survival, {3, false}}] = :ets.lookup(table, :survival)
    before = Valimc.TestConn.state(pid)
    assert {:error, :invalid_clock_change} = Clock.configure({:natural_regeneration, 1}, pid)
    assert Valimc.TestConn.state(pid) == before
    assert :ok = Clock.flush(pid)
    stop_supervised!(Clock)
    loaded = start_supervised!({Clock, opts})
    assert Clock.snapshot(loaded).natural_regeneration == false
    assert [{:survival, {3, false}}] = :ets.lookup(:sys.get_state(loaded).table, :survival)
  end
end
