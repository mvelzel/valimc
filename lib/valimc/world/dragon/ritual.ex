defmodule Valimc.World.Dragon.Ritual do
  @moduledoc "Live respawn effects, planned off-owner and admitted through ordered group effects."
  alias Valimc.Data.Blocks
  alias Valimc.Entity.Body
  alias Valimc.World.{Jobs, RegionData, Spec, View}
  alias Valimc.World.Dragon.Fight
  alias Valimc.Worldgen.{Generator, Pool}

  @doc "Try the native four-box admission after a placement or while a killed fight ticks."
  def try_respawn(%{arena: nil} = state, _ops), do: state

  def try_respawn(state, ops) do
    {fight, effects} = Fight.try_respawn(state.arena, crystals(state, ops))
    dispatch(%{state | arena: fight}, effects, ops)
  end

  @doc "One saved clock step; the first pillar waits for a bounded worker if necessary."
  def tick(state, ops) do
    state = prepare(state)
    fight = state.arena
    live = MapSet.new(crystals(state, ops), & &1.uuid)
    needs_plan = fight.stage == :pillars and rem(fight.time, 40) == 39

    if needs_plan and state.arena_pillars == nil and
         Enum.any?(fight.crystals, &MapSet.member?(live, &1)) do
      state
    else
      {fight, effects} = Fight.ritual(fight, state.arena_spikes, live)
      dispatch(%{state | arena: fight}, effects, ops)
    end
  end

  @doc "The participant callback aborts in the same shared frame as its destruction."
  def destroyed(state, uuid, ops) do
    {fight, effects} = Fight.crystal_destroyed(state.arena, uuid)
    dispatch(%{state | arena: fight}, effects, ops)
  end

  defp dispatch(state, effects, ops) do
    positions = Map.new(crystals(state, ops), &{&1.uuid, &1.position})

    Enum.reduce(effects, state, fn effect, state ->
      effects =
        case effect do
          {:pillar, spike} ->
            [{:pillar_clear, spike}, {:pillar_blast, spike}, {:pillar_build, spike}]

          {:ritual_explode, uuid} ->
            [{:ritual_explode, uuid, Map.fetch!(positions, uuid)}]

          other ->
            [other]
        end

      Enum.reduce(effects, state, fn effect, state ->
        ops.queue.(state, {:arena_effect, effect})
      end)
    end)
  end

  defp crystals(state, ops) do
    for {_, %{body: %Body{type: "minecraft:end_crystal"}, entity: e}} <- ops.entries.(state),
        do: %{
          uuid: e.uuid,
          position: {e.x, e.y, e.z},
          box: {e.x - 1, e.y, e.z - 1, e.x + 1, e.y + 2, e.z + 1}
        }
  end

  # One worker per origin, through existing job routing, deadlines and the
  # generation pool. A failure retries after twenty accepted world ticks.
  defp prepare(%{arena_pillars: plans} = state) when plans != nil, do: state

  defp prepare(state) do
    if Jobs.running?(state.jobs, :dragon_pillars) or state.game_tick < state.arena_retry do
      state
    else
      base = Valimc.config(:world_path, state.key)

      work = fn ->
        case Pool.run(fn -> plan(base) end, 15_000) do
          {:ok, result} -> result
          error -> error
        end
      end

      case RegionData.start_job(state, :dragon_pillars, work,
             supervisor: Valimc.TransferWorkers,
             deadline: 16_000
           ) do
        {:ok, next} -> next
        _ -> %{state | arena_retry: state.game_tick + 20}
      end
    end
  end

  @doc "Ten immutable plans from the same seed context and geometry as world generation."
  def plan(base) do
    spec = Spec.fetch(base)
    {:ok, generation} = Spec.generation(spec, :the_end)

    with {:ok, native} <-
           Generator.worldgen(spec.seed, generation.noise_settings, generation.facts),
         {:ok, plans} <- Valimc.Native.worldgen_end_pillars(native, spec.seed) do
      plans =
        Enum.zip(Fight.spikes(spec.seed), plans)
        |> Map.new(fn {s, build} ->
          clear =
            for z <- (s.z - 10)..(s.z + 10),
                y <- (s.height - 10)..(s.height + 10),
                x <- (s.x - 10)..(s.x + 10),
                into: <<>>,
                do: <<x::signed-32, y::signed-32, z::signed-32, 0::16>>

          {{s.x, s.z}, {clear, build}}
        end)

      {:ok, plans}
    end
  end

  @doc "Decode only the current pillar's bounded intent batch at admission."
  def intents(packed) do
    for <<x::signed-32, y::signed-32, z::signed-32, block::16 <- packed>>,
      do: {{x, y, z}, block, false}
  end

  @doc "The native matched portal's 7×7×5 volume, before the inactive feature."
  def clear_portal(state) do
    {ox, oy, oz} = state.arena.podium
    cells = for z <- -3..3, y <- -1..3, x <- -3..3, do: {ox + x, oy + y, oz + z}
    values = View.blocks(View.new(state.dimension), cells)
    bedrock = Blocks.default_state("bedrock")
    portal = Blocks.default_state("end_portal")
    stone = Blocks.default_state("end_stone")
    for {p, b} <- Enum.zip(cells, values), b in [bedrock, portal], do: {p, stone, false}
  end

  @doc "Crystals intersecting one of the native spike bounding boxes."
  def on_spike?(entity, spikes) do
    Enum.any?(spikes, fn s ->
      entity.x + 1 > s.x - s.radius and entity.x - 1 < s.x + s.radius and
        entity.z + 1 > s.z - s.radius and entity.z - 1 < s.z + s.radius
    end)
  end
end
