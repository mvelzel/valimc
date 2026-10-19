defmodule Valimc.World.RegionLog do
  @moduledoc """
  Append-only durability log for one region (VMC-063): checkpoints plus log
  segments of CRC-checked frames. Pure functions over files; the region writer
  process owns one `%RegionLog{}`.

  Layout of a region directory:

  - `ckpt.<lsn>`: `"VMCCKPT1" <> <<lsn::64, incarnation::32>> <> term <> sha256`,
    the full state through `lsn`
  - `log.<base_lsn>`: frames `<<len::32, crc32::32, lsn::64, incarnation::32, ops>>`,
    where `ops` is a `term_to_binary` list of absolute-value operations

  A frame is the unit of atomicity: replay applies whole frames in LSN order.
  Recovery uses the newest checkpoint that verifies, then later frames. Only the
  tail of the last segment may be torn (it is truncated); any other damage
  refuses the load. Each open appends an `{:open, incarnation}` frame, so a
  stale writer's frames can be told apart.
  """

  @ckpt_magic "VMCCKPT1"
  @max_frame 64 * 1024 * 1024
  @segment_limit 4 * 1024 * 1024

  defstruct [:dir, :fd, :segment, :segment_bytes, :next_lsn, :incarnation, :checkpoint_lsn]

  @type op :: tuple()
  @type frame :: %{lsn: non_neg_integer(), incarnation: non_neg_integer(), ops: [op]}

  ## Frames

  @doc "Encode one frame of `ops` at `lsn`."
  def encode_frame(lsn, incarnation, ops) when is_list(ops) do
    payload = <<lsn::64, incarnation::32, :erlang.term_to_binary(ops)::binary>>
    <<byte_size(payload)::32, :erlang.crc32(payload)::32, payload::binary>>
  end

  @doc """
  Decode a segment. Returns `{:ok, frames, valid_bytes, :clean | :torn}`, or
  `{:error, {:corrupt, offset}}` when damage is followed by more data.
  """
  def decode_frames(bytes, previous_lsn \\ -1), do: decode(bytes, 0, previous_lsn, [])

  defp decode(bytes, offset, _last, acc) when byte_size(bytes) == offset,
    do: {:ok, Enum.reverse(acc), offset, :clean}

  defp decode(bytes, offset, last, acc) do
    rest = byte_size(bytes) - offset

    case bytes do
      <<_::binary-size(^offset), len::32, crc::32, _::binary>>
      when len >= 12 and len <= @max_frame and rest >= 8 + len ->
        <<_::binary-size(^offset), _::64, payload::binary-size(^len), _::binary>> = bytes
        last_frame? = rest == 8 + len

        with true <- :erlang.crc32(payload) == crc,
             <<lsn::64, incarnation::32, body::binary>> = payload,
             true <- lsn > last,
             {:ok, ops} when is_list(ops) <- safe_term(body) do
          frame = %{lsn: lsn, incarnation: incarnation, ops: ops}
          decode(bytes, offset + 8 + len, lsn, [frame | acc])
        else
          _ when last_frame? -> {:ok, Enum.reverse(acc), offset, :torn}
          _ -> {:error, {:corrupt, offset}}
        end

      <<_::binary-size(^offset), len::32, _::binary>> when len < 12 or len > @max_frame ->
        if rest <= 8,
          do: {:ok, Enum.reverse(acc), offset, :torn},
          else: {:error, {:corrupt, offset}}

      _ ->
        # Fewer bytes than the header announces: an incomplete final append.
        {:ok, Enum.reverse(acc), offset, :torn}
    end
  end

  defp safe_term(body) do
    {:ok, :erlang.binary_to_term(body, [:safe])}
  rescue
    ArgumentError -> :error
  end

  ## Checkpoints

  def encode_checkpoint(lsn, incarnation, state) do
    body = <<@ckpt_magic, lsn::64, incarnation::32, :erlang.term_to_binary(state)::binary>>
    [body, :crypto.hash(:sha256, body)]
  end

  def decode_checkpoint(bytes) when byte_size(bytes) > 32 + 20 do
    size = byte_size(bytes) - 32
    <<body::binary-size(^size), digest::binary-size(32)>> = bytes

    with true <- :crypto.hash(:sha256, body) == digest,
         <<@ckpt_magic, lsn::64, incarnation::32, term::binary>> <- body,
         {:ok, state} <- safe_term(term) do
      {:ok, %{lsn: lsn, incarnation: incarnation, state: state}}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  def decode_checkpoint(_), do: {:error, :invalid_checkpoint}

  ## Directory lifecycle

  @doc """
  Recover `dir` and open it for appending. Returns
  `{:ok, log, %{checkpoint: state | nil, frames: [frame]}}` with every frame
  after the checkpoint, ending with this incarnation's `{:open, n}` frame.
  """
  def open(dir) do
    with :ok <- File.mkdir_p(dir),
         {:ok, checkpoint} <- newest_checkpoint(dir),
         {:ok, frames, tail} <- read_segments(dir, checkpoint && checkpoint.lsn) do
      base = if checkpoint, do: checkpoint.lsn, else: 0
      last_lsn = Enum.reduce(frames, base, &max(&1.lsn, &2))

      incarnation =
        Enum.reduce(frames, (checkpoint && checkpoint.incarnation) || 0, &max(&1.incarnation, &2)) +
          1

      log = %__MODULE__{
        dir: dir,
        next_lsn: last_lsn + 1,
        incarnation: incarnation,
        checkpoint_lsn: base
      }

      with {:ok, log} <- open_segment(log, tail),
           {:ok, log, _} <- append(log, [[{:open, incarnation}]]) do
        open_frame = %{
          lsn: log.next_lsn - 1,
          incarnation: incarnation,
          ops: [{:open, incarnation}]
        }

        {:ok, log, %{checkpoint: checkpoint && checkpoint.state, frames: frames ++ [open_frame]}}
      end
    end
  end

  @doc "Append one frame per ops list, then `datasync` once. Returns the last LSN."
  def append(%__MODULE__{} = log, batches) when is_list(batches) and batches != [] do
    {frames, next} =
      Enum.map_reduce(batches, log.next_lsn, fn ops, lsn ->
        {encode_frame(lsn, log.incarnation, ops), lsn + 1}
      end)

    with :ok <- :file.write(log.fd, frames),
         :ok <- :file.datasync(log.fd) do
      log = %{log | next_lsn: next, segment_bytes: log.segment_bytes + IO.iodata_length(frames)}
      log = if log.segment_bytes >= @segment_limit, do: rotate(log), else: {:ok, log}

      case log do
        {:ok, log} -> {:ok, log, next - 1}
        error -> error
      end
    end
  end

  @doc """
  Durably replace everything up to the last appended LSN by `state`, then drop
  covered segments and older checkpoints.
  """
  def checkpoint(%__MODULE__{} = log, state) do
    lsn = log.next_lsn - 1
    path = Path.join(log.dir, name("ckpt", lsn))
    tmp = path <> ".tmp"

    with {:ok, log} <- rotate(log),
         :ok <- File.write(tmp, encode_checkpoint(lsn, log.incarnation, state), [:binary, :sync]),
         :ok <- File.rename(tmp, path),
         :ok <- fsync_dir(log.dir) do
      for file <- list(log.dir, "ckpt."),
          file != Path.basename(path),
          do: File.rm(Path.join(log.dir, file))

      for {base, file} <- segments(log.dir),
          base <= lsn,
          file != Path.basename(log.segment),
          do: File.rm(Path.join(log.dir, file))

      :ok = fsync_dir(log.dir)
      {:ok, %{log | checkpoint_lsn: lsn}}
    end
  end

  def close(%__MODULE__{fd: fd}) when fd != nil, do: File.close(fd)
  def close(_), do: :ok

  @doc "Bytes appended since the last checkpoint, for compaction policy."
  def segment_bytes(%__MODULE__{} = log),
    do:
      Enum.sum(for {_, file} <- segments(log.dir), do: File.stat!(Path.join(log.dir, file)).size)

  ## Internals

  # Older checkpoints and covered segments are deleted only after a newer
  # checkpoint is durable, so a damaged newest checkpoint is corruption: refuse.
  defp newest_checkpoint(dir) do
    list(dir, "ckpt.")
    |> Enum.reject(&String.ends_with?(&1, ".tmp"))
    |> Enum.sort(:desc)
    |> case do
      [] -> {:ok, nil}
      [file | _] -> decode_checkpoint(File.read!(Path.join(dir, file)))
    end
  end

  defp read_segments(dir, checkpoint_lsn) do
    files = segments(dir)
    last_index = length(files) - 1

    files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], nil, -1}, fn {{_base, file}, index}, {:ok, acc, _, last} ->
      path = Path.join(dir, file)

      case decode_frames(File.read!(path), last) do
        {:ok, frames, _, :clean} ->
          {:cont, {:ok, acc ++ frames, {path, nil}, last_lsn(frames, last)}}

        {:ok, frames, valid, :torn} when index == last_index ->
          {:cont, {:ok, acc ++ frames, {path, valid}, last_lsn(frames, last)}}

        {:ok, _, offset, :torn} ->
          {:halt, {:error, {:corrupt_segment, file, offset}}}

        {:error, {:corrupt, offset}} ->
          {:halt, {:error, {:corrupt_segment, file, offset}}}
      end
    end)
    |> case do
      {:ok, frames, tail, _} ->
        floor = checkpoint_lsn || -1
        {:ok, Enum.filter(frames, &(&1.lsn > floor)), tail}

      error ->
        error
    end
  end

  defp last_lsn([], last), do: last
  defp last_lsn(frames, _), do: List.last(frames).lsn

  # Continue the last segment (truncating a torn tail) or start a new one.
  defp open_segment(log, {path, valid}) do
    with :ok <- if(valid, do: truncate(path, valid), else: :ok),
         size when size < @segment_limit <- File.stat!(path).size,
         {:ok, fd} <- File.open(path, [:append, :binary, :raw]) do
      {:ok, %{log | fd: fd, segment: path, segment_bytes: size}}
    else
      size when is_integer(size) -> new_segment(log)
      error -> error
    end
  end

  defp open_segment(log, nil), do: new_segment(log)

  defp new_segment(log) do
    path = Path.join(log.dir, name("log", log.next_lsn))

    with {:ok, fd} <- File.open(path, [:append, :binary, :raw]),
         :ok <- fsync_dir(log.dir) do
      {:ok, %{log | fd: fd, segment: path, segment_bytes: 0}}
    end
  end

  defp rotate(%{segment_bytes: 0} = log), do: {:ok, log}

  defp rotate(log) do
    :ok = File.close(log.fd)
    new_segment(%{log | fd: nil})
  end

  defp truncate(path, size) do
    with {:ok, fd} <- File.open(path, [:read, :write, :binary, :raw]),
         {:ok, _} <- :file.position(fd, size),
         :ok <- :file.truncate(fd),
         :ok <- :file.datasync(fd),
         do: File.close(fd)
  end

  defp segments(dir) do
    Enum.sort(
      for file <- list(dir, "log."),
          {base, ""} <- [Integer.parse(String.replace_prefix(file, "log.", ""))],
          do: {base, file}
    )
  end

  defp list(dir, prefix) do
    case File.ls(dir) do
      {:ok, files} -> Enum.filter(files, &String.starts_with?(&1, prefix))
      _ -> []
    end
  end

  defp name(kind, lsn), do: "#{kind}.#{String.pad_leading(Integer.to_string(lsn), 20, "0")}"

  defp fsync_dir(dir) do
    case Valimc.Native.fsync_dir(dir) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, {:fsync_dir, reason}}
    end
  end
end
