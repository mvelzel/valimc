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
  def region_new(_cx, _cz, _size, _layers, _budget), do: :erlang.nif_error(:nif_not_loaded)
  def get_blocks(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def set_blocks(_region, _changes), do: :erlang.nif_error(:nif_not_loaded)
  def encode_chunk(_region, _cx, _cz, _biome, _bits), do: :erlang.nif_error(:nif_not_loaded)
  def chunk_find(_region, _cx, _cz, _states), do: :erlang.nif_error(:nif_not_loaded)
  def diff(_region), do: :erlang.nif_error(:nif_not_loaded)
  def compact(_region), do: :erlang.nif_error(:nif_not_loaded)
  def touched_chunks(_region), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_chunk(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def heap_bytes(_region), do: :erlang.nif_error(:nif_not_loaded)
end
