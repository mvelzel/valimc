defmodule Valimc.Native do
  @moduledoc """
  Rust NIFs from `native/valimc_nif`, compiled into this Mix build's private assets
  (release profile; dev and test skip LTO, see `config/config.exs`). The stubs
  follow the crate's modules: region, light, codec, sys, worldgen, loot, and the
  parity NIFs that only dev, test and bench builds have (the `parity` cargo feature).

  Results: `{:ok, value}`, or `:ok` without one; an expected failure is
  `{:error, atom}`; a broken invariant raises. A region resource is changed only by
  the process that created it (`{:error, :not_owner}` otherwise). Positions travel
  as packed big-endian binaries (`native/valimc_nif/src/region.rs`).

  Scheduling: normal-scheduler NIFs stay under about 1 ms for any input; worldgen
  NIFs are dirty and live callers make them from `Valimc.Worldgen.Pool`, the
  generation jobs through their low-priority background twins (VMC-081c); a NIF
  with a dirty twin is called through `dispatch/3`.
  """
  use Rustler,
    otp_app: :valimc,
    crate: "valimc_nif",
    path: "native/valimc_nif",
    mode: :release,
    skip_compilation?: true

  for path <-
        ["native/Cargo.toml", "native/Cargo.lock"] ++
          Path.wildcard("native/*/Cargo.toml") ++ Path.wildcard("native/*/src/**/*"),
      File.regular?(path) do
    @external_resource path
  end

  # A normal scheduler runs one NIF call for at most about this long.
  @budget_ns 1_000_000

  # NIFs with a dirty twin: worst-case nanoseconds per unit (VMC-077b) and the
  # twin. Disk NBT per input byte (terms included); LZ4 per output byte; block
  # changes per change; random ticks per draw; block updates (VMC-077m) per
  # change, action or due tick. Neither a light update's cost nor a block update
  # cascade's is bounded by its input: past 64 positions a light update runs
  # dirty, past 500 changes block updates do, and on a normal scheduler Rust
  # stops either at a budget of work and drops it (`{:error, :too_large}`) for
  # the caller to run dirty (VMC-077c).
  @twins %{
    nbt_read: {8, :nbt_read_dirty},
    lz4_decode_stream: {0.5, :lz4_decode_stream_dirty},
    set_blocks: {40, :set_blocks_dirty},
    block_updates: {2_000, :block_updates_dirty},
    random_ticks: {5, :random_ticks_dirty},
    light_update: {15_625, :light_update_dirty},
    # Per cell an item tick scans (`Physics.Kernel.items/3` estimates them):
    # 110 µs for a scan of 1,024 cells of fences, walls and stairs (VMC-077l).
    physics_items: {120, :physics_items_dirty},
    # An orb tick scans as an item tick does.
    physics_orbs: {120, :physics_orbs_dirty},
    # Per cell a mob tick scans (`Physics.Kernel.mobs/4` estimates them): its
    # move, fluid, footing and contact scans, as an item's (VMC-015i).
    physics_mobs: {120, :physics_mobs_dirty},
    # Per supplied cell a mob ticker's view decodes (oracles and benches;
    # published rows decode nothing), VMC-043e.
    physics_mobs_begin: {100, :physics_mobs_begin_dirty},
    # Per cell one mob's step scans, as `physics_mobs`.
    physics_mobs_step: {120, :physics_mobs_step_dirty},
    # One fluid scan plus eye checks over the ticker's existing view.
    physics_mobs_sense: {120, :physics_mobs_sense_dirty},
    # A primed TNT or falling block scans as an item does (VMC-050a).
    physics_block_bodies: {120, :physics_block_bodies_dirty},
    # Per cell a projectile tick's ray and fluid scans read (VMC-037o).
    physics_projectiles: {120, :physics_projectiles_dirty},
    # Per simulated chunk and category: a start and up to three packs, with
    # the despawn checks (`World.Spawning`, VMC-042a; nine sections' 4,032
    # units took at most 0.7 ms, under 200 ns a unit).
    natural_spawn: {500, :natural_spawn_dirty},
    # Per node a path search may visit (`Valimc.AI.Paths`, VMC-041b): its
    # neighbours' path types over the mob's box, each a few block reads; a
    # zombie's search that visits all 560 took at most 0.86 ms.
    path_find: {2_500, :path_find_dirty}
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
  def region_give(_region, _to), do: :erlang.nif_error(:nif_not_loaded)
  def get_blocks(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def read_box(_region, _min, _max), do: :erlang.nif_error(:nif_not_loaded)
  def set_pistons(_region, _kept, _gone), do: :erlang.nif_error(:nif_not_loaded)

  def physics_pistons(_view, _pushes, _bodies, _states, _border, _authoritative \\ true),
    do: :erlang.nif_error(:nif_not_loaded)

  def chunk_pistons(_region, _cx, _cz), do: :erlang.nif_error(:nif_not_loaded)
  def set_blocks(_region, _changes), do: :erlang.nif_error(:nif_not_loaded)
  def set_blocks_dirty(_region, _changes), do: :erlang.nif_error(:nif_not_loaded)

  def encode_chunk(_region, _cx, _cz, _biome, _bits, _biome_bits, _window),
    do: :erlang.nif_error(:nif_not_loaded)

  def chunk_find(_region, _cx, _cz, _states), do: :erlang.nif_error(:nif_not_loaded)
  def touched_chunks(_region), do: :erlang.nif_error(:nif_not_loaded)
  def set_random_ticking(_region, _bitmap), do: :erlang.nif_error(:nif_not_loaded)
  def random_ticks(_region, _per_section), do: :erlang.nif_error(:nif_not_loaded)
  def random_ticks_dirty(_region, _per_section), do: :erlang.nif_error(:nif_not_loaded)
  def dump_column(_region, _cx, _cz, _default_biome), do: :erlang.nif_error(:nif_not_loaded)
  def biome_zoom(_zoom_seed, _x, _y, _z), do: :erlang.nif_error(:nif_not_loaded)

  ## Published chunk snapshots (VMC-077p)

  def snapshot_publish(_region, _chunks, _revision), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_get(_snapshot, _x, _y, _z), do: :erlang.nif_error(:nif_not_loaded)

  def snapshot_blocks(_snapshots, _positions, _outside),
    do: :erlang.nif_error(:nif_not_loaded)

  def snapshot_column(_snapshot, _x, _z), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_biome(_snapshot, _qx, _qy, _qz), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_find(_snapshot, _states), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_highest_filled(_snapshot, _below), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_revisions(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  def biome_temperature(_temperature, _frozen, _x, _y, _z, _sea_level),
    do: :erlang.nif_error(:nif_not_loaded)

  def region_light(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)

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

  def block_updates(
        _region,
        _siblings,
        _rules,
        _changes,
        _ticks,
        _fluid_ticks,
        _actions,
        _absent,
        _seed,
        _options,
        _redstone
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def block_updates_dirty(
        _region,
        _siblings,
        _rules,
        _changes,
        _ticks,
        _fluid_ticks,
        _actions,
        _absent,
        _seed,
        _options,
        _redstone
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def rules_support_cases(_rules, _updates, _states), do: :erlang.nif_error(:nif_not_loaded)

  def rules_scene(_rules, _floor, _sets), do: :erlang.nif_error(:nif_not_loaded)
  def rules_placement_cases(_rules, _cases), do: :erlang.nif_error(:nif_not_loaded)

  def block_place(
        _region,
        _siblings,
        _rules,
        _item,
        _values,
        _position,
        _absent,
        _seed,
        _outputs
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def fluid_scene(_rules, _cells, _actions, _ticks, _seed, _options),
    do: :erlang.nif_error(:nif_not_loaded)

  def piston_scene(_rules, _cells, _actions, _ticks, _seed),
    do: :erlang.nif_error(:nif_not_loaded)

  def piston_pushes(_cells, _moving, _ticking, _bodies, _states),
    do: :erlang.nif_error(:nif_not_loaded)

  def redstone_scene(_rules, _cells, _actions, _entities, _days, _ticks, _seed, _tnt),
    do: :erlang.nif_error(:nif_not_loaded)

  def growth_scene(_rules, _cells, _actions, _ticks, _seed, _sky, _darken, _rain, _corals),
    do: :erlang.nif_error(:nif_not_loaded)

  def growth_trees(_rules, _worldgen, _cases), do: :erlang.nif_error(:nif_not_loaded)

  def redstone_day(_rules, _samples), do: :erlang.nif_error(:nif_not_loaded)

  def light_sky(_region, _sky), do: :erlang.nif_error(:nif_not_loaded)
  def light_init(_region, _absent), do: :erlang.nif_error(:nif_not_loaded)
  def light_update(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def light_update_dirty(_region, _positions), do: :erlang.nif_error(:nif_not_loaded)
  def light_image(_region, _cx, _cz, _sections), do: :erlang.nif_error(:nif_not_loaded)
  def light_column_image(_image, _sky), do: :erlang.nif_error(:nif_not_loaded)
  def halo_put(_region, _chunks), do: :erlang.nif_error(:nif_not_loaded)
  def halo_set(_region, _edits), do: :erlang.nif_error(:nif_not_loaded)
  def put_columns_lit(_region, _images), do: :erlang.nif_error(:nif_not_loaded)

  ## Physics (VMC-077l: items, obstruction, the border; VMC-077l2: players)

  def physics_border_clear(_border, _subject, _body), do: :erlang.nif_error(:nif_not_loaded)
  def physics_sin_cos(_x), do: :erlang.nif_error(:nif_not_loaded)

  def physics_obstructs(_state, _position, _context, _bodies),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_collision_boxes(_state, _position, _context),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_items(_view, _items, _border, _refresh), do: :erlang.nif_error(:nif_not_loaded)
  def physics_orbs(_view, _orbs, _border), do: :erlang.nif_error(:nif_not_loaded)
  def physics_mobs(_view, _mobs, _players, _border), do: :erlang.nif_error(:nif_not_loaded)
  def physics_mobs_dirty(_view, _mobs, _players, _border), do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_begin(_view, _mobs, _players, _border, _colliders \\ []),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_begin_dirty(_view, _mobs, _players, _border, _colliders \\ []),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_step(_ticker, _index, _mob), do: :erlang.nif_error(:nif_not_loaded)
  def physics_mobs_step_dirty(_ticker, _index, _mob), do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_sense(_ticker, _body, _eye), do: :erlang.nif_error(:nif_not_loaded)
  def physics_mobs_sense_dirty(_ticker, _body, _eye), do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_displace(_ticker, _index, _mob, _delta),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_goal_position(_ticker, _index, _mob),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_displace(_view, _body, _delta, _boxes, _border, _authoritative),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_collider(_ticker, _index, _position, _box),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_mobs_velocity(_ticker, _index, _velocity), do: :erlang.nif_error(:nif_not_loaded)
  def physics_mobs_finish(_ticker), do: :erlang.nif_error(:nif_not_loaded)

  ## Path search (VMC-041b)

  def path_facts_init(_types, _flags), do: :erlang.nif_error(:nif_not_loaded)
  def path_find(_view, _requests), do: :erlang.nif_error(:nif_not_loaded)
  def path_find_dirty(_view, _requests), do: :erlang.nif_error(:nif_not_loaded)
  def physics_orbs_dirty(_view, _orbs, _border), do: :erlang.nif_error(:nif_not_loaded)

  def physics_items_dirty(_view, _items, _border, _refresh),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_explosion(_view, _center, _radius, _seed, _min_y, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_exposure(_view, _center, _bodies), do: :erlang.nif_error(:nif_not_loaded)
  def physics_block_bodies(_view, _bodies, _border), do: :erlang.nif_error(:nif_not_loaded)

  def physics_projectiles(_view, _projectiles, _targets, _border, _fast_lava),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_projectiles_dirty(_view, _projectiles, _targets, _border, _fast_lava),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_block_bodies_dirty(_view, _bodies, _border),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_player_query(_player, _target, _flags), do: :erlang.nif_error(:nif_not_loaded)

  def physics_player_move(_view, _player, _target, _flags, _border, _entities \\ []),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_player_rest(_view, _player, _border, _entities \\ []),
    do: :erlang.nif_error(:nif_not_loaded)

  ## Natural spawning (VMC-042a)

  def spawn_facts_install(_facts), do: :erlang.nif_error(:nif_not_loaded)
  def natural_spawn(_region, _siblings, _absent, _request), do: :erlang.nif_error(:nif_not_loaded)

  def spawn_position_ok(_region, _siblings, _absent, _environment, _kind, _pos, _reach),
    do: :erlang.nif_error(:nif_not_loaded)

  def natural_spawn_dirty(_region, _siblings, _absent, _request),
    do: :erlang.nif_error(:nif_not_loaded)

  def spawn_generated(_region, _siblings, _absent, _environment, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

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
  def worldgen_end_pillars(_state, _seed), do: :erlang.nif_error(:nif_not_loaded)
  def worldgen_end_spikes(_seed), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_columns(_state, _biome_source, _protocol_biomes, _chunks),
    do: :erlang.nif_error(:nif_not_loaded)

  # The generation scheduler's chunks and starts (VMC-077n).
  def gen_starts_new, do: :erlang.nif_error(:nif_not_loaded)
  def gen_starts_stats(_starts), do: :erlang.nif_error(:nif_not_loaded)
  def gen_starts_snapshot(_starts), do: :erlang.nif_error(:nif_not_loaded)
  def gen_starts_restore(_snapshot), do: :erlang.nif_error(:nif_not_loaded)
  def gen_terrain(_state, _biome_source, _starts, _x, _z), do: :erlang.nif_error(:nif_not_loaded)

  def gen_decorate(_state, _biome_source, _starts, _center, _cells),
    do: :erlang.nif_error(:nif_not_loaded)

  def gen_encode(_cell), do: :erlang.nif_error(:nif_not_loaded)
  def gen_cells_bytes(_cells), do: :erlang.nif_error(:nif_not_loaded)
  def gen_decode(_state, _encoded), do: :erlang.nif_error(:nif_not_loaded)

  def gen_reference(_state, _biome_source, _origin, _size, _order, _structures),
    do: :erlang.nif_error(:nif_not_loaded)

  def gen_full(_state, _cell, _protocol_biomes), do: :erlang.nif_error(:nif_not_loaded)

  # Their background twins (VMC-081c): each sends `{tag, :ok, value}` or
  # `{tag, :raise, reason}` to the caller; `background/1` waits for it.
  def background_threads(_threads, _nice), do: :erlang.nif_error(:nif_not_loaded)

  def gen_terrain_background(_tag, _state, _biome_source, _starts, _x, _z),
    do: :erlang.nif_error(:nif_not_loaded)

  def gen_decorate_background(_tag, _state, _biome_source, _starts, _center, _cells),
    do: :erlang.nif_error(:nif_not_loaded)

  def gen_encode_background(_tag, _cell), do: :erlang.nif_error(:nif_not_loaded)
  def gen_decode_background(_tag, _state, _encoded), do: :erlang.nif_error(:nif_not_loaded)

  def gen_reference_background(_tag, _state, _source, _origin, _size, _order, _structures),
    do: :erlang.nif_error(:nif_not_loaded)

  def gen_full_background(_tag, _state, _cell, _protocol_biomes, _sky),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Run a background twin (`start` gets the tag to call it with) and wait for
  `{:ok, value}`, as the dirty NIF returns it; a failure raises as it would.
  """
  def background(start) do
    tag = make_ref()
    :ok = start.(tag)

    receive do
      {^tag, :ok, value} -> {:ok, value}
      {^tag, :raise, reason} -> :erlang.error(reason)
    end
  end

  def worldgen_structure_locate(_state, _biome_source, _structures, _pos, _radius),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_place_plan(_state, _biome_source, _spec, _pos),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_grow(_state, _biome_source, _rules, _pos, _chunks, _base, _seed),
    do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_place(_state, _biome_source, _spec, _pos, _chunks, _base, _seed),
    do: :erlang.nif_error(:nif_not_loaded)

  ## Loot (VMC-072a, entity drops VMC-037n)

  def loot_registry(_tables, _registries), do: :erlang.nif_error(:nif_not_loaded)

  def loot_fill(_registry, _table, _seed, _luck, _origin, _size, _biome, _structure, _next_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def loot_items(_registry, _table, _seed, _luck, _origin, _biome, _structure, _next_map),
    do: :erlang.nif_error(:nif_not_loaded)

  def loot_entity(_registry, _table, _seed, _luck, _origin, _death),
    do: :erlang.nif_error(:nif_not_loaded)

  def loot_block(_registry, _table, _seed, _origin, _block),
    do: :erlang.nif_error(:nif_not_loaded)

  def loot_enchant(_registry, _item, _enchantments, _min, _span, _special, _tag, _random),
    do: :erlang.nif_error(:nif_not_loaded)

  # A mob's initial body and eye fluid samples, before its first travel tick.
  def physics_fluids(_view, _body), do: :erlang.nif_error(:nif_not_loaded)
  def physics_eyes(_view, _body, _eye), do: :erlang.nif_error(:nif_not_loaded)

  ## Parity and benchmarks (dev, test and bench builds)

  def spawn_scene(_case, _biome, _types), do: :erlang.nif_error(:nif_not_loaded)
  def spawn_spawner_scene(_case, _biome, _type), do: :erlang.nif_error(:nif_not_loaded)

  def spawn_despawn(_type, _difficulty, _distance, _persistent),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_player_parity(_op, _args), do: :erlang.nif_error(:nif_not_loaded)

  # The kernel's entry points one by one, for the oracle checks.
  def physics_move(_view, _body, _movement, _context, _extra, _max_step, _ground),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_colliding(_view, _boxes, _context, _extra, _subject),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_new_collision(_view, _old, _new, _context, _extra),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_fluid_eyes(_view, _body, _eye), do: :erlang.nif_error(:nif_not_loaded)
  def physics_any_liquid(_view, _body), do: :erlang.nif_error(:nif_not_loaded)
  def physics_flow(_view, _position), do: :erlang.nif_error(:nif_not_loaded)

  def physics_current(_view, _body, _velocity, _flags),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_sweep(_from, _to, _body, _stop), do: :erlang.nif_error(:nif_not_loaded)

  def physics_inside_shape(_state, _position, _context, _body, _movement),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_respond(_velocity, _moved_y, _collisions, _bounce, _drag),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_footing(_view, _body, _position, _movement, _context),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_parity_clip(_colliders, _axis, _body, _delta, _raw),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_parity_move(_colliders, _body, _movement), do: :erlang.nif_error(:nif_not_loaded)

  def physics_parity_step(_initial, _steps, _body, _movement, _max_step, _grounded),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_parity_heights(_colliders, _body, _max_step, _skip),
    do: :erlang.nif_error(:nif_not_loaded)

  def physics_parity_box_shape(_body), do: :erlang.nif_error(:nif_not_loaded)
  def physics_parity_intersects(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def physics_parity_shape(_state, _position, _context), do: :erlang.nif_error(:nif_not_loaded)
  def physics_parity_moving(_position, _moving, _noclip), do: :erlang.nif_error(:nif_not_loaded)
  def physics_parity_colliders(_view, _body, _context), do: :erlang.nif_error(:nif_not_loaded)
  def physics_parity_new_collision(_old, _colliders), do: :erlang.nif_error(:nif_not_loaded)

  def put_column(_region, _cx, _cz, _sections), do: :erlang.nif_error(:nif_not_loaded)
  def heap_bytes(_region), do: :erlang.nif_error(:nif_not_loaded)
  def snapshot_resident(_region, _snapshots), do: :erlang.nif_error(:nif_not_loaded)

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

  def gen_inspect(_cells), do: :erlang.nif_error(:nif_not_loaded)

  def worldgen_structure_time(_state, _biome_source, _origin, _size),
    do: :erlang.nif_error(:nif_not_loaded)
end
