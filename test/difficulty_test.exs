defmodule Valimc.DifficultyTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Clock, ClockRecord, ClockStore, Difficulty}
  alias Valimc.Protocol.Packets

  defp signed(body), do: body <> :crypto.hash(:sha256, body)

  test "version 2 migration preserves clocks and weather; version 3 rejects invalid fields" do
    data = %{
      ClockRecord.new()
      | game_time: 49,
        advance_time: false,
        difficulty: %Difficulty{level: 3, locked: true}
    }

    assert {:ok, bytes} = ClockRecord.encode(data)
    assert byte_size(bytes) == 199
    assert {:ok, ^data} = ClockRecord.decode(bytes)

    <<"VMCLOCK", 5, prior::binary-size(71), 3, 1, 1, _borders::binary-size(85),
      _checksum::binary-size(32)>> = bytes

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

  test "v4 stores the regeneration rule; v3 migrates to native true and invalid values reject" do
    data = %{ClockRecord.new() | natural_regeneration: false}
    assert {:ok, <<"VMCLOCK", 5, _::binary>> = bytes} = ClockRecord.encode(data)
    assert {:ok, ^data} = ClockRecord.decode(bytes)
    # Version 5 appends the world borders (one overworld entry: 85 bytes).
    size = byte_size(bytes) - 8 - 1 - 85 - 32
    <<"VMCLOCK", 5, prior::binary-size(^size), 0, _::binary-size(85), _::binary-size(32)>> = bytes
    assert {:ok, legacy} = ClockRecord.decode(signed(<<"VMCLOCK", 3, prior::binary>>))
    assert legacy.natural_regeneration

    for invalid <- [2, 255] do
      assert {:error, :invalid_clock_file} =
               ClockRecord.decode(signed(<<"VMCLOCK", 4, prior::binary, invalid>>))
    end

    assert {:error, :invalid_clock_state} =
             ClockRecord.encode(%{data | natural_regeneration: nil})
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
