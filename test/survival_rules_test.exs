defmodule Valimc.SurvivalRulesTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Clock, ClockRecord}
  defp seal(body), do: body <> :crypto.hash(:sha256, body)

  test "v4 stores the regeneration rule; v3 migrates to native true and invalid values reject" do
    data = %{ClockRecord.new() | natural_regeneration: false}
    assert {:ok, <<"VMCLOCK", 4, _::binary>> = bytes} = ClockRecord.encode(data)
    assert {:ok, ^data} = ClockRecord.decode(bytes)
    size = byte_size(bytes) - 8 - 1 - 32
    <<"VMCLOCK", 4, prior::binary-size(^size), 0, _::binary-size(32)>> = bytes
    assert {:ok, legacy} = ClockRecord.decode(seal(<<"VMCLOCK", 3, prior::binary>>))
    assert legacy.natural_regeneration

    for invalid <- [2, 255] do
      assert {:error, :invalid_clock_file} =
               ClockRecord.decode(seal(<<"VMCLOCK", 4, prior::binary, invalid>>))
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
