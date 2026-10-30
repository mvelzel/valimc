defmodule Valimc.World.BlockRules do
  @moduledoc """
  Vanilla's block updates in a region (VMC-077m), run by the Rust rules engine
  that decoration shares (`valimc_core::rules`).

  After block changes in a region's storage the engine does what
  `Level.setBlock` starts: neighbour updates and shape updates in vanilla's
  orders, through a collecting updater with vanilla's chain limit. A shape
  that becomes air destroys its block (it leaves its fluid and drops its
  loot); a dependent block's due tick breaks it if it can no longer survive.
  The engine reads the cells of a section and its group's other sections
  (VMC-077j) and returns what it decided; each section commits its part.
  Updates stop at the group's edge: an update at a cell the group does not
  hold, or whose rule reads one, is dropped.

  Rules come from the shared rule modules, live play's survival facts
  (`priv/physics/support.json`) and decoration's shape facts, in that order;
  a state none models keeps its state. Water and lava flow in the same engine
  (VMC-031a, `priv/physics/fluids.json`): due fluid ticks, buckets and a
  generated chunk's post-processing marks are part of a run. Placement
  (`place/6`) comes from the placement facts (`priv/physics/placement.json`).
  """
  import Bitwise
  alias Valimc.{Native, Worldgen}
  alias Valimc.Data.BlockFacts

  @doc "The native rules, parsed once per VM (the block facts are installed first)."
  def native do
    case :persistent_term.get({__MODULE__, :native}, nil) do
      nil ->
        :global.trans({__MODULE__, self()}, fn ->
          case :persistent_term.get({__MODULE__, :native}, nil) do
            nil ->
              BlockFacts.install!()
              {:ok, rules} = Native.rules_new(facts())
              :persistent_term.put({__MODULE__, :native}, rules)
              rules

            rules ->
              rules
          end
        end)

      rules ->
        rules
    end
  end

  defp facts do
    %{
      "block_registry" => Valimc.Data.Blocks.native_facts(),
      "block_facts" => Worldgen.block_facts(Valimc.Protocol.Data.tags()),
      "support" => Worldgen.fact("survival"),
      "shapes" => Worldgen.fact("shapes"),
      "live_support" => Valimc.Data.Facts.read!("physics/support.json"),
      "fluids" => Valimc.Blocks.Fluids.native_facts(),
      "placement" => Valimc.Data.Facts.read!("physics/placement.json"),
      "redstone" => Valimc.Data.Facts.read!("physics/redstone.json"),
      "growth" => Valimc.Data.Facts.read!("physics/growth.json"),
      "transformers" => Valimc.Data.Facts.read!("physics/block_transformers.json")
    }
  end

  @doc """
  One engine run in a section's storage, reading across the stores of
  `siblings` (the group's other sections; `absent` lists their chunks not
  generated yet). `input` holds what starts it, each optional:

  - `changes`: `position => old state` for cells the owner just changed;
  - `actions`: `{:empty, position, fluid, retry, secondary}` (a bucket of a
    fluid source poured, then at `retry` or nil), `{:pickup, position}` (a
    bucket filled), `{:post, position}` (a post-processing mark),
    `{:random_tick, position, fire?, rain?}` (a lava cell's or a growing
    plant's random tick, VMC-039a), `{:bone_meal, position, face, corals?}`
    (clicked on face 0..5 or nil; `corals?` whether the biome beside it
    grows corals),
    `{:transform, position, tool, face}` (a tool's block transformer, its
    index in `Valimc.Blocks.Transformers`, from a clicked face 0..5),
    `{:trample, position}` (farmland trampled), `{:harvest, position}`
    (berries picked, VMC-039b), `{:shear, position, facing}` (shears on a
    full beehive or a pumpkin, carved toward direction index `facing`,
    VMC-039c), `{:edit, position, from, to, event}` (a mob
    eating a block, VMC-043c: `from` becomes `to`, or nil destroys it, after
    a break event of data `event`, or nil), and
    redstone's (VMC-047a) `{:use, position, facing, may_build?}` (a
    player's use; `facing` a horizontal direction index, 2..5),
    `:contacts` (the entities' contacts), `{:daylight, position}`,
    `{:page, position}`, `{:hit, position, power, arrow?}`,
    `{:placed, position}` (a tripwire hook's or diode's `setPlacedBy`),
    `{:disarm, position}`, `{:output_changed, position}` (VMC-048a: a block
    entity's `setChanged`, which comparators reading it hear);
  - `ticks`: due block ticks, `[{position, state}]` (a tick runs while the
    cell holds that state's block);
  - `fluid_ticks`: due fluid ticks, `[{position, fluid}]`;
  - `random`: the tick's random ticks after the fluid ticks (VMC-081g1),
    `%{speed:, mask:, radius:, wet:, players: [{x, y, z}]}`: `speed` draws
    in each section with randomly ticking cells of this section's chunks in
    `mask` (bit `z * 8 + x`); lava's fire spreads within `radius` of a
    player (-1 anywhere); in `wet` weather farmland's draws go back too;
  - `options`: the level settings' bits (`Valimc.Blocks.Fluids.options/3`, and 16
    for the `tnt_explodes` game rule);
  - `redstone`: `%{time:, day: {ticks, rain, thunder}, toggles: [{position,
    when}], entities: [{min, max, kind}], pending: [{position, block}],
    outputs: [{position, output}], containers: [{position, signal}]}`
    (`day` the overworld clock's ticks and the weather's levels, which
    daylight detectors read; `kind` `:other`, `:living` or `:arrow`;
    `pending` the owner's pending ticks the run may ask about; `outputs`
    the comparators' outputs, `containers` the analog signals of the
    containers comparators may read, VMC-048a).

  Returns `%{changes: [{position, state}], destroyed: [{position, state,
  drops?, effects?}], ticks: [{position, block, delay, priority}], fluid_ticks:
  [{position, fluid, delay}], events: [{position, type, data}], results:
  [integer], sounds: [{{x, y, z}, sound, volume, pitch, actor?}],
  block_events: [{position, block, b0, b1}], primed: [position], dispensed:
  [position] (dispensers and droppers whose tick fired, VMC-049a), toggles:
  [{position, when}], outputs: [{position, output}], drawn: [{position,
  state}] (the random draws the owner ticks), grown: [position] (plants
  whose random tick grows what the generator grows), stopped: n, skipped:
  n, updates: n}` (`priority` a `TickPriority`, -3..3; `outputs` the
  comparators' outputs the run changed, nil for one gone; `effects?`: it
  breaks with particles and sound; `results`: one per action, see
  `live::Outcome::results`; `sound` an index into
  `Valimc.Blocks.Redstone.sounds/0`; the counts: updates dropped at the
  group's edge, past the chain limit and run); storage is not changed.
  """
  def run(%Valimc.World.Blocks{ref: ref}, siblings, input, absent) do
    changes = Map.get(input, :changes, %{})
    ticks = Map.get(input, :ticks, [])
    fluid_ticks = Map.get(input, :fluid_ticks, [])
    actions = Map.get(input, :actions, [])
    random = Map.get(input, :random)

    units =
      map_size(changes) + length(ticks) + length(fluid_ticks) + length(actions) +
        random_units(random)

    stores = for %Valimc.World.Blocks{ref: sibling} <- siblings, do: sibling

    args = [
      ref,
      stores,
      native(),
      pack(changes),
      pack(ticks),
      for(
        {{x, y, z}, fluid} <- fluid_ticks,
        into: <<>>,
        do: <<x::32-signed, y::32-signed, z::32-signed, fluid>>
      ),
      for(action <- actions, into: <<>>, do: pack_action(action)),
      absent,
      :rand.uniform(1 <<< 62),
      Map.get(input, :options, 0),
      pack_redstone(Map.get(input, :redstone)),
      pack_random(random)
    ]

    {:ok,
     {{changed, destroyed, scheduled, fluid, events, results}, {stopped, skipped, updates},
      {sounds, block_events, primed, toggles, outputs, dispensed},
      {kept, gone, pending, executed, pushes, hidden}, {drawn, grown}}} =
      case Native.dispatch(:block_updates, units, args) do
        # A cascade past the normal scheduler's budget runs again, dirty.
        {:error, :too_large} -> apply(Native, :block_updates_dirty, args)
        result -> result
      end

    %{
      changes:
        for(<<x::32-signed, y::32-signed, z::32-signed, s::16 <- changed>>, do: {{x, y, z}, s}),
      destroyed:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, s::16, flags::8 <- destroyed>>,
          do: {{x, y, z}, s, (flags &&& 1) == 1, (flags &&& 2) == 2}
        ),
      ticks:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, block::16, delay::32-signed,
            priority::8-signed <- scheduled>>,
          do: {{x, y, z}, block, delay, priority}
        ),
      fluid_ticks:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, kind::8, delay::32-signed <- fluid>>,
          do: {{x, y, z}, kind, delay}
        ),
      events:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, type::32-signed,
            data::32-signed <- events>>,
          do: {{x, y, z}, type, data}
        ),
      results: results,
      sounds:
        for(
          <<x::float-64, y::float-64, z::float-64, sound::16, volume::float-32, pitch::float-32,
            actor::8 <- sounds>>,
          do: {{x, y, z}, sound, volume, pitch, actor == 1}
        ),
      block_events:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, block::16, b0::32-signed,
            b1::32-signed <- block_events>>,
          do: {{x, y, z}, block, b0, b1}
        ),
      primed: for(<<x::32-signed, y::32-signed, z::32-signed <- primed>>, do: {x, y, z}),
      dispensed: for(<<x::32-signed, y::32-signed, z::32-signed <- dispensed>>, do: {x, y, z}),
      toggles:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, at::64-signed <- toggles>>,
          do: {{x, y, z}, at}
        ),
      outputs:
        for(
          <<x::32-signed, y::32-signed, z::32-signed, output::32-signed <- outputs>>,
          do: {{x, y, z}, if(output < 0, do: nil, else: output)}
        ),
      pistons:
        for(<<record::binary-size(40) <- kept>>, do: Valimc.Blocks.MovingPistons.unpack(record)) ++
          for(<<x::32-signed, y::32-signed, z::32-signed <- gone>>, do: {{x, y, z}, nil}),
      pending_events: unpack_events(pending),
      executed: unpack_events(executed),
      pushes:
        for(
          <<record::binary-size(40), progress::float-32, state::16, landed <- pushes>>,
          do:
            (
              {position, moving} = Valimc.Blocks.MovingPistons.unpack(record)
              {position, moving, progress, state, landed == 1}
            )
        ),
      hidden: for(<<x::32-signed, y::32-signed, z::32-signed <- hidden>>, do: {x, y, z}),
      drawn:
        for(<<x::32-signed, y::32-signed, z::32-signed, s::16 <- drawn>>, do: {{x, y, z}, s}),
      grown: for(<<x::32-signed, y::32-signed, z::32-signed <- grown>>, do: {x, y, z}),
      stopped: stopped,
      skipped: skipped,
      updates: updates
    }
  end

  defp pack_action({:empty, position, fluid, retry, secondary}) do
    flags = if(retry, do: 1, else: 0) ||| if(secondary, do: 2, else: 0)
    <<0, pos(position)::binary, fluid, flags, pos(retry || {0, 0, 0})::binary>>
  end

  defp pack_action({:pickup, position}),
    do: <<1, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:post, position}),
    do: <<2, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:random_tick, position, fire, rain}),
    do:
      <<3, pos(position)::binary, 0, if(fire, do: 1, else: 0) ||| if(rain, do: 2, else: 0),
        pos({0, 0, 0})::binary>>

  defp pack_action({:bone_meal, position}), do: pack_action({:bone_meal, position, nil, false})

  defp pack_action({:bone_meal, position, face, corals}),
    do:
      <<11, pos(position)::binary, face || 255, if(corals, do: 1, else: 0),
        pos({0, 0, 0})::binary>>

  defp pack_action({:transform, position, tool, face}),
    do: <<12, pos(position)::binary, tool, face, pos({0, 0, 0})::binary>>

  defp pack_action({:trample, position}),
    do: <<13, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:harvest, position}),
    do: <<15, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:edit, position, from, to, event}),
    do: pack_action({:edit, position, from, to, event, []})

  defp pack_action({:edit, position, from, to, event, options}) do
    {to, event} = {to || 0xFFFF, event || -1}

    flags =
      if(:updates in options, do: 1, else: 0) + if(:survives in options, do: 2, else: 0) +
        if(:drops in options, do: 4, else: 0)

    <<16, pos(position)::binary, 0, 0, from::16, to::16, event::32-signed, flags, 0::24>>
  end

  defp pack_action({:shear, position, facing}),
    do: <<18, pos(position)::binary, facing, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:use, position, facing, may_build}),
    do:
      <<4, pos(position)::binary, facing, if(may_build, do: 1, else: 0), pos({0, 0, 0})::binary>>

  defp pack_action(:contacts), do: <<5, pos({0, 0, 0})::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:daylight, position}),
    do: <<6, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:page, position}),
    do: <<7, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:hit, position, power, arrow}),
    do: <<8, pos(position)::binary, power, if(arrow, do: 1, else: 0), pos({0, 0, 0})::binary>>

  defp pack_action({:placed, position}),
    do: <<9, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:disarm, position}),
    do: <<10, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:output_changed, position}),
    do: <<14, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pack_action({:moving, position}),
    do: <<17, pos(position)::binary, 0, 0, pos({0, 0, 0})::binary>>

  defp pos({x, y, z}), do: <<x::32-signed, y::32-signed, z::32-signed>>

  # The tick's random phase (`rules.rs`'s `random_phase`); none packs empty.
  defp pack_random(nil), do: <<>>

  defp pack_random(%{speed: speed, mask: mask, radius: radius, wet: wet, players: players}) do
    <<speed::32, mask::64, radius::32-signed, if(wet, do: 1, else: 0), length(players)::32,
      for({x, y, z} <- players, into: <<>>, do: <<x::float-64, y::float-64, z::float-64>>)::binary>>
  end

  # A random phase's work: a unit per 200 draws a chunk may take (24
  # sections), at least one per chunk.
  defp random_units(nil), do: 0
  defp random_units(%{mask: mask, speed: speed}), do: chunks(mask) * max(1, div(speed * 24, 200))

  defp chunks(0), do: 0
  defp chunks(mask), do: (mask &&& 1) + chunks(mask >>> 1)

  # The redstone context (`rules.rs`'s `context`); none packs empty.
  defp pack_redstone(nil), do: <<>>

  defp pack_redstone(context) do
    toggles = Map.get(context, :toggles, [])
    entities = Map.get(context, :entities, [])
    pending = Map.get(context, :pending, [])
    outputs = Map.get(context, :outputs, [])
    containers = Map.get(context, :containers, [])

    {day, rain, thunder} = Map.get(context, :day, {0, 0.0, 0.0})

    <<Map.get(context, :time, 0)::64-signed, day::64-signed, rain::float-32, thunder::float-32,
      length(toggles)::32,
      for({p, at} <- toggles, into: <<>>, do: <<pos(p)::binary, at::64-signed>>)::binary,
      Enum.reduce(entities, 0, fn
        {:packed, n, _}, count -> count + n
        _, count -> count + 1
      end)::32,
      for(
        entity <- entities,
        into: <<>>,
        do: entity_record(entity)
      )::binary, length(pending)::32,
      for({p, block} <- pending, into: <<>>, do: <<pos(p)::binary, block::16>>)::binary,
      length(outputs)::32,
      for({p, output} <- outputs, into: <<>>, do: <<pos(p)::binary, output::32-signed>>)::binary,
      length(containers)::32,
      for({p, signal} <- containers, into: <<>>, do: <<pos(p)::binary, signal::32-signed>>)::binary,
      pack_pistons(Map.get(context, :pistons))::binary>>
  end

  # Pistons' part of the context (VMC-048b): whether the run runs the block
  # events and is in the tick's first part, the next tick order, the world
  # border, the build height and the pending block events.
  defp pack_pistons(nil), do: <<>>

  defp pack_pistons(p) do
    {min_x, min_z, max_x, max_z} = p.border
    {min_y, max_y} = p.build
    flags = if(p.run_events, do: 1, else: 0) ||| if(p.handling_tick, do: 2, else: 0)

    <<flags, p.order::64-signed, min_x::float-64, min_z::float-64, max_x::float-64,
      max_z::float-64, min_y::32-signed, max_y::32-signed, length(p.events)::32,
      for(
        {position, block, b0, b1} <- p.events,
        into: <<>>,
        do: <<pos(position)::binary, block::16, b0::32-signed, b1::32-signed>>
      )::binary>>
  end

  defp unpack_events(packed),
    do:
      for(
        <<x::32-signed, y::32-signed, z::32-signed, block::16, b0::32-signed,
          b1::32-signed <- packed>>,
        do: {{x, y, z}, block, b0, b1}
      )

  # An entity's record, or many a native mob section packed already
  # (`{:packed, count, records}`, VMC-081d).
  defp entity_record({:packed, _n, records}), do: records

  defp entity_record({{x0, y0, z0}, {x1, y1, z1}, kind}),
    do:
      <<x0::float-64, y0::float-64, z0::float-64, x1::float-64, y1::float-64, z1::float-64,
        entity_kind(kind)>>

  defp entity_kind(:living), do: 1
  defp entity_kind(:arrow), do: 2
  defp entity_kind(_), do: 0

  @doc """
  What placing `item` at `position` writes (VMC-029d), read with `siblings`
  as `run/4` reads (and the comparators' `outputs`, `[{position, output}]`,
  which a repeater's lock reads): `[{position, state}]`, or nil when vanilla
  refuses it.
  `values` are the click's inputs (`Valimc.Blocks.Placement.values/2`); the
  rules read the target's light and redstone power themselves.
  """
  def place(
        %Valimc.World.Blocks{ref: ref},
        siblings,
        item,
        values,
        position,
        absent,
        outputs \\ []
      ) do
    stores = for %Valimc.World.Blocks{ref: sibling} <- siblings, do: sibling
    seed = :rand.uniform(1 <<< 62)
    outputs = for {{x, y, z}, output} <- outputs, do: {{x, y, z}, output}

    case Native.block_place(ref, stores, native(), item, values, position, absent, seed, outputs) do
      {:ok, nil} -> nil
      {:ok, writes} -> for {x, y, z, state} <- writes, do: {{x, y, z}, state}
    end
  end

  defp pack(records),
    do:
      for(
        {{x, y, z}, state} <- records,
        into: <<>>,
        do: <<x::32-signed, y::32-signed, z::32-signed, state::16>>
      )
end
