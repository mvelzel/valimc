defmodule Valimc.Native do
  @moduledoc """
  Rust NIFs from `native/valimc_nif`, compiled by Rustler (release profile).

  Callers use `Valimc.World.Blocks`; these functions are the raw boundary. A
  region resource must only be used by the process that owns it.
  """
  use Rustler,
    otp_app: :valimc,
    crate: "valimc_nif",
    path: "native/valimc_nif",
    mode: :release

  def flags_init(_flags), do: :erlang.nif_error(:nif_not_loaded)
  def nbt_read(_bytes, _byte_limit, _nodes, _depth), do: :erlang.nif_error(:nif_not_loaded)
  def lz4_decode_stream(_bytes, _max), do: :erlang.nif_error(:nif_not_loaded)
  def lz4_decode_stream_dirty(_bytes, _max), do: :erlang.nif_error(:nif_not_loaded)
  def nbt_read_dirty(_bytes, _byte_limit, _nodes, _depth), do: :erlang.nif_error(:nif_not_loaded)
  def region_new(_cx, _cz, _size, _layers, _budget), do: :erlang.nif_error(:nif_not_loaded)
  def get_blocks(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def set_blocks(_region, _changes), do: :erlang.nif_error(:nif_not_loaded)

  def encode_chunk(_region, _cx, _cz, _biome, _bits, _biome_bits),
    do: :erlang.nif_error(:nif_not_loaded)

  def put_column(_region, _cx, _cz, _sections), do: :erlang.nif_error(:nif_not_loaded)
  def dump_column(_region, _cx, _cz, _default_biome), do: :erlang.nif_error(:nif_not_loaded)
  def pack_paletted(_values, _min_bits), do: :erlang.nif_error(:nif_not_loaded)
  def column_image(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def column_image_of(_sections), do: :erlang.nif_error(:nif_not_loaded)
  def put_column_image(_region, _cx, _cz, _image), do: :erlang.nif_error(:nif_not_loaded)
  def chunk_find(_region, _cx, _cz, _states), do: :erlang.nif_error(:nif_not_loaded)
  def diff(_region), do: :erlang.nif_error(:nif_not_loaded)
  def compact(_region), do: :erlang.nif_error(:nif_not_loaded)
  def touched_chunks(_region), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_chunk(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def heap_bytes(_region), do: :erlang.nif_error(:nif_not_loaded)
  def fsync_dir(_path), do: :erlang.nif_error(:nif_not_loaded)
  def full_sync(_path), do: :erlang.nif_error(:nif_not_loaded)
  def set_random_ticking(_region, _bitmap), do: :erlang.nif_error(:nif_not_loaded)
  def random_ticks(_region, _per_section), do: :erlang.nif_error(:nif_not_loaded)
end
