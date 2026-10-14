defmodule Valimc.WorldClockTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Clock, ClockRecord, ClockState, ClockStore}

  defp eventually(fun, attempts \\ 100) do
    if fun.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
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

  test "native float32 tick boundaries and long wrap, independent pauses and global stop" do
    state = %ClockState{rate: ClockState.float32(0.1)}
    stepped = Enum.reduce(1..100, state, fn _, clock -> ClockState.tick(clock) end)
    assert stepped.total_ticks == 10
    # Float32 rounds each addition, rather than retaining BEAM float64 intermediates.
    assert stepped.partial_tick > 0.0

    assert ClockState.tick(%ClockState{total_ticks: 9_223_372_036_854_775_807}).total_ticks ==
             -9_223_372_036_854_775_808

    assert ClockState.tick(%{state | paused: true}) == %{state | paused: true}
    stopped = %{ClockRecord.new() | advance_time: false}
    assert ClockRecord.tick(stopped).clocks == stopped.clocks
    assert ClockRecord.tick(stopped).game_time == 1
  end

  test "snapshot keeps both clocks, partial rates and pause flags; corrupt and oversized files reject" do
    data = ClockRecord.new()

    data = %{
      data
      | game_time: 17,
        advance_time: false,
        clocks:
          Map.put(data.clocks, "minecraft:overworld", %ClockState{
            total_ticks: 18_000,
            partial_tick: 0.25,
            rate: 0.5,
            paused: true
          })
    }

    assert {:ok, bytes} = ClockRecord.encode(data)
    assert byte_size(bytes) <= ClockRecord.max_bytes()
    assert {:ok, ^data} = ClockRecord.decode(bytes)

    for bad <- [
          <<>>,
          binary_part(bytes, 0, byte_size(bytes) - 1),
          bytes <> <<0>>,
          :binary.copy(<<0>>, 257)
        ] do
      assert {:error, :invalid_clock_file} = ClockRecord.decode(bad)
    end

    <<first, rest::binary>> = bytes

    assert {:error, :invalid_clock_file} =
             ClockRecord.decode(<<Bitwise.bxor(first, 1), rest::binary>>)

    assert {:error, :invalid_clock_state} = ClockRecord.encode(%{data | clocks: %{}})
    refute ClockState.valid?(%ClockState{rate: 1025.0})
  end

  test "host controls validate, reset fractions on set, and publish immediate immutable corrections" do
    pid = clock()
    assert :ok = Clock.configure({"minecraft:overworld", :rate, 0.1}, pid)
    assert Clock.snapshot(pid).clocks["minecraft:overworld"].rate == ClockState.float32(0.1)
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
    state = :sys.get_state(pid)
    [{:network, version, periodic, latest}] = :ets.lookup(state.table, :network)
    assert is_reference(version) and periodic == latest
    assert before.game_time == 0
  end

  test "delivered ticks advance game time; paused/global clocks do not; stale and early timers stay fenced" do
    pid = clock(tick_interval_ms: 1000)
    state = :sys.get_state(pid)
    {old_token, _} = state.tick_timer
    # An early matching timer cannot advance time or leave two live timer chains.
    send(pid, {:clock_tick, old_token})
    after_early = :sys.get_state(pid)
    assert after_early.data.game_time == 0
    assert elem(after_early.tick_timer, 0) != old_token
    send(pid, {:clock_tick, old_token})
    assert :sys.get_state(pid).tick_timer == after_early.tick_timer

    :sys.replace_state(
      pid,
      &%{&1 | next_tick: System.monotonic_time(:millisecond), tick_interval: 10}
    )

    send(pid, {:clock_tick, elem(after_early.tick_timer, 0)})
    eventually(fn -> Clock.snapshot(pid).game_time >= 2 end)
    assert :ok = Clock.configure({:advance_time, false}, pid)
    frozen = Clock.snapshot(pid)
    eventually(fn -> Clock.snapshot(pid).game_time >= frozen.game_time + 2 end)
    assert Clock.snapshot(pid).clocks == frozen.clocks
    assert :ok = Clock.configure({:advance_time, true}, pid)
    assert :ok = Clock.configure({"minecraft:overworld", :paused, true}, pid)
    frozen = Clock.snapshot(pid)
    eventually(fn -> Clock.snapshot(pid).game_time >= frozen.game_time + 2 end)

    assert Clock.snapshot(pid).clocks["minecraft:overworld"] ==
             frozen.clocks["minecraft:overworld"]

    assert Clock.snapshot(pid).clocks["minecraft:the_end"].total_ticks >
             frozen.clocks["minecraft:the_end"].total_ticks
  end

  test "one pending immutable save while storage stalls; ticks/controls respond and newer revision stays dirty" do
    path = temporary()
    pid = clock(world_path: path, save_interval_ms: 1000)
    store = :sys.get_state(pid).store
    :sys.suspend(store)

    try do
      assert :ok = Clock.configure({"minecraft:overworld", :ticks, 2}, pid)
      {token, _} = :sys.get_state(pid).save_timer
      send(pid, {:clock_save, token})
      pending = :sys.get_state(pid)
      assert pending.saving != nil
      assert :ok = Clock.configure({"minecraft:overworld", :ticks, 4}, pid)
      {next_token, _} = :sys.get_state(pid).save_timer
      send(pid, {:clock_save, next_token})
      assert :sys.get_state(pid).saving == pending.saving
      assert {:message_queue_len, 1} = Process.info(store, :message_queue_len)
      send(pid, {:clock_saved, make_ref(), :ok})
      send(pid, {:clock_save_deadline, make_ref()})
      assert :sys.get_state(pid).saving == pending.saving
    after
      :sys.resume(store)
    end

    eventually(fn -> :sys.get_state(pid).saving == nil end)
    assert :sys.get_state(pid).dirty
    assert {:ok, saved} = ClockRecord.decode(File.read!(ClockStore.path(path)))
    assert saved.clocks["minecraft:overworld"].total_ticks == 2
    {token, _} = :sys.get_state(pid).save_timer
    send(pid, {:clock_save, token})
    eventually(fn -> :sys.get_state(pid).saving == nil end)
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
    state = :sys.get_state(pid)
    :sys.suspend(state.store)
    {token, _} = state.save_timer
    send(pid, {:clock_save, token})
    pending = :sys.get_state(pid).saving
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
    assert_receive {:DOWN, ^monitor, :process, ^pid, :clock_save_timeout}, 1000
    refute Process.alive?(state.store)
    assert File.read!(ClockStore.path(path)) == bytes
    replacement = clock(world_path: path)
    assert Clock.snapshot(replacement) == committed
  end

  test "failed async write stops owner without publishing an old snapshot over uncertain state" do
    path = temporary()

    {:ok, pid} =
      Clock.start_link(name: nil, world_path: path, tick_interval_ms: nil, save_interval_ms: 1000)

    Process.unlink(pid)
    monitor = Process.monitor(pid)
    File.write!(path, "blocked-directory")
    assert :ok = Clock.configure({"minecraft:overworld", :ticks, 5}, pid)
    {token, _} = :sys.get_state(pid).save_timer
    send(pid, {:clock_save, token})

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:clock_save_failed, {:error, :enotdir}}},
                   1000

    assert File.read!(path) == "blocked-directory"
  end
end
