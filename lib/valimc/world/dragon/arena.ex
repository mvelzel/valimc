defmodule Valimc.World.Dragon.Arena do
  @moduledoc "The origin section's live End fight; operations use its existing group paths (VMC-045a7)."
  alias Valimc.Data.{BlockFacts, Blocks, Float32, Grid}
  alias Valimc.Entity.Body
  alias Valimc.Protocol.BossPackets
  alias Valimc.World.Dragon.{Fight, Podium}
  alias Valimc.World.View

  @chunks for x <- -8..8, z <- -8..8, do: {x, z}
  @title Valimc.Text.translatable("entity.minecraft.ender_dragon")

  def chunks, do: @chunks

  @doc "Only the End origin section holds a fight record."
  def new(:the_end, {0, 0}, seed), do: Fight.new(seed)
  def new(_dimension, _key, _seed), do: nil

  @doc "The complete arena must be loaded and writable in this owner before effects run."
  def ready?(state) do
    Enum.all?(@chunks, fn chunk ->
      key = Grid.region_key(chunk)

      if key == state.key do
        not MapSet.member?(state.generation.absent, chunk)
      else
        case state.siblings[key] do
          %{busy: false, absent_set: absent} -> not MapSet.member?(absent, chunk)
          _ -> false
        end
      end
    end)
  end

  @doc "One owner tick after player sensing, before entities; unloaded arenas wait."
  def tick(%{arena: nil} = state, _ops, _players), do: state

  def tick(state, ops, players) do
    state = audience(state, ops, players)

    if map_size(state.arena_view.players) > 0 and ready?(state) and ops.ready.(state) do
      state = if state.arena.initialized, do: state, else: initialize(state, ops)
      state = if state.arena.killed, do: state, else: track(state, ops)
      sync_bar(state, ops)
    else
      state
    end
  end

  defp initialize(state, ops) do
    view = View.new(state.dimension)
    {min_y, _} = Valimc.World.Dimension.bounds(state.dimension)
    floor = Podium.location(height(view, 0, 0, min_y), &View.block(view, &1), min_y)
    fight = %{state.arena | podium: state.arena.podium || floor, initialized: true}
    state = %{state | arena: fight}
    state = ops.edits.(state, Podium.feature(fight.podium, false))
    ensure_dragon(state, ops)
  end

  defp track(state, ops) do
    state =
      case Enum.find(ops.entries.(state), fn {_, e} -> e.entity.uuid == state.arena.dragon end) do
        nil ->
          missing = state.arena.missing + 1
          state = put_in(state.arena.missing, missing)

          if state.arena.dragon == nil or missing >= 1200,
            do: ensure_dragon(state, ops),
            else: state

        _ ->
          put_in(state.arena.missing, 0)
      end

    state = put_in(state.arena.scan, state.arena.scan + 1)

    if state.arena.scan >= 100,
      do: %{state | arena: %{state.arena | scan: 0, alive_crystals: count_crystals(state, ops)}},
      else: state
  end

  defp ensure_dragon(state, ops) do
    dragon =
      ops.entries.(state)
      |> Enum.filter(fn
        {_, %{body: %Body{type: "minecraft:ender_dragon"}}} -> true
        _ -> false
      end)
      |> Enum.min_by(&elem(&1, 0), fn -> nil end)

    {state, uuid} = if dragon, do: {state, elem(dragon, 1).entity.uuid}, else: ops.spawn.(state)
    %{state | arena: %{state.arena | dragon: uuid, missing: 0}}
  end

  @doc "Count authoritative crystal boxes in the generator's ten spike columns."
  def count_crystals(state, ops) do
    crystals =
      for {_, %{body: %Body{type: "minecraft:end_crystal"}, entity: e}} <- ops.entries.(state),
          do: e

    spikes =
      if state.arena,
        do: state.arena_spikes,
        else: get_in(state.siblings, [{0, 0}, :arena_spikes]) || []

    for spike <- spikes, crystal <- crystals, reduce: 0 do
      count ->
        if crystal.x + 1 > spike.x - spike.radius and crystal.x - 1 < spike.x + spike.radius and
             crystal.z + 1 > spike.z - spike.radius and crystal.z - 1 < spike.z + spike.radius,
           do: count + 1,
           else: count
    end
  end

  @doc "Admit completion in the root's removal frame; the same UUID cannot reward twice."
  def complete(%{arena: nil} = state, _uuid, _ops), do: state

  def complete(state, uuid, ops) do
    {fight, effects} = Fight.complete(state.arena, uuid)
    state = %{state | arena: fight}
    state = Enum.reduce(effects, state, &effect(&1, &2, ops))
    sync_bar(state, ops)
  end

  defp effect({:podium, active}, state, ops),
    do: ops.edits.(state, Podium.feature(state.arena.podium, active))

  defp effect({:gateway, at}, state, ops) do
    state = ops.gateway.(state, at)
    ops.event.(state, 3000, at)
  end

  defp effect(:egg, state, ops) do
    view = View.new(state.dimension)
    {:ok, %{motion_blocking: top}} = View.column(view, 0, 0)
    ops.edits.(state, [{{0, top, 0}, Blocks.default_state("dragon_egg"), false}])
  end

  defp audience(%{arena_view: nil} = state, ops, players) do
    bar = %{
      id: :crypto.strong_rand_bytes(16),
      players: %{},
      shown: MapSet.new(),
      health: 1.0,
      scan: 20
    }

    audience(%{state | arena_view: bar}, ops, players)
  end

  defp audience(state, ops, players) do
    bar = %{state.arena_view | scan: state.arena_view.scan + 1}

    if bar.scan >= 20 do
      players = for p <- players, Fight.eligible?(p), into: %{}, do: {p.uuid, true}
      state = %{state | arena_view: %{bar | scan: 0, players: players}}
      sync_bar(state, ops)
    else
      %{state | arena_view: bar}
    end
  end

  defp sync_bar(%{arena_view: nil} = state, _ops), do: state

  defp sync_bar(state, ops) do
    bar = state.arena_view
    shown = if state.arena.killed, do: MapSet.new(), else: MapSet.new(Map.keys(bar.players))

    health =
      case Enum.find(ops.entries.(state), fn {_, e} -> e.entity.uuid == state.arena.dragon end) do
        {_, %{body: %{mob: %{living: %{health: health}}}}} ->
          Float32.round(health.value / health.maximum)

        _ ->
          bar.health
      end

    entering = MapSet.difference(shown, bar.shown)
    leaving = MapSet.difference(bar.shown, shown)
    for uuid <- entering, do: ops.packet.(uuid, BossPackets.add(bar.id, @title, health))
    for uuid <- leaving, do: ops.packet.(uuid, BossPackets.remove(bar.id))

    if health != bar.health do
      for uuid <- MapSet.difference(shown, entering),
          do: ops.packet.(uuid, BossPackets.progress(bar.id, health))
    end

    %{state | arena_view: %{bar | shown: shown, health: health}}
  end

  @doc "First free motion-blocking cell without leaves, from the published column's bound."
  def height(view, x, z, min_y) do
    case View.column(view, x, z) do
      {:ok, %{motion_blocking: top}} when top > min_y ->
        cells = for y <- (top - 1)..min_y//-1, do: {x, y, z}

        Enum.zip(cells, View.blocks(view, cells))
        |> Enum.find_value(min_y, fn
          {{_, y, _}, block} when is_integer(block) ->
            if BlockFacts.heightmap?(block, :motion_blocking_no_leaves), do: y + 1

          _ ->
            nil
        end)

      _ ->
        min_y
    end
  end
end
