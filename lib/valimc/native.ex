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

  def light_facts_init(_properties, _faces, _sizes, _occludes, _sky, _sky_size, _sky_pairs),
    do: :erlang.nif_error(:nif_not_loaded)

  def light_columns(_images, _min_cx, _min_cz, _chunks_x, _chunks_z),
    do: :erlang.nif_error(:nif_not_loaded)

  def light_compute(_region), do: :erlang.nif_error(:nif_not_loaded)
  def light_update(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def light_update_dirty(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def light_image(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def halo_put(_region, _chunks), do: :erlang.nif_error(:nif_not_loaded)
  def halo_edits(_region, _edits), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_random_trace(_kind, _seed, _ops), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_noise_samples(_random, _noise, _params, _points, _volumes),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_registry(_facts), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_new(_registry, _seed, _settings), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_density_samples(_state, _function, _cached, _ops),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_chunk_biomes(_state, _preset, _chunks), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_closest_biomes(_state, _preset, _target), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_fill_terrain(_state, _chunks), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_build_terrain(_state, _biome_source, _carve, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_spawn_origin(_state), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_columns(_state, _biome_source, _protocol_biomes, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_decorate(_state, _biome_source, _centre, _order, _features),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_shape_cases(_registry, _cases), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_decoration_time(_state, _biome_source, _origin, _size, _order, _features),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_state(_state, _biome_source), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_starts(_state, _biome_source, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_window(_state, _biome_source, _origin, _size),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_proto_terrain(_state, _biome_source, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_proto_decorate(_state, _chunks, _order), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_proto_inspect(_state, _chunks), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_proto_full(_state, _chunks, _protocol_biomes),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_time(_state, _biome_source, _origin, _size),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_locate(_state, _biome_source, _structures, _pos, _radius),
    do: :erlang.nif_error(:nif_not_loaded)

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
