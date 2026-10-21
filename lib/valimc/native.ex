defmodule Valimc.Native do
  @moduledoc """
  Rust NIFs from `native/valimc_nif`, compiled by Rustler (release profile; dev and
  test builds skip LTO, see `config/config.exs`). The stubs follow the crate's
  modules: region, light, codec, sys, worldgen, loot, and the parity NIFs that only
  dev, test and bench builds have (the `parity` cargo feature).

  Results: `{:ok, value}`, or `:ok` without one; an expected failure is
  `{:error, atom}`; a broken invariant raises. A region resource is changed only by
  the process that created it (`{:error, :not_owner}` otherwise). Positions travel
  as packed big-endian binaries (`native/valimc_nif/src/region.rs`).

  Scheduling: normal-scheduler NIFs stay under about 1 ms for any input; worldgen
  NIFs are dirty and live callers make them from `Valimc.Worldgen.Pool`; a NIF with
  a dirty twin is called through `dispatch/3`.
  """
  use Rustler,
    otp_app: :valimc,
    crate: "valimc_nif",
    path: "native/valimc_nif",
    mode: :release

  # A normal scheduler runs one NIF call for at most about this long.
  @budget_ns 1_000_000

  # NIFs with a dirty twin: worst-case nanoseconds per unit (VMC-077b) and the
  # twin. Disk NBT per input byte (terms included); LZ4 per output byte; block
  # changes per change; random ticks per draw; block updates (VMC-077m) per
  # change or due tick, whose cascades are bounded by vanilla's chain limit,
  # not by their input. A light update's cost is not
  # bounded by its positions: past 64 it runs dirty, and on a normal scheduler
  # Rust stops it at a budget of work and undoes it (`{:error, :too_large}`)
  # for the caller to run dirty (VMC-077c).
  @twins %{
    nbt_read: {8, :nbt_read_dirty},
    lz4_decode_stream: {0.5, :lz4_decode_stream_dirty},
    set_blocks: {40, :set_blocks_dirty},
    block_updates: {2_000, :block_updates_dirty},
    random_ticks: {5, :random_ticks_dirty},
    light_update: {15_625, :light_update_dirty}
  }

  @doc """
  Call the NIF `name` with `args` on a normal scheduler when its worst-case cost
  for `units` (its unit in `@twins`) fits the budget of about 1 ms, else its
  dirty twin.
  """
  def dispatch(name, units, args) do
    {ns, dirty} = Map.fetch!(@twins, name)
    apply(__MODULE__, if(units * ns > @budget_ns, do: dirty, else: name), args)
  end

  ## Region

  def region_new(_cx, _cz, _size, _layers, _budget), do: :erlang.nif_error(:nif_not_loaded)
  def get_blocks(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def read_box(_region, _min, _max), do: :erlang.nif_error(:nif_not_loaded)
  def set_blocks(_region, _changes), do: :erlang.nif_error(:nif_not_loaded)
  def set_blocks_dirty(_region, _changes), do: :erlang.nif_error(:nif_not_loaded)

  def encode_chunk(_region, _cx, _cz, _biome, _bits, _biome_bits, _window),
    do: :erlang.nif_error(:nif_not_loaded)

  def chunk_find(_region, _cx, _cz, _states), do: :erlang.nif_error(:nif_not_loaded)
  def touched_chunks(_region), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_chunk(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def set_random_ticking(_region, _bitmap), do: :erlang.nif_error(:nif_not_loaded)
  def random_ticks(_region, _per_section), do: :erlang.nif_error(:nif_not_loaded)
  def random_ticks_dirty(_region, _per_section), do: :erlang.nif_error(:nif_not_loaded)
  def dump_column(_region, _cx, _cz, _default_biome), do: :erlang.nif_error(:nif_not_loaded)
  def column_facts(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def biome_zoom(_zoom_seed, _x, _y, _z), do: :erlang.nif_error(:nif_not_loaded)

  def biome_temperature(_temperature, _frozen, _x, _y, _z, _sea_level),
    do: :erlang.nif_error(:nif_not_loaded)

  def region_biome(_region, _zoom_seed, _position, _default_biome),
    do: :erlang.nif_error(:nif_not_loaded)

  def fill_biomes(_region, _chunks, _min, _max, _biome, _filter, _default),
    do: :erlang.nif_error(:nif_not_loaded)

  def encode_biomes(_region, _cx, _cz, _default, _bits, _window),
    do: :erlang.nif_error(:nif_not_loaded)

  def column_image(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def put_column_image(_region, _cx, _cz, _image), do: :erlang.nif_error(:nif_not_loaded)

  ## Light

  def block_facts_init(_columns), do: :erlang.nif_error(:nif_not_loaded)

  ## Block rules (VMC-077m)

  def rules_new(_facts), do: :erlang.nif_error(:nif_not_loaded)

  def block_updates(_region, _rules, _changes, _ticks, _absent, _seed),
    do: :erlang.nif_error(:nif_not_loaded)

  def block_updates_dirty(_region, _rules, _changes, _ticks, _absent, _seed),
    do: :erlang.nif_error(:nif_not_loaded)

  def rules_support_cases(_rules, _updates, _states), do: :erlang.nif_error(:nif_not_loaded)

  def light_sky(_region, _sky), do: :erlang.nif_error(:nif_not_loaded)
  def light_init(_region, _absent), do: :erlang.nif_error(:nif_not_loaded)
  def light_update(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def light_update_dirty(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def light_image(_region, _cx, _cz, _sections), do: :erlang.nif_error(:nif_not_loaded)
  def light_column_image(_image, _sky), do: :erlang.nif_error(:nif_not_loaded)
  def halo_put(_region, _chunks), do: :erlang.nif_error(:nif_not_loaded)
  def halo_set(_region, _edits), do: :erlang.nif_error(:nif_not_loaded)
  def put_columns_lit(_region, _images), do: :erlang.nif_error(:nif_not_loaded)

  ## Codec

  def nbt_read(_bytes, _byte_limit, _nodes, _depth), do: :erlang.nif_error(:nif_not_loaded)
  def nbt_read_dirty(_bytes, _byte_limit, _nodes, _depth), do: :erlang.nif_error(:nif_not_loaded)
  def lz4_decode_stream(_bytes, _max), do: :erlang.nif_error(:nif_not_loaded)
  def lz4_decode_stream_dirty(_bytes, _max), do: :erlang.nif_error(:nif_not_loaded)
  def column_image_of(_sections), do: :erlang.nif_error(:nif_not_loaded)
  def column_layers_image(_layers, _biome), do: :erlang.nif_error(:nif_not_loaded)
  def pack_paletted(_values, _min_bits), do: :erlang.nif_error(:nif_not_loaded)

  ## Sys

  def fsync_dir(_path), do: :erlang.nif_error(:nif_not_loaded)
  def full_sync(_path), do: :erlang.nif_error(:nif_not_loaded)
  def set_open_files_limit(_target), do: :erlang.nif_error(:nif_not_loaded)

  ## Worldgen

  def worldgen_registry(_facts), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_new(_registry, _seed, _settings), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_memory(_state), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_spawn_origin(_state), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_columns(_state, _biome_source, _protocol_biomes, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_proto_terrain(_state, _biome_source, _chunks, _structures),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_proto_decorate(_state, _biome_source, _chunks, _order, _structures),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_proto_full(_state, _chunks, _protocol_biomes),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_locate(_state, _biome_source, _structures, _pos, _radius),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_place_plan(_state, _biome_source, _spec, _pos),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_place(_state, _biome_source, _spec, _pos, _chunks, _base, _seed),
    do: :erlang.nif_error(:nif_not_loaded)

  ## Loot (VMC-072a)

  def loot_registry(_tables, _registries), do: :erlang.nif_error(:nif_not_loaded)

  def loot_fill(_registry, _table, _seed, _luck, _origin, _size, _biome, _structure, _next_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def loot_items(_registry, _table, _seed, _luck, _origin, _biome, _structure, _next_map),
    do: :erlang.nif_error(:nif_not_loaded)

  ## Parity and benchmarks (dev, test and bench builds)

  def put_column(_region, _cx, _cz, _sections), do: :erlang.nif_error(:nif_not_loaded)
  def heap_bytes(_region), do: :erlang.nif_error(:nif_not_loaded)

  def light_columns(_images, _min_cx, _min_cz, _chunks_x, _chunks_z),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_random_trace(_kind, _seed, _ops), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_noise_samples(_random, _noise, _params, _points, _volumes),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_density_samples(_state, _function, _cached, _ops),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_chunk_biomes(_state, _preset, _chunks), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_closest_biomes(_state, _preset, _target), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_fill_terrain(_state, _chunks), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_build_terrain(_state, _biome_source, _carve, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_decorate(_state, _biome_source, _centre, _order, _features),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_decorate_structures(_state, _biome_source, _centre, _order, _structures),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_shape_cases(_registry, _cases), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_decoration_time(_state, _biome_source, _origin, _size, _order, _features),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_state(_state, _biome_source), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_starts(_state, _biome_source, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_window(_state, _biome_source, _origin, _size),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_proto_inspect(_state, _chunks), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_time(_state, _biome_source, _origin, _size),
    do: :erlang.nif_error(:nif_not_loaded)
end
