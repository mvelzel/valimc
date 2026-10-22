defmodule Valimc.World.RegionLogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Valimc.Storage.RegionLog

  @moduletag :tmp_dir

  defp ops(log_frames), do: Enum.flat_map(log_frames, & &1.ops)

  property "frames round-trip and any truncation of the tail is a clean prefix" do
    check all(
            batches <-
              list_of(list_of(tuple({atom(:alphanumeric), integer()}), max_length: 4),
                min_length: 1,
                max_length: 6
              ),
            cut <- integer(0..64)
          ) do
      bytes =
        batches
        |> Enum.with_index(1)
        |> Enum.map(fn {ops, lsn} -> RegionLog.encode_frame(lsn, 7, ops) end)
        |> IO.iodata_to_binary()

      assert {:ok, frames, size, :clean} = RegionLog.decode_frames(bytes)
      assert size == byte_size(bytes) and Enum.map(frames, & &1.ops) == batches

      truncated = binary_part(bytes, 0, max(byte_size(bytes) - cut, 0))
      assert {:ok, prefix, valid, _} = RegionLog.decode_frames(truncated)
      assert Enum.map(prefix, & &1.ops) == Enum.take(batches, length(prefix))
      assert valid <= byte_size(truncated)
    end
  end

  test "damage before the last frame is corruption, damage in the last frame is a torn tail" do
    a = RegionLog.encode_frame(1, 1, [{:a, 1}])
    b = RegionLog.encode_frame(2, 1, [{:b, 2}])

    flip = fn bin, at ->
      binary_part(bin, 0, at) <>
        <<Bitwise.bxor(:binary.at(bin, at), 1)>> <>
        binary_part(bin, at + 1, byte_size(bin) - at - 1)
    end

    assert {:error, {:corrupt, 0}} = RegionLog.decode_frames(flip.(a <> b, 20))

    assert {:ok, [%{lsn: 1}], size, :torn} =
             RegionLog.decode_frames(flip.(a <> b, byte_size(a) + 20))

    assert size == byte_size(a)
    # LSNs must increase.
    assert {:error, {:corrupt, _}} = RegionLog.decode_frames(b <> a <> b)
  end

  test "open, append, reopen and recover with incarnations", %{tmp_dir: dir} do
    {:ok, log, %{checkpoint: nil, frames: [%{ops: [{:open, 1}]}]}} = RegionLog.open(dir)
    {:ok, log, [{2, _}, {3, _}]} = RegionLog.append(log, [[{:cells, 1}], [{:item_put, 2}]])
    :ok = RegionLog.close(log)

    {:ok, log, recovered} = RegionLog.open(dir)
    assert ops(recovered.frames) == [{:open, 1}, {:cells, 1}, {:item_put, 2}, {:open, 2}]
    assert log.incarnation == 2
    :ok = RegionLog.close(log)
  end

  test "a torn final append is truncated and later appends follow it", %{tmp_dir: dir} do
    {:ok, log, _} = RegionLog.open(dir)
    {:ok, log, _} = RegionLog.append(log, [[{:kept, 1}]])
    :ok = RegionLog.close(log)
    [segment] = Path.wildcard(Path.join(dir, "log.*"))

    File.write!(segment, binary_part(RegionLog.encode_frame(99, 1, [{:lost, 1}]), 0, 10), [
      :append
    ])

    {:ok, log, recovered} = RegionLog.open(dir)
    assert {:kept, 1} in ops(recovered.frames) and {:lost, 1} not in ops(recovered.frames)
    {:ok, log, _} = RegionLog.append(log, [[{:after, 1}]])
    :ok = RegionLog.close(log)
    {:ok, log, recovered} = RegionLog.open(dir)
    assert Enum.take(ops(recovered.frames), -2) == [{:after, 1}, {:open, 3}]
    :ok = RegionLog.close(log)
  end

  test "checkpoints replace covered segments and recovery replays only later frames",
       %{tmp_dir: dir} do
    {:ok, log, _} = RegionLog.open(dir)
    {:ok, log, _} = RegionLog.append(log, [[{:a, 1}], [{:b, 2}]])
    {:ok, log} = RegionLog.checkpoint(log, %{state: :folded})
    {:ok, log, _} = RegionLog.append(log, [[{:c, 3}]])
    :ok = RegionLog.close(log)

    assert [_] = Path.wildcard(Path.join(dir, "ckpt.*"))
    {:ok, log, recovered} = RegionLog.open(dir)
    assert recovered.checkpoint == %{state: :folded}
    assert ops(recovered.frames) == [{:c, 3}, {:open, 2}]
    :ok = RegionLog.close(log)

    # A damaged newest checkpoint refuses the load instead of losing frames.
    [ckpt] = Path.wildcard(Path.join(dir, "ckpt.*"))
    File.write!(ckpt, "garbage")
    assert {:error, :invalid_checkpoint} = RegionLog.open(dir)
  end

  test "a drive flush (F_FULLFSYNC) follows each append when enabled", %{tmp_dir: dir} do
    {:ok, log, _} = RegionLog.open(dir)
    {:ok, log, [_, {lsn, _}]} = RegionLog.append(%{log | full_sync: true}, [[{:a, 1}], [{:b, 2}]])
    assert {:ok, %{frames: frames}} = RegionLog.read(dir)
    assert List.last(frames).lsn == lsn and ops(frames) |> Enum.take(-2) == [{:a, 1}, {:b, 2}]
    assert {:error, _} = Valimc.Native.full_sync(Path.join(dir, "missing"))
    RegionLog.close(log)
  end

  test "segments rotate past their size limit", %{tmp_dir: dir} do
    {:ok, log, _} = RegionLog.open(dir)
    big = :binary.copy(<<7>>, 1_100_000)
    {:ok, log, _} = RegionLog.append(log, for(n <- 1..5, do: [{:blob, n, big}]))
    {:ok, log, _} = RegionLog.append(log, [[{:after, 1}]])
    :ok = RegionLog.close(log)
    assert length(Path.wildcard(Path.join(dir, "log.*"))) == 2
    {:ok, log, recovered} = RegionLog.open(dir)
    assert length(recovered.frames) == 8
    :ok = RegionLog.close(log)
  end
end
