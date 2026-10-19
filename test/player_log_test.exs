defmodule Valimc.PlayerLogTest do
  use ExUnit.Case, async: false
  alias Valimc.PlayerLog
  alias Valimc.World.RegionLog

  setup do
    dir =
      Path.join([
        System.tmp_dir!(),
        "valimc-player-log-#{System.unique_integer([:positive])}",
        "players"
      ])

    on_exit(fn -> File.rm_rf!(Path.dirname(dir)) end)
    %{dir: dir}
  end

  defp writer(path), do: GenServer.whereis({:via, PartitionSupervisor, {Valimc.PlayerLogs, path}})

  # Player file paths that the same partition writer handles.
  defp same_partition(dir, count) do
    first = Path.join(dir, "0.pose")
    pid = writer(first)

    paths =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&Path.join(dir, "#{&1}.pose"))
      |> Stream.filter(&(writer(&1) == pid))
      |> Enum.take(count - 1)

    {pid, [first | paths]}
  end

  defp frames(pid) do
    {:ok, %{frames: frames}} = RegionLog.read(:sys.get_state(pid).log.dir)
    frames
  end

  test "saves queued by many players share one frame, and files are current", %{dir: dir} do
    {pid, paths} = same_partition(dir, 20)
    assert :ok = PlayerLog.commit(hd(paths), "warm")
    before = length(frames(pid))
    :sys.suspend(pid)

    tasks =
      try do
        tasks = for path <- paths, do: Task.async(fn -> PlayerLog.commit(path, path) end)
        wait(fn -> Process.info(pid, :message_queue_len) == {:message_queue_len, 20} end)
        tasks
      after
        :sys.resume(pid)
      end

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
    assert length(frames(pid)) == before + 1
    for path <- paths, do: assert(File.read!(path) == path)
  end

  test "reopening replays durable frames over files a crash lost", %{dir: dir} do
    {pid, [lost, other]} = same_partition(dir, 2)
    assert :ok = PlayerLog.commit(lost, "durable")
    # A crash after the frame's datasync but before the file write reached disk.
    File.rm!(lost)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    wait(fn -> writer(other) not in [nil, pid] end)
    assert :ok = PlayerLog.commit(other, "next")
    assert File.read!(lost) == "durable" and File.read!(other) == "next"
  end

  test "an unwritable directory fails the save without stopping the writer", %{dir: dir} do
    File.mkdir_p!(Path.dirname(dir))
    File.write!(dir, "not a directory")
    path = Path.join(dir, "1.pose")
    pid = writer(path)
    assert {:error, _} = PlayerLog.commit(path, "x")
    File.rm!(dir)
    assert :ok = PlayerLog.commit(path, "x")
    assert writer(path) == pid
  end

  defp wait(fun, tries \\ 500) do
    unless fun.() do
      assert tries > 0
      Process.sleep(1)
      wait(fun, tries - 1)
    end
  end
end
