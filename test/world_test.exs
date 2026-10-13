defmodule Valimc.WorldTest do
  use ExUnit.Case, async: false
  alias Valimc.World
  alias Valimc.Protocol.Wire

  test "negative chunk/region boundaries use floor division" do
    assert World.chunk_key(-0.5, -16.1) == {-1, -2}
    assert World.region_key({-1, -9}) == {-1, -2}
  end

  test "a saturated encoder pool does not block region state operations" do
    blockers =
      for _ <- 1..System.schedulers_online() do
        {:ok, pid} =
          Task.Supervisor.start_child(Valimc.ChunkWorkers, fn ->
            receive do
              :release -> :ok
            end
          end)

        pid
      end

    try do
      task = Task.async(fn -> World.chunk({880, 880}) end)
      assert Task.yield(task, 20) == nil
      assert :ok = World.set_block({14081, 64, 14081}, 1)
      assert World.get_block({14081, 64, 14081}) == 1
      for pid <- blockers, do: send(pid, :release)
      assert is_binary(Task.await(task, 5000))
    after
      for pid <- blockers, do: send(pid, :release)
    end
  end

  test "racing creation requests converge on one region owner" do
    pids =
      1..64
      |> Task.async_stream(
        fn _ ->
          {:ok, pid} = World.region({100, 100})
          pid
        end,
        max_concurrency: 64
      )
      |> Enum.map(fn {:ok, pid} -> pid end)

    assert length(Enum.uniq(pids)) == 1
  end

  test "concurrent encodes share a binary and mutations invalidate the cache" do
    key = {800, 800}
    before_count = Valimc.Metrics.snapshot()[:chunks_encoded] || 0

    frames =
      1..64
      |> Task.async_stream(fn _ -> World.chunk(key) end, max_concurrency: 64)
      |> Enum.map(fn {:ok, frame} -> frame end)

    assert length(Enum.uniq(frames)) == 1
    assert (Valimc.Metrics.snapshot()[:chunks_encoded] || 0) - before_count == 1
    assert :ok = World.set_block({12801, 64, 12801}, 1)
    changed = World.chunk(key)
    refute changed == hd(frames)
    assert {:ok, 46, _, <<>>} = Wire.next_frame(changed, 2_097_152, 256)
    assert World.get_block({12801, 64, 12801}) == 1
  end

  test "separate regions continue responding when one region is suspended" do
    {:ok, a} = World.region({101, 101})
    {:ok, b} = World.region({102, 102})
    :sys.suspend(a)

    try do
      assert GenServer.call(b, {:get_block, {13056, 63, 13056}}, 500) == 9
    after
      :sys.resume(a)
    end
  end

  test "region files preserve flushed edits across process replacement" do
    path = Path.join(System.tmp_dir!(), "valimc-test-#{System.unique_integer([:positive])}")
    old = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, path)

    try do
      {:ok, pid} = World.region({103, 103})
      pos = {13184, 65, 13184}
      assert :ok = World.set_block(pos, 1)
      assert :ok = World.Region.flush(pid)
      ref = Process.monitor(pid)
      assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      {:ok, replacement} = World.region({103, 103})
      assert replacement != pid
      assert World.get_block(pos) == 1
      DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, replacement)
    after
      Application.put_env(:valimc, :world_path, old)
      File.rm_rf!(path)
    end
  end
end
