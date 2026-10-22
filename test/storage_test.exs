defmodule Valimc.StorageTest do
  @moduledoc """
  The world's striped write-ahead log and region checkpoints (VMC-077f):
  owners reply without waiting for the sync (D2), transfer proofs wait for
  their frame, checkpoints fold cells so a load replays nothing, frames stay
  below the cap, and worlds from before the log are refused (D4).
  """
  use ExUnit.Case, async: true
  # Refused loads and killed stripes log from other processes.
  @moduletag capture_log: true
  import ExUnit.CaptureLog
  alias Valimc.Storage.{Checkpoint, Log}
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.{BlockEntities, Containers, Entities, Region, RegionLog, RegionStorage}
  alias Valimc.World.ScheduledTicks

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-storage-#{nonce}")
    key = {20_000 + rem(nonce, 3_333) * 3, 900}
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {rx, rz} = key
    %{base: base, key: key, position: {rx * 128 + 3, 70, rz * 128 + 5}}
  end

  defp owner(ctx) do
    {:ok, owner} = World.owner(ctx.key)
    owner
  end

  defp resource({pid, _}), do: :sys.get_state(pid).resource

  test "a block edit answers while its frame waits for the disk; a receipt waits for it", ctx do
    owner = owner(ctx)
    stripe = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(stripe)

    try do
      assert :ok = Valimc.TestBlocks.set(ctx.position, 1)
      assert Valimc.TestBlocks.get(ctx.position) == 1
      Valimc.TestWait.until(fn -> Valimc.TestRegion.in_flight?(resource(owner)) end)

      receipt = Task.async(fn -> Region.item_transfer_receipt(owner, <<1::128>>) end)
      assert Task.yield(receipt, 100) == nil
      :sys.resume(stripe)
      assert {:error, :missing_transfer_receipt} = Task.await(receipt)
    after
      :sys.resume(stripe)
    end
  end

  test "a flushed region is one checkpoint: cells folded, no frames to replay", ctx do
    owner = owner(ctx)
    for dy <- 0..9, do: :ok = Valimc.TestBlocks.set(put_elem(ctx.position, 1, 70 + dy), 1)
    assert :ok = Region.flush(elem(owner, 0))

    path = Checkpoint.path(ctx.base, {:region, :overworld, ctx.key})
    {:ok, %{seq: seq, records: records}} = Checkpoint.read(path)
    refute Enum.any?(Map.keys(records), &match?({:cell, _}, &1))
    assert Log.frames(ctx.base, {:region, :overworld, ctx.key}, seq) == []

    TestScope.kill(elem(owner, 0))
    {:ok, reloaded} = World.owner(ctx.key)
    assert reloaded != owner
    assert Valimc.TestBlocks.get(put_elem(ctx.position, 1, 79)) == 1
  end

  test "a killed owner reloads every frame that reached the log", ctx do
    owner = owner(ctx)
    assert :ok = Valimc.TestBlocks.set(ctx.position, 1)
    assert :ok = Log.sync(ctx.base, {:region, :overworld, ctx.key})
    Valimc.TestWait.until(fn -> resource(owner).storage.seq > 0 end)
    assert :ok = Log.sync(ctx.base, {:region, :overworld, ctx.key})
    TestScope.kill(elem(owner, 0))

    {:ok, _} = World.owner(ctx.key)
    assert Valimc.TestBlocks.get(ctx.position) == 1
  end

  test "an owner whose stripe goes down with frames in flight reloads", ctx do
    {pid, _} = owner = owner(ctx)
    stripe = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(stripe)
    assert :ok = Valimc.TestBlocks.set(ctx.position, 1)
    Valimc.TestWait.until(fn -> Valimc.TestRegion.in_flight?(resource(owner)) end)
    ref = Process.monitor(pid)

    capture_log(fn ->
      Process.exit(stripe, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:storage_failed, {:log_down, :killed}}}
    end)

    {:ok, _} = World.owner(ctx.key)
  end

  test "an append whose segment will not open waits and lands once", ctx do
    owner = {:region, :overworld, ctx.key}
    stripe = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    %{log: %{segment: segment}} = :sys.get_state(stripe)

    :sys.replace_state(stripe, fn %{log: log} = state ->
      %{state | log: %{log | segment: Path.join([log.dir, "missing", "log"])}}
    end)

    Log.commit(ctx.base, owner, 1, :erlang.term_to_binary([{:put, :game_tick, 7}]), self())
    Valimc.TestWait.until(fn -> :sys.get_state(stripe).held != nil end)
    refute_received {:storage_durable, 1}

    :sys.replace_state(stripe, fn %{log: log} = state ->
      %{state | log: %{log | segment: segment}}
    end)

    assert_receive {:storage_durable, 1}, 5_000
    assert [{1, _}] = Log.frames(ctx.base, owner, 0)
  end

  test "player files from many writers share one append and survive a lost file", ctx do
    paths = for i <- 1..20, do: Path.join([ctx.base, "players", "#{i}.dat"])
    stripes = Enum.group_by(paths, &Log.stripe({:file, Path.relative_to(&1, ctx.base)}))
    {n, same} = Enum.max_by(stripes, fn {_, group} -> length(group) end)
    assert :ok = Log.commit_file(ctx.base, hd(same), "warm")
    [{stripe, _}] = Registry.lookup(Valimc.StorageRegistry, {ctx.base, n})
    {:ok, %{frames: before}} = RegionLog.read(Log.dir(ctx.base, n))
    :sys.suspend(stripe)

    tasks =
      try do
        tasks = for path <- same, do: Task.async(fn -> Log.commit_file(ctx.base, path, path) end)
        count = length(same)

        Valimc.TestWait.until(fn ->
          Process.info(stripe, :message_queue_len) == {:message_queue_len, count}
        end)

        tasks
      after
        :sys.resume(stripe)
      end

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
    {:ok, %{frames: frames}} = RegionLog.read(Log.dir(ctx.base, n))
    assert length(frames) == length(before) + 1
    for path <- same, do: assert(File.read!(path) == path)

    # A crash after the record's sync but before the file reached the disk.
    File.rm!(hd(same))
    TestScope.kill(stripe)
    assert :ok = Log.commit_file(ctx.base, List.last(same), "next")
    assert File.read!(hd(same)) == hd(same)
  end

  test "a commit too large for one frame is split below the cap", ctx do
    owner = {:region, :overworld, ctx.key}
    storage = %RegionStorage{base: ctx.base, owner: owner}
    columns = for x <- 0..9, into: %{}, do: {{x, 0}, :crypto.strong_rand_bytes(1024 * 1024)}

    parts = %{
      items: Entities.new(),
      receipts: %{},
      containers: %Containers{},
      ticks: ScheduledTicks.new(),
      block_entities: %BlockEntities{},
      game_tick: 0
    }

    {storage, []} = RegionStorage.commit(RegionStorage.columns(storage, columns), parts)
    assert storage.seq > 1
    assert_receive {:storage_durable, seq} when seq == storage.seq, 10_000
    frames = Log.frames(ctx.base, owner, 0)
    assert length(frames) == storage.seq
    assert Enum.all?(frames, fn {_, frame} -> byte_size(frame) < RegionLog.max_frame() end)

    assert_raise ArgumentError, fn ->
      RegionLog.encode_frame(1, 1, [:binary.copy("x", 65 * 1024 * 1024)])
    end
  end

  test "worlds stored before the shared log are refused, not migrated", ctx do
    {rx, rz} = ctx.key
    File.mkdir_p!(Path.join(ctx.base, "r.#{rx}.#{rz}"))

    capture_log(fn ->
      assert {:error, _} = World.owner(ctx.key)
    end)

    assert {:error, {:old_region_format, _}} = RegionStorage.keys(ctx.base, :overworld)

    old = Path.join(System.tmp_dir!(), "valimc-old-players-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([old, "players", "wal.0"]))
    on_exit(fn -> File.rm_rf(old) end)

    capture_log(fn ->
      assert {:error, {:storage_log, _}} =
               Log.commit_file(old, Path.join([old, "players", "a"]), "x")
    end)
  end
end
