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

  # Holds the whole budget of 2 at once and reports what it counts meanwhile.
  # A dead holder still counted would keep it full: the budget's wait would end
  # in `{:error, {:unwritten, :file_budget}}`.
  defp fill_budget, do: FileBudget.with_files(2, fn -> FileBudget.in_use() end)

  # Holders together never exceed the cap, whatever other tests' owners hold or
  # give back meanwhile, so this test's own holders never do either.
  @tag timeout: 300_000
  test "the budget bounds what is open at once" do
    FileBudget.set_cap(2)
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
    assert :atomics.get(inside, 2) in 1..2
  end

  @tag timeout: 300_000
  test "a holder killed mid-operation gives its descriptors back" do
    FileBudget.set_cap(2)
    parent = self()

    holder =
      spawn(fn ->
        FileBudget.with_files(2, fn ->
          send(parent, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding
    assert FileBudget.in_use() == 2
    Process.exit(holder, :kill)
    assert fill_budget() == 2
  end

  @tag timeout: 300_000
  test "holders killed at any point of taking, holding or giving back leak nothing" do
    FileBudget.set_cap(2)

    holders =
      for _ <- 1..32 do
        spawn(fn ->
          Stream.repeatedly(fn -> FileBudget.with_files(fn -> :ok end) end) |> Stream.run()
        end)
      end

    Process.sleep(50)
    Enum.each(holders, &Process.exit(&1, :kill))
    assert fill_budget() == 2
  end

  # Holding a descriptor per log would add 200; the margin is for whatever the
  # rest of the VM (other tests' owners, the logger) opens meanwhile.
  @tag timeout: 300_000
  test "logs hold no descriptor: hundreds open and append under a budget of 4", %{base: base} do
    FileBudget.set_cap(4)
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
