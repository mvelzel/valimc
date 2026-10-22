defmodule Valimc.Storage.Checkpoint do
  @moduledoc """
  An owner's checkpoint file (VMC-077f): its records as of its `seq`-th
  frame, `"VMCREG01" <> <<seq::64>> <> term <> sha256`, replaced crash-safely
  (`Valimc.DurableFile`). A region's is `r.X.Z.vmc` in its dimension's folder,
  with its export-only imported data beside it in `r.X.Z.extra`; a player's
  file has the same form (`Valimc.Player.State`, VMC-077i1). The header alone
  tells the log what a checkpoint covers.
  """
  alias Valimc.Dimension

  @magic "VMCREG01"

  def path(base, {:region, dimension, {rx, rz}}),
    do: Path.join(Dimension.storage(base, dimension), "r.#{rx}.#{rz}.vmc")

  def path(_base, _owner), do: nil

  @doc "The export-only side file of a region checkpoint."
  def extra(path), do: Path.rootname(path) <> ".extra"

  def write(path, seq, records) when is_integer(seq) and is_map(records),
    do: Valimc.DurableFile.write(path, encode(seq, records))

  @doc "A checkpoint's bytes (iodata): its records as of its `seq`-th frame."
  def encode(seq, records) when is_integer(seq) and is_map(records) do
    body = [@magic, <<seq::64>>, :erlang.term_to_binary(records)]
    [body, :crypto.hash(:sha256, IO.iodata_to_binary(body))]
  end

  @doc """
  `{:ok, %{seq: seq, records: records}}`, `{:ok, nil}` when there is none, or
  an error. Read raw: a slow file holds no other caller of the file server.
  """
  def read(path) do
    case File.read(path, [:raw]) do
      {:ok, bytes} -> decode(bytes)
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:checkpoint_unreadable, reason}}
    end
  end

  @doc "The `seq` a checkpoint holds frames up to, read from its header."
  def seq(nil), do: {:ok, -1}

  def seq(path) do
    case File.open(path, [:read, :raw, :binary], &IO.binread(&1, 16)) do
      {:ok, <<@magic, seq::64>>} -> {:ok, seq}
      {:error, :enoent} -> {:ok, -1}
      _ -> {:error, :invalid_checkpoint}
    end
  end

  @doc "A checkpoint's `seq` and records from its bytes."
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > 48 do
    size = byte_size(bytes) - 32
    <<body::binary-size(^size), digest::binary-size(32)>> = bytes

    with true <- :crypto.hash(:sha256, body) == digest,
         <<@magic, seq::64, term::binary>> <- body,
         records when is_map(records) <- :erlang.binary_to_term(term, [:safe]) do
      {:ok, %{seq: seq, records: records}}
    else
      _ -> {:error, :invalid_checkpoint}
    end
  rescue
    ArgumentError -> {:error, :invalid_checkpoint}
  end

  def decode(_), do: {:error, :invalid_checkpoint}
end
