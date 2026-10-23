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
  alias Valimc.World.{BlockEntities, Containers, Region, RegionStorage}
  alias Valimc.Entity.Store
  alias Valimc.Storage.RegionLog
  alias Valimc.World.ScheduledTicks

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-storage-#{nonce}")
    key = {20_000 + rem(nonce, 3_333) * 3, 900}
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {rx, rz} = key
    %{base: base, key: key, position: {rx * 128 + 3, 70, rz * 128 + 5}}
  end

  defp owner(ctx) do
    {:ok, owner} = Valimc.TestWorld.owner(ctx.key)
    owner
  end

  defp resource(owner), do: Valimc.TestRegion.section(owner)

  test "a block edit answers while its frame waits for the disk", ctx do
    owner = owner(ctx)
    stripe = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(stripe)

    try do
      assert :ok = Valimc.TestBlocks.set(ctx.position, 1)
      assert Valimc.TestBlocks.get(ctx.position) == 1
      Valimc.TestWait.until(fn -> Valimc.TestRegion.in_flight?(resource(owner)) end)
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
    {:ok, reloaded} = Valimc.TestWorld.owner(ctx.key)
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

    {:ok, _} = Valimc.TestWorld.owner(ctx.key)
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

    {:ok, _} = Valimc.TestWorld.owner(ctx.key)
  end

  test "an append whose segment will not open waits and lands once", ctx do
    owner = {:region, :overworld, ctx.key}
    stripe = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    %{log: %{segment: segment}} = :sys.get_state(stripe)

    :sys.replace_state(stripe, fn %{log: log} = state ->
      %{state | log: %{log | segment: Path.join([log.dir, "missing", "log"])}}
    end)

    Log.commit_group(
      ctx.base,
      owner,
      [{owner, 1, :erlang.term_to_binary([{:put, :game_tick, 7}])}],
      self()
    )

    Valimc.TestWait.until(fn -> :sys.get_state(stripe).held != nil end)
    refute_received {:storage_durable, _}

    :sys.replace_state(stripe, fn %{log: log} = state ->
      %{state | log: %{log | segment: segment}}
    end)

    assert_receive {:storage_durable, [{^owner, 1}]}, 5_000
    assert [{1, _}] = Log.frames(ctx.base, owner, 0)
  end

  test "a commit too large for one frame is split below the cap", ctx do
    owner = {:region, :overworld, ctx.key}
    storage = %RegionStorage{base: ctx.base, owner: owner}
    columns = for x <- 0..9, into: %{}, do: {{x, 0}, :crypto.strong_rand_bytes(1024 * 1024)}

    parts = %{
      items: Store.new(),
      containers: %Containers{},
      ticks: ScheduledTicks.new(),
      block_entities: %BlockEntities{},
      comparators: %{},
      post: %{},
      structures: %{},
      game_tick: 0
    }

    {storage, []} = RegionStorage.commit(RegionStorage.columns(storage, columns), parts)
    assert storage.seq > 1
    # The group sends the cut frames (VMC-077j).
    {frames, _} = RegionStorage.take(storage)
    Log.commit_group(ctx.base, owner, frames, self())
    assert_receive {:storage_durable, acks}, 10_000
    assert List.last(acks) == {owner, storage.seq}
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
      assert {:error, _} = Valimc.TestWorld.owner(ctx.key)
    end)

    assert {:error, {:old_region_format, _}} = RegionStorage.keys(ctx.base, :overworld)

    old = Path.join(System.tmp_dir!(), "valimc-old-players-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([old, "players", "wal.0"]))
    on_exit(fn -> File.rm_rf(old) end)

    capture_log(fn ->
      assert {:storage_log_unavailable, {:old_player_log, _}} =
               catch_exit(Log.sync(old, {:region, :overworld, ctx.key}))
    end)
  end
end
