defmodule Valimc.OpenFilesTest do
  @moduledoc """
  File descriptors are bounded and running out of them is survived (VMC-074):
  logs hold no descriptor between operations and take what they open from
  `Valimc.FileBudget`; with the process's open-files limit lowered so every
  open fails with `EMFILE`, log appends, proto log writes and region loading
  wait and finish once descriptors are back.
  """
  # Serial: these tests lower the whole VM's open-files limit.
  use ExUnit.Case, async: false
  alias Valimc.{FileBudget, Native, TestScope, World}
  alias Valimc.World.RegionLog
  alias Valimc.Worldgen.ProtoLog

  setup do
    base = Path.join(System.tmp_dir!(), "valimc-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    cap = FileBudget.cap()
    {:ok, {soft, _}} = Native.set_open_files_limit(1_000_000)

    on_exit(fn ->
      Native.set_open_files_limit(soft)
      FileBudget.set_cap(cap)
      File.rm_rf(base)
    end)

    %{base: base, soft: soft}
  end

  defp descriptors, do: length(File.ls!("/dev/fd"))

  # Every open fails (only standard input, output and error fit) until
  # `restore_after` milliseconds have passed.
  defp starve(soft, restore_after) do
    {:ok, {3, _}} = Native.set_open_files_limit(3)
    {:error, :emfile} = File.open(Path.join(System.tmp_dir!(), "valimc-starved"), [:write])

    spawn(fn ->
      Process.sleep(restore_after)
      Native.set_open_files_limit(soft)
    end)
  end

  test "the open-files limit is raised toward the hard limit and can be set lower", %{soft: soft} do
    {:ok, {raised, hard}} = Native.set_open_files_limit(1_000_000)
    assert raised == soft and raised <= hard
    if match?({:unix, :darwin}, :os.type()), do: assert(raised <= 10_240)
    assert {:ok, {100, ^hard}} = Native.set_open_files_limit(100)
    assert {:ok, {^raised, ^hard}} = Native.set_open_files_limit(1_000_000)
    assert FileBudget.cap() > 0
  end

  # The budget counts what owners took; one killed while it held some (tests
  # kill owners) never gives them back, so caps are set above what is counted.
  defp set_cap_above_counted(cap) do
    cap = FileBudget.in_use() + cap
    FileBudget.set_cap(cap)
    cap
  end

  # Holders together never exceed the cap, whatever other tests' owners hold or
  # give back meanwhile, so this test's own holders never do either.
  @tag timeout: 300_000
  test "the budget bounds what is open at once" do
    cap = set_cap_above_counted(2)
    # [inside now, most inside at once]
    inside = :atomics.new(2, [])

    results =
      1..24
      |> Task.async_stream(
        fn i ->
          FileBudget.with_files(fn ->
            now = :atomics.add_get(inside, 1, 1)
            :atomics.put(inside, 2, max(:atomics.get(inside, 2), now))
            Process.sleep(5)
            :atomics.sub(inside, 1, 1)
            i
          end)
        end,
        max_concurrency: 24,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, i} -> i end)

    assert results == Enum.to_list(1..24)
    assert :atomics.get(inside, 2) in 1..cap
  end

  test "out-of-descriptor errors are transient, others are not" do
    for reason <- [
          :emfile,
          :enfile,
          "Too many open files (os error 24)",
          {:mining_recovery_failed, {:full_sync, "Too many open files (os error 24)"}},
          {:invalid_region_file, "could not read file \"log.1\": too many open files"},
          {:file, :emfile, "/tmp/x"}
        ],
        do: assert(FileBudget.transient?(reason))

    for reason <- [:enoent, :eacces, "No such file or directory (os error 2)", {:corrupt, 3}],
        do: refute(FileBudget.transient?(reason))
  end

  # Holding a descriptor per log would add 200; the margin is for whatever the
  # rest of the VM (other tests' owners, the logger) opens meanwhile.
  @tag timeout: 300_000
  test "logs hold no descriptor: hundreds open and append", %{base: base} do
    before = descriptors()

    logs =
      for i <- 1..200 do
        {:ok, log, _} = RegionLog.open(Path.join(base, "r#{i}"))
        {:ok, log, _} = RegionLog.append(log, [[{:cells, i}]])
        log
      end

    assert descriptors() < before + 100

    {:ok, _, %{frames: frames}} = RegionLog.open(Path.join(base, "r200"))
    assert [{:open, 1}] in Enum.map(frames, & &1.ops)
    assert [{:cells, 200}] in Enum.map(frames, & &1.ops)
    Enum.each(logs, &RegionLog.close/1)
  end

  test "an append out of descriptors waits, then lands once", %{base: base, soft: soft} do
    dir = Path.join(base, "log")
    {:ok, log, _} = RegionLog.open(dir)
    starve(soft, 300)
    assert {:ok, _log, 2} = RegionLog.append(log, [[{:kept, 1}]])

    {:ok, _, %{frames: frames}} = RegionLog.open(dir)
    assert Enum.count(frames, &(&1.ops == [{:kept, 1}])) == 1
  end

  test "a log that cannot be listed is not empty", %{base: base, soft: soft} do
    dir = Path.join(base, "listed")
    {:ok, log, _} = RegionLog.open(dir)
    {:ok, _, _} = RegionLog.append(log, [[{:kept, 1}]])
    starve(soft, 300)
    {:ok, _, %{frames: frames}} = RegionLog.open(dir)
    assert [{:kept, 1}] in Enum.map(frames, & &1.ops)
  end

  test "a proto log write out of descriptors is saved once they are back", %{
    base: base,
    soft: soft
  } do
    {:ok, writer, _, _} = ProtoLog.open(Path.join(base, "gen"))
    starve(soft, 300)
    token = make_ref()
    ProtoLog.append(writer, [{:final, [{0, 0}]}], token)
    assert_receive {:proto_saved, ^token, :ok}, 10_000
    assert Process.alive?(writer)
    GenServer.stop(writer)

    {:ok, writer, state, _} = ProtoLog.open(Path.join(base, "gen"))
    assert MapSet.member?(state.final, {0, 0})
    GenServer.stop(writer)
  end

  test "a region loads and saves while descriptors run out", %{base: base, soft: soft} do
    nonce = System.unique_integer([:positive])
    first = {11_000 + rem(nonce, 2_000) * 3, -9_100}
    second = {elem(first, 0) + 1, -9_100}
    TestScope.isolate([first, second], world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for key <- [first, second],
          registry <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(registry, key),
          do: TestScope.kill(pid)
    end)

    # The first region loads every module a region load needs.
    {:ok, _} = World.owner(first)
    {x, z} = {elem(second, 0) * 128 + 5, -9_100 * 128 + 7}

    starve(soft, 400)
    assert {:ok, {pid, _}} = World.owner(second)
    assert :ok = World.set_block({x, 70, z}, 1)
    assert World.get_block({x, 70, z}) == 1
    assert Process.alive?(pid)
  end
end
