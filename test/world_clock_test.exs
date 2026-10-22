defmodule Valimc.WorldClockTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Clock, ClockRecord, ClockState, ClockStore}

  defp eventually(fun, _budget \\ nil) do
    Valimc.TestWait.until(fun)
    :ok
  end

  defp clock(opts \\ []) do
    pid =
      start_supervised!(
        {Clock,
         Keyword.merge(
           [name: nil, world_path: nil, tick_interval_ms: nil, save_interval_ms: nil],
           opts
         )}
      )

    pid
  end

  defp temporary do
    path = Path.join(System.tmp_dir!(), "valimc-clock-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "host controls validate, reset fractions on set, and publish immediate immutable corrections" do
    pid = clock()
    assert :ok = Clock.configure({"minecraft:overworld", :rate, 0.1}, pid)

    assert Clock.snapshot(pid).clocks["minecraft:overworld"].rate ==
             Valimc.Data.Float32.round(0.1)

    assert :ok = Clock.configure({"minecraft:overworld", :ticks, 18_000}, pid)
    assert :ok = Clock.configure({"minecraft:overworld", :paused, true}, pid)
    assert Clock.snapshot(pid).clocks["minecraft:overworld"].partial_tick == 0.0
    before = Clock.snapshot(pid)

    for operation <- [
          {"missing", :ticks, 0},
          {"minecraft:overworld", :ticks, 9_223_372_036_854_775_808},
          {"minecraft:overworld", :rate, 1025},
          {:advance_time, 1},
          {"minecraft:overworld", :paused, 1}
        ] do
      assert {:error, :invalid_clock_change} = Clock.configure(operation, pid)
      assert Clock.snapshot(pid) == before
    end

    assert :ok = Clock.configure({:advance_time, false}, pid)
    state = Valimc.TestConn.state(pid)
    [{:network, version, periodic, latest}] = :ets.lookup(state.table, :network)
    assert is_reference(version) and periodic == latest
    assert before.game_time == 0
  end

  test "one pending immutable save while storage stalls; ticks/controls respond and newer revision stays dirty" do
    path = temporary()
    pid = clock(world_path: path, save_interval_ms: 1000)
    store = Valimc.TestConn.state(pid).store
    :sys.suspend(store)

    try do
      assert :ok = Clock.configure({"minecraft:overworld", :ticks, 2}, pid)
      {token, _} = Valimc.TestConn.state(pid).save_timer
      send(pid, {:clock_save, token})
      pending = Valimc.TestConn.state(pid)
      assert pending.saving != nil
      assert :ok = Clock.configure({"minecraft:overworld", :ticks, 4}, pid)
      {next_token, _} = Valimc.TestConn.state(pid).save_timer
      send(pid, {:clock_save, next_token})
      assert Valimc.TestConn.state(pid).saving == pending.saving
      assert {:message_queue_len, 1} = Process.info(store, :message_queue_len)
      send(pid, {:clock_saved, make_ref(), :ok})
      send(pid, {:clock_save_deadline, make_ref()})
      assert Valimc.TestConn.state(pid).saving == pending.saving
    after
      :sys.resume(store)
    end

    eventually(fn -> Valimc.TestConn.state(pid).saving == nil end)
    assert Valimc.TestConn.state(pid).dirty
    assert {:ok, saved} = ClockRecord.decode(File.read!(ClockStore.path(path)))
    assert saved.clocks["minecraft:overworld"].total_ticks == 2
    {token, _} = Valimc.TestConn.state(pid).save_timer
    send(pid, {:clock_save, token})
    eventually(fn -> Valimc.TestConn.state(pid).saving == nil end)
    assert {:ok, saved} = ClockRecord.decode(File.read!(ClockStore.path(path)))
    assert saved.clocks["minecraft:overworld"].total_ticks == 4
  end

  test "graceful stop writes latest state and recovery preserves controls; corrupt file stays intact" do
    path = temporary()
    pid = clock(world_path: path)
    assert :ok = Clock.configure({"minecraft:overworld", :ticks, 18_000}, pid)
    assert :ok = Clock.configure({"minecraft:overworld", :paused, true}, pid)
    assert :ok = Clock.configure({:advance_time, false}, pid)
    saved = Clock.snapshot(pid)
    stop_supervised!(Clock)
    pid = clock(world_path: path)
    assert Clock.snapshot(pid) == saved
    assert :ok = Clock.flush(pid)
    stop_supervised!(Clock)
    File.write!(ClockStore.path(path), "corrupt")

    assert {:error, _} = start_supervised({Clock, [name: nil, world_path: path]})

    assert File.read!(ClockStore.path(path)) == "corrupt"
  end

  test "lost save acknowledgment fences the writer and reloads the actual committed file" do
    path = temporary()

    {:ok, pid} =
      Clock.start_link(name: nil, world_path: path, tick_interval_ms: nil, save_interval_ms: 1000)

    Process.unlink(pid)
    monitor = Process.monitor(pid)
    assert :ok = Clock.configure({"minecraft:overworld", :ticks, 2}, pid)
    state = Valimc.TestConn.state(pid)
    :sys.suspend(state.store)
    {token, _} = state.save_timer
    send(pid, {:clock_save, token})
    pending = Valimc.TestConn.state(pid).saving
    # A physical-commit/withheld-reply fixture. The owner must never flush its
    # older memory snapshot over the file when the save outcome is uncertain.
    committed = Clock.snapshot(pid)

    committed = %{
      committed
      | clocks:
          Map.put(committed.clocks, "minecraft:overworld", %ClockState{
            total_ticks: 9,
            paused: true
          })
    }

    {:ok, bytes} = ClockRecord.encode(committed)
    File.mkdir_p!(path)
    File.write!(ClockStore.path(path), bytes)
    send(pid, {:clock_save_deadline, pending.token})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :clock_save_timeout}
    refute Process.alive?(state.store)
    assert File.read!(ClockStore.path(path)) == bytes
    replacement = clock(world_path: path)
    assert Clock.snapshot(replacement) == committed
  end
end
